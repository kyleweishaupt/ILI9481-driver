#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# uninstall.sh — Remove Inland TFT35 ILI9481 userspace driver and configuration
#
# Reverses the changes made by install.sh: stops/disables services, removes
# the daemon binary, configuration files, module autoload hints, and cleans
# boot config entries.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: sudo ./uninstall.sh"
    exit 1
fi

# =====================================================================
# Locate boot partition paths
# =====================================================================

OVERLAYS_DIR="/boot/overlays"
CONFIG="/boot/config.txt"
CMDLINE="/boot/cmdline.txt"
if [ -d "/boot/firmware/overlays" ]; then
    OVERLAYS_DIR="/boot/firmware/overlays"
    CONFIG="/boot/firmware/config.txt"
    CMDLINE="/boot/firmware/cmdline.txt"
fi

if [ ! -f "$CONFIG" ] || [ ! -f "$CMDLINE" ]; then
    echo "Could not find boot configuration files."
    exit 1
fi

echo "Inland TFT35 ILI9481 uninstaller"
echo "Config:  $CONFIG"
echo "Cmdline: $CMDLINE"
echo

# =====================================================================
# [1/7] Stop and disable services
# =====================================================================

echo "[1/7] Stopping and disabling services"
systemctl disable --now ili9481-fb.service >/dev/null 2>&1 || true
systemctl disable --now inland-tft35-boot.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/ili9481-fb.service
rm -f /etc/systemd/system/inland-tft35-boot.service
rm -f /usr/local/bin/inland-tft35-boot
systemctl daemon-reload

# =====================================================================
# [2/7] Remove daemon binary
# =====================================================================

echo "[2/7] Removing daemon binary"
rm -f /usr/local/bin/ili9481-fb

# =====================================================================
# [3/7] Remove configuration files
# =====================================================================

echo "[3/7] Removing configuration files"
rm -rf /etc/ili9481
rm -f /etc/modprobe.d/vfb-ili9481.conf

# =====================================================================
# [4/7] Remove X11 display and touch config
# =====================================================================

echo "[4/7] Removing X11 display and touch config"
rm -f /etc/X11/xorg.conf.d/99-inland-fbdev.conf
rm -f /etc/X11/xorg.conf.d/99-inland-touch.conf

# =====================================================================
# [5/7] Remove module autoload hints
# =====================================================================

echo "[5/7] Removing module autoload hints"
rm -f /etc/modules-load.d/inland-tft35.conf

# =====================================================================
# [6/7] Clean config.txt and cmdline.txt entries
# =====================================================================

echo "[6/7] Cleaning boot config entries"

# Remove any entries from the old kernel-module installer too
sed -i '/^# BEGIN inland-tft35$/,/^# END inland-tft35$/d' "$CONFIG"
sed -i '/^# Inland TFT35 ILI9481 display/d'              "$CONFIG"
sed -i '/^dtoverlay=inland-ili9481-overlay/d'              "$CONFIG"
sed -i '/^dtoverlay=ads7846,/d'                            "$CONFIG"
sed -i '/^dtoverlay=xpt2046,/d'                            "$CONFIG"
sed -i '/^disable_fw_kms_setup=1/d'                        "$CONFIG"

# Restore KMS / display auto-detect lines that any installer commented out
sed -i 's/^#\(dtoverlay=vc4-kms-v3d\)/\1/'     "$CONFIG"
sed -i 's/^#\(dtoverlay=vc4-fkms-v3d\)/\1/'    "$CONFIG"
sed -i 's/^#\(display_auto_detect=1\)/\1/'      "$CONFIG"

# Clean cmdline.txt
sed -i 's/ fbcon=map:[^ ]*//g'  "$CMDLINE"
sed -i 's/  */ /g'              "$CMDLINE"
sed -i 's/[[:space:]]*$//'      "$CMDLINE"

# =====================================================================
# [7/7] Remove installed overlay artifacts (from old kernel-module installs)
# =====================================================================

echo "[7/7] Removing overlay artifacts"
rm -f "${OVERLAYS_DIR}/inland-ili9481-overlay.dtbo"
rm -f "${OVERLAYS_DIR}/inland-ili9481-overlay.dts"

# Optionally restore Wayland
if command -v raspi-config >/dev/null 2>&1; then
    raspi-config nonint do_wayland W2 >/dev/null 2>&1 || true
fi

echo
echo "Uninstall complete."
echo "Reboot now: sudo reboot"
