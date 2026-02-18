# SPDX-License-Identifier: GPL-2.0-only
#
# Kbuild Makefile for the ili9481-gpio out-of-tree module.
#
# Usage from install.sh (or manually):
#   make -C /lib/modules/$(uname -r)/build M=$(pwd) modules
#   make -C /lib/modules/$(uname -r)/build M=$(pwd) modules_install
#

KERNEL_DIR ?= /lib/modules/$(shell uname -r)/build
PWD        := $(shell pwd)

obj-m := ili9481-gpio.o

all:
	$(MAKE) -C $(KERNEL_DIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KERNEL_DIR) M=$(PWD) clean

install:
	$(MAKE) -C $(KERNEL_DIR) M=$(PWD) modules_install

.PHONY: all clean install
