#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# install.sh — Install pre-built ILI9481 DRM display driver
#
# Usage:  sudo ./install.sh
#
# This script installs the pre-compiled kernel module and device-tree
# overlays, blacklists the conflicting fbtft staging driver, enables
# SPI, and configures the system to load everything on boot.  It is
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
TOUCH_DTBO="$SCRIPT_DIR/xpt2046.dtbo"

for f in "$KO" "$DTBO"; do
    if [ ! -f "$f" ]; then
        echo "Error: Required file not found: $f"
        exit 1
    fi
done

# ── Determine paths ────────────────────────────────────────────────

KVER="$(uname -r)"
MOD_DIR="/lib/modules/$KVER/extra"
OVERLAYS_DIR="/boot/overlays"
CONFIG="/boot/config.txt"
CMDLINE="/boot/cmdline.txt"

# Raspberry Pi OS Bookworm+ may use /boot/firmware
if [ -d "/boot/firmware/overlays" ]; then
    OVERLAYS_DIR="/boot/firmware/overlays"
    CONFIG="/boot/firmware/config.txt"
    CMDLINE="/boot/firmware/cmdline.txt"
fi

STEP=1
TOTAL=8

echo "ILI9481 Display Driver Installer"
echo "================================"
echo ""
echo "Kernel:    $KVER"
echo "Module:    $MOD_DIR/ili9481.ko"
echo "Overlay:   $OVERLAYS_DIR/ili9481.dtbo"
echo "Config:    $CONFIG"
echo ""

# ── Blacklist conflicting fbtft staging driver ───────────────────────

echo "[$STEP/$TOTAL] Blacklisting conflicting fbtft staging driver ..."
BLACKLIST_CONF="/etc/modprobe.d/ili9481-blacklist.conf"
cat > "$BLACKLIST_CONF" <<'EOF'
# Prevent the old fbtft staging driver from grabbing the ILI9481 device.
# The staging fb_ili9481 driver matches the same compatible string but
# lacks DRM/KMS support and fails to probe without fbtft-specific DT
# properties (buswidth, etc.).
blacklist fb_ili9481
blacklist fbtft
EOF
echo "  Created $BLACKLIST_CONF"
STEP=$((STEP + 1))

# ── Install module ───────────────────────────────────────────────────

echo "[$STEP/$TOTAL] Installing kernel module ..."
mkdir -p "$MOD_DIR"
cp -f "$KO" "$MOD_DIR/ili9481.ko"
STEP=$((STEP + 1))

echo "[$STEP/$TOTAL] Updating module dependencies ..."
depmod -a "$KVER"
STEP=$((STEP + 1))

# ── Install overlays ────────────────────────────────────────────────

echo "[$STEP/$TOTAL] Installing device-tree overlays ..."
mkdir -p "$OVERLAYS_DIR"
cp -f "$DTBO" "$OVERLAYS_DIR/ili9481.dtbo"
if [ -f "$TOUCH_DTBO" ]; then
    cp -f "$TOUCH_DTBO" "$OVERLAYS_DIR/xpt2046.dtbo"
    echo "  Installed ili9481.dtbo and xpt2046.dtbo"
else
    echo "  Installed ili9481.dtbo (xpt2046.dtbo not found — touch support skipped)"
fi
STEP=$((STEP + 1))

# ── Enable SPI ───────────────────────────────────────────────────────

echo "[$STEP/$TOTAL] Ensuring SPI is enabled in $CONFIG ..."
if [ -f "$CONFIG" ]; then
    if grep -q "^dtparam=spi=on" "$CONFIG"; then
        echo "  dtparam=spi=on already present — skipping."
    else
        echo "" >> "$CONFIG"
        echo "# Enable SPI bus (required for ILI9481 display)" >> "$CONFIG"
        echo "dtparam=spi=on" >> "$CONFIG"
        echo "  Added dtparam=spi=on to $CONFIG"
    fi
