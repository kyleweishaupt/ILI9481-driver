/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * fbcp.c — Userspace SPI framebuffer mirror for MPI3501 (ILI9486) TFT
 *
 * CRITICAL: The ILI9486 uses 16-bit SPI register width (regwidth=16).
 * Every command byte and every parameter byte must be sent as TWO bytes:
 *   0x00, <byte>
 * Only bulk pixel data (after RAMWR) is sent as raw bytes.
 * This matches the kernel fbtft fb_ili9486 driver behavior.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <time.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <linux/fb.h>
#include <linux/spi/spidev.h>
#include <linux/gpio.h>

#define DISPLAY_W  480
#define DISPLAY_H  320
#define GPIO_DC    24
#define GPIO_RST   25
#define SPI_HZ     8000000
#define SPI_CHUNK  4096

static volatile int g_running = 1;
static int spi_fd = -1, dc_fd = -1, rst_fd = -1;

static void sig_handler(int s) { (void)s; g_running = 0; }

/* ── GPIO (gpiochip v2) ─────────────────────────────────────────── */
static int gpio_req_out(int chip, unsigned line, int init_val)
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
    strncpy(r.consumer, "fbcp", 4);
    if (ioctl(chip, GPIO_V2_GET_LINE_IOCTL, &r) < 0) {
        fprintf(stderr, "GPIO line %u: %s\n", line, strerror(errno));
        return -1;
    }
    return r.fd;
}

static inline void gpio_set(int fd, int v)
{
    struct gpio_v2_line_values lv = { .bits = v ? 1 : 0, .mask = 1 };
    ioctl(fd, GPIO_V2_LINE_SET_VALUES_IOCTL, &lv);
}

/* ── SPI ─────────────────────────────────────────────────────────── */
static int spi_init(const char *dev)
{
    spi_fd = open(dev, O_RDWR);
    if (spi_fd < 0) { perror(dev); return -1; }
    uint8_t m = SPI_MODE_0, b = 8;
    uint32_t s = SPI_HZ;
    ioctl(spi_fd, SPI_IOC_WR_MODE, &m);
    ioctl(spi_fd, SPI_IOC_WR_BITS_PER_WORD, &b);
    ioctl(spi_fd, SPI_IOC_WR_MAX_SPEED_HZ, &s);
    return 0;
}

static void spi_tx(const uint8_t *buf, uint32_t len)
{
    struct spi_ioc_transfer t;
    memset(&t, 0, sizeof(t));
    t.tx_buf = (uintptr_t)buf;
    t.len = len;
    t.speed_hz = SPI_HZ;
    t.bits_per_word = 8;
    ioctl(spi_fd, SPI_IOC_MESSAGE(1), &t);
}

/*
 * ILI9486 requires 16-bit register width:
 *   Command byte 0xAB  is sent as  DC=0, SPI bytes: 0x00 0xAB
 *   Data byte    0xCD  is sent as  DC=1, SPI bytes: 0x00 0xCD
 * Pixel data after RAMWR is sent as raw bytes (no padding).
 */
static void lcd_cmd(uint8_t c)
{
    uint8_t buf[2] = { 0x00, c };
    gpio_set(dc_fd, 0);
    spi_tx(buf, 2);
}

static void lcd_data16(const uint8_t *d, size_t n)
{
    /* Each data byte is expanded to 2 bytes: 0x00, byte */
    uint8_t buf[128];  /* max 64 data bytes at a time */
    gpio_set(dc_fd, 1);
    while (n > 0) {
        size_t batch = n > 64 ? 64 : n;
        for (size_t i = 0; i < batch; i++) {
            buf[i*2]     = 0x00;
            buf[i*2 + 1] = d[i];
        }
        spi_tx(buf, batch * 2);
        d += batch;
        n -= batch;
    }
}

static void lcd_d8(uint8_t v) { lcd_data16(&v, 1); }

/* Raw data (no 16-bit padding) — for pixel writes */
static void lcd_raw(const uint8_t *d, size_t n)
{
    gpio_set(dc_fd, 1);
    spi_tx(d, n);
}

