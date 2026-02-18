/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * service_main.c — Entry point for the ILI9481 userspace framebuffer daemon
 *
 * Initialises GPIO MMIO, opens the framebuffer, starts the flush
 * thread, and optionally the touch polling thread.  Handles SIGTERM/SIGINT
 * for clean shutdown.
 *
 * Diagnostic modes:
 *   --test-pattern  Fill screen with solid R/G/B/W/K for 3 s each.
 *   --gpio-probe    Toggle each GPIO pin one-by-one for multimeter probing.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <pthread.h>
#include <time.h>

#include "config.h"
#include "logging.h"
#include "../bus/gpio_mmio.h"
#include "../display/ili9481.h"
#include "../display/framebuffer.h"
#include "ili9481_hw.h"

#ifdef ENABLE_TOUCH
#include "../touch/xpt2046.h"
#include "../touch/uinput_touch.h"
#endif

/* ------------------------------------------------------------------ */
/* Global running flag (set to 0 by signal handler)                   */
/* ------------------------------------------------------------------ */

static volatile int g_running = 1;

static void signal_handler(int sig)
{
    (void)sig;
    g_running = 0;
}

static void install_signal_handlers(void)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = signal_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;

    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
}

/* ------------------------------------------------------------------ */
/* Compute display dimensions from rotation                           */
/* ------------------------------------------------------------------ */

static void get_display_size(uint32_t rotate, uint16_t *w, uint16_t *h)
{
    switch (rotate) {
    case 90:
    case 270:
        *w = ILI9481_HEIGHT;    /* 480 */
        *h = ILI9481_WIDTH;     /* 320 */
        break;
    default:
        *w = ILI9481_WIDTH;     /* 320 */
        *h = ILI9481_HEIGHT;    /* 480 */
        break;
    }
}

/* ------------------------------------------------------------------ */
/* Benchmark mode                                                     */
/* ------------------------------------------------------------------ */

static void run_benchmark(struct gpio_bus *bus, uint16_t w, uint16_t h)
{
    uint32_t npixels = (uint32_t)w * h;
    uint16_t *dummy = calloc(npixels, sizeof(uint16_t));
    if (!dummy) {
        log_error("Cannot allocate benchmark buffer");
        return;
    }

    /* Fill with a test pattern */
    for (uint32_t i = 0; i < npixels; i++)
        dummy[i] = (uint16_t)(i & 0xFFFF);

    log_info("Benchmark: flushing %ux%u frames...", w, h);

    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);

    int frames = 100;
    for (int f = 0; f < frames; f++)
        ili9481_flush_full(bus, w, h, dummy);

    clock_gettime(CLOCK_MONOTONIC, &end);

    double elapsed = (end.tv_sec - start.tv_sec)
                   + (end.tv_nsec - start.tv_nsec) / 1e9;
    double fps = frames / elapsed;

    log_info("Benchmark result: %d frames in %.2f s = %.1f FPS", frames, elapsed, fps);
    printf("Benchmark: %d frames in %.2f s = %.1f FPS\n", frames, elapsed, fps);

    free(dummy);
}

/* ------------------------------------------------------------------ */
/* Test-pattern mode:  solid R / G / B / W / Blk, 3 seconds each     */
/* ------------------------------------------------------------------ */

static void run_test_pattern(struct gpio_bus *bus, uint16_t w, uint16_t h)
{
    uint32_t npixels = (uint32_t)w * h;
    uint16_t *buf = malloc(npixels * sizeof(uint16_t));
    if (!buf) {
        log_error("Cannot allocate test-pattern buffer");
        return;
    }

    /*  RGB565 values: R=0xF800, G=0x07E0, B=0x001F, W=0xFFFF, K=0x0000 */
    static const struct { const char *name; uint16_t colour; } fills[] = {
        { "RED",   0xF800 },
        { "GREEN", 0x07E0 },
        { "BLUE",  0x001F },
        { "WHITE", 0xFFFF },
        { "BLACK", 0x0000 },
    };

    printf("\n=== Test-Pattern Mode ===\n");
    printf("The display should show solid colours, 3 seconds each.\n");
    printf("If the screen stays white for every colour, the init sequence\n");
    printf("is not reaching the controller (wrong pin map or wrong chip).\n\n");

    for (int c = 0; c < 5; c++) {
        printf("  %s ... ", fills[c].name);
        fflush(stdout);
        for (uint32_t i = 0; i < npixels; i++)
            buf[i] = fills[c].colour;
        ili9481_flush_full(bus, w, h, buf);
        sleep(3);
        printf("done\n");
    }

    printf("\nTest-pattern complete.\n");
    free(buf);
}

/* ------------------------------------------------------------------ */
/* Touch thread (optional)                                            */
/* ------------------------------------------------------------------ */

#ifdef ENABLE_TOUCH