else
    echo "  Warning: $CONFIG not found — add 'dtparam=spi=on' manually."
fi
STEP=$((STEP + 1))

# ── Enable display overlay in config.txt ─────────────────────────────

echo "[$STEP/$TOTAL] Configuring overlays in $CONFIG ..."
if [ -f "$CONFIG" ]; then
    # ILI9481 display overlay
    if grep -q "^dtoverlay=ili9481" "$CONFIG"; then
        echo "  dtoverlay=ili9481 already present — skipping."
    else
        echo "" >> "$CONFIG"
        echo "# ILI9481 SPI display driver" >> "$CONFIG"
        echo "dtoverlay=ili9481" >> "$CONFIG"
        echo "  Added dtoverlay=ili9481 to $CONFIG"
    fi

    # XPT2046 touch overlay
    if [ -f "$TOUCH_DTBO" ]; then
        if grep -q "^dtoverlay=xpt2046" "$CONFIG"; then
            echo "  dtoverlay=xpt2046 already present — skipping."
        else
            echo "# XPT2046 resistive touchscreen" >> "$CONFIG"
            echo "dtoverlay=xpt2046" >> "$CONFIG"
            echo "  Added dtoverlay=xpt2046 to $CONFIG"
        fi
    fi
else
    echo "  Warning: $CONFIG not found — add overlay lines manually."
fi
STEP=$((STEP + 1))

# ── Ensure DRM/KMS is enabled ───────────────────────────────────────

echo "[$STEP/$TOTAL] Ensuring DRM/KMS is enabled ..."
if [ -f "$CONFIG" ]; then
    if grep -q "^dtoverlay=vc4-kms-v3d" "$CONFIG" || grep -q "^dtoverlay=vc4-fkms-v3d" "$CONFIG"; then
        echo "  vc4-kms-v3d already enabled — skipping."
    else
        echo "" >> "$CONFIG"
        echo "# Enable DRM/KMS (required for ILI9481 DRM driver)" >> "$CONFIG"
        echo "dtoverlay=vc4-kms-v3d" >> "$CONFIG"
        echo "  Added dtoverlay=vc4-kms-v3d to $CONFIG"
    fi
else
    echo "  Warning: $CONFIG not found — ensure DRM/KMS is enabled manually."
fi
STEP=$((STEP + 1))

# ── Configure fbcon for SPI display ──────────────────────────────────

echo "[$STEP/$TOTAL] Configuring framebuffer console ..."
if [ -f "$CMDLINE" ]; then
    if grep -q "fbcon=map:10" "$CMDLINE"; then
        echo "  fbcon=map:10 already present — skipping."
    else
        # Append fbcon=map:10 to the existing single-line cmdline
        sed -i 's/$/ fbcon=map:10/' "$CMDLINE"
        echo "  Added fbcon=map:10 to $CMDLINE"
    fi
else
    echo "  Warning: $CMDLINE not found — add 'fbcon=map:10' to kernel cmdline manually."
fi
STEP=$((STEP + 1))

# ── Done ─────────────────────────────────────────────────────────────

echo ""
echo "Installation complete!"
echo ""
echo "Next steps:"
echo "  1. Reboot:  sudo reboot"
echo "  2. Verify:  dmesg | grep ili9481"
echo "  3. Touch:   cat /proc/bus/input/devices | grep -A5 -i touch"
echo ""
echo "To uninstall later:"
echo "  sudo rm $MOD_DIR/ili9481.ko"
echo "  sudo rm $OVERLAYS_DIR/ili9481.dtbo"
echo "  sudo rm $OVERLAYS_DIR/xpt2046.dtbo"
echo "  sudo rm $BLACKLIST_CONF"
echo "  sudo depmod -a"
echo "  Remove 'dtoverlay=ili9481', 'dtoverlay=xpt2046', 'dtparam=spi=on' from $CONFIG"
echo "  Remove 'fbcon=map:10' from $CMDLINE"
