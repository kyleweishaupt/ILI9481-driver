# SPDX-License-Identifier: GPL-2.0-only
#
# Makefile — ILI9486 TFT display tools
#
# Build:   make
# Install: sudo make install
# Clean:   make clean
#
# The display is driven by the kernel's fbtft/fb_ili9486 SPI module
# (loaded via dtoverlay=piscreen).  We only build fbcp — a simple
# framebuffer copy utility that mirrors /dev/fb0 → /dev/fb1.

CC      ?= gcc
CFLAGS   = -O2 -Wall -Wextra -Wno-unused-parameter
LDFLAGS  = -lrt

TARGET = fbcp

.PHONY: all install uninstall clean

all: $(TARGET)

$(TARGET): src/fbcp.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

install: $(TARGET)
	install -m 755 $(TARGET) /usr/local/bin/$(TARGET)

uninstall:
	rm -f /usr/local/bin/$(TARGET)

clean:
	rm -f $(TARGET)
