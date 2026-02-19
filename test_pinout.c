/*
 * test_pinout.c — Brute-force pinout/protocol tester for 3.5" RPi TFT
 *
 * Tries different combinations of:
 *   - DC / RST GPIO pins
 *   - SPI mode (0 vs 3)
 *   - Register width (8-bit vs 16-bit)
 *   - SPI device (CE0 vs CE1)
 *   - Init sequences (tft35a, waveshare, minimal, ILI9488)
 *
 * Each test fills the screen with a unique solid color.
 * Usage: sudo ./test_pinout
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <sys/ioctl.h>
#include <linux/spi/spidev.h>
#include <linux/gpio.h>

#define W 480
#define H 320

static int spi_fd = -1, dc_fd = -1, rst_fd = -1;
static int g_regwidth = 16;  /* 8 or 16 */

/* ── GPIO ─────────────────────────────────────────────────────── */
static int gpio_open(int chip_fd, unsigned line, int init_val)
{
    struct gpio_v2_line_request r;
    memset(&r, 0, sizeof(r));
    r.offsets[0] = line;
    r.num_lines = 1;
    r.config.flags = GPIO_V2_LINE_FLAG_OUTPUT;
    if (init_val) {
        r.config.num_attrs = 1;
        r.config.attrs[0].attr.id = GPIO_V2_LINE_ATTR_ID_OUTPUT_VALUES;
        r.config.attrs[0].attr.values = 1;
        r.config.attrs[0].mask = 1;
    }
    strncpy(r.consumer, "tptest", 6);
    if (ioctl(chip_fd, GPIO_V2_GET_LINE_IOCTL, &r) < 0) {
        fprintf(stderr, "    GPIO %u: %s\n", line, strerror(errno));
        return -1;
    }
    return r.fd;
}

static void gpio_set(int fd, int v)
{
    struct gpio_v2_line_values lv = { .bits = v ? 1 : 0, .mask = 1 };
    ioctl(fd, GPIO_V2_LINE_SET_VALUES_IOCTL, &lv);
}

static void gpio_close(int *fd) { if (*fd >= 0) { close(*fd); *fd = -1; } }

/* ── SPI ──────────────────────────────────────────────────────── */
static int spi_open(const char *dev, int mode, uint32_t hz)
{
    int fd = open(dev, O_RDWR);
    if (fd < 0) { fprintf(stderr, "    SPI %s: %s\n", dev, strerror(errno)); return -1; }
    uint8_t m = mode, b = 8;
    ioctl(fd, SPI_IOC_WR_MODE, &m);
    ioctl(fd, SPI_IOC_WR_BITS_PER_WORD, &b);
    ioctl(fd, SPI_IOC_WR_MAX_SPEED_HZ, &hz);
    return fd;
}

static void spi_tx(const uint8_t *buf, uint32_t len)
{
    while (len > 0) {
        uint32_t chunk = len > 4096 ? 4096 : len;
        struct spi_ioc_transfer t;
        memset(&t, 0, sizeof(t));
        t.tx_buf = (uintptr_t)buf;
        t.len = chunk;
        t.speed_hz = 0; /* use default */
        t.bits_per_word = 8;
        ioctl(spi_fd, SPI_IOC_MESSAGE(1), &t);
        buf += chunk;
        len -= chunk;
    }
}

/* ── LCD primitives (adapt to regwidth) ───────────────────────── */
static void lcd_cmd(uint8_t c)
{
    gpio_set(dc_fd, 0);
    if (g_regwidth == 16) {
        uint8_t buf[2] = {0x00, c};
        spi_tx(buf, 2);
    } else {
        spi_tx(&c, 1);
    }
}

static void lcd_data(const uint8_t *d, size_t n)
{
    gpio_set(dc_fd, 1);
    if (g_regwidth == 16) {
        uint8_t buf[128];
        while (n > 0) {
            size_t batch = n > 64 ? 64 : n;
            for (size_t i = 0; i < batch; i++) {
                buf[i*2]   = 0x00;
                buf[i*2+1] = d[i];
            }
            spi_tx(buf, batch * 2);
            d += batch;
            n -= batch;
        }
    } else {
        spi_tx(d, n);
    }
}

static void lcd_d8(uint8_t v) { lcd_data(&v, 1); }

