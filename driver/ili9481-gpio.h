/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * ili9481-gpio.h — ILI9481 register definitions and initialization table
 *
 * For use with the self-contained ili9481-gpio kernel framebuffer driver.
 */

#ifndef ILI9481_GPIO_H
#define ILI9481_GPIO_H

#include <linux/types.h>

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
/* Initialization command table                                       */
/* ------------------------------------------------------------------ */

/**
 * struct ili9481_reg_cmd - one step of the ILI9481 init sequence
 * @cmd:      command register to write
 * @len:      number of data bytes that follow the command (0–12)
 * @data:     parameter bytes
 * @delay_ms: milliseconds to sleep after this command (0 = none)
 */
struct ili9481_reg_cmd {
	u8  cmd;
	u8  len;
	u8  data[12];
	u16 delay_ms;
};

/*
 * Standard ILI9481 initialisation sequence.
 * Based on the ILI9481 datasheet and the fbtft fb_ili9481 driver.
 * MADCTL is NOT included — it is written separately based on rotation.
 */
static const struct ili9481_reg_cmd ili9481_init_cmds[] = {
	/* Software reset */
	{ ILI9481_SWRESET,  0, {}, 50 },

	/* Exit sleep */
	{ ILI9481_SLPOUT,   0, {}, 20 },

	/* Power setting */
	{ ILI9481_PWRSET,   3, { 0x07, 0x42, 0x18 }, 0 },

	/* VCOM control */
	{ ILI9481_VMCTR,    3, { 0x00, 0x07, 0x10 }, 0 },

	/* Power setting for normal mode */
	{ ILI9481_PWRNORM,  2, { 0x01, 0x02 }, 0 },

	/* Panel driving setting */
	{ ILI9481_PANELDRV, 5, { 0x10, 0x3B, 0x00, 0x02, 0x11 }, 0 },

	/* Frame rate / inversion control */
	{ ILI9481_FRMCTR,   1, { 0x03 }, 0 },

	/* Gamma setting (12 bytes) */
	{ ILI9481_GAMMASET, 12, { 0x00, 0x32, 0x36, 0x45, 0x06, 0x16,
				   0x37, 0x75, 0x77, 0x54, 0x0C, 0x00 }, 0 },

	/* Pixel format — 16-bit RGB565 */
	{ ILI9481_COLMOD,   1, { ILI9481_COLMOD_16BIT }, 0 },

	/* Display on */
	{ ILI9481_DISPON,   0, {}, 25 },
};

#define ILI9481_INIT_CMD_COUNT  ARRAY_SIZE(ili9481_init_cmds)

/* ------------------------------------------------------------------ */
/* Helper: choose MADCTL byte for a given rotation angle              */
/* ------------------------------------------------------------------ */

static inline u8 ili9481_madctl_for_rotate(u32 rotate)
{
	switch (rotate) {
	case 0:   return ILI9481_MADCTL_0;
	case 90:  return ILI9481_MADCTL_90;
	case 180: return ILI9481_MADCTL_180;
	case 270: return ILI9481_MADCTL_270;
	default:  return ILI9481_MADCTL_270;
	}
}

#endif /* ILI9481_GPIO_H */
