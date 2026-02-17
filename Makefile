# SPDX-License-Identifier: GPL-2.0-only
#
# Makefile for the ILI9481 DRM/KMS display driver (out-of-tree)
#
# Usage:
#   make                         — build against running kernel
#   make KDIR=/path/to/kernel    — build against a specific kernel tree
#   make install                 — install module + overlay + DKMS
#   make uninstall               — remove module + overlay + DKMS
#   make dtbo                    — compile device-tree overlay only
#
# Cross-compilation example (Raspberry Pi arm64):
#   make KDIR=~/kernel-source ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
#

MODULE_NAME := ili9481
obj-m += $(MODULE_NAME).o

KDIR    ?= /lib/modules/$(shell uname -r)/build
DTC     ?= dtc
INSTALL_MOD_DIR ?= extra

# Device-tree overlay
DTS_SRC := ili9481-overlay.dts
DTBO    := ili9481.dtbo
OVERLAYS_DIR := /boot/overlays

# DKMS
DKMS_NAME    := $(MODULE_NAME)
DKMS_VERSION := $(shell sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' dkms.conf)
DKMS_SRC     := /usr/src/$(DKMS_NAME)-$(DKMS_VERSION)

# ── Build targets ────────────────────────────────────────────────────

all: modules dtbo

modules:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

dtbo: $(DTBO)

$(DTBO): $(DTS_SRC)
	$(DTC) -@ -Hepapr -I dts -O dtb -o $@ $<

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
	$(RM) $(DTBO)

# ── Install / Uninstall ─────────────────────────────────────────────

install: modules dtbo
	$(MAKE) -C $(KDIR) M=$(PWD) INSTALL_MOD_DIR=$(INSTALL_MOD_DIR) modules_install
	install -D -m 0644 $(DTBO) $(DESTDIR)$(OVERLAYS_DIR)/$(DTBO)
	depmod -a
	@echo "Module and overlay installed."
	@echo "Add 'dtoverlay=ili9481' to /boot/config.txt and reboot."

install-dkms:
	install -d $(DKMS_SRC)
	cp -f $(MODULE_NAME).c Makefile Kconfig dkms.conf $(DKMS_SRC)/
	dkms add $(DKMS_NAME)/$(DKMS_VERSION)
	dkms build $(DKMS_NAME)/$(DKMS_VERSION)
	dkms install $(DKMS_NAME)/$(DKMS_VERSION)
	@echo "DKMS module installed. It will rebuild automatically on kernel upgrades."

uninstall:
	$(RM) $(DESTDIR)$(OVERLAYS_DIR)/$(DTBO)
	$(RM) /lib/modules/$(shell uname -r)/$(INSTALL_MOD_DIR)/$(MODULE_NAME).ko*
	depmod -a
	@echo "Module and overlay removed."

uninstall-dkms:
	dkms remove $(DKMS_NAME)/$(DKMS_VERSION) --all || true
	$(RM) -r $(DKMS_SRC)
	@echo "DKMS module removed."

.PHONY: all modules dtbo clean install install-dkms uninstall uninstall-dkms
