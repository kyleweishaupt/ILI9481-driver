// SPDX-License-Identifier: GPL-2.0-only
/*
 * ili9481-gpio.c — Self-contained ILI9481 16-bit parallel GPIO framebuffer driver
 *
 * Drives Inland TFT35 (and compatible Kedei-style) 320×480 shields that use a
 * 16-bit 8080-parallel bus over Raspberry Pi GPIO, with 74HC245 level shifters.
 *
 * Designed for kernel 6.12+ — uses gpiod descriptor API, deferred fb IO, and
 * the modern platform-driver remove (void return) convention.
 *
 * Bind via device-tree: compatible = "inland,ili9481-gpio";
 *
 * Copyright 2025  ILI9481-driver contributors
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/platform_device.h>
#include <linux/of.h>
#include <linux/fb.h>
#include <linux/gpio/consumer.h>
#include <linux/delay.h>
#include <linux/vmalloc.h>
#include <linux/mm.h>
#include <linux/slab.h>
#include <linux/workqueue.h>
#include <linux/version.h>

#include "ili9481-gpio.h"

#define DRIVER_NAME	"ili9481-gpio"
#define DRIVER_DESC	"ILI9481 16-bit parallel GPIO framebuffer"

/* ================================================================== */
/* Private state                                                      */
/* ================================================================== */

struct ili9481_priv {
	struct fb_info		*info;
	struct device		*dev;
	struct gpio_descs	*data_gpios;	/* DB0–DB15 (16 pins)  */
	struct gpio_desc	*dc_gpio;	/* RS / DC             */
	struct gpio_desc	*wr_gpio;	/* /WR  (write strobe) */
	struct gpio_desc	*rst_gpio;	/* /RST (optional)     */
	u32			 width;
	u32			 height;
	u32			 rotate;
	u32			 fps;
};

/* ================================================================== */
/* GPIO bit-bang write helpers                                        */
/* ================================================================== */

/*
 * Write a raw 16-bit value onto DB0–DB15 and pulse /WR.
 *
 * 8080-style timing (active-low WR in DTS):
 *   1.  Place data on bus
 *   2.  Assert /WR  (gpiod logical 1 → pin LOW)
 *   3.  Hold ≥ 15 ns  (ILI9481 tWRL)
 *   4.  De-assert /WR (gpiod logical 0 → pin HIGH, rising edge latches data)
 */
static inline void ili9481_write16(struct ili9481_priv *par, u16 val)
{
	DECLARE_BITMAP(bits, 16);

	bits[0] = val;

	gpiod_set_array_value(par->data_gpios->ndescs,
			      par->data_gpios->desc,
			      par->data_gpios->info,
			      bits);

	gpiod_set_value(par->wr_gpio, 1);	/* /WR LOW  (assert)   */
	ndelay(15);
	gpiod_set_value(par->wr_gpio, 0);	/* /WR HIGH (latch)    */
}

/* Send a command byte (DC low, 8-bit zero-extended to 16 bits). */
static void ili9481_write_cmd(struct ili9481_priv *par, u8 cmd)
{
	gpiod_set_value(par->dc_gpio, 0);	/* command mode */
	ili9481_write16(par, cmd);
	gpiod_set_value(par->dc_gpio, 1);	/* back to data mode */
}

/* Send an 8-bit data/parameter byte (DC high). */
static void ili9481_write_data(struct ili9481_priv *par, u8 data)
{
	ili9481_write16(par, data);
}

/* Send a 16-bit pixel value (DC high). */
static void ili9481_write_pixel(struct ili9481_priv *par, u16 pixel)
{
	ili9481_write16(par, pixel);
}

/* ================================================================== */
/* Hardware reset and initialisation                                  */
/* ================================================================== */

static void ili9481_hw_reset(struct ili9481_priv *par)
{
	if (!par->rst_gpio)
		return;

	gpiod_set_value(par->rst_gpio, 1);	/* assert reset  */
	msleep(20);
	gpiod_set_value(par->rst_gpio, 0);	/* release reset */
	msleep(20);
}

