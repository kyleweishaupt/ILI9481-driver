#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# uninstall.sh — Remove Inland TFT35 ILI9481 userspace driver and configuration
#
# Reverses the changes made by install.sh: stops/disables services, removes
# the daemon binary, configuration files, and cleans boot config entries.

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
systemctl disable --now fbcp.service >/dev/null 2>&1 || true
systemctl disable --now inland-tft35-boot.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/ili9481-fb.service
rm -f /etc/systemd/system/fbcp.service
rm -f /etc/systemd/system/inland-tft35-boot.service
rm -f /usr/local/bin/inland-tft35-boot
systemctl daemon-reload

# =====================================================================
# [2/7] Remove daemon binary
# =====================================================================

echo "[2/7] Removing daemon binaries"
rm -f /usr/local/bin/ili9481-fb
rm -f /usr/local/bin/fbcp

# =====================================================================
# [3/7] Remove configuration files
# =====================================================================

echo "[3/7] Removing configuration files"
rm -rf /etc/ili9481
rm -f /etc/modprobe.d/vfb-ili9481.conf    # legacy vfb installs

# =====================================================================
# [4/7] Remove X11 display and touch config
# =====================================================================

echo "[4/7] Removing X11 display and touch config"
rm -f /etc/X11/xorg.conf.d/99-fbdev-tft.conf
rm -f /etc/X11/xorg.conf.d/99-inland-fbdev.conf
rm -f /etc/X11/xorg.conf.d/99-inland-touch.conf
rm -f /etc/X11/xorg.conf.d/99-v3d.conf.bak

# Restore the modesetting config if we disabled it
NOGLAMOR="/usr/share/X11/xorg.conf.d/20-noglamor.conf"
if [ -f "${NOGLAMOR}.bak" ] && [ ! -f "$NOGLAMOR" ]; then
    mv "${NOGLAMOR}.bak" "$NOGLAMOR"
    echo "  Restored 20-noglamor.conf"
fi

# =====================================================================
# [5/7] Remove module autoload hints
# =====================================================================

echo "[5/7] Removing module autoload hints"
rm -f /etc/modules-load.d/inland-tft35.conf    # legacy vfb/kernel-module installs

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

# Switch fkms back to full kms (Pi OS default)
sed -i 's/^dtoverlay=vc4-fkms-v3d/dtoverlay=vc4-kms-v3d/' "$CONFIG"

# Clean cmdline.txt
sed -i 's/ fbcon=map:[^ ]*//g'           "$CMDLINE"
sed -i 's/ video=HDMI-A-1:[^ ]*//g'      "$CMDLINE"
sed -i 's/  */ /g'              "$CMDLINE"
sed -i 's/[[:space:]]*$//'      "$CMDLINE"

# Restore 'quiet splash' if missing (typical Pi OS default)
if ! grep -q 'quiet' "$CMDLINE"; then
    sed -i 's/rootwait/rootwait quiet splash/' "$CMDLINE"
fi

# =====================================================================
# [7/7] Remove installed overlay artifacts (from old kernel-module installs)
# =====================================================================

echo "[7/7] Removing overlay artifacts"
rm -f "${OVERLAYS_DIR}/inland-ili9481-overlay.dtbo"
rm -f "${OVERLAYS_DIR}/inland-ili9481-overlay.dts"

# Restore Wayland sessions if install.sh switched to X11
LIGHTDM_CONF="/etc/lightdm/lightdm.conf"
if [ -f "$LIGHTDM_CONF" ]; then
    sed -i 's/^greeter-session=pi-greeter$/greeter-session=pi-greeter-labwc/' "$LIGHTDM_CONF" 2>/dev/null || true
    sed -i 's/^user-session=rpd-x$/user-session=rpd-labwc/' "$LIGHTDM_CONF" 2>/dev/null || true
    sed -i 's/^autologin-session=rpd-x$/autologin-session=rpd-labwc/' "$LIGHTDM_CONF" 2>/dev/null || true
    echo "  Restored Wayland (labwc) desktop sessions"
fi

echo
echo "Uninstall complete."
echo "Reboot now: sudo reboot"
