/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * xpt2046.c — SPI XPT2046 touch reader with median + EWMA filtering
 *
 * Improvements over naive implementation:
 *   - 7-sample median filter (rejects outlier spikes)
 *   - Settling reads discarded after pressure detection
 *   - Dual-pass pressure validation (before and after XY read)
 *   - Adaptive EWMA: fast initial lock-on, smooth tracking
 *   - Pen-down debounce: require consecutive pen-down reads
 *
 * Only compiled when ENABLE_TOUCH=1.
 */

#ifdef ENABLE_TOUCH

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <linux/spi/spidev.h>

#include "xpt2046.h"
#include "../core/logging.h"

/* ------------------------------------------------------------------ */
/* Constants                                                          */
/* ------------------------------------------------------------------ */

/* XPT2046 control bytes */
#define XPT_CMD_X      0xD0    /* Differential X measurement, 12-bit */
#define XPT_CMD_Y      0x90    /* Differential Y measurement, 12-bit */
#define XPT_CMD_Z1     0xB0    /* Z1 pressure */
#define XPT_CMD_Z2     0xC0    /* Z2 pressure */

/* Pressure threshold to consider pen as down */
#define PRESSURE_MIN   100

/* Number of samples for median filtering (must be odd) */
#define MEDIAN_SAMPLES 7

/* Number of settling reads to discard after pen-down detection */
#define SETTLE_READS   2

/* Consecutive pen-down reads required before reporting touch */
#define DEBOUNCE_COUNT 2

/* EWMA smoothing factor (0.0–1.0, higher = more responsive, noisier) */
#define EWMA_ALPHA         0.40f   /* steady-state tracking */
#define EWMA_ALPHA_INITIAL 0.85f   /* fast lock-on for first few samples */
#define EWMA_LOCK_SAMPLES  3       /* how many samples use initial alpha */

/* Maximum jump (in raw ADC units) before we reset the filter */
#define JUMP_THRESHOLD     300

/* ------------------------------------------------------------------ */
/* Internal state                                                     */
/* ------------------------------------------------------------------ */

struct xpt2046 {
    int         fd;
    uint32_t    speed_hz;
    uint8_t     mode;
    uint8_t     bits;

    /* EWMA filter state */
    float       filt_x;
    float       filt_y;
    int         sample_count;   /* 0 = first sample after pen-up */

    /* Debounce state */
    int         pen_down_count; /* consecutive pen-down reads */

    /* Last reported position (for jump detection) */
    float       last_raw_x;
    float       last_raw_y;
};

/* ------------------------------------------------------------------ */
/* SPI transfer helper                                                */
/* ------------------------------------------------------------------ */

static uint16_t spi_read_channel(struct xpt2046 *ts, uint8_t cmd)
{
    uint8_t tx[3] = { cmd, 0x00, 0x00 };
    uint8_t rx[3] = { 0 };

    struct spi_ioc_transfer xfer = {
        .tx_buf        = (unsigned long)tx,
        .rx_buf        = (unsigned long)rx,
        .len           = 3,
        .speed_hz      = ts->speed_hz,
        .bits_per_word = ts->bits,
        .delay_usecs   = 0,
    };

    if (ioctl(ts->fd, SPI_IOC_MESSAGE(1), &xfer) < 0)
        return 0;

    /* 12-bit result is in rx[1] (bits 7..0) and rx[2] (bits 7..4) */
    return (uint16_t)(((rx[1] << 8) | rx[2]) >> 3) & 0x0FFF;
}

/* ------------------------------------------------------------------ */
/* Median helper: insertion sort + pick middle                        */
/* ------------------------------------------------------------------ */

static int cmp_u16(const void *a, const void *b)
{
    uint16_t va = *(const uint16_t *)a;
    uint16_t vb = *(const uint16_t *)b;
    return (va > vb) - (va < vb);
}

static uint16_t median_of(uint16_t *arr, int n)
{
    qsort(arr, n, sizeof(uint16_t), cmp_u16);
    return arr[n / 2];
}

/* ------------------------------------------------------------------ */
/* Pressure reading with validation                                   */
/* ------------------------------------------------------------------ */

static int read_pressure(struct xpt2046 *ts)
{
    uint16_t z1 = spi_read_channel(ts, XPT_CMD_Z1);
    uint16_t z2 = spi_read_channel(ts, XPT_CMD_Z2);

    if (z1 == 0)
        return 0;

    return (int)z1 - (int)z2 + 4095;
}

/* ------------------------------------------------------------------ */
/* Public API                                                         */
/* ------------------------------------------------------------------ */

struct xpt2046 *xpt2046_open(const char *spi_device, uint32_t speed_hz)
{
    struct xpt2046 *ts = calloc(1, sizeof(*ts));
    if (!ts)
        return NULL;

