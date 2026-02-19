/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * xpt2046.h — SPI XPT2046 touch reader API
 *
 * Only compiled when ENABLE_TOUCH=1.
 * WARNING: SPI0 pins (GPIO 9=MISO, 10=MOSI, 11=SCLK) overlap with the
 * 8-bit parallel data bus (DB0=9, DB2=10, DB1=11).  Touch reads require
 * pausing display writes and reconfiguring the shared GPIO pins.
 */

#ifndef XPT2046_H
#define XPT2046_H

#ifdef ENABLE_TOUCH

#include <stdint.h>

/* Calibration matrix for mapping raw ADC → screen coordinates */
struct touch_cal {
    float ax, bx, cx;  /* x = ax * raw_x + bx * raw_y + cx */
    float ay, by, cy;  /* y = ay * raw_x + by * raw_y + cy */
};

/* Opaque touch reader handle */
struct xpt2046;

/*
 * xpt2046_open() — Open spidev device, configure SPI mode/speed.
 *
 * `spi_device` is e.g. "/dev/spidev0.1"
 * `speed_hz` is SPI clock (e.g. 2000000)
 */
struct xpt2046 *xpt2046_open(const char *spi_device, uint32_t speed_hz);

/*
 * xpt2046_read() — Read current touch position.
 *
 * Applies EWMA filter for noise reduction.
 * Returns 1 if pen is down (valid x/y), 0 if pen up.
 * `x` and `y` are set to calibrated screen coordinates when pen is down.
 */
int xpt2046_read(struct xpt2046 *ts, const struct touch_cal *cal,
                 int *x, int *y);

/*
 * xpt2046_close() — Close SPI device and free.
 */
void xpt2046_close(struct xpt2046 *ts);

#endif /* ENABLE_TOUCH */

#endif /* XPT2046_H */