static void lcd_set_window(void)
{
    uint16_t x1 = W - 1, y1 = H - 1;
    lcd_cmd(0x2A);
    { uint8_t d[] = {0,0, x1>>8, x1&0xFF}; lcd_data(d, 4); }
    lcd_cmd(0x2B);
    { uint8_t d[] = {0,0, y1>>8, y1&0xFF}; lcd_data(d, 4); }
}

static void lcd_fill(uint16_t color)
{
    lcd_set_window();
    lcd_cmd(0x2C);
    /* pixel data is ALWAYS raw (no 16-bit padding) */
    uint8_t hi = color >> 8, lo = color & 0xFF;
    uint8_t row[W * 2];
    for (int i = 0; i < W; i++) { row[i*2] = hi; row[i*2+1] = lo; }
    gpio_set(dc_fd, 1);
    for (int y = 0; y < H; y++)
        spi_tx(row, sizeof(row));
}

/* ── Init sequences ───────────────────────────────────────────── */
static void init_tft35a(void)
{
    /* tft35a overlay init (goodtft LCD-show) */
    lcd_cmd(0xF1); { uint8_t d[]={0x36,0x04,0x00,0x3C,0x0F,0x8F}; lcd_data(d,sizeof d); }
    lcd_cmd(0xF2); { uint8_t d[]={0x18,0xA3,0x12,0x02,0xB2,0x12,0xFF,0x10,0x00}; lcd_data(d,sizeof d); }
    lcd_cmd(0xF8); { uint8_t d[]={0x21,0x04}; lcd_data(d,sizeof d); }
    lcd_cmd(0xF9); { uint8_t d[]={0x00,0x08}; lcd_data(d,sizeof d); }
    lcd_cmd(0x36); lcd_d8(0x08);
    lcd_cmd(0xB4); lcd_d8(0x00);
    lcd_cmd(0xC1); lcd_d8(0x41);
    lcd_cmd(0xC5); { uint8_t d[]={0x00,0x91,0x80,0x00}; lcd_data(d,sizeof d); }
    lcd_cmd(0xE0); { uint8_t d[]={0x0F,0x1F,0x1C,0x0C,0x0F,0x08,
                                  0x48,0x98,0x37,0x0A,0x13,0x04,
                                  0x11,0x0D,0x00}; lcd_data(d,sizeof d); }
    lcd_cmd(0xE1); { uint8_t d[]={0x0F,0x32,0x2E,0x0B,0x0D,0x05,
                                  0x47,0x75,0x37,0x06,0x10,0x03,
                                  0x24,0x20,0x00}; lcd_data(d,sizeof d); }
    lcd_cmd(0x3A); lcd_d8(0x55);
    lcd_cmd(0x11); usleep(150000);
    lcd_cmd(0x36); lcd_d8(0x28);
    usleep(50000);
    lcd_cmd(0x29); usleep(50000);
}

static void init_waveshare(void)
{
    /* Waveshare 3.5" (A) / waveshare35a init */
    lcd_cmd(0x11); usleep(150000);
    lcd_cmd(0x3A); lcd_d8(0x55);
    lcd_cmd(0x36); lcd_d8(0x28);
    lcd_cmd(0xC2); lcd_d8(0x44);
    lcd_cmd(0xC5); { uint8_t d[]={0x00,0x00,0x00,0x00}; lcd_data(d,4); }
    lcd_cmd(0xE0); { uint8_t d[]={0x0F,0x1F,0x1C,0x0C,0x0F,0x08,
                                  0x48,0x98,0x37,0x0A,0x13,0x04,
                                  0x11,0x0D,0x00}; lcd_data(d,sizeof d); }
    lcd_cmd(0xE1); { uint8_t d[]={0x0F,0x32,0x2E,0x0B,0x0D,0x05,
                                  0x47,0x75,0x37,0x06,0x10,0x03,
                                  0x24,0x20,0x00}; lcd_data(d,sizeof d); }
    lcd_cmd(0x29); usleep(50000);
}

static void init_minimal(void)
{
    /* Absolute minimum: software reset + sleep out + display on */
    lcd_cmd(0x01); usleep(200000);  /* SWRST */
    lcd_cmd(0x11); usleep(150000);  /* SLPOUT */
    lcd_cmd(0x3A); lcd_d8(0x55);   /* 16bpp */
    lcd_cmd(0x36); lcd_d8(0x28);   /* landscape */
    lcd_cmd(0x29); usleep(50000);  /* DISPON */
}