static void ili9481_init_display(struct ili9481_priv *par)
{
	unsigned int i, j;

	ili9481_hw_reset(par);

	for (i = 0; i < ILI9481_INIT_CMD_COUNT; i++) {
		const struct ili9481_reg_cmd *c = &ili9481_init_cmds[i];

		ili9481_write_cmd(par, c->cmd);
		for (j = 0; j < c->len; j++)
			ili9481_write_data(par, c->data[j]);
		if (c->delay_ms)
			msleep(c->delay_ms);
	}

	/* Apply rotation */
	ili9481_write_cmd(par, ILI9481_MADCTL);
	ili9481_write_data(par, ili9481_madctl_for_rotate(par->rotate));
}

/* ================================================================== */
/* Framebuffer flush (deferred-IO callback)                           */
/* ================================================================== */

static void ili9481_flush(struct fb_info *info,
			  struct list_head *pagereflist)
{
	struct ili9481_priv *par = info->par;
	u16 *vmem = (u16 *)info->screen_buffer;
	unsigned int npixels, i;

	/* Column address range — full width */
	ili9481_write_cmd(par, ILI9481_CASET);
	ili9481_write_data(par, 0x00);
	ili9481_write_data(par, 0x00);
	ili9481_write_data(par, (par->width - 1) >> 8);
	ili9481_write_data(par, (par->width - 1) & 0xFF);

	/* Page (row) address range — full height */
	ili9481_write_cmd(par, ILI9481_PASET);
	ili9481_write_data(par, 0x00);
	ili9481_write_data(par, 0x00);
	ili9481_write_data(par, (par->height - 1) >> 8);
	ili9481_write_data(par, (par->height - 1) & 0xFF);

	/* Begin memory write and stream every pixel */
	ili9481_write_cmd(par, ILI9481_RAMWR);

	npixels = par->width * par->height;
	for (i = 0; i < npixels; i++)
		ili9481_write_pixel(par, vmem[i]);
}

/* ================================================================== */
/* fb_ops wrappers — schedule deferred IO after every draw path       */
/* ================================================================== */

static ssize_t ili9481_fb_write(struct fb_info *info,
				const char __user *buf,
				size_t count, loff_t *ppos)
{
	ssize_t ret = fb_sys_write(info, buf, count, ppos);

	if (ret > 0)
		schedule_delayed_work(&info->deferred_work,
				      info->fbdefio->delay);
	return ret;
}

static void ili9481_fb_fillrect(struct fb_info *info,
				const struct fb_fillrect *rect)
{
	sys_fillrect(info, rect);
	schedule_delayed_work(&info->deferred_work, info->fbdefio->delay);
}

static void ili9481_fb_copyarea(struct fb_info *info,
				const struct fb_copyarea *area)
{
	sys_copyarea(info, area);
	schedule_delayed_work(&info->deferred_work, info->fbdefio->delay);
}

static void ili9481_fb_imageblit(struct fb_info *info,
				 const struct fb_image *image)
{
	sys_imageblit(info, image);
	schedule_delayed_work(&info->deferred_work, info->fbdefio->delay);
}

/* ================================================================== */
/* fb_check_var / fb_set_par / fb_setcolreg                           */
/* ================================================================== */

static int ili9481_fb_check_var(struct fb_var_screeninfo *var,
				struct fb_info *info)
{
	if (var->bits_per_pixel != 16)
		return -EINVAL;

	var->red.offset    = 11;  var->red.length    = 5;
	var->green.offset  = 5;   var->green.length  = 6;
	var->blue.offset   = 0;   var->blue.length   = 5;
	var->transp.offset = 0;   var->transp.length = 0;

	var->xres          = info->var.xres;
	var->yres          = info->var.yres;
	var->xres_virtual  = var->xres;
	var->yres_virtual  = var->yres;

	return 0;
}

static int ili9481_fb_set_par(struct fb_info *info)
{
	/* Fixed-mode display — nothing to reconfigure. */
	return 0;
}

static int ili9481_fb_setcolreg(unsigned int regno,
				unsigned int red, unsigned int green,
				unsigned int blue, unsigned int transp,
				struct fb_info *info)
{
	u32 *pal = info->pseudo_palette;

