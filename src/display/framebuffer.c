/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * framebuffer.c — Mirror an existing Linux framebuffer to the ILI9481 TFT
 *
 * Opens /dev/fb0 (or whichever device is configured), mmaps it read-only,
 * and each frame converts pixels to 16-bit RGB565 + nearest-neighbor
 * scales to the TFT resolution before flushing to the display via GPIO.
 *
 * RGB565 packing: bits [15:11]=R(5), [10:5]=G(6), [4:0]=B(5).
 * Sent over the 8-bit bus as two bus cycles per pixel (high byte first).
 *
 * No kernel modules are loaded — works with the stock vc4drmfb framebuffer.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <linux/fb.h>

#include "framebuffer.h"
#include "ili9481.h"
#include "../bus/gpio_mmio.h"
#include "../core/logging.h"

/* ------------------------------------------------------------------ */
/* Internal state                                                     */
/* ------------------------------------------------------------------ */

struct fb_provider {
    int         fd;
    uint8_t    *map;            /* raw mmap'd source framebuffer     */
    uint32_t    map_size;       /* mmap'd region size in bytes       */

    /* Source framebuffer properties */
    uint32_t    src_width;
    uint32_t    src_height;
    uint32_t    src_bpp;        /* bits per pixel (16 or 32)         */
    uint32_t    src_stride;     /* bytes per source row (line_length)*/

    /* RGB bit-field positions (for 32bpp conversion) */
    uint32_t    red_offset;
    uint32_t    red_length;
    uint32_t    green_offset;
    uint32_t    green_length;
    uint32_t    blue_offset;
    uint32_t    blue_length;

    /* Pre-allocated scale buffer (TFT-sized, RGB565 in uint16_t) */
    uint16_t   *scale_buf;
    uint32_t    tft_width;
    uint32_t    tft_height;
};

/* ------------------------------------------------------------------ */
/* Pixel format conversion                                            */
/* ------------------------------------------------------------------ */

/*
 * Convert a 32-bit pixel to RGB565 using the source fb's bit-field layout.
 * Handles XRGB8888, ARGB8888, BGRX8888, and any other layout described
 * by the fb_var_screeninfo red/green/blue offset/length fields.
 *
 * Result: bits [15:11]=R(5), [10:5]=G(6), [4:0]=B(5).
 */
static inline uint16_t pixel32_to_rgb565(uint32_t px,
                                          uint32_t r_off, uint32_t r_len,
                                          uint32_t g_off, uint32_t g_len,
                                          uint32_t b_off, uint32_t b_len)
{
    uint32_t r = (px >> r_off) & ((1u << r_len) - 1);
    uint32_t g = (px >> g_off) & ((1u << g_len) - 1);
    uint32_t b = (px >> b_off) & ((1u << b_len) - 1);

    /* Normalise each channel: R to 5 bits, G to 6 bits, B to 5 bits */
    if (r_len > 5) r >>= (r_len - 5); else if (r_len < 5) r <<= (5 - r_len);
    if (g_len > 6) g >>= (g_len - 6); else if (g_len < 6) g <<= (6 - g_len);
    if (b_len > 5) b >>= (b_len - 5); else if (b_len < 5) b <<= (5 - b_len);

    return (uint16_t)((r << 11) | (g << 5) | b);
}

/* ------------------------------------------------------------------ */
/* Scale + convert a full frame into the pre-allocated TFT buffer     */
/* ------------------------------------------------------------------ */

static void scale_frame(struct fb_provider *fb)
{
    const uint32_t tw = fb->tft_width;
    const uint32_t th = fb->tft_height;
    const uint32_t sw = fb->src_width;
    const uint32_t sh = fb->src_height;
    const uint32_t stride = fb->src_stride;
    const uint8_t *src = fb->map;

    if (fb->src_bpp == 16) {
        /* 16bpp source is already RGB565 — just scale (no conversion) */
        for (uint32_t dy = 0; dy < th; dy++) {
            uint32_t sy = dy * sh / th;
            const uint16_t *srow = (const uint16_t *)(src + sy * stride);
            uint16_t *drow = &fb->scale_buf[dy * tw];
            for (uint32_t dx = 0; dx < tw; dx++) {
                uint32_t sx = dx * sw / tw;
                drow[dx] = srow[sx];
            }
        }
        return;
    }

    /* 32bpp source: convert to RGB565 + scale in one pass */
    const uint32_t r_off = fb->red_offset;
    const uint32_t r_len = fb->red_length;
    const uint32_t g_off = fb->green_offset;
    const uint32_t g_len = fb->green_length;
    const uint32_t b_off = fb->blue_offset;
    const uint32_t b_len = fb->blue_length;

    for (uint32_t dy = 0; dy < th; dy++) {
        uint32_t sy = dy * sh / th;
        const uint32_t *srow = (const uint32_t *)(src + sy * stride);
        uint16_t *drow = &fb->scale_buf[dy * tw];
        for (uint32_t dx = 0; dx < tw; dx++) {
            uint32_t sx = dx * sw / tw;
            drow[dx] = pixel32_to_rgb565(srow[sx],
                                          r_off, r_len,
                                          g_off, g_len,
                                          b_off, b_len);
        }
    }
}

/* ------------------------------------------------------------------ */
/* Public API                                                         */
/* ------------------------------------------------------------------ */