static void init_ili9488(void)
{
    /* ILI9488 style init (8-bit registers, different power control) */
    lcd_cmd(0xE0); { uint8_t d[]={0x00,0x03,0x09,0x08,0x16,0x0A,
                                  0x3F,0x78,0x4C,0x09,0x0A,0x08,
                                  0x16,0x1A,0x0F}; lcd_data(d,sizeof d); }
    lcd_cmd(0xE1); { uint8_t d[]={0x00,0x16,0x19,0x03,0x0F,0x05,
                                  0x32,0x45,0x46,0x04,0x0E,0x0D,
                                  0x35,0x37,0x0F}; lcd_data(d,sizeof d); }
    lcd_cmd(0xC0); { uint8_t d[]={0x17,0x15}; lcd_data(d,2); }
    lcd_cmd(0xC1); lcd_d8(0x41);
    lcd_cmd(0xC5); { uint8_t d[]={0x00,0x12,0x80}; lcd_data(d,3); }
    lcd_cmd(0x36); lcd_d8(0x28);
    lcd_cmd(0x3A); lcd_d8(0x55);   /* 16bpp */
    lcd_cmd(0xB0); lcd_d8(0x00);
    lcd_cmd(0xB1); { uint8_t d[]={0xA0,0x11}; lcd_data(d,2); }
    lcd_cmd(0xB4); lcd_d8(0x02);
    lcd_cmd(0xB6); { uint8_t d[]={0x02,0x02}; lcd_data(d,2); }
    lcd_cmd(0xE9); lcd_d8(0x00);
    lcd_cmd(0xF7); { uint8_t d[]={0xA9,0x51,0x2C,0x82}; lcd_data(d,4); }
    lcd_cmd(0x11); usleep(150000);
    lcd_cmd(0x29); usleep(50000);
}

static void init_st7796(void)
{
    /* ST7796S init */
    lcd_cmd(0x01); usleep(150000);
    lcd_cmd(0x11); usleep(150000);
    lcd_cmd(0xF0); lcd_d8(0xC3);
    lcd_cmd(0xF0); lcd_d8(0x96);
    lcd_cmd(0x36); lcd_d8(0x28);
    lcd_cmd(0x3A); lcd_d8(0x55);
    lcd_cmd(0xB4); lcd_d8(0x01);
    lcd_cmd(0xB7); lcd_d8(0xC6);
    lcd_cmd(0xC0); { uint8_t d[]={0x80,0x65}; lcd_data(d,2); }
    lcd_cmd(0xC1); lcd_d8(0x13);
    lcd_cmd(0xC2); lcd_d8(0xA7);
    lcd_cmd(0xC5); lcd_d8(0x09);
    lcd_cmd(0xE8); { uint8_t d[]={0x40,0x8A,0x00,0x00,0x29,0x19,0xA5,0x33}; lcd_data(d,8); }
    lcd_cmd(0xE0); { uint8_t d[]={0xF0,0x06,0x0B,0x07,0x06,0x05,
                                  0x2E,0x33,0x47,0x3A,0x17,0x16,
                                  0x2E,0x31}; lcd_data(d,sizeof d); }
    lcd_cmd(0xE1); { uint8_t d[]={0xF0,0x09,0x0D,0x09,0x08,0x23,
                                  0x2E,0x33,0x46,0x38,0x13,0x13,
                                  0x2C,0x32}; lcd_data(d,sizeof d); }
    lcd_cmd(0xF0); lcd_d8(0x3C);
    lcd_cmd(0xF0); lcd_d8(0x69);
    lcd_cmd(0x29); usleep(50000);
}

/* ── Test runner ──────────────────────────────────────────────── */
struct test_config {
    const char *name;
    const char *color_name;
    uint16_t    color;
    int         dc_pin;
    int         rst_pin;
    int         regwidth;
    int         spi_mode;
    uint32_t    spi_hz;
    const char *spi_dev;
    void       (*init_fn)(void);
};

