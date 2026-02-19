#!/bin/bash
# install.sh — Inland 3.5" TFT (ILI9486-compat SPI) display installer
#
# Userspace SPI mirror: fbcp reads /dev/fb0, converts/scales to 480×320
# RGB565, and pushes frames to the TFT via /dev/spidev0.0.
#
# IMPORTANT: Requires vc4-fkms-v3d (not full kms) so that /dev/fb0
# contains real pixel data that fbcp can read via mmap.
#
# Usage: sudo ./install.sh

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: run as root:  sudo ./install.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "═══════════════════════════════════════════════════"
echo " Inland 3.5\" TFT LCD (SPI) — Installer"
echo "═══════════════════════════════════════════════════"

# ── Locate boot partition ─────────────────────────────
CONFIG="/boot/config.txt"
CMDLINE="/boot/cmdline.txt"
if [ -f "/boot/firmware/config.txt" ]; then
    CONFIG="/boot/firmware/config.txt"
    CMDLINE="/boot/firmware/cmdline.txt"
fi

echo "  Boot config: $CONFIG"
echo "  Cmdline:     $CMDLINE"

# ── 1. Build ──────────────────────────────────────────
echo ""
echo "[1/9] Building fbcp..."
if ! command -v gcc &>/dev/null; then
    apt-get update -qq && apt-get install -y -qq gcc
fi
make clean >/dev/null 2>&1 || true
make
echo "  Built OK"

# ── 2. Install binary ────────────────────────────────
echo ""
echo "[2/9] Installing binary..."
install -m 755 fbcp /usr/local/bin/fbcp
echo "  Installed /usr/local/bin/fbcp"

# ── 3. Disable conflicting services/modules ──────────
echo ""
echo "[3/9] Removing conflicting drivers..."
systemctl disable --now ili9481-fb.service 2>/dev/null || true
rm -f /etc/systemd/system/ili9481-fb.service
rmmod fb_ili9486 2>/dev/null || true
rmmod fb_ili9481 2>/dev/null || true
rmmod fbtft      2>/dev/null || true
rmmod ads7846    2>/dev/null || true

# The gldriver-test package ships rp1-test.service and glamor-test.service
# which recreate /etc/X11/xorg.conf.d/99-v3d.conf and
# /usr/share/X11/xorg.conf.d/20-noglamor.conf on every boot.
# Both force the modesetting driver which conflicts with fbdev.
systemctl disable --now rp1-test.service 2>/dev/null || true
systemctl disable --now glamor-test.service 2>/dev/null || true
echo "  Disabled rp1-test / glamor-test services (prevent modesetting conflicts)"

# Remove old fbtft overlays from config.txt
sed -i '/^dtoverlay=piscreen/d'     "$CONFIG" 2>/dev/null || true
sed -i '/^dtoverlay=tft35a/d'       "$CONFIG" 2>/dev/null || true
sed -i '/^dtoverlay=waveshare35a/d' "$CONFIG" 2>/dev/null || true
# Remove old marker blocks from previous installers
sed -i '/^# BEGIN inland-ili9486$/,/^# END inland-ili9486$/d' "$CONFIG" 2>/dev/null || true
echo "  Cleaned up old drivers and overlays"

# ── 4. Configure config.txt ──────────────────────────
echo ""
echo "[4/9] Configuring boot firmware..."

# Enable SPI (required for /dev/spidev0.0)
if ! grep -q "^dtparam=spi=on" "$CONFIG" 2>/dev/null; then
    echo "dtparam=spi=on" >> "$CONFIG"
    echo "  Added dtparam=spi=on"
else
    echo "  SPI already enabled"
fi

# Ensure spidev devices exist (spi0-2cs overlay)
if ! grep -q "^dtoverlay=spi0-2cs" "$CONFIG" 2>/dev/null; then
    echo "dtoverlay=spi0-2cs" >> "$CONFIG"
    echo "  Added dtoverlay=spi0-2cs"
else
    echo "  spi0-2cs overlay already present"
fi

