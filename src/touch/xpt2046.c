/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * xpt2046.c — SPI XPT2046 touch reader with EWMA filtering
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
#define PRESSURE_MIN   50

/* EWMA smoothing factor (0.0–1.0, higher = more responsive, noisier) */
#define EWMA_ALPHA     0.3f

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
    int         has_prev;   /* 0 = first sample after pen-up */
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

    /* Read pressure to determine if pen is down */
    uint16_t z1 = spi_read_channel(ts, XPT_CMD_Z1);
    uint16_t z2 = spi_read_channel(ts, XPT_CMD_Z2);

    int pressure = 0;
    if (z1 > 0)
        pressure = (int)z1 - (int)z2 + 4095;

    if (pressure < PRESSURE_MIN) {
        ts->has_prev = 0;
        return 0; /* pen up */
    }

    /* Read raw X/Y (multi-sample for noise reduction) */
    uint32_t sum_x = 0, sum_y = 0;
    for (int i = 0; i < 3; i++) {
        sum_x += spi_read_channel(ts, XPT_CMD_X);
        sum_y += spi_read_channel(ts, XPT_CMD_Y);
    }
    float raw_x = sum_x / 3.0f;
    float raw_y = sum_y / 3.0f;

    /* EWMA filter */
    if (!ts->has_prev) {
        ts->filt_x = raw_x;
        ts->filt_y = raw_y;
        ts->has_prev = 1;
    } else {
        ts->filt_x = EWMA_ALPHA * raw_x + (1.0f - EWMA_ALPHA) * ts->filt_x;
        ts->filt_y = EWMA_ALPHA * raw_y + (1.0f - EWMA_ALPHA) * ts->filt_y;
    }

    /* Apply calibration matrix */
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
