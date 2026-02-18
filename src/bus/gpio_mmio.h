/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * gpio_mmio.h — MMIO GPIO bus for ILI9481, 8-bit 8080-I parallel interface
 *
 * 26-pin shields: 8 data lines (DB0–DB7) + 5 control (RST, CS, DC, WR, RD).
 */

#ifndef GPIO_MMIO_H
#define GPIO_MMIO_H

#include <stdint.h>

/* Forward declaration */
struct gpio_bus;

/*
 * gpio_bus_open() — Detect Pi model, open /dev/gpiomem, mmap GPIO registers,
 *                   set 13 pins to output (8 data + 5 control), build LUT.
 *
 * Returns a heap-allocated gpio_bus on success, NULL on failure.
 */
struct gpio_bus *gpio_bus_open(void);

/*
 * gpio_bus_close() — Unmap registers, close fd, free memory.
 */
void gpio_bus_close(struct gpio_bus *bus);

/*
 * gpio_hw_reset() — Assert /RST low for 20 ms, release, wait 120 ms.
 */
void gpio_hw_reset(struct gpio_bus *bus);

/*
 * gpio_write_cmd() — Send a command byte (DC low → write byte → DC high).
 */
void gpio_write_cmd(struct gpio_bus *bus, uint8_t cmd);

/*
 * gpio_write_data() — Send an 8-bit data/parameter byte (DC high).
 */
void gpio_write_data(struct gpio_bus *bus, uint8_t data);

/*
 * gpio_write_pixels() — Stream `count` RGB565 pixels, two 8-bit bus cycles
 *                        per pixel (high byte first, then low byte).
 */
void gpio_write_pixels(struct gpio_bus *bus, const uint16_t *pixels, uint32_t count);

/*
 * gpio_bus_probe() — Toggle each configured GPIO pin one-by-one (3 seconds
 *                    each), printing the pin name.  For board-level debugging
 *                    with a multimeter.
 */
void gpio_bus_probe(struct gpio_bus *bus);

#endif /* GPIO_MMIO_H */