# Switch from full KMS to FKMS.
# Full KMS (vc4-kms-v3d) renders directly to the display via DRM planes,
# so /dev/fb0 is empty — fbcp reads all zeros → black screen.
# FKMS (vc4-fkms-v3d) keeps a legacy framebuffer with real pixel data
# that fbcp can mmap and mirror to the TFT.
if grep -q "^dtoverlay=vc4-kms-v3d" "$CONFIG" 2>/dev/null; then
    sed -i 's/^dtoverlay=vc4-kms-v3d/dtoverlay=vc4-fkms-v3d/' "$CONFIG"
    echo "  Switched vc4-kms-v3d → vc4-fkms-v3d (required for fb0 content)"
elif grep -q "^dtoverlay=vc4-fkms-v3d" "$CONFIG" 2>/dev/null; then
    echo "  vc4-fkms-v3d already set"
else
    echo "dtoverlay=vc4-fkms-v3d" >> "$CONFIG"
    echo "  Added dtoverlay=vc4-fkms-v3d"
fi

# Ensure max_framebuffers=2
if ! grep -q "^max_framebuffers=" "$CONFIG" 2>/dev/null; then
    echo "max_framebuffers=2" >> "$CONFIG"
    echo "  Added max_framebuffers=2"
else
    echo "  max_framebuffers already set"
fi

# Force HDMI hotplug so fb0 exists even without a monitor
if ! grep -q "^hdmi_force_hotplug=1" "$CONFIG" 2>/dev/null; then
    echo "hdmi_force_hotplug=1" >> "$CONFIG"
    echo "  Added hdmi_force_hotplug=1"
else
    echo "  hdmi_force_hotplug=1 already set"
fi

# ── 5. Configure kernel cmdline for boot console ─────
echo ""
echo "[5/9] Configuring boot console on TFT..."

if [ -f "$CMDLINE" ]; then
    CMDLINE_CONTENT=$(cat "$CMDLINE")

    # Force a video mode so the HDMI framebuffer exists at boot
    if ! echo "$CMDLINE_CONTENT" | grep -q "video=HDMI-A-1"; then
        CMDLINE_CONTENT="$CMDLINE_CONTENT video=HDMI-A-1:640x480@60D"
        echo "  Added video=HDMI-A-1:640x480@60D (force HDMI fb at boot)"
    else
        echo "  video=HDMI-A-1 already set"
    fi

    # Remove 'quiet' and 'splash' so boot messages are visible on TFT
    CMDLINE_CONTENT=$(echo "$CMDLINE_CONTENT" | sed 's/ quiet / /g; s/^quiet //; s/ quiet$//; s/ splash / /g; s/^splash //; s/ splash$//')

    # Clean up double spaces
    CMDLINE_CONTENT=$(echo "$CMDLINE_CONTENT" | sed 's/  */ /g; s/^ //; s/ $//')

    echo "$CMDLINE_CONTENT" > "$CMDLINE"
    echo "  Removed 'quiet' and 'splash' for visible boot"
fi

# ── 6. Switch desktop session to X11 ──────────────────
echo ""
echo "[6/9] Configuring desktop session..."

# FKMS does not support Wayland compositors (labwc, wlroots).
# If lightdm is configured for Wayland sessions, switch to X11.
LIGHTDM_CONF="/etc/lightdm/lightdm.conf"
if [ -f "$LIGHTDM_CONF" ]; then
    CHANGED=0
    if grep -q "^greeter-session=pi-greeter-labwc" "$LIGHTDM_CONF" 2>/dev/null; then
        sed -i 's/^greeter-session=pi-greeter-labwc/greeter-session=pi-greeter/' "$LIGHTDM_CONF"
        CHANGED=1
    fi
    if grep -q "^user-session=rpd-labwc" "$LIGHTDM_CONF" 2>/dev/null; then
        sed -i 's/^user-session=rpd-labwc/user-session=rpd-x/' "$LIGHTDM_CONF"
        CHANGED=1
    fi
    if grep -q "^autologin-session=rpd-labwc" "$LIGHTDM_CONF" 2>/dev/null; then
        sed -i 's/^autologin-session=rpd-labwc/autologin-session=rpd-x/' "$LIGHTDM_CONF"
        CHANGED=1
    fi
    if [ "$CHANGED" -eq 1 ]; then
        echo "  Switched Wayland (labwc) → X11 (rpd-x) sessions"
    else
        echo "  Already using X11 sessions"
    fi
