#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# uninstall.sh — Uninstall ILI9481 DRM display driver
#
# Usage:  sudo ./uninstall.sh
#
# This script reverses all changes made by install.sh:
# removes the kernel module (DKMS), device-tree overlays, boot config
# entries, X11/display configuration, touchscreen settings, and the
# systemd helper service.

set -euo pipefail

# ── Checks ───────────────────────────────────────────────────────────

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root (sudo ./uninstall.sh)"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Parse DKMS version ──────────────────────────────────────────────

DKMS_NAME="ili9481"
DKMS_VERSION=""
if [ -f "$SCRIPT_DIR/dkms.conf" ]; then
    DKMS_VERSION=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$SCRIPT_DIR/dkms.conf")
fi

# Fallback: probe whatever version is actually installed
if [ -z "$DKMS_VERSION" ]; then
    DKMS_VERSION=$(dkms status "$DKMS_NAME" 2>/dev/null \
                   | head -1 | sed -n 's/.*\/\([^,]*\),.*/\1/p' || true)
fi
if [ -z "$DKMS_VERSION" ]; then
    DKMS_VERSION="1.1.0"   # last-resort default
fi

DKMS_SRC="/usr/src/${DKMS_NAME}-${DKMS_VERSION}"

# ── Determine paths ─────────────────────────────────────────────────

OVERLAYS_DIR="/boot/overlays"
CONFIG="/boot/config.txt"
CMDLINE="/boot/cmdline.txt"

if [ -d "/boot/firmware/overlays" ]; then
    OVERLAYS_DIR="/boot/firmware/overlays"
    CONFIG="/boot/firmware/config.txt"
    CMDLINE="/boot/firmware/cmdline.txt"
fi

STEP=1
TOTAL=7

echo "ILI9481 Display Driver Uninstaller"
echo "==================================="
echo ""
echo "DKMS:      ${DKMS_NAME}/${DKMS_VERSION}"
echo "Source:    $DKMS_SRC"
echo "Overlays:  $OVERLAYS_DIR"
echo "Config:    $CONFIG"
echo ""

# ── 1. Remove DKMS module ───────────────────────────────────────────

echo "[$STEP/$TOTAL] Removing DKMS module ..."
# Try to remove every version that may exist
if dkms status "${DKMS_NAME}" 2>/dev/null | grep -q .; then
    for ver in $(dkms status "${DKMS_NAME}" 2>/dev/null \
                 | sed -n 's/.*\/\([^,]*\),.*/\1/p' | sort -u); do
        dkms remove "${DKMS_NAME}/${ver}" --all 2>/dev/null || true
        echo "  Removed DKMS ${DKMS_NAME}/${ver}"
    done
else
    echo "  No DKMS module found — skipping"
fi
# Remove source trees (all versions)
for d in /usr/src/${DKMS_NAME}-*/; do
    [ -d "$d" ] && rm -rf "$d" && echo "  Removed $d"
done
STEP=$((STEP + 1))

# ── 2. Remove device-tree overlays ──────────────────────────────────

echo "[$STEP/$TOTAL] Removing device-tree overlays ..."
for f in ili9481.dtbo xpt2046.dtbo; do
    if [ -f "$OVERLAYS_DIR/$f" ]; then
        rm -f "$OVERLAYS_DIR/$f"
        echo "  Removed $OVERLAYS_DIR/$f"
    fi
done
# Also remove locally compiled overlays from the source tree
rm -f "$SCRIPT_DIR/ili9481.dtbo" "$SCRIPT_DIR/xpt2046.dtbo" 2>/dev/null || true
STEP=$((STEP + 1))

# ── 3. Clean config.txt ─────────────────────────────────────────────

