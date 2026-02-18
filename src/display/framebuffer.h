/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * framebuffer.h — Virtual framebuffer provider API
 */

#ifndef FRAMEBUFFER_H
#define FRAMEBUFFER_H

#include <stdint.h>

struct gpio_bus;

/* Opaque framebuffer provider handle */
struct fb_provider;

/*
 * fb_provider_init() — Load the vfb module, open the fb device, verify
 *                      resolution and format, mmap the video memory.
 *
 * `fb_device` is the framebuffer device path (e.g. "/dev/fb1").
 * `width` and `height` are the expected dimensions.
 *
 * Returns a provider handle on success, NULL on failure.
 */
struct fb_provider *fb_provider_init(const char *fb_device,
                                     uint16_t width, uint16_t height);

/*
 * fb_provider_get_buffer() — Return the mmap'd framebuffer pointer.
 */
uint16_t *fb_provider_get_buffer(struct fb_provider *fb);

/*
 * fb_provider_get_size() — Return the framebuffer size in bytes.
 */
uint32_t fb_provider_get_size(struct fb_provider *fb);

/*
 * fb_flush_loop() — Run the flush-to-display loop.
 *
 * Calls ili9481_flush_full() at the configured FPS using
 * clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME).
 *
 * This function runs until `*running` becomes 0 (set by signal handler).
 * Logs actual FPS every 10 seconds.
 */
void fb_flush_loop(struct fb_provider *fb, struct gpio_bus *bus,
                   uint16_t width, uint16_t height,
                   int fps, volatile int *running);

/*
 * fb_provider_destroy() — Unmap, close, free.
 */
void fb_provider_destroy(struct fb_provider *fb);

#endif /* FRAMEBUFFER_H */
