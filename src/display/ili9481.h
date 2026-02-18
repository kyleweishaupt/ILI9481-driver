/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * ili9481.h — ILI9481 display controller API
 */

#ifndef ILI9481_H
#define ILI9481_H

#include <stdint.h>

struct gpio_bus;

/*
 * ili9481_init() — Hardware reset + send full init command sequence + apply
 *                  MADCTL for the given rotation.
 *
 * `rotate` must be 0, 90, 180, or 270.
 */
void ili9481_init(struct gpio_bus *bus, uint32_t rotate);

/*
 * ili9481_flush_full() — Write a complete frame of `width * height` pixels
 *                        to the display, setting CASET/PASET/RAMWR first.
 *
 * `pixels` points to width*height uint16_t values in RGB565 format.
 */
void ili9481_flush_full(struct gpio_bus *bus,
                        uint16_t width, uint16_t height,
                        const uint16_t *pixels);

/*
 * ili9481_power_off() — Send DISPOFF + SLPIN to the panel.
 */
void ili9481_power_off(struct gpio_bus *bus);

#endif /* ILI9481_H */
