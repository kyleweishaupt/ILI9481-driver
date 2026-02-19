/*
 * test_speed.c — Find max stable SPI speed for TFT display
 * Tests speeds from 2MHz to 16MHz, filling unique colors at each.
 * Reports which ones work visually.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <linux/spi/spidev.h>
#include <linux/gpio.h>

#define W 480
#define H 320
#define DC_PIN  24
#define RST_PIN 25

static int spi_fd = -1, dc_fd = -1, rst_fd = -1;

static int gpio_open(int chip_fd, unsigned line, int init_val) {
    struct gpio_v2_line_request r;
    memset(&r, 0, sizeof(r));
    r.offsets[0] = line; r.num_lines = 1;
    r.config.flags = GPIO_V2_LINE_FLAG_OUTPUT;
    if (init_val) {
        r.config.num_attrs = 1;
        r.config.attrs[0].attr.id = GPIO_V2_LINE_ATTR_ID_OUTPUT_VALUES;
        r.config.attrs[0].attr.values = 1; r.config.attrs[0].mask = 1;
    }
    strncpy(r.consumer, "sptest", 6);
    if (ioctl(chip_fd, GPIO_V2_GET_LINE_IOCTL, &r) < 0) return -1;
    return r.fd;
}
static void gpio_set(int fd, int v) {
    struct gpio_v2_line_values lv = { .bits = v?1:0, .mask = 1 };
    ioctl(fd, GPIO_V2_LINE_SET_VALUES_IOCTL, &lv);
}
static void spi_tx(const uint8_t *buf, uint32_t len, uint32_t hz) {
    while (len > 0) {
        uint32_t c = len > 4096 ? 4096 : len;
        struct spi_ioc_transfer t;
        memset(&t, 0, sizeof(t));
        t.tx_buf = (uintptr_t)buf; t.len = c;
        t.speed_hz = hz; t.bits_per_word = 8;
        ioctl(spi_fd, SPI_IOC_MESSAGE(1), &t);
        buf += c; len -= c;
    }
}
static void lcd_cmd(uint8_t c, uint32_t hz) {
    uint8_t buf[2] = {0x00, c};
    gpio_set(dc_fd, 0); spi_tx(buf, 2, hz);
}
static void lcd_data16(const uint8_t *d, size_t n, uint32_t hz) {
    uint8_t buf[128];
    gpio_set(dc_fd, 1);
    while (n > 0) {
        size_t batch = n > 64 ? 64 : n;
        for (size_t i = 0; i < batch; i++) { buf[i*2]=0; buf[i*2+1]=d[i]; }
        spi_tx(buf, batch*2, hz);
        d += batch; n -= batch;
    }
}
static void lcd_d8(uint8_t v, uint32_t hz) { lcd_data16(&v, 1, hz); }

static void hw_reset(void) {
    gpio_set(rst_fd, 1); usleep(50000);
    gpio_set(rst_fd, 0); usleep(50000);
    gpio_set(rst_fd, 1); usleep(150000);
}

/* Always init at 1MHz (known working speed) */
static void init_display(void) {
    uint32_t hz = 1000000;
    hw_reset();
    lcd_cmd(0xF1, hz); { uint8_t d[]={0x36,0x04,0x00,0x3C,0x0F,0x8F}; lcd_data16(d,sizeof d,hz); }
    lcd_cmd(0xF2, hz); { uint8_t d[]={0x18,0xA3,0x12,0x02,0xB2,0x12,0xFF,0x10,0x00}; lcd_data16(d,sizeof d,hz); }
    lcd_cmd(0xF8, hz); { uint8_t d[]={0x21,0x04}; lcd_data16(d,sizeof d,hz); }
    lcd_cmd(0xF9, hz); { uint8_t d[]={0x00,0x08}; lcd_data16(d,sizeof d,hz); }
    lcd_cmd(0x36, hz); lcd_d8(0x08, hz);
    lcd_cmd(0xB4, hz); lcd_d8(0x00, hz);
    lcd_cmd(0xC1, hz); lcd_d8(0x41, hz);
    lcd_cmd(0xC5, hz); { uint8_t d[]={0x00,0x91,0x80,0x00}; lcd_data16(d,sizeof d,hz); }
    lcd_cmd(0xE0, hz); { uint8_t d[]={0x0F,0x1F,0x1C,0x0C,0x0F,0x08,0x48,0x98,0x37,0x0A,0x13,0x04,0x11,0x0D,0x00}; lcd_data16(d,sizeof d,hz); }
    lcd_cmd(0xE1, hz); { uint8_t d[]={0x0F,0x32,0x2E,0x0B,0x0D,0x05,0x47,0x75,0x37,0x06,0x10,0x03,0x24,0x20,0x00}; lcd_data16(d,sizeof d,hz); }
    lcd_cmd(0x3A, hz); lcd_d8(0x55, hz);
    lcd_cmd(0x11, hz); usleep(150000);
    lcd_cmd(0x36, hz); lcd_d8(0x28, hz); usleep(50000);
    lcd_cmd(0x29, hz); usleep(50000);
}