struct fb_provider *fb_provider_init(const char *fb_device,
                                      uint16_t tft_width, uint16_t tft_height)
{
    struct fb_var_screeninfo vinfo;
    struct fb_fix_screeninfo finfo;
    int fd;

    fd = open(fb_device, O_RDONLY);
    if (fd < 0) {
        log_error("Cannot open %s: %s", fb_device, strerror(errno));
        return NULL;
    }

    /* Query variable screen info */
    if (ioctl(fd, FBIOGET_VSCREENINFO, &vinfo) < 0) {
        log_error("FBIOGET_VSCREENINFO on %s failed: %s", fb_device, strerror(errno));
        close(fd);
        return NULL;
    }

    if (vinfo.bits_per_pixel != 16 && vinfo.bits_per_pixel != 32) {
        log_error("Unsupported pixel format: %u bpp (need 16 or 32)",
                  vinfo.bits_per_pixel);
        close(fd);
        return NULL;
    }

    /* Query fixed screen info for line_length and mmap size */
    if (ioctl(fd, FBIOGET_FSCREENINFO, &finfo) < 0) {
        log_error("FBIOGET_FSCREENINFO on %s failed: %s", fb_device, strerror(errno));
        close(fd);
        return NULL;
    }

    uint32_t mmap_size = finfo.smem_len;
    if (mmap_size == 0)
        mmap_size = vinfo.yres_virtual * finfo.line_length;
    if (mmap_size == 0)
        mmap_size = vinfo.yres * vinfo.xres * (vinfo.bits_per_pixel / 8);

    void *map = mmap(NULL, mmap_size, PROT_READ, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) {
        log_error("mmap %s failed: %s", fb_device, strerror(errno));
        close(fd);
        return NULL;
    }

    /* Allocate the TFT-sized output buffer */
    uint16_t *scale_buf = calloc((uint32_t)tft_width * tft_height, sizeof(uint16_t));
    if (!scale_buf) {
        log_error("Cannot allocate scale buffer (%ux%u)", tft_width, tft_height);
        munmap(map, mmap_size);
        close(fd);
        return NULL;
    }

    struct fb_provider *fb = calloc(1, sizeof(*fb));
    if (!fb) {
        free(scale_buf);
        munmap(map, mmap_size);
        close(fd);
        return NULL;
    }

    fb->fd          = fd;
    fb->map         = (uint8_t *)map;
    fb->map_size    = mmap_size;
    fb->src_width   = vinfo.xres;
    fb->src_height  = vinfo.yres;
    fb->src_bpp     = vinfo.bits_per_pixel;
    fb->src_stride  = finfo.line_length;
    fb->red_offset  = vinfo.red.offset;
    fb->red_length  = vinfo.red.length;
    fb->green_offset = vinfo.green.offset;
    fb->green_length = vinfo.green.length;
    fb->blue_offset  = vinfo.blue.offset;
    fb->blue_length  = vinfo.blue.length;
    fb->scale_buf   = scale_buf;
    fb->tft_width   = tft_width;
    fb->tft_height  = tft_height;

    log_info("Source framebuffer %s: %ux%u %ubpp (stride=%u)",
             fb_device, fb->src_width, fb->src_height,
             fb->src_bpp, fb->src_stride);
    log_info("TFT target: %ux%u RGB565 — scale+convert",
             tft_width, tft_height);

    return fb;
}

void fb_flush_loop(struct fb_provider *fb, struct gpio_bus *bus,
                   uint16_t tft_width, uint16_t tft_height,
                   int fps, volatile int *running)
{
    struct timespec next_tick;
    long frame_ns = 1000000000L / fps;
    unsigned int frame_count = 0;
    struct timespec fps_start;

    clock_gettime(CLOCK_MONOTONIC, &next_tick);
    fps_start = next_tick;

    log_info("Flush loop starting: mirror %ux%u %ubpp → %ux%u RGB565 @ %d FPS",
             fb->src_width, fb->src_height, fb->src_bpp,
             tft_width, tft_height, fps);

    while (*running) {
        /* Wait until the next frame time */
        clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next_tick, NULL);

        /* Convert and scale the source framebuffer into the TFT buffer */
        scale_frame(fb);

        /* Flush the scaled RGB565 buffer to the display */
        ili9481_flush_full(bus, tft_width, tft_height, fb->scale_buf);

        frame_count++;

        /* Log actual FPS every 10 seconds */
        if (frame_count % (unsigned int)(fps * 10) == 0) {
            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            double elapsed = (now.tv_sec - fps_start.tv_sec)
                           + (now.tv_nsec - fps_start.tv_nsec) / 1e9;
            if (elapsed > 0.0) {
                log_info("Actual FPS: %.1f (frames=%u, elapsed=%.1fs)",
                         frame_count / elapsed, frame_count, elapsed);
            }
        }

        /* Advance to the next tick (absolute time) */
        next_tick.tv_nsec += frame_ns;
        while (next_tick.tv_nsec >= 1000000000L) {
            next_tick.tv_nsec -= 1000000000L;
            next_tick.tv_sec++;
        }
    }

    log_info("Flush loop stopped after %u frames", frame_count);
}

void fb_provider_destroy(struct fb_provider *fb)
{
    if (!fb)
        return;

    if (fb->scale_buf)
        free(fb->scale_buf);

    if (fb->map && fb->map != MAP_FAILED)
        munmap(fb->map, fb->map_size);

    if (fb->fd >= 0)
        close(fb->fd);

    free(fb);
}
