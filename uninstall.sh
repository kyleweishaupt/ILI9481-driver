#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# uninstall.sh — Uninstall Inland TFT35 / MPI3501 display configuration
#
# Usage:  sudo ./uninstall.sh
#
# Reverses all changes made by install.sh: removes the systemd service,
# X11/touch configs, udev rules, boot config entries, and restores
# vc4-kms-v3d for HDMI output.  Also cleans up artifacts from the old
# ili9481 kernel module if present.

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

# ═════════════════════════════════════════════════════════════════════
# Step 1: Remove systemd service and helper script
# ═════════════════════════════════════════════════════════════════════

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
    [ -f "$helper" ] && rm -f "$helper" && echo "  Removed $helper"
done
STEP=$((STEP + 1))

# ═════════════════════════════════════════════════════════════════════
# Step 2: Remove X11 display configuration
# ═════════════════════════════════════════════════════════════════════

echo "[$STEP/$TOTAL] Removing display configuration ..."
for f in 99-spi-display.conf 99-ili9481.conf; do
    [ -f "/etc/X11/xorg.conf.d/$f" ] && rm -f "/etc/X11/xorg.conf.d/$f" && \
        echo "  Removed /etc/X11/xorg.conf.d/$f"
done

# Remove Wayland environment files from old ili9481 driver
rm -f /etc/environment.d/99-ili9481.conf 2>/dev/null || true
rm -f /etc/labwc/environment 2>/dev/null || true
STEP=$((STEP + 1))

# ═════════════════════════════════════════════════════════════════════
# Step 3: Remove touchscreen configuration
# ═════════════════════════════════════════════════════════════════════

echo "[$STEP/$TOTAL] Removing touchscreen configuration ..."
rm -f /etc/X11/xorg.conf.d/99-touch-calibration.conf 2>/dev/null && \
    echo "  Removed /etc/X11/xorg.conf.d/99-touch-calibration.conf" || true
rm -f /etc/X11/xorg.conf.d/99-xpt2046-touch.conf 2>/dev/null && \
    echo "  Removed /etc/X11/xorg.conf.d/99-xpt2046-touch.conf (old)" || true
rm -f /etc/udev/rules.d/99-xpt2046.rules 2>/dev/null && \
    echo "  Removed /etc/udev/rules.d/99-xpt2046.rules" || true
STEP=$((STEP + 1))

# ═════════════════════════════════════════════════════════════════════
# Step 4: Restore config.txt
# ═════════════════════════════════════════════════════════════════════

echo "[$STEP/$TOTAL] Restoring ${CONFIG} ..."
if [ -f "$CONFIG" ]; then
    # Remove piscreen/waveshare35a overlay entries
    sed -i '/^# Inland TFT35 SPI display/d' "$CONFIG"
    sed -i '/^dtoverlay=piscreen/d' "$CONFIG"
    sed -i '/^dtoverlay=waveshare35a/d' "$CONFIG"

    # Restore vc4-kms-v3d (uncomment — handles lines with parameters)
    sed -i 's/^#\(dtoverlay=vc4-kms-v3d\)/\1/' "$CONFIG"
    sed -i 's/^#\(dtoverlay=vc4-fkms-v3d\)/\1/' "$CONFIG"

    # Restore display_auto_detect
    sed -i 's/^#\(display_auto_detect=1\)/\1/' "$CONFIG"

    # Clean old ili9481 entries (idempotent)
    sed -i '/^# ILI9481 SPI display driver/d' "$CONFIG"
    sed -i '/^dtoverlay=ili9481/d' "$CONFIG"
    sed -i '/^# XPT2046 resistive touchscreen/d' "$CONFIG"
    sed -i '/^dtoverlay=xpt2046/d' "$CONFIG"
    sed -i '/^# Enable DRM\/KMS (required for ILI9481 DRM driver)/d' "$CONFIG"
    sed -i '/^# Enable SPI bus (required for ILI9481 display)/d' "$CONFIG"
    sed -i '/^# Enable SPI bus (required for SPI display)/d' "$CONFIG"
    sed -i '/^# Disable firmware KMS setup (required for fbtft)/d' "$CONFIG"

    # NOTE: We intentionally do NOT remove disable_fw_kms_setup=1.
    # On Trixie it is a default value; removing it would break the
    # standard config.  On Bookworm it is harmless when vc4-kms-v3d
    # is active (the DRM driver handles framebuffer creation).

    # NOTE: We intentionally do NOT remove dtparam=spi=on.
    # Other hardware (touchscreen, sensors) may depend on it.

    # Collapse multiple consecutive blank lines
    sed -i '/^$/N;/^\n$/d' "$CONFIG"

    echo "  Restored vc4-kms-v3d (HDMI output)"
    echo "  Restored display_auto_detect"
    echo "  Removed piscreen/ili9481 overlay entries"
    echo "  Note: dtparam=spi=on and disable_fw_kms_setup=1 left intact"
else
    echo "  ${CONFIG} not found — skipping"
fi
STEP=$((STEP + 1))

# ═════════════════════════════════════════════════════════════════════
# Step 5: Clean cmdline.txt
# ═════════════════════════════════════════════════════════════════════

echo "[$STEP/$TOTAL] Cleaning ${CMDLINE} ..."
if [ -f "$CMDLINE" ]; then
    sed -i 's/ fbcon=map:[^ ]*//g' "$CMDLINE"
    echo "  Removed fbcon=map: from kernel command line"
    echo "  Note: 'splash' was NOT restored — add it back if desired:"
    echo "        sudo sed -i '1s/\$/ splash/' ${CMDLINE}"
else
    echo "  ${CMDLINE} not found — skipping"
fi
STEP=$((STEP + 1))

# ═════════════════════════════════════════════════════════════════════
# Step 6: Clean old ili9481 DKMS artifacts
# ═════════════════════════════════════════════════════════════════════

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

for f in ili9481.dtbo xpt2046.dtbo; do
    [ -f "$OVERLAYS_DIR/$f" ] && rm -f "$OVERLAYS_DIR/$f" && echo "  Removed $OVERLAYS_DIR/$f"
done

rm -f /etc/modprobe.d/ili9481-blacklist.conf 2>/dev/null && \
    echo "  Removed /etc/modprobe.d/ili9481-blacklist.conf" || true
STEP=$((STEP + 1))

# ═════════════════════════════════════════════════════════════════════
# Step 7: Summary
# ═════════════════════════════════════════════════════════════════════

echo ""
echo "[$STEP/$TOTAL] Uninstall complete!"
echo ""
echo "  Reboot to finish:  sudo reboot"
echo ""
echo "  HDMI output has been restored (vc4-kms-v3d uncommented)."
echo ""
echo "  To switch back to Wayland (Trixie default):"
echo "    sudo raspi-config → Advanced Options → Wayland → labwc (W2)"
echo ""