	if (regno >= 16)
		return -EINVAL;

	/*
	 * The colour values are 16-bit with significant bits in the MSBs.
	 * Pack into RGB565 for the pseudo-palette used by fbcon.
	 */
	pal[regno] = ((red   & 0xF800))       |
		     ((green & 0xFC00) >> 5)   |
		     ((blue  & 0xF800) >> 11);

	return 0;
}

/* ================================================================== */
/* fb_ops structure                                                   */
/* ================================================================== */

static const struct fb_ops ili9481_fbops = {
	.owner          = THIS_MODULE,
	.fb_read        = fb_sys_read,
	.fb_write       = ili9481_fb_write,
	.fb_check_var   = ili9481_fb_check_var,
	.fb_set_par     = ili9481_fb_set_par,
	.fb_setcolreg   = ili9481_fb_setcolreg,
	.fb_fillrect    = ili9481_fb_fillrect,
	.fb_copyarea    = ili9481_fb_copyarea,
	.fb_imageblit   = ili9481_fb_imageblit,
};

/* ================================================================== */
/* Platform driver probe                                              */
/* ================================================================== */

static int ili9481_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct ili9481_priv *par;
	struct fb_info *info;
	struct fb_deferred_io *defio;
	u32 vmem_size;
	void *vmem;
	int ret;

	/* ----- Allocate fb_info + private data ---- */
	info = framebuffer_alloc(sizeof(*par), dev);
	if (!info)
		return -ENOMEM;

	par       = info->par;
	par->info = info;
	par->dev  = dev;

	/* ----- Device-tree properties ----- */
	if (of_property_read_u32(dev->of_node, "rotate", &par->rotate))
		par->rotate = 270;
	if (of_property_read_u32(dev->of_node, "fps", &par->fps))
		par->fps = 30;

	switch (par->rotate) {
	case 90:
	case 270:
		par->width  = ILI9481_HEIGHT;	/* 480 */
		par->height = ILI9481_WIDTH;	/* 320 */
		break;
	default:
		par->width  = ILI9481_WIDTH;	/* 320 */
		par->height = ILI9481_HEIGHT;	/* 480 */
		break;
	}

	/* ----- Acquire GPIOs ----- */
	par->rst_gpio = devm_gpiod_get_optional(dev, "rst", GPIOD_OUT_LOW);
	if (IS_ERR(par->rst_gpio)) {
		ret = PTR_ERR(par->rst_gpio);
		dev_err(dev, "rst GPIO: %d\n", ret);
		goto err_fb;
	}

	par->dc_gpio = devm_gpiod_get(dev, "dc", GPIOD_OUT_LOW);
	if (IS_ERR(par->dc_gpio)) {
		ret = PTR_ERR(par->dc_gpio);
		dev_err(dev, "dc GPIO: %d\n", ret);
		goto err_fb;
	}

	par->wr_gpio = devm_gpiod_get(dev, "wr", GPIOD_OUT_LOW);
	if (IS_ERR(par->wr_gpio)) {
		ret = PTR_ERR(par->wr_gpio);
		dev_err(dev, "wr GPIO: %d\n", ret);
		goto err_fb;
	}

	par->data_gpios = devm_gpiod_get_array(dev, "data", GPIOD_OUT_LOW);
	if (IS_ERR(par->data_gpios)) {
		ret = PTR_ERR(par->data_gpios);
		dev_err(dev, "data GPIOs: %d\n", ret);
		goto err_fb;
	}
	if (par->data_gpios->ndescs != 16) {
		dev_err(dev, "need 16 data GPIOs, got %u\n",
			par->data_gpios->ndescs);
		ret = -EINVAL;
		goto err_fb;
	}

	/* ----- Allocate video memory (vmalloc) ----- */
	vmem_size = par->width * par->height * 2;	/* 16 bpp */
	vmem = vzalloc(vmem_size);
	if (!vmem) {
		ret = -ENOMEM;
		goto err_fb;
	}

	/* ----- fb_fix_screeninfo ----- */
	strscpy(info->fix.id, "ili9481", sizeof(info->fix.id));
	info->fix.type        = FB_TYPE_PACKED_PIXELS;
	info->fix.visual      = FB_VISUAL_TRUECOLOR;
	info->fix.line_length = par->width * 2;
	info->fix.accel       = FB_ACCEL_NONE;
	info->fix.smem_len    = vmem_size;

	/* ----- fb_var_screeninfo ----- */
	info->var.xres           = par->width;
	info->var.yres           = par->height;
	info->var.xres_virtual   = par->width;
	info->var.yres_virtual   = par->height;
	info->var.bits_per_pixel = 16;
	info->var.nonstd         = 0;
	info->var.grayscale      = 0;
	info->var.activate       = FB_ACTIVATE_NOW;
	info->var.width          = -1;		/* physical size unknown */
	info->var.height         = -1;

	/* RGB565 bit-field layout */
	info->var.red.offset     = 11;  info->var.red.length     = 5;
	info->var.green.offset   = 5;   info->var.green.length   = 6;
	info->var.blue.offset    = 0;   info->var.blue.length    = 5;
	info->var.transp.offset  = 0;   info->var.transp.length  = 0;

	/* ----- Wire up fb_info ----- */
	info->fbops         = &ili9481_fbops;
	info->flags         = FBINFO_VIRTFB;
	info->screen_buffer = vmem;
	info->screen_size   = vmem_size;

	info->pseudo_palette = devm_kcalloc(dev, 16, sizeof(u32), GFP_KERNEL);
	if (!info->pseudo_palette) {
		ret = -ENOMEM;
		goto err_vmem;
	}

	/* ----- Deferred IO (automatic flush at fps interval) ----- */
	defio = devm_kzalloc(dev, sizeof(*defio), GFP_KERNEL);
	if (!defio) {
		ret = -ENOMEM;
		goto err_vmem;
	}
	defio->delay       = max(1UL, (unsigned long)(HZ / par->fps));
	defio->deferred_io = ili9481_flush;
	info->fbdefio      = defio;
	fb_deferred_io_init(info);

	/* ----- Initialise the ILI9481 panel ----- */
	ili9481_init_display(par);

	/* ----- Register the framebuffer ----- */
	ret = register_framebuffer(info);
	if (ret < 0) {
		dev_err(dev, "register_framebuffer failed: %d\n", ret);
		goto err_defio;
	}

	platform_set_drvdata(pdev, par);
	dev_info(dev,
		 "ILI9481 %ux%u fb%d registered (rotate=%u, fps=%u)\n",
		 par->width, par->height, info->node,
		 par->rotate, par->fps);

	return 0;

