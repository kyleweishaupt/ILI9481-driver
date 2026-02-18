#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# uninstall.sh — Uninstall Inland TFT35 / MPI3501 display configuration
#
# Usage:  sudo ./uninstall.sh
#
# This script reverses all changes made by install.sh:
# removes the systemd service, X11/touch configs, udev rules,
# and boot config entries.  Also cleans up artifacts from the
# old ili9481 kernel module if present.

set -euo pipefail

# ── Checks ───────────────────────────────────────────────────────────

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root (sudo ./uninstall.sh)"
    exit 1
fi

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

echo "Inland TFT35 Display Uninstaller"
echo "================================="
echo ""
echo "Config:    ${CONFIG}"
echo ""

# ── 1. Remove systemd service and helper script ─────────────────────

echo "[$STEP/$TOTAL] Removing systemd service ..."
for svc in inland-tft35-display ili9481-display; do
    if [ -f "/etc/systemd/system/${svc}.service" ]; then
        systemctl disable "${svc}.service" 2>/dev/null || true
        rm -f "/etc/systemd/system/${svc}.service"
        echo "  Removed ${svc}.service"
    fi
done
systemctl daemon-reload 2>/dev/null || true

for helper in /usr/local/bin/inland-tft35-setup /usr/local/bin/ili9481-find-card; do
    if [ -f "$helper" ]; then
        rm -f "$helper"
        echo "  Removed $helper"
    fi
done
STEP=$((STEP + 1))

# ── 2. Remove X11 display configuration ─────────────────────────────

echo "[$STEP/$TOTAL] Removing display configuration ..."
for f in 99-spi-display.conf 99-ili9481.conf; do
    rm -f "/etc/X11/xorg.conf.d/$f" 2>/dev/null && \
        echo "  Removed /etc/X11/xorg.conf.d/$f" || true
done

# Remove Wayland environment files from old ili9481 driver
rm -f /etc/environment.d/99-ili9481.conf 2>/dev/null && \
    echo "  Removed /etc/environment.d/99-ili9481.conf" || true
rm -f /etc/labwc/environment 2>/dev/null && \
    echo "  Removed /etc/labwc/environment" || true
STEP=$((STEP + 1))

# ── 3. Remove touchscreen configuration ─────────────────────────────

echo "[$STEP/$TOTAL] Removing touchscreen configuration ..."
rm -f /etc/X11/xorg.conf.d/99-touch-calibration.conf 2>/dev/null && \
    echo "  Removed /etc/X11/xorg.conf.d/99-touch-calibration.conf" || true
rm -f /etc/X11/xorg.conf.d/99-xpt2046-touch.conf 2>/dev/null && \
    echo "  Removed /etc/X11/xorg.conf.d/99-xpt2046-touch.conf (old)" || true
rm -f /etc/udev/rules.d/99-xpt2046.rules 2>/dev/null && \
    echo "  Removed /etc/udev/rules.d/99-xpt2046.rules" || true
STEP=$((STEP + 1))

# ── 4. Clean config.txt ─────────────────────────────────────────────

echo "[$STEP/$TOTAL] Cleaning ${CONFIG} ..."
if [ -f "$CONFIG" ]; then
    # Remove piscreen/waveshare35a overlay entries added by install.sh
    sed -i '/^# Inland TFT35 SPI display/d' "$CONFIG"
    sed -i '/^dtoverlay=piscreen/d' "$CONFIG"
    sed -i '/^dtoverlay=waveshare35a/d' "$CONFIG"

    # Remove disable_fw_kms_setup
    sed -i '/^# Disable firmware KMS setup/d' "$CONFIG"
    sed -i '/^disable_fw_kms_setup=1/d' "$CONFIG"

    # Uncomment vc4-kms-v3d if we commented it out (handles lines with parameters too)
    sed -i 's/^#\(dtoverlay=vc4-kms-v3d\)/\1/' "$CONFIG"
    sed -i 's/^#\(dtoverlay=vc4-fkms-v3d\)/\1/' "$CONFIG"

    # Also clean old ili9481 entries (idempotent)
    sed -i '/^# ILI9481 SPI display driver/d' "$CONFIG"
    sed -i '/^dtoverlay=ili9481/d' "$CONFIG"
    sed -i '/^# XPT2046 resistive touchscreen/d' "$CONFIG"
    sed -i '/^dtoverlay=xpt2046/d' "$CONFIG"
    sed -i '/^# Enable DRM\/KMS (required for ILI9481 DRM driver)/d' "$CONFIG"
    sed -i '/^# Enable SPI bus (required for ILI9481 display)/d' "$CONFIG"
    sed -i '/^# Enable SPI bus (required for SPI display)/d' "$CONFIG"

    # Collapse multiple consecutive blank lines
    sed -i '/^$/N;/^\n$/d' "$CONFIG"

    echo "  Removed piscreen/ili9481 overlay entries"
    echo "  Uncommented vc4-kms-v3d"
    echo "  Removed disable_fw_kms_setup=1"
    echo "  Note: dtparam=spi=on was NOT removed (other hardware may use it)"
else
    echo "  ${CONFIG} not found — skipping"
fi
STEP=$((STEP + 1))

# ── 5. Clean cmdline.txt ────────────────────────────────────────────

echo "[$STEP/$TOTAL] Cleaning ${CMDLINE} ..."
if [ -f "$CMDLINE" ]; then
    sed -i 's/ fbcon=map:[^ ]*//g' "$CMDLINE"
    echo "  Removed fbcon=map: from kernel command line"
    echo "  Note: 'splash' was NOT restored — add it back manually if desired:"
    echo "        sudo sed -i '1s/\$/ splash/' ${CMDLINE}"
else
    echo "  ${CMDLINE} not found — skipping"
fi
STEP=$((STEP + 1))

# ── 6. Remove old ili9481 DKMS module (if present) ──────────────────

echo "[$STEP/$TOTAL] Cleaning old ili9481 DKMS artifacts ..."
if command -v dkms >/dev/null 2>&1; then
    if dkms status "ili9481" 2>/dev/null | grep -q .; then
        for ver in $(dkms status "ili9481" 2>/dev/null \
                     | sed -n 's/.*\/\([^,]*\),.*/\1/p' | sort -u); do
            dkms remove "ili9481/${ver}" --all 2>/dev/null || true
            echo "  Removed DKMS ili9481/${ver}"
        done
    else
        echo "  No DKMS ili9481 module found — skipping"
    fi
fi
for d in /usr/src/ili9481-*/; do
    [ -d "$d" ] && rm -rf "$d" && echo "  Removed $d"
done

# Remove old overlays
for f in ili9481.dtbo xpt2046.dtbo; do
    if [ -f "$OVERLAYS_DIR/$f" ]; then
        rm -f "$OVERLAYS_DIR/$f"
        echo "  Removed $OVERLAYS_DIR/$f"
    fi
done

# Remove old blacklist
rm -f /etc/modprobe.d/ili9481-blacklist.conf 2>/dev/null && \
    echo "  Removed /etc/modprobe.d/ili9481-blacklist.conf" || true
STEP=$((STEP + 1))

# ── 7. Summary ──────────────────────────────────────────────────────

echo ""
echo "[$STEP/$TOTAL] Uninstall complete!  Reboot to finish cleanup."
echo ""
echo "  sudo reboot"
echo ""
echo "If your SPI display was the only output, re-enable HDMI by uncommenting"
echo "dtoverlay=vc4-kms-v3d in ${CONFIG} (this was done automatically)."
echo ""
