// SPDX-License-Identifier: GPL-2.0-only
/*
 * DRM driver for Ilitek ILI9481 display controller
 *
 * Copyright (C) 2026
 *
 * Based on drivers/gpu/drm/tiny/ili9341.c and hx8357d.c
 * Init sequence sourced from TFT_eSPI ILI9481_INIT_1
 *
 * This is an out-of-tree DRM/KMS replacement for the removed fbtft
 * driver.  It uses the MIPI DBI helper and the DRM simple display
 * pipe abstraction to present a /dev/dri/card* device that works
 * with standard KMS clients (Wayland compositors, Plymouth, etc.)
 * as well as the legacy fbdev emulation layer (/dev/fb*).
 *
 * Requirements:
 *   - Kernel >= 6.2 (drm_gem_dma_helper.h, DRM_MIPI_DBI_SIMPLE_DISPLAY_PIPE_FUNCS)
 *   - SPI controller with GPIO chip-select
 *   - DC (data/command) GPIO
 *   - Optional: RESET GPIO, backlight device
 */

#include <linux/backlight.h>
#include <linux/delay.h>
#include <linux/module.h>
#include <linux/property.h>
#include <linux/spi/spi.h>
#include <linux/gpio/consumer.h>

#include <video/mipi_display.h>

#include <drm/drm_atomic_helper.h>
#include <drm/drm_drv.h>
#include <drm/drm_gem_dma_helper.h>

#include <linux/version.h>
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 11, 0)
#include <drm/drm_fbdev_dma.h>
#else
#include <drm/drm_fbdev_generic.h>
#endif
#include <drm/drm_mipi_dbi.h>
#include <drm/drm_modeset_helper.h>
#include <drm/drm_print.h>
#include <drm/drm_framebuffer.h>
#include <drm/drm_fb_dma_helper.h>

/* ILI9481-specific register definitions */
#define ILI9481_PWRSET    0xD0   /* Power Setting */
#define ILI9481_VMCTR     0xD1   /* VCOM Control */
#define ILI9481_PWRNORM   0xD2   /* Power Setting Normal Mode */
#define ILI9481_PANELDRV  0xC0   /* Panel Driving Setting */
#define ILI9481_FRMCTL    0xC5   /* Frame Rate & Inversion Control */
#define ILI9481_GAMSET    0xC8   /* Gamma Setting */
#define ILI9481_CMDPROT   0xB0   /* Command Access Protect */
#define ILI9481_IFCTL     0xC6   /* Interface Control */
#define ILI9481_DISPTIM   0xC1   /* Display Timing for Normal Mode */

static void ili9481_enable(struct drm_simple_display_pipe *pipe,
			   struct drm_crtc_state *crtc_state,
			   struct drm_plane_state *plane_state)
{
	struct mipi_dbi_dev *dbidev = drm_to_mipi_dbi_dev(pipe->crtc.dev);
	struct device *dev = pipe->crtc.dev->dev;
	struct mipi_dbi *dbi = &dbidev->dbi;
	struct drm_framebuffer *fb = plane_state->fb;
	u8 addr_mode;
	int idx, ret;

	if (!drm_dev_enter(pipe->crtc.dev, &idx))
		return;

	dev_info(dev, "ili9481_enable: starting display init (SPI max %u Hz)\n",
		 dbi->spi->max_speed_hz);

	/*
	 * Bypass mipi_dbi_poweron_conditional_reset() entirely.
	 *
	 * That helper tries to detect whether the panel is already
	 * running by reading the power-mode register (0x0A) over SPI.
	 * This fails in two common ways on cheap ILI9481 SPI modules:
	 *
	 *  1. MISO is unconnected → read returns 0xFF → helper thinks
	 *     the display is already alive → returns 1 → init skipped.
	 *
	 *  2. SPI transfer of the NOP verification command fails for
	 *     timing reasons → helper returns -errno → enable aborts
	 *     via goto out_exit → init skipped.
	 *
	 * Both leave the display in its default white state.
	 *
	 * Instead we unconditionally:
	 *   - Toggle the hardware reset GPIO (if present), or
	 *   - Issue a software reset (if no reset GPIO).
	 * Then always run the full init sequence.
	 */
	if (dbi->reset) {
		mipi_dbi_hw_reset(dbi);
		dev_info(dev, "ili9481_enable: hardware reset done\n");
	} else {
		mipi_dbi_command(dbi, MIPI_DCS_SOFT_RESET);
		msleep(150);
		dev_info(dev, "ili9481_enable: software reset done (no reset GPIO)\n");
	}