/* ── ILI9486 init (MPI3501 / tft35a from LCD-show) ───────────────── */
static void ili9486_init(void)
{
    fprintf(stderr, "  RST: high → low → high\n");
    gpio_set(rst_fd, 1); usleep(50000);
    gpio_set(rst_fd, 0); usleep(50000);
    gpio_set(rst_fd, 1); usleep(150000);

    fprintf(stderr, "  Sending init sequence (16-bit register width)...\n");

    lcd_cmd(0xF1); { uint8_t d[]={0x36,0x04,0x00,0x3C,0x0F,0x8F}; lcd_data16(d,sizeof d); }
    lcd_cmd(0xF2); { uint8_t d[]={0x18,0xA3,0x12,0x02,0xB2,0x12,0xFF,0x10,0x00}; lcd_data16(d,sizeof d); }
    lcd_cmd(0xF8); { uint8_t d[]={0x21,0x04}; lcd_data16(d,sizeof d); }
    lcd_cmd(0xF9); { uint8_t d[]={0x00,0x08}; lcd_data16(d,sizeof d); }
    lcd_cmd(0x36); lcd_d8(0x08);
    lcd_cmd(0xB4); lcd_d8(0x00);
    lcd_cmd(0xC1); lcd_d8(0x41);
    lcd_cmd(0xC5); { uint8_t d[]={0x00,0x91,0x80,0x00}; lcd_data16(d,sizeof d); }
    lcd_cmd(0xE0); { uint8_t d[]={0x0F,0x1F,0x1C,0x0C,0x0F,0x08,
                                  0x48,0x98,0x37,0x0A,0x13,0x04,
                                  0x11,0x0D,0x00}; lcd_data16(d,sizeof d); }
    lcd_cmd(0xE1); { uint8_t d[]={0x0F,0x32,0x2E,0x0B,0x0D,0x05,
                                  0x47,0x75,0x37,0x06,0x10,0x03,
                                  0x24,0x20,0x00}; lcd_data16(d,sizeof d); }
    lcd_cmd(0x3A); lcd_d8(0x55);           /* 16-bit color */

    fprintf(stderr, "  Sleep out (0x11)...\n");
    lcd_cmd(0x11); usleep(150000);

    lcd_cmd(0x36); lcd_d8(0x28);           /* landscape */
    usleep(255000);

    fprintf(stderr, "  Display on (0x29)...\n");
    lcd_cmd(0x29); usleep(50000);
}

static void lcd_set_window(uint16_t x0, uint16_t y0, uint16_t x1, uint16_t y1)
{
    lcd_cmd(0x2A);
    { uint8_t d[]={x0>>8,x0&0xFF,x1>>8,x1&0xFF}; lcd_data16(d,4); }
    lcd_cmd(0x2B);
    { uint8_t d[]={y0>>8,y0&0xFF,y1>>8,y1&0xFF}; lcd_data16(d,4); }
}

/* Fill entire screen with a solid color (for testing) */
static void lcd_fill(uint16_t color)
{
    lcd_set_window(0, 0, DISPLAY_W - 1, DISPLAY_H - 1);
    lcd_cmd(0x2C);  /* RAMWR */
    /* Pixel data is raw (no 16-bit padding) */
    uint8_t hi = color >> 8, lo = color & 0xFF;
    uint8_t row[DISPLAY_W * 2];
    for (int i = 0; i < DISPLAY_W; i++) {
        row[i*2]   = hi;
        row[i*2+1] = lo;
    }
    gpio_set(dc_fd, 1);
    for (int y = 0; y < DISPLAY_H; y++)
        spi_tx(row, sizeof(row));
}

static void lcd_push(const uint16_t *buf, size_t npx)
{
    lcd_set_window(0, 0, DISPLAY_W - 1, DISPLAY_H - 1);
    lcd_cmd(0x2C);
    gpio_set(dc_fd, 1);
    const uint8_t *p = (const uint8_t *)buf;
    size_t rem = npx * 2;
    while (rem) {
        size_t c = rem > SPI_CHUNK ? SPI_CHUNK : rem;
        spi_tx(p, c);
        p += c;
        rem -= c;
    }
}

/* ── Framebuffer ─────────────────────────────────────────────────── */
struct fbi { int fd; uint8_t *m; uint32_t sz; struct fb_var_screeninfo v; struct fb_fix_screeninfo f; };

static int fb_open(const char *dev, struct fbi *fb)
{
    fb->fd = open(dev, O_RDONLY);
    if (fb->fd < 0) { perror(dev); return -1; }
    ioctl(fb->fd, FBIOGET_VSCREENINFO, &fb->v);
    ioctl(fb->fd, FBIOGET_FSCREENINFO, &fb->f);
    fb->sz = fb->f.smem_len ? fb->f.smem_len : fb->v.yres * fb->f.line_length;
    fb->m = mmap(NULL, fb->sz, PROT_READ, MAP_SHARED, fb->fd, 0);
    if (fb->m == MAP_FAILED) { perror("mmap"); close(fb->fd); return -1; }
    return 0;
}

static inline uint16_t to565(uint32_t px, uint32_t ro, uint32_t go, uint32_t bo)
{
    return (uint16_t)(((px >> (ro+8-5)) & 0xF800) |
                      ((px >> (go+8-6-5)) & 0x07E0) |
                      ((px >> (bo+8-5-11)) & 0x001F));
}