else
    echo "  No lightdm config found (skipped)"
fi

# ── 7. Configure Xorg for fbdev ──────────────────────
echo ""
echo "[7/9] Configuring Xorg for framebuffer rendering..."

# Xorg must use the fbdev driver (not modesetting) so that it renders
# into /dev/fb0 which fbcp can mmap.  The system's 20-noglamor.conf
# defines a modesetting Device that conflicts with fbdev; disable it.
mkdir -p /etc/X11/xorg.conf.d

cat > /etc/X11/xorg.conf.d/99-fbdev-tft.conf << 'XEOF'
# Force Xorg to use fbdev driver so /dev/fb0 has real pixel data.
# Required for fbcp to mirror the desktop to the TFT display.

Section "ServerLayout"
  Identifier "TFT Layout"
  Screen "Default Screen"
  Option "AutoAddGPU" "false"
EndSection

Section "ServerFlags"
  Option "AutoAddDevices" "true"
  Option "AutoAddGPU" "false"
  Option "Debug" "None"
EndSection

Section "Device"
  Identifier "FBDEV"
  Driver "fbdev"
  Option "fbdev" "/dev/fb0"
EndSection

Section "Screen"
  Identifier "Default Screen"
  Device "FBDEV"
  DefaultDepth 16
  SubSection "Display"
    Depth 16
    Modes "640x480"
  EndSubSection
EndSection
XEOF
echo "  Installed /etc/X11/xorg.conf.d/99-fbdev-tft.conf"

# Remove modesetting configs that conflict with fbdev.
# rp1-test.service / glamor-test.service were already disabled above,
# so these files will NOT be recreated on next boot.
NOGLAMOR="/usr/share/X11/xorg.conf.d/20-noglamor.conf"
if [ -f "$NOGLAMOR" ]; then
    mv "$NOGLAMOR" "${NOGLAMOR}.bak"
    echo "  Disabled 20-noglamor.conf (modesetting conflict)"
else
    echo "  20-noglamor.conf already disabled"
fi

V3DCONF="/etc/X11/xorg.conf.d/99-v3d.conf"
rm -f "$V3DCONF" "${V3DCONF}.bak" "${V3DCONF}.tmp"
echo "  Removed 99-v3d.conf (modesetting OutputClass conflict)"

# ── 8. Install systemd service ───────────────────────
echo ""
echo "[8/9] Installing systemd service..."
cp systemd/fbcp.service /etc/systemd/system/fbcp.service
systemctl daemon-reload
systemctl enable fbcp.service
echo "  Enabled fbcp.service"

# ── 9. Start the service now ─────────────────────────
echo ""
echo "[9/9] Starting display service..."
systemctl restart fbcp.service
sleep 3

if systemctl is-active --quiet fbcp.service; then
    echo "  ✓ fbcp.service is running"
else
    echo "  ✗ Service failed. Check: journalctl -u fbcp.service -n 30"
fi

echo ""
echo "═══════════════════════════════════════════════════"
echo " Installation complete!"
echo ""
echo " IMPORTANT: A reboot is required for vc4-fkms-v3d"
echo " to take effect. Until then, /dev/fb0 may be empty"
echo " and the TFT will show the SPI test pattern only."
echo ""
echo " After reboot the TFT will show:"
echo "   • Boot text messages (kernel + systemd)"
echo "   • Desktop (mirrored from HDMI framebuffer)"
echo ""
echo " Commands:"
echo "   Status:  sudo systemctl status fbcp"
echo "   Logs:    journalctl -u fbcp.service -f"
echo "   Stop:    sudo systemctl stop fbcp"
echo "   Remove:  sudo ./uninstall.sh"
echo ""
echo " Reboot now: sudo reboot"
echo "═══════════════════════════════════════════════════"