echo "[$STEP/$TOTAL] Cleaning $CONFIG ..."
if [ -f "$CONFIG" ]; then
    # Remove comment + entry lines we added (idempotent)
    sed -i '/^# Enable SPI bus (required for ILI9481 display)/d' "$CONFIG"
    sed -i '/^# Enable DRM\/KMS (required for ILI9481 DRM driver)/d' "$CONFIG"
    sed -i '/^# ILI9481 SPI display driver/d' "$CONFIG"
    sed -i '/^# XPT2046 resistive touchscreen/d' "$CONFIG"
    sed -i '/^dtoverlay=ili9481/d' "$CONFIG"
    sed -i '/^dtoverlay=xpt2046/d' "$CONFIG"
    # Collapse multiple consecutive blank lines into one
    sed -i '/^$/N;/^\n$/d' "$CONFIG"
    echo "  Removed ILI9481 and XPT2046 overlay entries"
    echo "  Note: dtparam=spi=on and dtoverlay=vc4-kms-v3d were NOT removed"
    echo "        (they may be used by other hardware)"
else
    echo "  $CONFIG not found — skipping"
fi
STEP=$((STEP + 1))

# ── 4. Clean cmdline.txt ────────────────────────────────────────────

echo "[$STEP/$TOTAL] Cleaning $CMDLINE ..."
if [ -f "$CMDLINE" ]; then
    sed -i 's/ fbcon=map:[^ ]*//g' "$CMDLINE"
    echo "  Removed fbcon=map: from kernel command line"
    echo "  Note: 'splash' was NOT restored — add it back manually if desired:"
    echo "        sudo sed -i '1s/\$/ splash/' $CMDLINE"
else
    echo "  $CMDLINE not found — skipping"
fi
STEP=$((STEP + 1))

# ── 5. Remove display / X11 configuration ───────────────────────────

echo "[$STEP/$TOTAL] Removing display configuration ..."
rm -f /etc/X11/xorg.conf.d/99-ili9481.conf 2>/dev/null && \
    echo "  Removed /etc/X11/xorg.conf.d/99-ili9481.conf" || true
rm -f /usr/local/bin/ili9481-find-card 2>/dev/null && \
    echo "  Removed /usr/local/bin/ili9481-find-card" || true
rm -f /etc/environment.d/99-ili9481.conf 2>/dev/null && \
    echo "  Removed /etc/environment.d/99-ili9481.conf (Wayland WLR_DRM_DEVICES)" || true
rm -f /etc/labwc/environment 2>/dev/null && \
    echo "  Removed /etc/labwc/environment (labwc compositor env)" || true

if [ -f /etc/systemd/system/ili9481-display.service ]; then
    systemctl disable ili9481-display.service 2>/dev/null || true
    rm -f /etc/systemd/system/ili9481-display.service
    systemctl daemon-reload 2>/dev/null || true
    echo "  Removed and disabled ili9481-display.service"
fi
STEP=$((STEP + 1))

# ── 6. Remove touchscreen configuration ─────────────────────────────

echo "[$STEP/$TOTAL] Removing touchscreen configuration ..."
rm -f /etc/X11/xorg.conf.d/99-xpt2046-touch.conf 2>/dev/null && \
    echo "  Removed /etc/X11/xorg.conf.d/99-xpt2046-touch.conf" || true
rm -f /etc/udev/rules.d/99-xpt2046.rules 2>/dev/null && \
    echo "  Removed /etc/udev/rules.d/99-xpt2046.rules" || true
STEP=$((STEP + 1))

# ── 7. Remove fbtft blacklist ───────────────────────────────────────

echo "[$STEP/$TOTAL] Removing fbtft blacklist ..."
rm -f /etc/modprobe.d/ili9481-blacklist.conf 2>/dev/null && \
    echo "  Removed /etc/modprobe.d/ili9481-blacklist.conf" || true
STEP=$((STEP + 1))

# ── Done ─────────────────────────────────────────────────────────────

echo ""
echo "Uninstall complete!  Reboot to finish cleanup."
echo ""
echo "  sudo reboot"
echo ""
echo "If your display was the only output, re-enable HDMI before rebooting:"
echo "  sudo sed -i '1s/\$/ splash/' $CMDLINE"
echo ""