	/* Exit Sleep Mode — ILI9481 needs ≥120 ms before further cmds */
	mipi_dbi_command(dbi, MIPI_DCS_EXIT_SLEEP_MODE);
	msleep(150);

	/*
	 * Explicitly set operating modes.
	 *
	 * After reset the ILI9481 *should* default to Normal + Non-Idle +
	 * Non-Inverted, but some panel variants (and some SPI modules with
	 * no MISO) end up in an undefined state.  Sending these three
	 * commands is harmless when the defaults are already correct, and
	 * fixes white-screen issues on panels that reset to Partial, Idle,
	 * or Inverted mode.
	 */
	mipi_dbi_command(dbi, MIPI_DCS_EXIT_IDLE_MODE);
	mipi_dbi_command(dbi, MIPI_DCS_ENTER_NORMAL_MODE);
	msleep(5);
	mipi_dbi_command(dbi, MIPI_DCS_EXIT_INVERT_MODE);

	/* Unlock all commands (needed by some ILI9481 panel variants) */
	mipi_dbi_command(dbi, ILI9481_CMDPROT, 0x00);

	/* Power Setting: VCI1=VCI, DDVDH=VCI*2, VGH=VCI*7, VGL=-VCI*4 */
	mipi_dbi_command(dbi, ILI9481_PWRSET, 0x07, 0x42, 0x18);

	/* VCOM Control: VCOMH, VCOML */
	mipi_dbi_command(dbi, ILI9481_VMCTR, 0x00, 0x07, 0x10);

	/* Power Setting for Normal Mode */
	mipi_dbi_command(dbi, ILI9481_PWRNORM, 0x01, 0x02);

	/* Panel Driving Setting */
	mipi_dbi_command(dbi, ILI9481_PANELDRV, 0x10, 0x3B, 0x00, 0x02, 0x11);

	/*
	 * Display Timing Setting for Normal Mode —
	 * Ensures the display controller uses the correct internal clocks
	 * and division ratios for the panel's scan timing.
	 */
	mipi_dbi_command(dbi, ILI9481_DISPTIM, 0x10, 0x10, 0x02, 0x02);

	/* Frame Rate & Inversion Control */
	mipi_dbi_command(dbi, ILI9481_FRMCTL, 0x03);

	/* Interface Control — set DBI type to match our SPI wiring */
	mipi_dbi_command(dbi, ILI9481_IFCTL, 0x02);

	/* Gamma Setting */
	mipi_dbi_command(dbi, ILI9481_GAMSET,
			 0x00, 0x32, 0x36, 0x45, 0x06, 0x16,
			 0x37, 0x75, 0x77, 0x54, 0x0C, 0x00);

	/*
	 * Set rotation via MADCTL — BEFORE Display ON and pixel writes.
	 *
	 * ILI9481 MADCTL bit layout (differs from ILI9341!):
	 *   Bit 5: MV  (Row/Column Exchange)  = 0x20
	 *   Bit 3: BGR (RGB-BGR Order)        = 0x08
	 *   Bit 1: VF  (Vertical Flip)        = 0x02
	 *   Bit 0: HF  (Horizontal Flip)      = 0x01
	 *
	 * Values match the proven fbtft fb_ili9481.c driver.
	 */
	switch (dbidev->rotation) {
	default:
	case 0:
		addr_mode = 0x0A; /* VF | BGR */
		break;
	case 90:
		addr_mode = 0x28; /* MV | BGR */
		break;
	case 180:
		addr_mode = 0x09; /* HF | BGR */
		break;
	case 270:
		addr_mode = 0x2B; /* MV | HF | VF | BGR */
		break;
	}
	mipi_dbi_command(dbi, MIPI_DCS_SET_ADDRESS_MODE, addr_mode);

