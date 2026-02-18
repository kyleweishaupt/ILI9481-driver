/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * framebuffer.h — Framebuffer source provider API
 *
 * Opens an existing Linux framebuffer device (e.g. /dev/fb0), mmaps it,
 * and provides a flush loop that reads pixels, converts/scales them to
 * the TFT resolution (480×320 RGB444), and pushes them to the display.
 *
 * No kernel modules are loaded — the daemon mirrors whatever fb device
 * already exists (typically vc4drmfb on HDMI).
 */

#ifndef FRAMEBUFFER_H
#define FRAMEBUFFER_H

#include <stdint.h>

struct gpio_bus;

/* Opaque framebuffer provider handle */
struct fb_provider;

/*
 * fb_provider_init() — Open an existing framebuffer device, query its
 *                      resolution and pixel format, and mmap the video
 *                      memory for reading.
 *
 * `fb_device` is the framebuffer device path (e.g. "/dev/fb0").
 * `tft_width` and `tft_height` are the target TFT panel dimensions.
 *
 * The source framebuffer may be any resolution and 16 or 32 bpp;
 * the flush loop handles format conversion and nearest-neighbor scaling.
 *
 * Returns a provider handle on success, NULL on failure.
 */
struct fb_provider *fb_provider_init(const char *fb_device,
                                     uint16_t tft_width, uint16_t tft_height);

/*
 * fb_flush_loop() — Run the mirror-to-display loop.
 *
 * Each frame: reads from the mmap'd source fb, converts pixel format
 * (32bpp XRGB8888 → 12bpp RGB444 if needed), scales to tft_width ×
 * tft_height via nearest-neighbor, and calls ili9481_flush_full().
 *
 * Uses clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME) for timing.
 * Runs until `*running` becomes 0.  Logs actual FPS every 10 seconds.
 */
void fb_flush_loop(struct fb_provider *fb, struct gpio_bus *bus,
                   uint16_t tft_width, uint16_t tft_height,
                   int fps, volatile int *running);

/*
 * fb_provider_destroy() — Unmap, close, free.
 */
void fb_provider_destroy(struct fb_provider *fb);

#endif /* FRAMEBUFFER_H */
