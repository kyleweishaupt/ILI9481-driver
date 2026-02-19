# SPDX-License-Identifier: GPL-2.0-only
#
# Makefile — ILI9481 userspace framebuffer daemon
#
# Build:          make
# Build + touch:  make TOUCH=1
# Install:        sudo make install
# Clean:          make clean
#
# The ILI9481 is driven via 8-bit 8080-I parallel interface using MMIO
# GPIO.  The daemon mirrors /dev/fb0 onto the TFT display.

CC       ?= gcc
CFLAGS    = -O2 -Wall -Wextra -Wno-unused-parameter
LDFLAGS   = -lrt -lpthread
INCLUDES  = -Iinclude

TARGET = ili9481-fb

# Source files
SRCS = src/core/service_main.c \
       src/core/config.c \
       src/core/logging.c \
       src/bus/gpio_mmio.c \
       src/display/ili9481.c \
       src/display/framebuffer.c

# Optional touch support (make TOUCH=1)
ifdef TOUCH
CFLAGS  += -DENABLE_TOUCH
SRCS    += src/touch/xpt2046.c src/touch/uinput_touch.c
endif

.PHONY: all install uninstall clean

all: $(TARGET)

$(TARGET): $(SRCS)
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ $^ $(LDFLAGS)

install: $(TARGET)
	install -m 755 $(TARGET) /usr/local/bin/$(TARGET)
	install -d /etc/ili9481
	install -m 644 config/ili9481.conf /etc/ili9481/ili9481.conf

uninstall:
	rm -f /usr/local/bin/$(TARGET)
	rm -rf /etc/ili9481

clean:
	rm -f $(TARGET)
