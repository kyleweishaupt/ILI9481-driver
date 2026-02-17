#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# install.sh — Install ILI9481 DRM display driver
#
# Usage:  sudo ./install.sh
#
# This script installs the ILI9481 kernel module via DKMS so it is
# compiled against your running kernel (correct symbol versions) and
# automatically rebuilt on kernel upgrades.  Pre-compiled device-tree
# overlays are installed directly.  The script also blacklists the
# conflicting fbtft staging driver, enables SPI, and configures the
# display overlay to load on boot.

set -euo pipefail

# ── Checks ───────────────────────────────────────────────────────────

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root (sudo ./install.sh)"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DTBO="$SCRIPT_DIR/ili9481.dtbo"
TOUCH_DTBO="$SCRIPT_DIR/xpt2046.dtbo"

# Source files for DKMS
SRC_FILES=(ili9481.c Makefile Kconfig dkms.conf)
for f in "$DTBO" "$SCRIPT_DIR/ili9481.c" "$SCRIPT_DIR/dkms.conf"; do
    if [ ! -f "$f" ]; then
        echo "Error: Required file not found: $f"
        exit 1
    fi
done

# ── Parse dkms.conf ──────────────────────────────────────────────────

DKMS_NAME="ili9481"
DKMS_VERSION=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$SCRIPT_DIR/dkms.conf")
DKMS_SRC="/usr/src/${DKMS_NAME}-${DKMS_VERSION}"

# ── Determine paths ─────────────────────────────────────────────────

KVER="$(uname -r)"
OVERLAYS_DIR="/boot/overlays"
CONFIG="/boot/config.txt"
CMDLINE="/boot/cmdline.txt"

# Raspberry Pi OS Bookworm+ uses /boot/firmware
if [ -d "/boot/firmware/overlays" ]; then
    OVERLAYS_DIR="/boot/firmware/overlays"
    CONFIG="/boot/firmware/config.txt"
    CMDLINE="/boot/firmware/cmdline.txt"
fi

STEP=1
TOTAL=7

echo "ILI9481 Display Driver Installer"
echo "================================"
echo ""
echo "Kernel:    $KVER"
echo "DKMS:      ${DKMS_NAME}/${DKMS_VERSION}"
echo "Overlay:   $OVERLAYS_DIR/ili9481.dtbo"
echo "Config:    $CONFIG"
echo ""

# ── 1. Blacklist conflicting fbtft staging driver ────────────────────

echo "[$STEP/$TOTAL] Blacklisting conflicting fbtft staging driver ..."
BLACKLIST_CONF="/etc/modprobe.d/ili9481-blacklist.conf"
cat > "$BLACKLIST_CONF" <<'EOF'
# Prevent the old fbtft staging driver from grabbing the ILI9481 device.
blacklist fb_ili9481
blacklist fbtft
EOF
echo "  Created $BLACKLIST_CONF"
STEP=$((STEP + 1))

# ── 2. Install dependencies ─────────────────────────────────────────

echo "[$STEP/$TOTAL] Installing DKMS and kernel headers ..."
apt-get update -qq
apt-get install -y -qq dkms raspberrypi-kernel-headers 2>/dev/null \
  || apt-get install -y -qq dkms "linux-headers-${KVER}"
echo "  Done"
STEP=$((STEP + 1))

# ── 3. Build & install via DKMS ──────────────────────────────────────

echo "[$STEP/$TOTAL] Building kernel module via DKMS ..."
# Remove any previous registration
if dkms status "${DKMS_NAME}/${DKMS_VERSION}" 2>/dev/null | grep -q .; then
    dkms remove "${DKMS_NAME}/${DKMS_VERSION}" --all 2>/dev/null || true
fi
# Copy source to DKMS tree
mkdir -p "$DKMS_SRC"
for f in "${SRC_FILES[@]}"; do
    [ -f "$SCRIPT_DIR/$f" ] && cp -f "$SCRIPT_DIR/$f" "$DKMS_SRC/"
done
# Build and install in one step
dkms install "${DKMS_NAME}/${DKMS_VERSION}" -k "$KVER"
echo "  Module built and installed for kernel $KVER"
STEP=$((STEP + 1))

