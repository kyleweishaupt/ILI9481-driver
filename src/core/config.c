/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * config.c — INI-style key=value config file parser + CLI override
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#include "config.h"
#include "logging.h"

/* ------------------------------------------------------------------ */
/* Defaults                                                           */
/* ------------------------------------------------------------------ */

void config_defaults(struct ili9481_config *cfg)
{
    memset(cfg, 0, sizeof(*cfg));
    cfg->rotation     = 270;
    cfg->fps          = 30;
    strncpy(cfg->fb_device, "/dev/fb0", sizeof(cfg->fb_device) - 1);
    cfg->enable_touch = 0;
    strncpy(cfg->spi_device, "/dev/spidev0.1", sizeof(cfg->spi_device) - 1);
    cfg->spi_speed    = 2000000;
    cfg->benchmark    = 0;
    cfg->test_pattern = 0;
    cfg->gpio_probe   = 0;
}

/* ------------------------------------------------------------------ */
/* INI parser                                                         */
/* ------------------------------------------------------------------ */

static char *strip(char *s)
{
    while (*s && isspace((unsigned char)*s)) s++;
    char *end = s + strlen(s) - 1;
    while (end > s && isspace((unsigned char)*end)) *end-- = '\0';
    return s;
}

static void apply_kv(struct ili9481_config *cfg, const char *key, const char *val)
{
    if (strcmp(key, "rotation") == 0 || strcmp(key, "rotate") == 0) {
        cfg->rotation = (uint32_t)atoi(val);
    } else if (strcmp(key, "fps") == 0) {
        cfg->fps = atoi(val);
        if (cfg->fps < 1) cfg->fps = 1;
        if (cfg->fps > 60) cfg->fps = 60;
    } else if (strcmp(key, "fb_device") == 0) {
        strncpy(cfg->fb_device, val, sizeof(cfg->fb_device) - 1);
    } else if (strcmp(key, "enable_touch") == 0) {
        cfg->enable_touch = atoi(val);
    } else if (strcmp(key, "spi_device") == 0) {
        strncpy(cfg->spi_device, val, sizeof(cfg->spi_device) - 1);
    } else if (strcmp(key, "spi_speed") == 0) {
        cfg->spi_speed = (uint32_t)atoi(val);
    }
    /* Unknown keys are silently ignored */
}

int config_load(struct ili9481_config *cfg, const char *path)
{
    FILE *fp = fopen(path, "r");
    if (!fp) {
        log_warn("Config file %s not found, using defaults", path);
        return -1;
    }

    char line[256];
    while (fgets(line, sizeof(line), fp)) {
        char *s = strip(line);

        /* Skip comments and empty lines */
        if (*s == '\0' || *s == '#' || *s == ';')
            continue;

        /* Skip section headers */
        if (*s == '[')
            continue;

        char *eq = strchr(s, '=');
        if (!eq)
            continue;

        *eq = '\0';
        char *key = strip(s);
        char *val = strip(eq + 1);

        apply_kv(cfg, key, val);
    }

    fclose(fp);
    log_info("Config loaded from %s", path);
    return 0;
}

/* ------------------------------------------------------------------ */
/* CLI argument parser                                                */
/* ------------------------------------------------------------------ */

int config_parse_args(struct ili9481_config *cfg, int argc, char **argv)
{
    const char *config_path = NULL;

    /* First pass: look for --config= so we can load the file first */
    for (int i = 1; i < argc; i++) {
        if (strncmp(argv[i], "--config=", 9) == 0) {
            config_path = argv[i] + 9;
        }
    }

    /* Load config file (if specified) before applying CLI overrides */
    if (config_path)
        config_load(cfg, config_path);

    /* Second pass: apply all CLI options (override config file) */
    for (int i = 1; i < argc; i++) {
        if (strncmp(argv[i], "--config=", 9) == 0) {
            /* Already handled */
        } else if (strncmp(argv[i], "--rotate=", 9) == 0) {
            cfg->rotation = (uint32_t)atoi(argv[i] + 9);
        } else if (strncmp(argv[i], "--fps=", 6) == 0) {
            cfg->fps = atoi(argv[i] + 6);
            if (cfg->fps < 1) cfg->fps = 1;
            if (cfg->fps > 60) cfg->fps = 60;
        } else if (strncmp(argv[i], "--fb=", 5) == 0) {
            strncpy(cfg->fb_device, argv[i] + 5, sizeof(cfg->fb_device) - 1);
        } else if (strcmp(argv[i], "--touch") == 0) {
            cfg->enable_touch = 1;
        } else if (strcmp(argv[i], "--no-touch") == 0) {
            cfg->enable_touch = 0;
        } else if (strcmp(argv[i], "--benchmark") == 0) {
            cfg->benchmark = 1;
        } else if (strcmp(argv[i], "--test-pattern") == 0) {
            cfg->test_pattern = 1;
        } else if (strcmp(argv[i], "--gpio-probe") == 0) {
            cfg->gpio_probe = 1;
        } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            printf("Usage: ili9481-fb [OPTIONS]\n"
                   "  --config=PATH    Config file path\n"
                   "  --rotate=DEG     Rotation: 0, 90, 180, 270 (default: 270)\n"
                   "  --fps=N          Target FPS (default: 30)\n"
                   "  --fb=DEVICE      Source framebuffer to mirror (default: /dev/fb0)\n"
                   "  --touch          Enable touch support\n"
                   "  --no-touch       Disable touch support (default)\n"
                   "  --benchmark      Run FPS benchmark and exit\n"
                   "  --test-pattern   Show solid colour test bars and exit\n"
                   "  --gpio-probe     Toggle each GPIO pin one by one (diagnostic)\n"
                   "  -h, --help       Show this help\n");
            exit(0);
        } else {
            log_error("Unknown option: %s", argv[i]);
            return -1;
        }
    }

    return 0;
}

/* ------------------------------------------------------------------ */
/* Dump configuration                                                 */
/* ------------------------------------------------------------------ */

void config_dump(const struct ili9481_config *cfg)
{
    log_info("Configuration:");
    log_info("  rotation    = %u", cfg->rotation);
    log_info("  fps         = %d", cfg->fps);
    log_info("  fb_device   = %s", cfg->fb_device);
    log_info("  touch       = %s", cfg->enable_touch ? "enabled" : "disabled");
    if (cfg->enable_touch) {
        log_info("  spi_device  = %s", cfg->spi_device);
        log_info("  spi_speed   = %u", cfg->spi_speed);
    }
    log_info("  benchmark   = %s", cfg->benchmark ? "yes" : "no");
}
