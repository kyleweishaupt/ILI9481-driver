/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * gpio_mmio.c — MMIO GPIO bus driver for ILI9481 16-bit parallel interface
 *
 * Writes directly to BCM283x GPIO registers via /dev/gpiomem.
 * Uses precomputed 256-entry lookup tables for fast pixel writes.
 *
 * Pi 5 (RP1 chip) is NOT supported — detected and rejected at open time.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <time.h>

#include "gpio_mmio.h"
#include "timing.h"
#include "ili9481_hw.h"
#include "../core/logging.h"

/* ------------------------------------------------------------------ */
/* Internal state                                                     */
/* ------------------------------------------------------------------ */

struct gpio_bus {
    volatile uint32_t *regs;        /* mmap'd GPIO register base         */
    int                fd;          /* /dev/gpiomem file descriptor      */
    uint32_t           wr_mask;     /* 1 << GPIO_WR                     */
    uint32_t           dc_mask;     /* 1 << GPIO_DC                     */
    uint32_t           rst_mask;    /* 1 << GPIO_RST                    */

    /* Lookup tables: map each byte value to SET/CLR masks */
    uint32_t lut_lo_set[256];       /* DB0–DB7: bits to set             */
    uint32_t lut_lo_clr[256];       /* DB0–DB7: bits to clear           */
    uint32_t lut_hi_set[256];       /* DB8–DB15: bits to set            */
    uint32_t lut_hi_clr[256];       /* DB8–DB15: bits to clear          */
};

/* All data bus pins, low byte and high byte groups */
static const int db_lo_pins[8] = {
    GPIO_DB0, GPIO_DB1, GPIO_DB2, GPIO_DB3,
    GPIO_DB4, GPIO_DB5, GPIO_DB6, GPIO_DB7
};

static const int db_hi_pins[8] = {
    GPIO_DB8, GPIO_DB9, GPIO_DB10, GPIO_DB11,
    GPIO_DB12, GPIO_DB13, GPIO_DB14, GPIO_DB15
};

/* ------------------------------------------------------------------ */
/* Pi model detection                                                 */
/* ------------------------------------------------------------------ */

/*
 * Detect whether this is a Pi 5 (RP1), which uses a completely different
 * GPIO register layout and is NOT supported by MMIO via /dev/gpiomem.
 *
 * Returns 0 if safe to proceed, -1 if Pi 5 detected or unrecognised.
 */
static int detect_pi_model(void)
{
    FILE *fp = fopen("/proc/cpuinfo", "r");
    if (!fp) {
        log_error("Cannot open /proc/cpuinfo");
        return -1;
    }

    char line[256];
    int found_revision = 0;
    int is_pi5 = 0;

    while (fgets(line, sizeof(line), fp)) {
        /* Look for "Model" line containing "Pi 5" */
        if (strstr(line, "Model") && strstr(line, "Pi 5")) {
            is_pi5 = 1;
            break;
        }
        /* Also check "Revision" field — Pi 5 revisions start with 'c0' in new-style */
        if (strncmp(line, "Revision", 8) == 0) {
            found_revision = 1;
            /* New-style revision: if bits [23:12] hardware type = 0x17, it's Pi 5 */
            char *colon = strchr(line, ':');
            if (colon) {
                unsigned long rev = strtoul(colon + 1, NULL, 16);
                /* New-style flag is bit 23 */
                if (rev & (1 << 23)) {
                    unsigned int type = (rev >> 4) & 0xFF;
                    if (type == 0x17) {
                        is_pi5 = 1;
                        break;
                    }
                }
            }
        }
    }

    fclose(fp);

    if (is_pi5) {
        log_error("Raspberry Pi 5 detected — RP1 GPIO is not supported by MMIO.");
        log_error("This driver only works on Pi 1/2/3/4/Zero/Zero 2 W.");
        return -1;
    }

    if (!found_revision) {
        log_warn("Could not find Revision in /proc/cpuinfo — assuming BCM283x GPIO.");
    }

    return 0;
}

/* ------------------------------------------------------------------ */
/* GPIO pin configuration via MMIO                                    */
/* ------------------------------------------------------------------ */

/*
 * Set a single GPIO pin as output.
 * GPFSEL registers: each pin occupies 3 bits, 10 pins per register.
 * Output mode = 001 in the 3-bit field.
 */
static void gpio_set_output(volatile uint32_t *regs, int pin)
{
    int reg = pin / 10;
    int shift = (pin % 10) * 3;
    uint32_t val = regs[GPFSEL0 + reg];
    val &= ~(7u << shift);     /* clear function bits */
    val |=  (1u << shift);     /* set to output (001) */
    regs[GPFSEL0 + reg] = val;
}

/* ------------------------------------------------------------------ */
/* LUT construction                                                   */
/* ------------------------------------------------------------------ */

