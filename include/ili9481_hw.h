/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * ili9481_hw.h — ILI9481 register definitions, MADCTL values, and GPIO pin
 *                constants for the userspace framebuffer daemon.
 *
 * Ported from driver/ili9481-gpio.h (kernel module).
 * Uses <stdint.h> types instead of <linux/types.h>.
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

#define ILI9481_COLMOD_16BIT    0x55    /* 16-bit/pixel RGB565 */

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
/* GPIO pin mapping (BCM numbering)                                   */
/*                                                                    */
/* Source: driver/dts/inland-ili9481.dts (authoritative)              */
/* ------------------------------------------------------------------ */

/* Control pins */
#define GPIO_RST        27
#define GPIO_DC         22
#define GPIO_WR         17

/* 16-bit data bus: DB0–DB15 */
#define GPIO_DB0         7
#define GPIO_DB1         8
#define GPIO_DB2        25
#define GPIO_DB3        24
#define GPIO_DB4        23
#define GPIO_DB5        18
#define GPIO_DB6        15
#define GPIO_DB7        14
#define GPIO_DB8        12
#define GPIO_DB9        16
#define GPIO_DB10       20
#define GPIO_DB11       21
#define GPIO_DB12        5
#define GPIO_DB13        6
#define GPIO_DB14       13
#define GPIO_DB15       19

/* Number of data bus pins */
#define DATA_BUS_WIDTH  16

/* All data bus pins as an array initialiser */
#define DATA_BUS_PINS \
    { GPIO_DB0,  GPIO_DB1,  GPIO_DB2,  GPIO_DB3,  \
      GPIO_DB4,  GPIO_DB5,  GPIO_DB6,  GPIO_DB7,  \
      GPIO_DB8,  GPIO_DB9,  GPIO_DB10, GPIO_DB11, \
      GPIO_DB12, GPIO_DB13, GPIO_DB14, GPIO_DB15 }

/* ------------------------------------------------------------------ */
/* BCM2835 GPIO register offsets (word index into the mmap'd region)  */
/* ------------------------------------------------------------------ */

#define GPFSEL0         (0x00 / 4)
#define GPSET0          (0x1C / 4)
#define GPCLR0          (0x28 / 4)
#define GPLEV0          (0x34 / 4)

#endif /* ILI9481_HW_H */
