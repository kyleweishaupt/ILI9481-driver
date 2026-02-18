# SPDX-License-Identifier: GPL-2.0-only
#
# Makefile — ILI9481 userspace framebuffer daemon
#
# Build:   make
# Install: sudo make install
# Clean:   make clean
#
# Options:
#   ENABLE_TOUCH=1   Compile with XPT2046 touch support (default: 0)

CC      ?= gcc
CFLAGS   = -O2 -Wall -Wextra -Wno-unused-parameter -Iinclude -Isrc
LDFLAGS  = -lpthread -lrt

ENABLE_TOUCH ?= 0
ifeq ($(ENABLE_TOUCH),1)
  CFLAGS += -DENABLE_TOUCH
  TOUCH_OBJS = src/touch/xpt2046.o src/touch/uinput_touch.o
endif

OBJS = src/bus/gpio_mmio.o \
       src/display/ili9481.o \
       src/display/framebuffer.o \
       src/core/config.o \
       src/core/logging.o \
       src/core/service_main.o \
       $(TOUCH_OBJS)

TARGET = ili9481-fb

.PHONY: all install uninstall clean

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

# Pattern rule for .c → .o
%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

install: $(TARGET)
	install -m 755 $(TARGET) /usr/local/bin/$(TARGET)
	install -d /etc/ili9481
	install -m 644 config/ili9481.conf /etc/ili9481/ili9481.conf
	install -d /etc/systemd/system
	install -m 644 systemd/ili9481-fb.service /etc/systemd/system/ili9481-fb.service

uninstall:
	rm -f /usr/local/bin/$(TARGET)
	rm -f /etc/systemd/system/ili9481-fb.service
	rm -rf /etc/ili9481

clean:
	rm -f $(OBJS) $(TARGET)
