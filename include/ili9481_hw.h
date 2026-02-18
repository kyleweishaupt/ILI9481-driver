/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * ili9481_hw.h — ILI9481 register definitions, MADCTL values, and GPIO pin
 *                constants for the userspace framebuffer daemon.
 *
 * Pin mapping for 26-pin Inland / Kuman / MCUfriend 3.5" TFT shields.
 * The ILI9481 IM strapping pins are set for 8-bit 8080-I mode on these
 * boards (only 17 GPIOs available on the 26-pin header).  Each pixel is
 * written as two sequential 8-bit bus cycles in RGB565 format.
 */

#ifndef ILI9481_HW_H
#define ILI9481_HW_H

#include <stdint.h>

/* ------------------------------------------------------------------ */
/* ILI9481 command register addresses                                 */
/* ------------------------------------------------------------------ */

#define ILI9481_NOP             0x00
#define ILI9481_SWRESET         0x01
#define ILI9481_RDDID           0x04
#define ILI9481_SLPIN           0x10
#define ILI9481_SLPOUT          0x11
#define ILI9481_PTLON           0x12
#define ILI9481_NORON           0x13
#define ILI9481_INVOFF          0x20
#define ILI9481_INVON           0x21
#define ILI9481_DISPOFF         0x28
#define ILI9481_DISPON          0x29
#define ILI9481_CASET           0x2A
#define ILI9481_PASET           0x2B
#define ILI9481_RAMWR           0x2C
#define ILI9481_MADCTL          0x36
#define ILI9481_COLMOD          0x3A

#define ILI9481_PWRSET          0xD0
#define ILI9481_VMCTR           0xD1
#define ILI9481_PWRNORM         0xD2
#define ILI9481_PANELDRV        0xC0
#define ILI9481_FRMCTR          0xC5
#define ILI9481_GAMMASET        0xC8

/* ------------------------------------------------------------------ */
/* Pixel format                                                       */
/* ------------------------------------------------------------------ */

#define ILI9481_COLMOD_12BIT    0x03    /* 12-bit/pixel RGB444 (unused)  */
#define ILI9481_COLMOD_16BIT    0x55    /* 16-bit/pixel RGB565           */

/* ------------------------------------------------------------------ */
/* MADCTL rotation values                                             */
/*                                                                    */
/*   Bit 7: MY  (row address order)                                   */
/*   Bit 6: MX  (column address order)                                */
/*   Bit 5: MV  (row/column exchange)                                 */
/*   Bit 3: BGR (colour order)                                        */
/*                                                                    */
/* Values sourced from the fbtft fb_ili9481 driver.                   */
/* ------------------------------------------------------------------ */

#define ILI9481_MADCTL_0        0x0A    /*   0°  portrait  320×480 */
#define ILI9481_MADCTL_90       0xE8    /*  90°  landscape 480×320 */
#define ILI9481_MADCTL_180      0xCA    /* 180°  portrait  320×480 */
#define ILI9481_MADCTL_270      0x28    /* 270°  landscape 480×320 */

/* ------------------------------------------------------------------ */
/* Native panel resolution                                            */
/* ------------------------------------------------------------------ */

#define ILI9481_WIDTH           320
#define ILI9481_HEIGHT          480

/* ------------------------------------------------------------------ */
/* GPIO pin mapping (BCM numbering) — 26-pin header                   */
/*                                                                    */
/* Inland / Kuman / MCUfriend / Banggood 3.5" TFT shields piggyback  */
/* on pins 1–26 of the Pi 40-pin header (the original 26-pin layout). */
/* ILI9481 IM pins are strapped for 8-bit 8080-I mode.  Only DB0–DB7  */
/* are used; GPIO 14, 15, 2, 7 are left free for UART/I2C/SPI.        */
/* ------------------------------------------------------------------ */

/* Control pins */
#define GPIO_RST        25      /* Pin 22 — active-low hardware reset */
#define GPIO_CS          8      /* Pin 24 — active-low chip select    */
#define GPIO_DC         24      /* Pin 18 — register select (RS/DC)   */
#define GPIO_WR         23      /* Pin 16 — active-low write strobe   */
#define GPIO_RD         18      /* Pin 12 — active-low read (unused, held HIGH) */

/* 8-bit data bus: DB0–DB7 */
#define GPIO_DB0         9      /* Pin 21 */
#define GPIO_DB1        11      /* Pin 23 */
#define GPIO_DB2        10      /* Pin 19 */
#define GPIO_DB3        22      /* Pin 15 */
#define GPIO_DB4        27      /* Pin 13 */
#define GPIO_DB5        17      /* Pin 11 */
#define GPIO_DB6         4      /* Pin  7 */
#define GPIO_DB7         3      /* Pin  5 */

/* Number of data bus pins (8-bit mode) */
#define DATA_BUS_WIDTH  8

/* Data bus pins as an array initialiser */
#define DATA_BUS_PINS \
    { GPIO_DB0, GPIO_DB1, GPIO_DB2, GPIO_DB3, \
      GPIO_DB4, GPIO_DB5, GPIO_DB6, GPIO_DB7 }

/* ------------------------------------------------------------------ */
/* BCM2835 GPIO register offsets (word index into the mmap'd region)  */
/* ------------------------------------------------------------------ */

#define GPFSEL0         (0x00 / 4)
#define GPSET0          (0x1C / 4)
#define GPCLR0          (0x28 / 4)
#define GPLEV0          (0x34 / 4)

#endif /* ILI9481_HW_H */
