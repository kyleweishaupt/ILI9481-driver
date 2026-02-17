#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# install.sh — Install pre-built ILI9481 DRM display driver
#
# Usage:  sudo ./install.sh
#
# This script installs the pre-compiled kernel module and device-tree
# overlay, then configures the system to load them on boot.  It is
# included in the GitHub Actions build artifact so users can install
# the driver without compiling anything.

set -euo pipefail

# ── Checks ───────────────────────────────────────────────────────────

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root (sudo ./install.sh)"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KO="$SCRIPT_DIR/ili9481.ko"
DTBO="$SCRIPT_DIR/ili9481.dtbo"

for f in "$KO" "$DTBO"; do
    if [ ! -f "$f" ]; then
        echo "Error: Required file not found: $f"
        exit 1
    fi
done

# ── Determine kernel version ────────────────────────────────────────

KVER="$(uname -r)"
MOD_DIR="/lib/modules/$KVER/extra"
OVERLAYS_DIR="/boot/overlays"
CONFIG="/boot/config.txt"

# Raspberry Pi OS Bookworm+ may use /boot/firmware
if [ -d "/boot/firmware/overlays" ]; then
    OVERLAYS_DIR="/boot/firmware/overlays"
    CONFIG="/boot/firmware/config.txt"
fi

echo "ILI9481 Display Driver Installer"
echo "================================"
echo ""
echo "Kernel:    $KVER"
echo "Module:    $MOD_DIR/ili9481.ko"
echo "Overlay:   $OVERLAYS_DIR/ili9481.dtbo"
echo "Config:    $CONFIG"
echo ""

# ── Install module ───────────────────────────────────────────────────

echo "[1/4] Installing kernel module ..."
mkdir -p "$MOD_DIR"
cp -f "$KO" "$MOD_DIR/ili9481.ko"

echo "[2/4] Updating module dependencies ..."
depmod -a "$KVER"

# ── Install overlay ──────────────────────────────────────────────────

echo "[3/4] Installing device-tree overlay ..."
mkdir -p "$OVERLAYS_DIR"
cp -f "$DTBO" "$OVERLAYS_DIR/ili9481.dtbo"

# ── Enable overlay in config.txt ─────────────────────────────────────

echo "[4/4] Checking $CONFIG ..."
if [ -f "$CONFIG" ]; then
    if grep -q "^dtoverlay=ili9481" "$CONFIG"; then
        echo "  dtoverlay=ili9481 already present — skipping."
    else
        echo "" >> "$CONFIG"
        echo "# ILI9481 SPI display driver" >> "$CONFIG"
        echo "dtoverlay=ili9481" >> "$CONFIG"
        echo "  Added dtoverlay=ili9481 to $CONFIG"
    fi
else
    echo "  Warning: $CONFIG not found — add 'dtoverlay=ili9481' manually."
fi

# ── Done ─────────────────────────────────────────────────────────────

echo ""
echo "Installation complete!"
echo ""
echo "Next steps:"
echo "  1. Reboot:  sudo reboot"
echo "  2. Verify:  dmesg | grep ili9481"
echo ""
echo "To uninstall later:"
echo "  sudo rm $MOD_DIR/ili9481.ko"
echo "  sudo rm $OVERLAYS_DIR/ili9481.dtbo"
echo "  sudo depmod -a"
echo "  Remove 'dtoverlay=ili9481' from $CONFIG"
