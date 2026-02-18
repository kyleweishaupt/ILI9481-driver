/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * ili9481.c — ILI9481 display controller init sequence and flush logic
 *
 * Ported from driver/ili9481-gpio.h (init table) and
 * driver/ili9481-gpio.c (reset + init loop + CASET/PASET/RAMWR flush).
 */

#include <stdint.h>
#include <unistd.h>

#include "ili9481.h"
#include "../bus/gpio_mmio.h"
#include "../core/logging.h"
#include "ili9481_hw.h"

/* ------------------------------------------------------------------ */
/* Init command table (verbatim from kernel driver)                   */
/* ------------------------------------------------------------------ */

struct ili9481_reg_cmd {
    uint8_t  cmd;
    uint8_t  len;
    uint8_t  data[12];
    uint16_t delay_ms;
};

static const struct ili9481_reg_cmd ili9481_init_cmds[] = {
    /* Software reset */
    { ILI9481_SWRESET,  0, {0}, 50 },

    /* Exit sleep */
    { ILI9481_SLPOUT,   0, {0}, 20 },

    /* Power setting */
    { ILI9481_PWRSET,   3, { 0x07, 0x42, 0x18 }, 0 },

    /* VCOM control */
    { ILI9481_VMCTR,    3, { 0x00, 0x07, 0x10 }, 0 },

    /* Power setting for normal mode */
    { ILI9481_PWRNORM,  2, { 0x01, 0x02 }, 0 },

    /* Panel driving setting */
    { ILI9481_PANELDRV, 5, { 0x10, 0x3B, 0x00, 0x02, 0x11 }, 0 },

    /* Frame rate / inversion control */
    { ILI9481_FRMCTR,   1, { 0x03 }, 0 },

    /* Gamma setting (12 bytes) */
    { ILI9481_GAMMASET, 12, { 0x00, 0x32, 0x36, 0x45, 0x06, 0x16,
                               0x37, 0x75, 0x77, 0x54, 0x0C, 0x00 }, 0 },

    /* Pixel format — 12-bit RGB444 (only DB0–DB11 are wired) */
    { ILI9481_COLMOD,   1, { ILI9481_COLMOD_12BIT }, 0 },

    /* Display on */
    { ILI9481_DISPON,   0, {0}, 25 },
};

#define ILI9481_INIT_CMD_COUNT \
    (sizeof(ili9481_init_cmds) / sizeof(ili9481_init_cmds[0]))

/* ------------------------------------------------------------------ */
/* MADCTL rotation helper                                             */
/* ------------------------------------------------------------------ */

static uint8_t ili9481_madctl_for_rotate(uint32_t rotate)
{
    switch (rotate) {
    case 0:   return ILI9481_MADCTL_0;
    case 90:  return ILI9481_MADCTL_90;
    case 180: return ILI9481_MADCTL_180;
    case 270: return ILI9481_MADCTL_270;
    default:  return ILI9481_MADCTL_270;
    }
}

/* ------------------------------------------------------------------ */
/* Public API                                                         */
/* ------------------------------------------------------------------ */

void ili9481_init(struct gpio_bus *bus, uint32_t rotate)
{
    unsigned int i, j;

    /* Hardware reset */
    gpio_hw_reset(bus);

    /* Send init command sequence */
    for (i = 0; i < ILI9481_INIT_CMD_COUNT; i++) {
        const struct ili9481_reg_cmd *c = &ili9481_init_cmds[i];

        gpio_write_cmd(bus, c->cmd);
        for (j = 0; j < c->len; j++)
            gpio_write_data(bus, c->data[j]);
        if (c->delay_ms)
            usleep((unsigned int)c->delay_ms * 1000);
    }

    /* Apply rotation via MADCTL */
    gpio_write_cmd(bus, ILI9481_MADCTL);
    gpio_write_data(bus, ili9481_madctl_for_rotate(rotate));

    log_info("ILI9481 initialised (rotate=%u, MADCTL=0x%02X)",
             rotate, ili9481_madctl_for_rotate(rotate));
}

void ili9481_flush_full(struct gpio_bus *bus,
                        uint16_t width, uint16_t height,
                        const uint16_t *pixels)
{
    /* Column address range — full width */
    gpio_write_cmd(bus, ILI9481_CASET);
    gpio_write_data(bus, 0x00);
    gpio_write_data(bus, 0x00);
    gpio_write_data(bus, (width - 1) >> 8);
    gpio_write_data(bus, (width - 1) & 0xFF);

    /* Page (row) address range — full height */
    gpio_write_cmd(bus, ILI9481_PASET);
    gpio_write_data(bus, 0x00);
    gpio_write_data(bus, 0x00);
    gpio_write_data(bus, (height - 1) >> 8);
    gpio_write_data(bus, (height - 1) & 0xFF);

    /* Begin memory write and stream all pixels */
    gpio_write_cmd(bus, ILI9481_RAMWR);
    gpio_write_pixels(bus, pixels, (uint32_t)width * height);
}

void ili9481_power_off(struct gpio_bus *bus)
{
    gpio_write_cmd(bus, ILI9481_DISPOFF);
    usleep(20000);
    gpio_write_cmd(bus, ILI9481_SLPIN);
    usleep(120000);

    log_info("ILI9481 powered off (DISPOFF + SLPIN)");
}