    ts->fd = open(spi_device, O_RDWR);
    if (ts->fd < 0) {
        log_error("Cannot open %s: %s", spi_device, strerror(errno));
        free(ts);
        return NULL;
    }

    ts->speed_hz = speed_hz;
    ts->mode = SPI_MODE_0;
    ts->bits = 8;

    if (ioctl(ts->fd, SPI_IOC_WR_MODE, &ts->mode) < 0 ||
        ioctl(ts->fd, SPI_IOC_WR_BITS_PER_WORD, &ts->bits) < 0 ||
        ioctl(ts->fd, SPI_IOC_WR_MAX_SPEED_HZ, &ts->speed_hz) < 0) {
        log_error("SPI configuration failed: %s", strerror(errno));
        close(ts->fd);
        free(ts);
        return NULL;
    }

    log_info("XPT2046 opened on %s @ %u Hz", spi_device, speed_hz);
    return ts;
}

int xpt2046_read(struct xpt2046 *ts, const struct touch_cal *cal,
                 int *x, int *y)
{
    if (!ts)
        return 0;

    /* ── Step 1: Read pressure (pen-down detection) ── */
    int pressure = read_pressure(ts);

    if (pressure < PRESSURE_MIN) {
        ts->sample_count = 0;
        ts->pen_down_count = 0;
        return 0; /* pen up */
    }

    /* ── Step 2: Pen-down debounce ── */
    ts->pen_down_count++;
    if (ts->pen_down_count < DEBOUNCE_COUNT) {
        return 0; /* not enough consecutive reads yet */
    }

    /* ── Step 3: Settling reads (discard noisy initial reads) ── */
    if (ts->pen_down_count <= DEBOUNCE_COUNT + SETTLE_READS) {
        /* Read and discard to let the ADC settle */
        (void)spi_read_channel(ts, XPT_CMD_X);
        (void)spi_read_channel(ts, XPT_CMD_Y);
        return 0;
    }

    /* ── Step 4: Multi-sample with median filtering ── */
    uint16_t samples_x[MEDIAN_SAMPLES];
    uint16_t samples_y[MEDIAN_SAMPLES];

    for (int i = 0; i < MEDIAN_SAMPLES; i++) {
        samples_x[i] = spi_read_channel(ts, XPT_CMD_X);
        samples_y[i] = spi_read_channel(ts, XPT_CMD_Y);
    }

    float raw_x = (float)median_of(samples_x, MEDIAN_SAMPLES);
    float raw_y = (float)median_of(samples_y, MEDIAN_SAMPLES);

    /* ── Step 5: Validate pressure again (pen may have lifted) ── */
    int pressure2 = read_pressure(ts);
    if (pressure2 < PRESSURE_MIN) {
        ts->sample_count = 0;
        ts->pen_down_count = 0;
        return 0; /* pen lifted during read */
    }

    /* ── Step 6: Jump detection — reset filter on large jumps ── */
    if (ts->sample_count > 0) {
        float dx = raw_x - ts->last_raw_x;
        float dy = raw_y - ts->last_raw_y;
        if (dx * dx + dy * dy > (float)JUMP_THRESHOLD * JUMP_THRESHOLD) {
            /* Large jump: likely noise or intentional fast move.
             * Reset filter to avoid lagging towards the old position. */
            ts->sample_count = 0;
        }
    }
    ts->last_raw_x = raw_x;
    ts->last_raw_y = raw_y;

    /* ── Step 7: Adaptive EWMA filter ── */
    if (ts->sample_count == 0) {
        /* First sample after pen-down or jump: snap to position */
        ts->filt_x = raw_x;
        ts->filt_y = raw_y;
        ts->sample_count = 1;
    } else {
        float alpha;
        if (ts->sample_count < EWMA_LOCK_SAMPLES)
            alpha = EWMA_ALPHA_INITIAL;  /* fast lock-on */
        else
            alpha = EWMA_ALPHA;          /* steady tracking */

        ts->filt_x = alpha * raw_x + (1.0f - alpha) * ts->filt_x;
        ts->filt_y = alpha * raw_y + (1.0f - alpha) * ts->filt_y;
        ts->sample_count++;
    }

    /* ── Step 8: Apply calibration matrix ── */
    *x = (int)(cal->ax * ts->filt_x + cal->bx * ts->filt_y + cal->cx);
    *y = (int)(cal->ay * ts->filt_x + cal->by * ts->filt_y + cal->cy);

    return 1; /* pen down */
}

void xpt2046_close(struct xpt2046 *ts)
{
    if (!ts)
        return;
    if (ts->fd >= 0)
        close(ts->fd);
    free(ts);
}

#endif /* ENABLE_TOUCH */