struct touch_thread_args {
    const struct ili9481_config *cfg;
    uint16_t width;
    uint16_t height;
    volatile int *running;
};

static void *touch_thread_fn(void *arg)
{
    struct touch_thread_args *ta = arg;

    struct xpt2046 *ts = xpt2046_open(ta->cfg->spi_device, ta->cfg->spi_speed);
    if (!ts) {
        log_error("Touch: failed to open XPT2046, thread exiting");
        return NULL;
    }

    struct uinput_touch *ut = uinput_touch_create(ta->width, ta->height);
    if (!ut) {
        log_error("Touch: failed to create uinput device, thread exiting");
        xpt2046_close(ts);
        return NULL;
    }

    /* Default identity calibration — users should calibrate for accuracy */
    struct touch_cal cal = {
        .ax = (float)ta->width / 4096.0f, .bx = 0.0f, .cx = 0.0f,
        .ay = 0.0f, .by = (float)ta->height / 4096.0f, .cy = 0.0f,
    };

    log_info("Touch thread started (polling at ~100 Hz)");

    while (*(ta->running)) {
        int x, y;
        int down = xpt2046_read(ts, &cal, &x, &y);

        /* Clamp to screen bounds */
        if (down) {
            if (x < 0) x = 0;
            if (x >= ta->width) x = ta->width - 1;
            if (y < 0) y = 0;
            if (y >= ta->height) y = ta->height - 1;
        }

        uinput_touch_report(ut, down, x, y);
        usleep(10000); /* ~100 Hz polling */
    }

    uinput_touch_destroy(ut);
    xpt2046_close(ts);
    log_info("Touch thread stopped");
    return NULL;
}

#endif /* ENABLE_TOUCH */

/* ------------------------------------------------------------------ */
/* Main                                                               */
/* ------------------------------------------------------------------ */

int main(int argc, char **argv)
{
    struct ili9481_config cfg;
    struct gpio_bus *bus = NULL;
    struct fb_provider *fb = NULL;
    int ret = EXIT_FAILURE;

    /* Initialise logging */
    log_init("ili9481-fb");

    /* Parse configuration */
    config_defaults(&cfg);
    if (config_parse_args(&cfg, argc, argv) < 0)
        goto out;

    config_dump(&cfg);

    /* Compute display dimensions */
    uint16_t disp_w, disp_h;
    get_display_size(cfg.rotation, &disp_w, &disp_h);

    /* Open GPIO MMIO bus */
    bus = gpio_bus_open();
    if (!bus) {
        log_error("Failed to open GPIO bus — aborting");
        goto out;
    }

    /* Initialise the ILI9481 display panel */
    ili9481_init(bus, cfg.rotation);

    /* Benchmark mode: run and exit */
    if (cfg.benchmark) {
        run_benchmark(bus, disp_w, disp_h);
        ret = EXIT_SUCCESS;
        goto out;
    }

    /* GPIO probe mode: toggle pins one-by-one and exit */
    if (cfg.gpio_probe) {
        gpio_bus_probe(bus);
        ret = EXIT_SUCCESS;
        goto out;
    }

    /* Test-pattern mode: solid colour fills, then exit */
    if (cfg.test_pattern) {
        run_test_pattern(bus, disp_w, disp_h);
        ret = EXIT_SUCCESS;
        goto out;
    }

    /* Open the framebuffer */
    fb = fb_provider_init(cfg.fb_device, disp_w, disp_h);
    if (!fb) {
        log_error("Failed to initialise framebuffer — aborting");
        goto out;
    }

    /* Install signal handlers for clean shutdown */
    install_signal_handlers();

#ifdef ENABLE_TOUCH
    /* Start touch thread if enabled */
    pthread_t touch_tid = 0;
    struct touch_thread_args ta;

    if (cfg.enable_touch) {
        ta.cfg = &cfg;
        ta.width = disp_w;
        ta.height = disp_h;
        ta.running = &g_running;

        if (pthread_create(&touch_tid, NULL, touch_thread_fn, &ta) != 0) {
            log_error("Failed to create touch thread");
            touch_tid = 0;
        }
    }
#endif

    log_info("ILI9481 framebuffer daemon running (PID %d)", getpid());

    /* Run the main flush loop (blocks until g_running becomes 0) */
    fb_flush_loop(fb, bus, disp_w, disp_h, cfg.fps, &g_running);

#ifdef ENABLE_TOUCH
    /* Wait for touch thread to finish */
    if (touch_tid) {
        pthread_join(touch_tid, NULL);
    }
#endif

    log_info("Shutting down...");

    /* Power off the display panel */
    ili9481_power_off(bus);

    ret = EXIT_SUCCESS;

out:
    if (fb)
        fb_provider_destroy(fb);
    if (bus)
        gpio_bus_close(bus);

    log_info("ili9481-fb exited (code %d)", ret);
    log_close();
    return ret;
}
