/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * framebuffer.c — Virtual framebuffer provider: loads vfb module, opens fb
 *                 device, mmaps video memory, and runs the flush loop.
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
    uint16_t   *buffer;     /* mmap'd framebuffer memory */
    uint32_t    size;       /* buffer size in bytes      */
    uint16_t    width;
    uint16_t    height;
};

/* ------------------------------------------------------------------ */
/* vfb module loading                                                 */
/* ------------------------------------------------------------------ */

static int load_vfb_module(uint16_t width, uint16_t height)
{
    char cmd[256];
    int ret;

    /* First try dry-run to see if vfb is available */
    ret = system("modprobe --dry-run vfb 2>/dev/null");
    if (ret != 0) {
        log_error("vfb module is not available (CONFIG_FB_VIRTUAL not enabled?)");
        return -1;
    }

    snprintf(cmd, sizeof(cmd),
             "modprobe vfb vfb_enable=1 videomemorysize=%u",
             (unsigned)(width * height * 2));
    ret = system(cmd);
    if (ret != 0) {
        log_warn("modprobe vfb returned %d (may already be loaded)", ret);
    }

    return 0;
}

/* ------------------------------------------------------------------ */
/* Public API                                                         */
/* ------------------------------------------------------------------ */

struct fb_provider *fb_provider_init(const char *fb_device,
                                      uint16_t width, uint16_t height)
{
    struct fb_provider *fb;
    struct fb_var_screeninfo vinfo;
    struct fb_fix_screeninfo finfo;
    int attempts = 0;
    int fd = -1;

    /* Load the vfb kernel module */
    if (load_vfb_module(width, height) < 0)
        return NULL;

    /* Retry open for up to 2 seconds (module load can be async) */
    while (attempts < 20) {
        fd = open(fb_device, O_RDWR);
        if (fd >= 0)
            break;
        usleep(100000); /* 100 ms */
        attempts++;
    }

    if (fd < 0) {
        log_error("Cannot open %s after 2s: %s", fb_device, strerror(errno));
        return NULL;
    }

    /* Query variable screen info */
    if (ioctl(fd, FBIOGET_VSCREENINFO, &vinfo) < 0) {
        log_error("FBIOGET_VSCREENINFO failed: %s", strerror(errno));
        close(fd);
        return NULL;
    }

    /* Try to set the resolution and bpp we need */
    vinfo.xres = width;
    vinfo.yres = height;
    vinfo.xres_virtual = width;
    vinfo.yres_virtual = height;
    vinfo.bits_per_pixel = 16;

    /* RGB565 layout */
    vinfo.red.offset     = 11;  vinfo.red.length     = 5;
    vinfo.green.offset   = 5;   vinfo.green.length   = 6;
    vinfo.blue.offset    = 0;   vinfo.blue.length    = 5;
    vinfo.transp.offset  = 0;   vinfo.transp.length  = 0;

    if (ioctl(fd, FBIOPUT_VSCREENINFO, &vinfo) < 0) {
        log_warn("FBIOPUT_VSCREENINFO failed: %s (using current settings)",
                 strerror(errno));
        /* Re-read to get actual settings */
        ioctl(fd, FBIOGET_VSCREENINFO, &vinfo);
    }

    /* Verify we got what we need */
    if (vinfo.bits_per_pixel != 16) {
        log_error("Framebuffer is %u bpp, need 16 bpp", vinfo.bits_per_pixel);
        close(fd);
        return NULL;
    }

    log_info("Framebuffer: %ux%u %ubpp (requested %ux%u)",
             vinfo.xres, vinfo.yres, vinfo.bits_per_pixel, width, height);

    /* Query fixed screen info for mmap size */
    if (ioctl(fd, FBIOGET_FSCREENINFO, &finfo) < 0) {
        log_error("FBIOGET_FSCREENINFO failed: %s", strerror(errno));
        close(fd);
        return NULL;
    }

    uint32_t buf_size = (uint32_t)vinfo.xres * vinfo.yres * (vinfo.bits_per_pixel / 8);
    uint32_t mmap_size = finfo.smem_len > 0 ? finfo.smem_len : buf_size;

    void *map = mmap(NULL, mmap_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) {
        log_error("mmap framebuffer failed: %s", strerror(errno));
        close(fd);
        return NULL;
    }

    fb = calloc(1, sizeof(*fb));
    if (!fb) {
        munmap(map, mmap_size);
        close(fd);
        return NULL;
    }

    fb->fd = fd;
    fb->buffer = (uint16_t *)map;
    fb->size = mmap_size;
    fb->width = vinfo.xres;
    fb->height = vinfo.yres;

    log_info("Framebuffer %s opened: %ux%u, %u bytes mapped",
             fb_device, fb->width, fb->height, fb->size);

    return fb;
}

uint16_t *fb_provider_get_buffer(struct fb_provider *fb)
{
    return fb ? fb->buffer : NULL;
}

uint32_t fb_provider_get_size(struct fb_provider *fb)
{
    return fb ? fb->size : 0;
}

void fb_flush_loop(struct fb_provider *fb, struct gpio_bus *bus,
                   uint16_t width, uint16_t height,
                   int fps, volatile int *running)
{
    struct timespec next_tick;
    long frame_ns = 1000000000L / fps;
    unsigned int frame_count = 0;
    struct timespec fps_start;

    clock_gettime(CLOCK_MONOTONIC, &next_tick);
    fps_start = next_tick;

    log_info("Flush loop starting: %ux%u @ %d FPS (interval=%ld ns)",
             width, height, fps, frame_ns);

    while (*running) {
        /* Wait until the next frame time */
        clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next_tick, NULL);

        /* Flush the entire framebuffer to the display */
        ili9481_flush_full(bus, width, height, fb->buffer);

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

    if (fb->buffer && fb->buffer != MAP_FAILED)
        munmap(fb->buffer, fb->size);

    if (fb->fd >= 0)
        close(fb->fd);

    free(fb);
}