	/* Interface Pixel Format: RGB565 for both DBI and DPI */
	mipi_dbi_command(dbi, MIPI_DCS_SET_PIXEL_FORMAT, 0x55);

	/*
	 * Set the full-screen GRAM write window explicitly.
	 * Some panels need this before they will accept pixel data.
	 */
	mipi_dbi_command(dbi, MIPI_DCS_SET_COLUMN_ADDRESS,
			 0x00, 0x00,
			 (u8)((ili9481_mode.hdisplay - 1) >> 8),
			 (u8)((ili9481_mode.hdisplay - 1) & 0xFF));
	mipi_dbi_command(dbi, MIPI_DCS_SET_PAGE_ADDRESS,
			 0x00, 0x00,
			 (u8)((ili9481_mode.vdisplay - 1) >> 8),
			 (u8)((ili9481_mode.vdisplay - 1) & 0xFF));

	dev_info(dev, "ili9481_enable: init commands sent (MADCTL=0x%02x), turning display on\n",
		 addr_mode);

	/* Display ON */
	mipi_dbi_command(dbi, MIPI_DCS_SET_DISPLAY_ON);
	msleep(100);

	/*
	 * Log framebuffer state for diagnostics.
	 * If the first bytes are all 0x00, the buffer is black (expected).
	 * If 0xFF, something unexpected is happening.
	 */
	if (fb) {
		struct drm_gem_dma_object *dma_obj;

		dma_obj = drm_fb_dma_get_gem_obj(fb, 0);
		if (dma_obj && dma_obj->vaddr) {
			u8 *p = dma_obj->vaddr;

			dev_info(dev,
				 "ili9481_enable: fb %ux%u fmt=0x%08x first 8 bytes: %02x %02x %02x %02x %02x %02x %02x %02x\n",
				 fb->width, fb->height,
				 fb->format ? fb->format->format : 0,
				 p[0], p[1], p[2], p[3],
				 p[4], p[5], p[6], p[7]);
		} else {
			dev_warn(dev, "ili9481_enable: fb GEM object or vaddr is NULL!\n");
		}
	} else {
		dev_warn(dev, "ili9481_enable: plane_state->fb is NULL!\n");
	}

	dev_info(dev, "ili9481_enable: rotation %u, flushing fb via mipi_dbi_enable_flush\n",
		 dbidev->rotation);

	mipi_dbi_enable_flush(dbidev, crtc_state, plane_state);

	/*
	 * Diagnostic: write 8 red pixels at the top-left corner
	 * directly via the MIPI DBI command interface.
	 *
	 * This bypasses the entire DRM/framebuffer pipeline and tests
	 * whether SPI commands and pixel data actually reach the
	 * ILI9481's GRAM.  If these pixels are visible (even briefly),
	 * SPI communication works and the issue is elsewhere.
	 *
	 * RGB565 red = 0xF800 → sent big-endian on SPI: 0xF8 0x00
	 */
	mipi_dbi_command(dbi, MIPI_DCS_SET_COLUMN_ADDRESS,
			 0x00, 0x00, 0x00, 0x07);
	mipi_dbi_command(dbi, MIPI_DCS_SET_PAGE_ADDRESS,
			 0x00, 0x00, 0x00, 0x00);
	ret = mipi_dbi_command_buf(dbi, MIPI_DCS_WRITE_MEMORY_START,
				   (u8[]){
					   0xF8, 0x00, 0xF8, 0x00,
					   0xF8, 0x00, 0xF8, 0x00,
					   0xF8, 0x00, 0xF8, 0x00,
					   0xF8, 0x00, 0xF8, 0x00,
				   }, 16);
	dev_info(dev,
		 "ili9481_enable: diag pixel write ret=%d (expect 8 red px at 0,0)\n",
		 ret);

	dev_info(dev, "ili9481_enable: display init complete\n");

	drm_dev_exit(idx);
}

static const struct drm_simple_display_pipe_funcs ili9481_pipe_funcs = {
	DRM_MIPI_DBI_SIMPLE_DISPLAY_PIPE_FUNCS(ili9481_enable),
};

static const struct drm_display_mode ili9481_mode = {
	DRM_SIMPLE_MODE(320, 480, 49, 73),
};

