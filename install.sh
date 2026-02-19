#!/bin/bash
# install.sh — Inland 3.5" TFT (ILI9481, 8-bit parallel) display installer
#
# Userspace MMIO GPIO driver: ili9481-fb mirrors /dev/fb0 onto the TFT
# via the 8-bit 8080-I parallel bus (13 GPIOs on the 26-pin header).
# Displays desktop, boot text, and the full boot process on the TFT.
#
# Usage: sudo ./install.sh [--touch]

set -euo pipefail

ENABLE_TOUCH=0
for arg in "$@"; do
    case "$arg" in
        --touch) ENABLE_TOUCH=1 ;;
        --help|-h)
            echo "Usage: sudo ./install.sh [--touch]"
            echo "  --touch   Build with XPT2046 touch support (experimental)"
            exit 0 ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: run as root:  sudo ./install.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "═══════════════════════════════════════════════════"
echo " Inland 3.5\" TFT LCD (ILI9481, parallel) — Installer"
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
echo "[1/8] Building ili9481-fb daemon..."
if ! command -v gcc &>/dev/null; then
    apt-get update -qq && apt-get install -y -qq gcc
fi

if [ "$ENABLE_TOUCH" -eq 1 ]; then
    echo "  Touch support: ENABLED"
    make clean >/dev/null 2>&1 || true
    make TOUCH=1
else
    echo "  Touch support: disabled"
    make clean >/dev/null 2>&1 || true
    make
fi
echo "  Built OK"

# ── 2. Install binary + config ───────────────────────
echo ""
echo "[2/8] Installing binary and configuration..."
install -m 755 ili9481-fb /usr/local/bin/ili9481-fb
install -d /etc/ili9481
install -m 644 config/ili9481.conf /etc/ili9481/ili9481.conf
echo "  Installed /usr/local/bin/ili9481-fb"
echo "  Installed /etc/ili9481/ili9481.conf"

# ── 3. Disable conflicting services/modules ──────────
echo ""
echo "[3/8] Removing conflicting drivers..."
systemctl disable --now fbcp.service 2>/dev/null || true
rm -f /etc/systemd/system/fbcp.service
rm -f /usr/local/bin/fbcp
rmmod fb_ili9486 2>/dev/null || true
rmmod fb_ili9481 2>/dev/null || true
rmmod fbtft      2>/dev/null || true
rmmod ads7846    2>/dev/null || true

# Remove old fbtft overlays from config.txt
sed -i '/^dtoverlay=piscreen/d'     "$CONFIG" 2>/dev/null || true
sed -i '/^dtoverlay=tft35a/d'       "$CONFIG" 2>/dev/null || true
sed -i '/^dtoverlay=waveshare35a/d' "$CONFIG" 2>/dev/null || true
# Remove stale SPI overlay added by old installer (not needed for parallel bus)
sed -i '/^dtoverlay=spi0-2cs/d'     "$CONFIG" 2>/dev/null || true
# Remove old marker blocks
sed -i '/^# BEGIN inland-ili9486$/,/^# END inland-ili9486$/d' "$CONFIG" 2>/dev/null || true
echo "  Cleaned up old drivers and overlays"

# ── 4. Configure config.txt ──────────────────────────
echo ""
echo "[4/8] Configuring boot firmware..."

# Force HDMI hotplug so KMS creates /dev/fb0 even without a monitor
if ! grep -q "^hdmi_force_hotplug=1" "$CONFIG" 2>/dev/null; then
    echo "hdmi_force_hotplug=1" >> "$CONFIG"
    echo "  Added hdmi_force_hotplug=1"
else
    echo "  hdmi_force_hotplug=1 already set"
fi

# Ensure max_framebuffers=2 for potential dual-fb usage
if ! grep -q "^max_framebuffers=" "$CONFIG" 2>/dev/null; then
    echo "max_framebuffers=2" >> "$CONFIG"
    echo "  Added max_framebuffers=2"
fi

# ── 5. Configure kernel cmdline for boot console ─────
echo ""
echo "[5/8] Configuring boot console on TFT..."

if [ -f "$CMDLINE" ]; then
    CMDLINE_CONTENT=$(cat "$CMDLINE")

    # Add fbcon=map:0 so text console appears on fb0 (mirrored to TFT)
    if ! echo "$CMDLINE_CONTENT" | grep -q "fbcon=map:"; then
        CMDLINE_CONTENT="$CMDLINE_CONTENT fbcon=map:0"
        echo "  Added fbcon=map:0"
    else
        echo "  fbcon=map already set"
    fi

    # Force a video mode so the HDMI framebuffer exists at boot
    if ! echo "$CMDLINE_CONTENT" | grep -q "video=HDMI-A-1"; then
        CMDLINE_CONTENT="$CMDLINE_CONTENT video=HDMI-A-1:640x480@60D"
        echo "  Added video=HDMI-A-1:640x480@60D (force HDMI fb)"
    else
        echo "  video=HDMI-A-1 already set"
    fi

    # Remove 'quiet' and 'splash' so boot messages are visible on TFT
    CMDLINE_CONTENT=$(echo "$CMDLINE_CONTENT" | sed 's/ quiet / /g; s/^quiet //; s/ quiet$//; s/ splash / /g; s/^splash //; s/ splash$//')

    # Clean up double spaces
    CMDLINE_CONTENT=$(echo "$CMDLINE_CONTENT" | sed 's/  */ /g; s/^ //; s/ $//')

    echo "$CMDLINE_CONTENT" > "$CMDLINE"
    echo "  Removed 'quiet' and 'splash' for visible boot"
    echo "  cmdline: $CMDLINE_CONTENT"
fi

# ── 6. Install systemd service ───────────────────────
echo ""
echo "[6/8] Installing systemd service..."
cp systemd/ili9481-fb.service /etc/systemd/system/ili9481-fb.service
systemctl daemon-reload
systemctl enable ili9481-fb.service
echo "  Enabled ili9481-fb.service"

# ── 7. Set up /dev/gpiomem permissions ────────────────
echo ""
echo "[7/8] Ensuring GPIO access..."
if [ -e /dev/gpiomem ]; then
    # The daemon runs as root via systemd, but also allow gpio group
    chown root:gpio /dev/gpiomem 2>/dev/null || true
    chmod 660 /dev/gpiomem 2>/dev/null || true
    echo "  /dev/gpiomem: permissions OK"
else
    echo "  Warning: /dev/gpiomem not found (will be available after boot)"
fi

# ── 8. Start the service now ─────────────────────────
echo ""
echo "[8/8] Starting display service..."
systemctl restart ili9481-fb.service
sleep 3

if systemctl is-active --quiet ili9481-fb.service; then
    echo "  ✓ ili9481-fb.service is running"
else
    echo "  ✗ Service failed. Check: journalctl -u ili9481-fb.service -n 30"
fi

echo ""
echo "═══════════════════════════════════════════════════"
echo " Installation complete!"
echo ""
echo " The TFT will show:"
echo "   • Boot text messages (kernel + systemd)"
echo "   • Desktop (mirrored from HDMI framebuffer)"
echo ""
echo " Commands:"
echo "   Status:  sudo systemctl status ili9481-fb"
echo "   Logs:    journalctl -u ili9481-fb.service -f"
echo "   Stop:    sudo systemctl stop ili9481-fb"
echo "   Test:    sudo ili9481-fb --test-pattern"
echo "   Remove:  sudo ./uninstall.sh"
echo ""
echo " Reboot now for full boot display: sudo reboot"
echo "═══════════════════════════════════════════════════"
