/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * config.h — INI-style key=value configuration parser
 */

#ifndef CONFIG_H
#define CONFIG_H

#include <stdint.h>

/*
 * Runtime configuration for the ILI9481 framebuffer daemon.
 * All fields have sensible defaults; the config file is optional.
 */
struct ili9481_config {
    uint32_t    rotation;       /* 0, 90, 180, 270             */
    int         fps;            /* Target refresh rate          */
    char        fb_device[64];  /* Framebuffer device path      */
    int         enable_touch;   /* 0 = disabled, 1 = enabled   */
    char        spi_device[64]; /* SPI device for touch         */
    uint32_t    spi_speed;      /* SPI clock in Hz              */
    int         benchmark;      /* 1 = benchmark mode           */
};

/*
 * config_defaults() — Populate `cfg` with default values.
 */
void config_defaults(struct ili9481_config *cfg);

/*
 * config_load() — Parse an INI-style config file.
 *
 * Returns 0 on success, -1 if the file cannot be opened (defaults remain).
 * Unknown keys are silently ignored.
 */
int config_load(struct ili9481_config *cfg, const char *path);

/*
 * config_parse_args() — Apply command-line overrides.
 *
 * Recognised options:
 *   --config=PATH
 *   --rotate=DEG
 *   --fps=N
 *   --fb=DEVICE
 *   --touch / --no-touch
 *   --benchmark
 *
 * Returns 0 on success, -1 on unrecognised option.
 */
int config_parse_args(struct ili9481_config *cfg, int argc, char **argv);

/*
 * config_dump() — Log the current configuration via log_info().
 */
void config_dump(const struct ili9481_config *cfg);

#endif /* CONFIG_H */