DEFINE_DRM_GEM_DMA_FOPS(ili9481_fops);

static const struct drm_driver ili9481_driver = {
	.driver_features	= DRIVER_GEM | DRIVER_MODESET | DRIVER_ATOMIC,
	.fops			= &ili9481_fops,
	DRM_GEM_DMA_DRIVER_OPS_VMAP,
	.debugfs_init		= mipi_dbi_debugfs_init,
	.name			= "ili9481",
	.desc			= "Ilitek ILI9481",
	.date			= "20260217",
	.major			= 1,
	.minor			= 1,
};

static int ili9481_probe(struct spi_device *spi)
{
	struct device *dev = &spi->dev;
	struct mipi_dbi_dev *dbidev;
	struct drm_device *drm;
	struct mipi_dbi *dbi;
	struct gpio_desc *dc;
	u32 rotation = 0;
	int ret;

	dbidev = devm_drm_dev_alloc(dev, &ili9481_driver,
				    struct mipi_dbi_dev, drm);
	if (IS_ERR(dbidev))
		return PTR_ERR(dbidev);

	dbi = &dbidev->dbi;
	drm = &dbidev->drm;

	dbi->reset = devm_gpiod_get_optional(dev, "reset", GPIOD_OUT_HIGH);
	if (IS_ERR(dbi->reset))
		return dev_err_probe(dev, PTR_ERR(dbi->reset),
				     "Failed to get GPIO 'reset'\n");

	dc = devm_gpiod_get_optional(dev, "dc", GPIOD_OUT_LOW);
	if (IS_ERR(dc))
		return dev_err_probe(dev, PTR_ERR(dc),
				     "Failed to get GPIO 'dc'\n");

	dbidev->backlight = devm_of_find_backlight(dev);
	if (IS_ERR(dbidev->backlight))
		return dev_err_probe(dev, PTR_ERR(dbidev->backlight),
				     "Failed to get backlight\n");

	device_property_read_u32(dev, "rotation", &rotation);

	ret = mipi_dbi_spi_init(spi, dbi, dc);
	if (ret)
		return ret;

	ret = mipi_dbi_dev_init(dbidev, &ili9481_pipe_funcs,
				&ili9481_mode, rotation);
	if (ret)
		return ret;

	drm_mode_config_reset(drm);

	ret = drm_dev_register(drm, 0);
	if (ret)
		return ret;

	spi_set_drvdata(spi, drm);

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 11, 0)
	drm_fbdev_dma_setup(drm, 16);   /* 16 bpp = RGB565 — must match pixel format */
#else
	drm_fbdev_generic_setup(drm, 16);
#endif

	dev_info(dev, "ILI9481 display registered (%ux%u, rotation %u°)\n",
		 ili9481_mode.hdisplay, ili9481_mode.vdisplay, rotation);

	return 0;
}

static void ili9481_remove(struct spi_device *spi)
{
	struct drm_device *drm = spi_get_drvdata(spi);

	drm_dev_unplug(drm);
	drm_atomic_helper_shutdown(drm);
	dev_info(&spi->dev, "ILI9481 display removed\n");
}

static void ili9481_shutdown(struct spi_device *spi)
{
	drm_atomic_helper_shutdown(spi_get_drvdata(spi));
}

static const struct of_device_id ili9481_of_match[] = {
	{ .compatible = "ilitek,ili9481" },
	{ }
};
MODULE_DEVICE_TABLE(of, ili9481_of_match);

static const struct spi_device_id ili9481_id[] = {
	{ "ili9481", 0 },
	{ }
};
MODULE_DEVICE_TABLE(spi, ili9481_id);

static struct spi_driver ili9481_spi_driver = {
	.driver = {
		.name		= "ili9481",
		.of_match_table	= ili9481_of_match,
	},
	.id_table	= ili9481_id,
	.probe		= ili9481_probe,
	.remove		= ili9481_remove,
	.shutdown	= ili9481_shutdown,
};
module_spi_driver(ili9481_spi_driver);

MODULE_DESCRIPTION("DRM driver for Ilitek ILI9481 display controller");
MODULE_AUTHOR("ScreenDriver Project");
MODULE_LICENSE("GPL");