static void gpio_build_luts(struct gpio_bus *bus)
{
    for (int val = 0; val < 256; val++) {
        uint32_t lo_set = 0, lo_clr = 0;
        uint32_t hi_set = 0, hi_clr = 0;

        for (int bit = 0; bit < 8; bit++) {
            if (val & (1 << bit)) {
                lo_set |= (1u << db_lo_pins[bit]);
                hi_set |= (1u << db_hi_pins[bit]);
            } else {
                lo_clr |= (1u << db_lo_pins[bit]);
                hi_clr |= (1u << db_hi_pins[bit]);
            }
        }

        bus->lut_lo_set[val] = lo_set;
        bus->lut_lo_clr[val] = lo_clr;
        bus->lut_hi_set[val] = hi_set;
        bus->lut_hi_clr[val] = hi_clr;
    }
}

/* ------------------------------------------------------------------ */
/* Core 16-bit bus write (hot path)                                   */
/* ------------------------------------------------------------------ */

/*
 * Write a single 16-bit value onto the data bus and pulse /WR.
 *
 * 8080-style timing:
 *   1. Place data on bus (SET/CLR in one shot via LUTs)
 *   2. Assert /WR low  (active-low: GPCLR the WR pin)
 *   3. Hold ≥ 15 ns
 *   4. Release /WR high (GPSET the WR pin — rising edge latches)
 */
static inline void __attribute__((optimize("O3")))
bus_write16(struct gpio_bus *bus, uint16_t val)
{
    uint8_t lo = val & 0xFF;
    uint8_t hi = (val >> 8) & 0xFF;

    /* Set data bus: combine lo-byte and hi-byte masks */
    bus->regs[GPSET0] = bus->lut_lo_set[lo] | bus->lut_hi_set[hi];
    bus->regs[GPCLR0] = bus->lut_lo_clr[lo] | bus->lut_hi_clr[hi];

    /* Assert /WR low (active-low → clear the pin) */
    bus->regs[GPCLR0] = bus->wr_mask;
    dmb();

    /* Release /WR high (rising edge latches data into ILI9481) */
    bus->regs[GPSET0] = bus->wr_mask;
}

/* ------------------------------------------------------------------ */
/* Public API                                                         */
/* ------------------------------------------------------------------ */

struct gpio_bus *gpio_bus_open(void)
{
    if (detect_pi_model() < 0)
        return NULL;

    struct gpio_bus *bus = calloc(1, sizeof(*bus));
    if (!bus) {
        log_error("Out of memory");
        return NULL;
    }

    bus->fd = open("/dev/gpiomem", O_RDWR | O_SYNC);
    if (bus->fd < 0) {
        log_error("Cannot open /dev/gpiomem (run as root or add user to 'gpio' group)");
        free(bus);
        return NULL;
    }

    bus->regs = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, bus->fd, 0);
    if (bus->regs == MAP_FAILED) {
        log_error("mmap /dev/gpiomem failed");
        close(bus->fd);
        free(bus);
        return NULL;
    }

    /* Precompute pin masks */
    bus->wr_mask  = 1u << GPIO_WR;
    bus->dc_mask  = 1u << GPIO_DC;
    bus->rst_mask = 1u << GPIO_RST;

    /* Set all control and data pins to output */
    gpio_set_output(bus->regs, GPIO_RST);
    gpio_set_output(bus->regs, GPIO_DC);
    gpio_set_output(bus->regs, GPIO_WR);

    static const int all_data_pins[DATA_BUS_WIDTH] = DATA_BUS_PINS;
    for (int i = 0; i < DATA_BUS_WIDTH; i++)
        gpio_set_output(bus->regs, all_data_pins[i]);

    /* Start with WR high (idle), DC high (data mode) */
    bus->regs[GPSET0] = bus->wr_mask | bus->dc_mask;

    /* Build LUTs */
    gpio_build_luts(bus);

    log_info("GPIO MMIO bus opened successfully (19 pins configured)");
    return bus;
}

void gpio_bus_close(struct gpio_bus *bus)
{
    if (!bus)
        return;

    if (bus->regs && bus->regs != MAP_FAILED)
        munmap((void *)bus->regs, 4096);

    if (bus->fd >= 0)
        close(bus->fd);

    free(bus);
}

void gpio_hw_reset(struct gpio_bus *bus)
{
    if (!bus)
        return;

    /* Assert /RST low */
    bus->regs[GPCLR0] = bus->rst_mask;
    usleep(20000);  /* 20 ms */

    /* Release /RST high */
    bus->regs[GPSET0] = bus->rst_mask;
    usleep(120000); /* 120 ms for ILI9481 power-on sequence */
}

void gpio_write_cmd(struct gpio_bus *bus, uint8_t cmd)
{
    /* DC low = command mode */
    bus->regs[GPCLR0] = bus->dc_mask;
    dmb();

    bus_write16(bus, (uint16_t)cmd);

    /* DC high = data mode */
    bus->regs[GPSET0] = bus->dc_mask;
    dmb();
}

void gpio_write_data(struct gpio_bus *bus, uint8_t data)
{
    /* DC stays high (data mode) */
    bus_write16(bus, (uint16_t)data);
}

void __attribute__((optimize("O3")))
gpio_write_pixels(struct gpio_bus *bus, const uint16_t *pixels, uint32_t count)
{
    /* DC stays high (data mode) — stream pixels as fast as possible */
    for (uint32_t i = 0; i < count; i++)
        bus_write16(bus, pixels[i]);
}
