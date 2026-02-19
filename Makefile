# SPDX-License-Identifier: GPL-2.0-only
#
# Makefile — Inland 3.5" TFT display SPI mirror daemon
#
# Build:   make
# Install: sudo make install
# Clean:   make clean
#
# fbcp mirrors /dev/fb0 → TFT display via SPI (/dev/spidev0.0).
# Requires vc4-fkms-v3d so that fb0 has real content.

CC       ?= gcc
CFLAGS    = -O2 -Wall -Wextra -Wno-unused-parameter -Wno-stringop-truncation
LDFLAGS   = -lrt

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