int main(int argc, char **argv)
{
    const char *src_dev="/dev/fb0", *spi_dev="/dev/spidev0.0", *gpiochip="/dev/gpiochip0";
    int fps = 15;

    for (int i=1; i<argc; i++) {
        if (!strncmp(argv[i],"--src=",6)) src_dev=argv[i]+6;
        else if (!strncmp(argv[i],"--spi=",6)) spi_dev=argv[i]+6;
        else if (!strncmp(argv[i],"--gpio=",7)) gpiochip=argv[i]+7;
        else if (!strncmp(argv[i],"--fps=",6)) { fps=atoi(argv[i]+6); if(fps<1)fps=1; if(fps>60)fps=60; }
        else if (!strcmp(argv[i],"-h")||!strcmp(argv[i],"--help")) {
            printf("Usage: fbcp [--src=DEV] [--spi=DEV] [--gpio=CHIP] [--fps=N]\n"); return 0;
        }
    }

    struct sigaction sa={0}; sa.sa_handler=sig_handler;
    sigaction(SIGTERM,&sa,NULL); sigaction(SIGINT,&sa,NULL);

    int chip = open(gpiochip, O_RDONLY);
    if (chip < 0) { perror(gpiochip); return 1; }
    dc_fd  = gpio_req_out(chip, GPIO_DC,  0);
    rst_fd = gpio_req_out(chip, GPIO_RST, 1);
    close(chip);
    if (dc_fd < 0 || rst_fd < 0) return 1;

    if (spi_init(spi_dev) < 0) return 1;

    fprintf(stderr, "fbcp: Initializing ILI9486 (16-bit regwidth)...\n");
    ili9486_init();
    fprintf(stderr, "fbcp: Init done. Filling screen RED...\n");

    /* Test: fill screen solid red so user can see immediately */
    lcd_fill(0xF800);  /* Red in RGB565 */
    fprintf(stderr, "fbcp: RED fill sent. Display should show red now.\n");
    sleep(2);

    fprintf(stderr, "fbcp: Filling GREEN...\n");
    lcd_fill(0x07E0);
    sleep(1);

    fprintf(stderr, "fbcp: Filling BLUE...\n");
    lcd_fill(0x001F);
    sleep(1);

    /* Now open fb0 and start mirroring */
    struct fbi src;
    if (fb_open(src_dev, &src) < 0) { close(spi_fd); return 1; }

    uint32_t sw=src.v.xres, sh=src.v.yres, sbpp=src.v.bits_per_pixel, sstr=src.f.line_length;
    uint32_t ro=src.v.red.offset, go=src.v.green.offset, bo=src.v.blue.offset;

    fprintf(stderr, "fbcp: %s %ux%u %ubpp → %dx%d @ %d FPS\n",
            src_dev, sw, sh, sbpp, DISPLAY_W, DISPLAY_H, fps);

    size_t npx = DISPLAY_W * DISPLAY_H;
    uint16_t *dbuf = calloc(npx, 2);
    long fns = 1000000000L / fps;
    struct timespec next, t0;
    clock_gettime(CLOCK_MONOTONIC, &next); t0 = next;
    unsigned fc = 0;

    while (g_running) {
        for (uint32_t dy = 0; dy < DISPLAY_H; dy++) {
            uint32_t sy = dy * sh / DISPLAY_H;
            uint16_t *dr = dbuf + dy * DISPLAY_W;
            if (sbpp == 16) {
                const uint16_t *sr = (const uint16_t*)(src.m + sy*sstr);
                for (uint32_t dx = 0; dx < DISPLAY_W; dx++) {
                    uint16_t v = sr[dx*sw/DISPLAY_W];
                    dr[dx] = (v>>8)|(v<<8);
                }
            } else {
                const uint32_t *sr = (const uint32_t*)(src.m + sy*sstr);
                for (uint32_t dx = 0; dx < DISPLAY_W; dx++) {
                    uint16_t v = to565(sr[dx*sw/DISPLAY_W], ro, go, bo);
                    dr[dx] = (v>>8)|(v<<8);
                }
            }
        }
        lcd_push(dbuf, npx);

        if (++fc % 100 == 0) {
            struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
            double e = (now.tv_sec-t0.tv_sec)+(now.tv_nsec-t0.tv_nsec)/1e9;
            if (e>0) fprintf(stderr, "fbcp: %.1f FPS (%u frames)\n", fc/e, fc);
        }
        next.tv_nsec += fns;
        while (next.tv_nsec >= 1000000000L) { next.tv_nsec -= 1000000000L; next.tv_sec++; }
        clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next, NULL);
    }

    free(dbuf); close(spi_fd); close(dc_fd); close(rst_fd);
    return 0;
}
