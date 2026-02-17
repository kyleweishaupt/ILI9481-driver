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
#include <drm/drm_fbdev_generic.h>
#include <drm/drm_gem_dma_helper.h>
#include <drm/drm_mipi_dbi.h>
#include <drm/drm_modeset_helper.h>
#include <drm/drm_print.h>

/* ILI9481-specific register definitions */
#define ILI9481_PWRSET    0xD0   /* Power Setting */
#define ILI9481_VMCTR     0xD1   /* VCOM Control */
#define ILI9481_PWRNORM   0xD2   /* Power Setting Normal Mode */
#define ILI9481_PANELDRV  0xC0   /* Panel Driving Setting */
#define ILI9481_FRMCTL    0xC5   /* Frame Rate & Inversion Control */
#define ILI9481_GAMSET    0xC8   /* Gamma Setting */

static void ili9481_enable(struct drm_simple_display_pipe *pipe,
			   struct drm_crtc_state *crtc_state,
			   struct drm_plane_state *plane_state)
{
	struct mipi_dbi_dev *dbidev = drm_to_mipi_dbi_dev(pipe->crtc.dev);
	struct mipi_dbi *dbi = &dbidev->dbi;
	u8 addr_mode;
	int ret, idx;

	if (!drm_dev_enter(pipe->crtc.dev, &idx))
		return;

	drm_dbg_driver(pipe->crtc.dev, "Initialising ILI9481 display\n");

	ret = mipi_dbi_poweron_conditional_reset(dbidev);
	if (ret < 0) {
		drm_err(pipe->crtc.dev, "Failed to reset display: %d\n", ret);
		goto out_exit;
	}
	if (ret == 1)
		goto out_enable;

	/* Exit Sleep Mode */
	mipi_dbi_command(dbi, MIPI_DCS_EXIT_SLEEP_MODE);
	msleep(20);

	/* Power Setting: VCI1=VCI, DDVDH=VCI*2, VGH=VCI*7, VGL=-VCI*4 */
	mipi_dbi_command(dbi, ILI9481_PWRSET, 0x07, 0x42, 0x18);

	/* VCOM Control: VCOMH, VCOML */
	mipi_dbi_command(dbi, ILI9481_VMCTR, 0x00, 0x07, 0x10);

	/* Power Setting for Normal Mode */
	mipi_dbi_command(dbi, ILI9481_PWRNORM, 0x01, 0x02);

	/* Panel Driving Setting */
	mipi_dbi_command(dbi, ILI9481_PANELDRV, 0x10, 0x3B, 0x00, 0x02, 0x11);

	/* Frame Rate & Inversion Control */
	mipi_dbi_command(dbi, ILI9481_FRMCTL, 0x03);

	/* Gamma Setting */
	mipi_dbi_command(dbi, ILI9481_GAMSET,
			 0x00, 0x32, 0x36, 0x45, 0x06, 0x16,
			 0x37, 0x75, 0x77, 0x54, 0x0C, 0x00);

	/* Interface Pixel Format: RGB565 for both DBI and DPI */
	mipi_dbi_command(dbi, MIPI_DCS_SET_PIXEL_FORMAT, 0x55);

	/* Enter Inversion Mode (required for correct colors on SPI) */
	mipi_dbi_command(dbi, MIPI_DCS_ENTER_INVERT_MODE);

	/* Column Address Set: 0x0000 - 0x013F (0 - 319) */
	mipi_dbi_command(dbi, MIPI_DCS_SET_COLUMN_ADDRESS,
			 0x00, 0x00, 0x01, 0x3F);

	/* Page Address Set: 0x0000 - 0x01DF (0 - 479) */
	mipi_dbi_command(dbi, MIPI_DCS_SET_PAGE_ADDRESS,
			 0x00, 0x00, 0x01, 0xDF);

	msleep(120);

	/* Display ON */
	mipi_dbi_command(dbi, MIPI_DCS_SET_DISPLAY_ON);
	msleep(25);

out_enable:
	/* Set rotation via MADCTL */
	switch (dbidev->rotation) {
	default:
	case 0:
		addr_mode = 0x48; /* MX | BGR */
		break;
	case 90:
		addr_mode = 0x28; /* MV | BGR */
		break;
	case 180:
		addr_mode = 0x88; /* MY | BGR */
		break;
	case 270:
		addr_mode = 0xE8; /* MY | MX | MV | BGR */
		break;
	}
	mipi_dbi_command(dbi, MIPI_DCS_SET_ADDRESS_MODE, addr_mode);
	drm_dbg_driver(pipe->crtc.dev,
		       "Rotation %u°, MADCTL=0x%02x\n",
		       dbidev->rotation, addr_mode);

	mipi_dbi_enable_flush(dbidev, crtc_state, plane_state);

out_exit:
	drm_dev_exit(idx);
}

static const struct drm_simple_display_pipe_funcs ili9481_pipe_funcs = {
	DRM_MIPI_DBI_SIMPLE_DISPLAY_PIPE_FUNCS(ili9481_enable),
};

static const struct drm_display_mode ili9481_mode = {
	DRM_SIMPLE_MODE(480, 320, 73, 49),
};

DEFINE_DRM_GEM_DMA_FOPS(ili9481_fops);

static const struct drm_driver ili9481_driver = {
	.driver_features	= DRIVER_GEM | DRIVER_MODESET | DRIVER_ATOMIC,
	.fops			= &ili9481_fops,
	DRM_GEM_DMA_DRIVER_OPS_VMAP,
	.debugfs_init		= mipi_dbi_debugfs_init,
	.name			= "ili9481",
	.desc			= "Ilitek ILI9481",
	.date			= "20260216",
	.major			= 1,
	.minor			= 0,
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

	drm_fbdev_generic_setup(drm, 0);

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