static void hw_reset(void)
{
    gpio_set(rst_fd, 1); usleep(50000);
    gpio_set(rst_fd, 0); usleep(50000);
    gpio_set(rst_fd, 1); usleep(150000);
}

static int run_test(int chip_fd, const struct test_config *t, int hold_sec)
{
    fprintf(stderr, "\n═══════════════════════════════════════════════════\n");
    fprintf(stderr, " TEST: %s\n", t->name);
    fprintf(stderr, " Color: %s (0x%04X)\n", t->color_name, t->color);
    fprintf(stderr, " DC=GPIO%d  RST=GPIO%d  regwidth=%d  SPI_MODE_%d\n",
            t->dc_pin, t->rst_pin, t->regwidth, t->spi_mode);
    fprintf(stderr, " SPI=%s  speed=%uHz\n", t->spi_dev, t->spi_hz);
    fprintf(stderr, "═══════════════════════════════════════════════════\n");

    /* Open GPIO */
    dc_fd  = gpio_open(chip_fd, t->dc_pin, 0);
    rst_fd = gpio_open(chip_fd, t->rst_pin, 1);
    if (dc_fd < 0 || rst_fd < 0) {
        fprintf(stderr, "  SKIP (GPIO busy)\n");
        gpio_close(&dc_fd); gpio_close(&rst_fd);
        return -1;
    }

    /* Open SPI */
    spi_fd = spi_open(t->spi_dev, t->spi_mode, t->spi_hz);
    if (spi_fd < 0) {
        fprintf(stderr, "  SKIP (SPI failed)\n");
        gpio_close(&dc_fd); gpio_close(&rst_fd);
        return -1;
    }

    g_regwidth = t->regwidth;

    /* Reset + Init + Fill */
    hw_reset();
    t->init_fn();
    lcd_fill(t->color);

    fprintf(stderr, "  >>> HOLDING %s for %d seconds <<<\n", t->color_name, hold_sec);
    sleep(hold_sec);

    /* Cleanup */
    close(spi_fd); spi_fd = -1;
    gpio_close(&dc_fd);
    gpio_close(&rst_fd);
    return 0;
}