# ── 4. Install device-tree overlays ─────────────────────────────────

echo "[$STEP/$TOTAL] Installing device-tree overlays ..."
mkdir -p "$OVERLAYS_DIR"
cp -f "$DTBO" "$OVERLAYS_DIR/ili9481.dtbo"
if [ -f "$TOUCH_DTBO" ]; then
    cp -f "$TOUCH_DTBO" "$OVERLAYS_DIR/xpt2046.dtbo"
    echo "  Installed ili9481.dtbo and xpt2046.dtbo"
else
    echo "  Installed ili9481.dtbo (xpt2046.dtbo not found — touch skipped)"
fi
STEP=$((STEP + 1))

# ── 5. Configure config.txt ─────────────────────────────────────────

echo "[$STEP/$TOTAL] Configuring $CONFIG ..."
if [ -f "$CONFIG" ]; then
    changed=0

    # SPI
    if ! grep -q "^dtparam=spi=on" "$CONFIG"; then
        printf '\n# Enable SPI bus (required for ILI9481 display)\ndtparam=spi=on\n' >> "$CONFIG"
        echo "  Added dtparam=spi=on"
        changed=1
    fi

    # DRM/KMS
    if ! grep -q "^dtoverlay=vc4-kms-v3d" "$CONFIG" && \
       ! grep -q "^dtoverlay=vc4-fkms-v3d" "$CONFIG"; then
        printf '\n# Enable DRM/KMS (required for ILI9481 DRM driver)\ndtoverlay=vc4-kms-v3d\n' >> "$CONFIG"
        echo "  Added dtoverlay=vc4-kms-v3d"
        changed=1
    fi

    # ILI9481 overlay
    if ! grep -q "^dtoverlay=ili9481" "$CONFIG"; then
        printf '\n# ILI9481 SPI display driver\ndtoverlay=ili9481\n' >> "$CONFIG"
        echo "  Added dtoverlay=ili9481"
        changed=1
    fi

    # XPT2046 touch overlay
    if [ -f "$TOUCH_DTBO" ] && ! grep -q "^dtoverlay=xpt2046" "$CONFIG"; then
        printf '# XPT2046 resistive touchscreen\ndtoverlay=xpt2046\n' >> "$CONFIG"
        echo "  Added dtoverlay=xpt2046"
        changed=1
    fi

    [ "$changed" -eq 0 ] && echo "  Already configured — skipping."
else
    echo "  Warning: $CONFIG not found — configure manually."
fi
STEP=$((STEP + 1))

# ── 6. Configure fbcon ───────────────────────────────────────────────

echo "[$STEP/$TOTAL] Configuring framebuffer console ..."
if [ -f "$CMDLINE" ]; then
    if ! grep -q "fbcon=map:10" "$CMDLINE"; then
        sed -i 's/$/ fbcon=map:10/' "$CMDLINE"
        echo "  Added fbcon=map:10 to $CMDLINE"
    else
        echo "  Already configured — skipping."
    fi
else
    echo "  Warning: $CMDLINE not found — add 'fbcon=map:10' manually."
fi
STEP=$((STEP + 1))

# ── Done ─────────────────────────────────────────────────────────────

echo ""
echo "Installation complete!  Reboot to activate."
echo ""
echo "  sudo reboot"
echo ""
echo "After reboot:"
echo "  dmesg | grep ili9481"
echo "  cat /proc/bus/input/devices | grep -A5 -i touch"
echo ""
echo "To uninstall:"
echo "  sudo dkms remove ${DKMS_NAME}/${DKMS_VERSION} --all"
echo "  sudo rm -rf $DKMS_SRC"
echo "  sudo rm $OVERLAYS_DIR/ili9481.dtbo $OVERLAYS_DIR/xpt2046.dtbo"
echo "  sudo rm $BLACKLIST_CONF"
echo "  # Remove dtoverlay=ili9481, dtoverlay=xpt2046, dtparam=spi=on from $CONFIG"
echo "  # Remove fbcon=map:10 from $CMDLINE"
