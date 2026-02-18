#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: sudo ./uninstall.sh"
    exit 1
fi

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
echo "Config: $CONFIG"
echo "Cmdline: $CMDLINE"
echo

echo "[1/6] Removing service and helper"
systemctl disable --now inland-tft35-boot.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/inland-tft35-boot.service
rm -f /usr/local/bin/inland-tft35-boot
systemctl daemon-reload

echo "[2/6] Removing X11 display and touch config"
rm -f /etc/X11/xorg.conf.d/99-inland-fbdev.conf
rm -f /etc/X11/xorg.conf.d/99-inland-touch.conf

echo "[3/6] Removing module autoload hints"
rm -f /etc/modules-load.d/inland-tft35.conf

echo "[4/6] Cleaning config.txt entries"
sed -i '/^# BEGIN inland-tft35$/,/^# END inland-tft35$/d' "$CONFIG"
sed -i '/^# Inland TFT35 ILI9481 display/d' "$CONFIG"
sed -i '/^dtoverlay=inland-ili9481-overlay/d' "$CONFIG"
sed -i '/^dtoverlay=ads7846,/d' "$CONFIG"
sed -i '/^dtoverlay=xpt2046,/d' "$CONFIG"

sed -i 's/^#\(dtoverlay=vc4-kms-v3d\)/\1/' "$CONFIG"
sed -i 's/^#\(dtoverlay=vc4-fkms-v3d\)/\1/' "$CONFIG"
sed -i 's/^#\(display_auto_detect=1\)/\1/' "$CONFIG"

echo "[5/6] Cleaning cmdline.txt entries"
sed -i 's/ fbcon=map:[^ ]*//g' "$CMDLINE"
sed -i 's/  */ /g' "$CMDLINE"
sed -i 's/[[:space:]]*$//' "$CMDLINE"

echo "[6/6] Removing installed overlay artifacts"
rm -f "${OVERLAYS_DIR}/inland-ili9481-overlay.dtbo"
rm -f "${OVERLAYS_DIR}/inland-ili9481-overlay.dts"

if command -v raspi-config >/dev/null 2>&1; then
    raspi-config nonint do_wayland W2 >/dev/null 2>&1 || true
fi

echo
echo "Uninstall complete."
echo "Reboot now: sudo reboot"