err_defio:
	fb_deferred_io_cleanup(info);
err_vmem:
	vfree(vmem);
err_fb:
	framebuffer_release(info);
	return ret;
}

/* ================================================================== */
/* Platform driver remove (void return — kernel 6.11+)                */
/* ================================================================== */

static void ili9481_remove(struct platform_device *pdev)
{
	struct ili9481_priv *par = platform_get_drvdata(pdev);
	struct fb_info *info = par->info;

	unregister_framebuffer(info);
	fb_deferred_io_cleanup(info);

	/* Power down the panel */
	ili9481_write_cmd(par, ILI9481_DISPOFF);
	ili9481_write_cmd(par, ILI9481_SLPIN);

	vfree(info->screen_buffer);
	framebuffer_release(info);
}

/* ================================================================== */
/* Device-tree match and module boilerplate                           */
/* ================================================================== */

static const struct of_device_id ili9481_of_match[] = {
	{ .compatible = "inland,ili9481-gpio" },
	{ /* sentinel */ }
};
MODULE_DEVICE_TABLE(of, ili9481_of_match);

static struct platform_driver ili9481_gpio_driver = {
	.driver = {
		.name           = DRIVER_NAME,
		.of_match_table = ili9481_of_match,
	},
	.probe  = ili9481_probe,
	.remove = ili9481_remove,
};
module_platform_driver(ili9481_gpio_driver);

MODULE_AUTHOR("ILI9481-driver contributors");
MODULE_DESCRIPTION(DRIVER_DESC);
MODULE_LICENSE("GPL");