static void fill(uint16_t color, uint32_t hz) {
    uint16_t x1=W-1, y1=H-1;
    lcd_cmd(0x2A, hz); { uint8_t d[]={0,0,x1>>8,x1&0xFF}; lcd_data16(d,4,hz); }
    lcd_cmd(0x2B, hz); { uint8_t d[]={0,0,y1>>8,y1&0xFF}; lcd_data16(d,4,hz); }
    lcd_cmd(0x2C, hz);
    uint8_t hi=color>>8, lo=color&0xFF;
    uint8_t row[W*2];
    for (int i=0;i<W;i++){row[i*2]=hi;row[i*2+1]=lo;}
    gpio_set(dc_fd, 1);
    for (int y=0;y<H;y++) spi_tx(row,sizeof(row),hz);
}

int main(void) {
    struct { uint32_t hz; const char *label; uint16_t color; } speeds[] = {
        {  2000000, " 2 MHz", 0xF800 },  /* RED */
        {  4000000, " 4 MHz", 0x07E0 },  /* GREEN */
        {  6000000, " 6 MHz", 0x001F },  /* BLUE */
        {  8000000, " 8 MHz", 0xFFE0 },  /* YELLOW */
        { 10000000, "10 MHz", 0xF81F },  /* MAGENTA */
        { 12000000, "12 MHz", 0x07FF },  /* CYAN */
        { 14000000, "14 MHz", 0xFD20 },  /* ORANGE */
        { 16000000, "16 MHz", 0xFC18 },  /* PINK */
    };
    int n = sizeof(speeds)/sizeof(speeds[0]);

    int gchip = open("/dev/gpiochip0", O_RDONLY);
    if (gchip < 0) { perror("gpiochip0"); return 1; }
    dc_fd = gpio_open(gchip, DC_PIN, 0);
    rst_fd = gpio_open(gchip, RST_PIN, 1);
    close(gchip);
    if (dc_fd<0||rst_fd<0) return 1;

    spi_fd = open("/dev/spidev0.0", O_RDWR);
    if (spi_fd<0){perror("spi");return 1;}
    uint8_t m=0,b=8; uint32_t s=1000000;
    ioctl(spi_fd, SPI_IOC_WR_MODE, &m);
    ioctl(spi_fd, SPI_IOC_WR_BITS_PER_WORD, &b);
    ioctl(spi_fd, SPI_IOC_WR_MAX_SPEED_HZ, &s);

    fprintf(stderr, "Initializing display at 1MHz...\n");
    init_display();

    fprintf(stderr, "\n╔══════════════════════════════════════╗\n");
    fprintf(stderr, "║  SPI SPEED TEST — 8 speeds, 8s each ║\n");
    fprintf(stderr, "╚══════════════════════════════════════╝\n\n");

    for (int i = 0; i < n; i++) {
        fprintf(stderr, " Test %d/%d: %s → %s (0x%04X) ...\n",
                i+1, n, speeds[i].label,
                (char*[]){"RED","GREEN","BLUE","YELLOW","MAGENTA","CYAN","ORANGE","PINK"}[i],
                speeds[i].color);
        fill(speeds[i].color, speeds[i].hz);
        fprintf(stderr, "   Holding 8 seconds...\n");
        sleep(8);
    }

    fprintf(stderr, "\n══════ SPEED TEST DONE ══════\n");
    fprintf(stderr, "Which colors showed correctly?\n");
    fprintf(stderr, "  RED=2MHz GREEN=4MHz BLUE=6MHz YELLOW=8MHz\n");
    fprintf(stderr, "  MAGENTA=10MHz CYAN=12MHz ORANGE=14MHz PINK=16MHz\n");

    close(spi_fd); close(dc_fd); close(rst_fd);
    return 0;
}
