/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * gpio_mmio.h — MMIO GPIO bus for ILI9481 12-bit parallel interface
 *
 * 26-pin shields: 12 data lines (DB0–DB11) + 5 control (RST, CS, DC, WR, RD).
 */

#ifndef GPIO_MMIO_H
#define GPIO_MMIO_H

#include <stdint.h>

/* Forward declaration */
struct gpio_bus;

/*
 * gpio_bus_open() — Detect Pi model, open /dev/gpiomem, mmap GPIO registers,
 *                   set all 17 pins to output, and build LUTs.
 *
 * Returns a heap-allocated gpio_bus on success, NULL on failure
 * (with a message logged to stderr/syslog).
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
 * gpio_write_cmd() — Send a command byte (DC low → write 12-bit → DC high).
 */
void gpio_write_cmd(struct gpio_bus *bus, uint8_t cmd);

/*
 * gpio_write_data() — Send an 8-bit data/parameter byte (DC high, 12-bit bus).
 */
void gpio_write_data(struct gpio_bus *bus, uint8_t data);

/*
 * gpio_write_pixels() — Stream `count` 12-bit RGB444 pixels (DC stays high).
 */
void gpio_write_pixels(struct gpio_bus *bus, const uint16_t *pixels, uint32_t count);

#endif /* GPIO_MMIO_H */
