#!/bin/bash
# install.sh — Inland 3.5" TFT (ILI9486 SPI) display installer
#
# Userspace SPI driver approach: fbcp talks directly to /dev/spidev0.0
# using GPIO chardev for DC/RST pins. No kernel fbtft overlay needed.
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
echo " Inland 3.5\" TFT LCD (ILI9486) — Installer"
echo "═══════════════════════════════════════════════════"

# ── 1. Build ──────────────────────────────────────────
echo "[1/5] Building fbcp..."
if ! command -v gcc &>/dev/null; then
    apt-get update -qq && apt-get install -y -qq gcc
fi
gcc -O2 -Wall -Wno-stringop-truncation -o fbcp src/fbcp.c
echo "  Built OK"

# ── 2. Install binary ────────────────────────────────
echo "[2/5] Installing binary..."
install -m 755 fbcp /usr/local/bin/fbcp
echo "  Installed /usr/local/bin/fbcp"

# ── 3. Enable SPI in config.txt ──────────────────────
echo "[3/5] Enabling SPI..."
CONFIG="/boot/config.txt"
[ -f "/boot/firmware/config.txt" ] && CONFIG="/boot/firmware/config.txt"

if ! grep -q "^dtparam=spi=on" "$CONFIG" 2>/dev/null; then
    echo "dtparam=spi=on" >> "$CONFIG"
    echo "  Added dtparam=spi=on to $CONFIG"
else
    echo "  SPI already enabled in $CONFIG"
fi

# Remove any conflicting fbtft overlays
sed -i '/^dtoverlay=piscreen/d'     "$CONFIG" 2>/dev/null || true
sed -i '/^dtoverlay=tft35a/d'       "$CONFIG" 2>/dev/null || true
sed -i '/^dtoverlay=waveshare35a/d' "$CONFIG" 2>/dev/null || true

# Ensure spidev devices exist (add spi0-2cs overlay if no other SPI overlay)
if ! grep -q "^dtoverlay=spi0" "$CONFIG" 2>/dev/null; then
    echo "dtoverlay=spi0-2cs" >> "$CONFIG"
    echo "  Added dtoverlay=spi0-2cs to $CONFIG"
fi

# ── 4. Install systemd service ───────────────────────
echo "[4/5] Installing systemd service..."
cp systemd/fbcp.service /etc/systemd/system/fbcp.service
systemctl daemon-reload
systemctl enable fbcp.service
echo "  Enabled fbcp.service"

# ── 5. Unload conflicting kernel modules ─────────────
echo "[5/5] Cleaning up kernel modules..."
rmmod fb_ili9486 2>/dev/null && echo "  Unloaded fb_ili9486" || true
rmmod fbtft      2>/dev/null && echo "  Unloaded fbtft"      || true
rmmod ads7846    2>/dev/null && echo "  Unloaded ads7846"    || true

# Ensure spidev devices exist now
if [ ! -e /dev/spidev0.0 ]; then
    modprobe spi_bcm2835 2>/dev/null || true
    modprobe spidev 2>/dev/null || true
    for d in /sys/bus/spi/devices/spi0.*; do
        [ -e "$d/driver_override" ] && echo spidev > "$d/driver_override" 2>/dev/null || true
        echo "$(basename "$d")" > /sys/bus/spi/drivers/spidev/bind 2>/dev/null || true
    done
    sleep 1
fi

echo ""
echo "═══════════════════════════════════════════════════"
echo " Installation complete!"
echo ""
echo " Starting display now..."
systemctl restart fbcp.service
sleep 2
if systemctl is-active --quiet fbcp.service; then
    echo " ✓ Display service is running"
else
    echo " ✗ Service failed — check: journalctl -u fbcp.service"
fi
echo ""
echo " The display will auto-start on boot."
echo " To stop:   sudo systemctl stop fbcp.service"
echo " To remove: sudo ./uninstall.sh"
echo "═══════════════════════════════════════════════════"