int main(int argc, char **argv)
{
    int hold = 10;
    int start_test = -1;  /* -1 = run all */

    for (int i = 1; i < argc; i++) {
        if (!strncmp(argv[i], "--hold=", 7)) hold = atoi(argv[i]+7);
        if (!strncmp(argv[i], "--test=", 7)) start_test = atoi(argv[i]+7);
    }

    /* ----------- TEST MATRIX ----------- */
    struct test_config tests[] = {
        /* Test 0: GPIO-only RST test (uses init_minimal, but main goal is RST toggle) */
        { "RST toggle test (display should flicker/blank)",
          "RED", 0xF800, 24, 25, 8, 0, 16000000, "/dev/spidev0.0", init_minimal },

        /* Tests 1-4: tft35a init, vary DC/RST and regwidth */
        { "DC=24 RST=25 regwidth=16 MODE_0 tft35a",
          "GREEN", 0x07E0, 24, 25, 16, 0, 16000000, "/dev/spidev0.0", init_tft35a },
        { "DC=24 RST=25 regwidth=8 MODE_0 tft35a",
          "BLUE", 0x001F, 24, 25, 8, 0, 16000000, "/dev/spidev0.0", init_tft35a },
        { "DC=25 RST=24 regwidth=16 MODE_0 tft35a (SWAPPED)",
          "YELLOW", 0xFFE0, 25, 24, 16, 0, 16000000, "/dev/spidev0.0", init_tft35a },
        { "DC=25 RST=24 regwidth=8 MODE_0 tft35a (SWAPPED)",
          "MAGENTA", 0xF81F, 25, 24, 8, 0, 16000000, "/dev/spidev0.0", init_tft35a },

        /* Tests 5-6: SPI MODE_3 */
        { "DC=24 RST=25 regwidth=16 MODE_3 tft35a",
          "CYAN", 0x07FF, 24, 25, 16, 3, 16000000, "/dev/spidev0.0", init_tft35a },
        { "DC=24 RST=25 regwidth=8 MODE_3 tft35a",
          "ORANGE", 0xFD20, 24, 25, 8, 3, 16000000, "/dev/spidev0.0", init_tft35a },

        /* Tests 7-8: Slow SPI (1MHz) */
        { "DC=24 RST=25 regwidth=16 MODE_0 1MHz tft35a",
          "PINK", 0xFC18, 24, 25, 16, 0, 1000000, "/dev/spidev0.0", init_tft35a },
        { "DC=24 RST=25 regwidth=8 MODE_0 1MHz tft35a",
          "PURPLE", 0x780F, 24, 25, 8, 0, 1000000, "/dev/spidev0.0", init_tft35a },

        /* Tests 9-10: CE1 instead of CE0 */
        { "CE1 DC=24 RST=25 regwidth=16 MODE_0 tft35a",
          "DARK_GREEN", 0x03E0, 24, 25, 16, 0, 16000000, "/dev/spidev0.1", init_tft35a },
        { "CE1 DC=24 RST=25 regwidth=8 MODE_0 tft35a",
          "DARK_RED", 0x7800, 24, 25, 8, 0, 16000000, "/dev/spidev0.1", init_tft35a },

        /* Tests 11-12: Different init sequences */
        { "DC=24 RST=25 regwidth=8 MODE_0 ILI9488 init",
          "LIME", 0xAFE5, 24, 25, 8, 0, 16000000, "/dev/spidev0.0", init_ili9488 },
        { "DC=24 RST=25 regwidth=8 MODE_0 ST7796 init",
          "BROWN", 0x9A60, 24, 25, 8, 0, 16000000, "/dev/spidev0.0", init_st7796 },

        /* Tests 13-14: Waveshare init */
        { "DC=24 RST=25 regwidth=16 MODE_0 waveshare init",
          "TEAL", 0x0410, 24, 25, 16, 0, 16000000, "/dev/spidev0.0", init_waveshare },
        { "DC=24 RST=25 regwidth=8 MODE_0 waveshare init",
          "NAVY", 0x0010, 24, 25, 8, 0, 16000000, "/dev/spidev0.0", init_waveshare },

        /* Tests 15-16: Minimal init (maybe controller was already initialized) */
        { "DC=24 RST=25 regwidth=16 MODE_0 minimal init",
          "MAROON", 0x7800, 24, 25, 16, 0, 16000000, "/dev/spidev0.0", init_minimal },
        { "DC=24 RST=25 regwidth=8 MODE_0 minimal init",
          "OLIVE", 0x7BE0, 24, 25, 8, 0, 16000000, "/dev/spidev0.0", init_minimal },

        /* Tests 17-18: Swapped DC/RST with different inits */
        { "DC=25 RST=24 regwidth=8 MODE_0 ILI9488 init (SWAPPED)",
          "SALMON", 0xFC0E, 25, 24, 8, 0, 16000000, "/dev/spidev0.0", init_ili9488 },
        { "DC=25 RST=24 regwidth=8 MODE_0 minimal (SWAPPED)",
          "VIOLET", 0xEC1D, 25, 24, 8, 0, 16000000, "/dev/spidev0.0", init_minimal },
    };

    int ntests = sizeof(tests) / sizeof(tests[0]);

    int gchip = open("/dev/gpiochip0", O_RDONLY);
    if (gchip < 0) { perror("gpiochip0"); return 1; }

    fprintf(stderr, "\n");
    fprintf(stderr, "╔═══════════════════════════════════════════════════╗\n");
    fprintf(stderr, "║   TFT DISPLAY PINOUT / PROTOCOL TESTER           ║\n");
    fprintf(stderr, "║   %d tests, %d seconds each                       ║\n", ntests, hold);
    fprintf(stderr, "║   Watch the display for ANY color change!         ║\n");
    fprintf(stderr, "╚═══════════════════════════════════════════════════╝\n");

    if (start_test >= 0 && start_test < ntests) {
        fprintf(stderr, "Running single test #%d\n", start_test);
        run_test(gchip, &tests[start_test], hold);
    } else {
        for (int i = 0; i < ntests; i++) {
            fprintf(stderr, "\n──── Test %d of %d ────\n", i+1, ntests);
            run_test(gchip, &tests[i], hold);
        }
    }

    close(gchip);
    fprintf(stderr, "\n══════ ALL TESTS COMPLETE ══════\n");
    fprintf(stderr, "Which test(s) showed a color? Report the color name(s).\n");
    return 0;
}
