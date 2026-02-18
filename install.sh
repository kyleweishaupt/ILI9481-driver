#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# install.sh — Install Inland TFT35 / MPI3501 display + touch configuration
#
# Usage:  sudo ./install.sh [OPTIONS]
#
# This script configures Raspberry Pi OS to use the built-in piscreen
# device-tree overlay and fb_ili9486 (fbtft) driver for the Inland TFT35"
# Touch Shield (MicroCenter) and compatible MPI3501 / Waveshare 3.5" (A)
# clone displays.
#
# No custom kernel module is compiled — the driver is already built into
# the stock kernel.
#
# Options:
#   --speed=HZ       SPI clock frequency (default: 16000000)
#   --rotate=DEG     Display rotation: 0, 90, 180, 270 (default: 270)
#   --fps=N          Framerate hint (default: 30)
#   --no-touch       Skip touchscreen configuration
#   --overlay=NAME   Overlay to use (default: piscreen; fallback: waveshare35a)

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────

SPI_SPEED=16000000
ROTATE=270
FPS=30
TOUCH=1
OVERLAY="piscreen"
SERVICE_NAME="inland-tft35-display"

# ── Parse arguments ──────────────────────────────────────────────────

for arg in "$@"; do
    case "$arg" in
        --speed=*)   SPI_SPEED="${arg#*=}" ;;
        --rotate=*)  ROTATE="${arg#*=}" ;;
        --fps=*)     FPS="${arg#*=}" ;;
        --no-touch)  TOUCH=0 ;;
        --overlay=*) OVERLAY="${arg#*=}" ;;
        --help|-h)
            sed -n '2,/^$/s/^# //p' "$0"
            exit 0 ;;
        *)
            echo "Unknown option: $arg"
            echo "Run with --help for usage."
            exit 1 ;;
    esac
done

# ── Checks ───────────────────────────────────────────────────────────

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root (sudo ./install.sh)"
    exit 1
fi

# Validate rotation
case "$ROTATE" in
    0|90|180|270) ;;
    *)
        echo "Error: Invalid rotation '$ROTATE'. Must be 0, 90, 180, or 270."
        exit 1 ;;
esac

# ── Determine paths ─────────────────────────────────────────────────

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
TOTAL=8
[ "$TOUCH" -eq 0 ] && TOTAL=7

echo "Inland TFT35 Display Installer"
echo "==============================="
echo ""
echo "Overlay:   ${OVERLAY}"
echo "SPI speed: ${SPI_SPEED} Hz"
echo "Rotation:  ${ROTATE}°"
echo "FPS:       ${FPS}"
echo "Touch:     $([ "$TOUCH" -eq 1 ] && echo 'yes' || echo 'no')"
echo "Config:    ${CONFIG}"
echo ""

# ── 1. Clean old artifacts from previous ili9481 driver ──────────────

echo "[$STEP/$TOTAL] Cleaning old ili9481 driver artifacts ..."

# Remove old DKMS module
if command -v dkms >/dev/null 2>&1; then
    if dkms status "ili9481" 2>/dev/null | grep -q .; then
        for ver in $(dkms status "ili9481" 2>/dev/null \
                     | sed -n 's/.*\/\([^,]*\),.*/\1/p' | sort -u); do
            dkms remove "ili9481/${ver}" --all 2>/dev/null || true
            echo "  Removed DKMS ili9481/${ver}"
        done
    fi
fi
# Remove DKMS source trees
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

# Remove old blacklist that blocked fbtft (we now WANT fbtft)
rm -f /etc/modprobe.d/ili9481-blacklist.conf 2>/dev/null && \
    echo "  Removed /etc/modprobe.d/ili9481-blacklist.conf" || true

# Remove old systemd service
if [ -f /etc/systemd/system/ili9481-display.service ]; then
    systemctl disable ili9481-display.service 2>/dev/null || true
    rm -f /etc/systemd/system/ili9481-display.service
    systemctl daemon-reload 2>/dev/null || true
    echo "  Removed ili9481-display.service"
fi

# Remove old helper script
rm -f /usr/local/bin/ili9481-find-card 2>/dev/null || true

# Remove old X11/Wayland configs
rm -f /etc/X11/xorg.conf.d/99-ili9481.conf 2>/dev/null || true
rm -f /etc/environment.d/99-ili9481.conf 2>/dev/null || true
rm -f /etc/labwc/environment 2>/dev/null || true

# Remove old config.txt entries for ili9481/xpt2046
if [ -f "$CONFIG" ]; then
    sed -i '/^# ILI9481 SPI display driver/d' "$CONFIG"
    sed -i '/^dtoverlay=ili9481/d' "$CONFIG"
    sed -i '/^# XPT2046 resistive touchscreen/d' "$CONFIG"
    sed -i '/^dtoverlay=xpt2046/d' "$CONFIG"
    sed -i '/^# Enable DRM\/KMS (required for ILI9481 DRM driver)/d' "$CONFIG"
    sed -i '/^# Enable SPI bus (required for ILI9481 display)/d' "$CONFIG"
    sed -i '/^# Blacklist fbtft/d' "$CONFIG"
fi

echo "  Old artifacts cleaned"
STEP=$((STEP + 1))

# ── 2. Verify overlay exists ────────────────────────────────────────

echo "[$STEP/$TOTAL] Verifying ${OVERLAY} overlay ..."
DTBO_PATH="${OVERLAYS_DIR}/${OVERLAY}.dtbo"
if [ ! -f "$DTBO_PATH" ]; then
    echo "  Warning: ${DTBO_PATH} not found."
    # Try fallback
    if [ "$OVERLAY" = "piscreen" ] && [ -f "${OVERLAYS_DIR}/waveshare35a.dtbo" ]; then
        OVERLAY="waveshare35a"
        DTBO_PATH="${OVERLAYS_DIR}/${OVERLAY}.dtbo"
        echo "  Falling back to waveshare35a overlay"
    else
        echo "  Error: No compatible overlay found in ${OVERLAYS_DIR}"
        echo "  Expected: piscreen.dtbo or waveshare35a.dtbo"
        echo "  Make sure you are running a stock Raspberry Pi OS kernel."
        exit 1
    fi
fi
echo "  Found ${DTBO_PATH}"
STEP=$((STEP + 1))

# ── 3. Configure config.txt ─────────────────────────────────────────

echo "[$STEP/$TOTAL] Configuring ${CONFIG} ..."
if [ -f "$CONFIG" ]; then
    changed=0

    # Enable SPI
    if ! grep -q "^dtparam=spi=on" "$CONFIG"; then
        printf '\n# Enable SPI bus (required for SPI display)\ndtparam=spi=on\n' >> "$CONFIG"
        echo "  Added dtparam=spi=on"
        changed=1
    fi

    # Comment out vc4-kms-v3d (fbtft needs legacy framebuffer, not KMS)
    if grep -q "^dtoverlay=vc4-kms-v3d" "$CONFIG"; then
        sed -i 's/^dtoverlay=vc4-kms-v3d/#dtoverlay=vc4-kms-v3d/' "$CONFIG"
        echo "  Commented out dtoverlay=vc4-kms-v3d (fbtft requires legacy fb)"
        changed=1
    fi
    if grep -q "^dtoverlay=vc4-fkms-v3d" "$CONFIG"; then
        sed -i 's/^dtoverlay=vc4-fkms-v3d/#dtoverlay=vc4-fkms-v3d/' "$CONFIG"
        echo "  Commented out dtoverlay=vc4-fkms-v3d (fbtft requires legacy fb)"
        changed=1
    fi

    # Disable firmware KMS setup
    if ! grep -q "^disable_fw_kms_setup=1" "$CONFIG"; then
        printf '\n# Disable firmware KMS setup (required for fbtft)\ndisable_fw_kms_setup=1\n' >> "$CONFIG"
        echo "  Added disable_fw_kms_setup=1"
        changed=1
    fi

    # Remove any existing piscreen/waveshare35a overlay lines (prevent duplicates)
    sed -i '/^# Inland TFT35 SPI display/d' "$CONFIG"
    sed -i "/^dtoverlay=${OVERLAY}/d" "$CONFIG"

    # Add overlay with parameters
    OVERLAY_LINE="dtoverlay=${OVERLAY},speed=${SPI_SPEED},rotate=${ROTATE},fps=${FPS}"
    printf '\n# Inland TFT35 SPI display (fbtft / fb_ili9486)\n%s\n' "$OVERLAY_LINE" >> "$CONFIG"
    echo "  Added ${OVERLAY_LINE}"
    changed=1

    # Collapse multiple consecutive blank lines
    sed -i '/^$/N;/^\n$/d' "$CONFIG"

    [ "$changed" -eq 0 ] && echo "  Already configured."
else
    echo "  Warning: ${CONFIG} not found — configure manually."
fi
STEP=$((STEP + 1))

# ── 4. Configure cmdline.txt ────────────────────────────────────────

echo "[$STEP/$TOTAL] Configuring ${CMDLINE} ..."
if [ -f "$CMDLINE" ]; then
    # Remove stale fbcon mapping
    sed -i 's/ fbcon=map:[^ ]*//g' "$CMDLINE"
    # Remove 'splash' — Plymouth only renders on HDMI/DSI, not SPI
    sed -i 's/ splash//g' "$CMDLINE"
    echo "  Cleaned cmdline.txt (removed stale fbcon/splash settings)"
    echo "  fbcon will be mapped dynamically at boot by ${SERVICE_NAME}.service"
else
    echo "  Warning: ${CMDLINE} not found."
fi
STEP=$((STEP + 1))

# ── 5. Create systemd service + helper script ───────────────────────

echo "[$STEP/$TOTAL] Creating boot-time display setup service ..."

HELPER="/usr/local/bin/inland-tft35-setup"
cat > "$HELPER" <<'HEOF'
#!/bin/bash
# Find the fbtft/ili9486 framebuffer and configure fbcon + X11 to use it.
# Runs at boot via inland-tft35-display.service.
set -euo pipefail

TIMEOUT=30
ELAPSED=0
FB_DEV=""
FB_NUM=""

# Wait for the fbtft framebuffer to appear
while [ $ELAPSED -lt $TIMEOUT ]; do
    for fb in /sys/class/graphics/fb*; do
        [ -d "$fb" ] || continue
        fb_name=$(cat "$fb/name" 2>/dev/null || true)
        if echo "$fb_name" | grep -qi "ili9486"; then
            FB_NUM=$(basename "$fb" | sed 's/fb//')
            FB_DEV="/dev/fb${FB_NUM}"
            break 2
        fi
    done
    sleep 1
    ELAPSED=$((ELAPSED + 1))
done

if [ -z "$FB_DEV" ]; then
    echo "inland-tft35: fbtft framebuffer (ili9486) not found after ${TIMEOUT}s" >&2
    exit 1
fi

echo "inland-tft35: found framebuffer ${FB_DEV} (fb_name=${fb_name})" >&2

# Rebind fbcon to the fbtft framebuffer
for vtcon in /sys/class/vtconsole/vtcon*; do
    [ -d "$vtcon" ] || continue
    vtname=$(cat "$vtcon/name" 2>/dev/null || true)
    if echo "$vtname" | grep -qi "frame buffer"; then
        echo 0 > "$vtcon/bind" 2>/dev/null || true
        echo 1 > "$vtcon/bind" 2>/dev/null || true
        echo "inland-tft35: rebound fbcon to fb${FB_NUM}" >&2
    fi
done

# Update X11 fbdev config with the correct device
XORG_CONF="/etc/X11/xorg.conf.d/99-spi-display.conf"
if [ -f "$XORG_CONF" ]; then
    sed -i "s|Option.*\"fbdev\".*|    Option      \"fbdev\"  \"${FB_DEV}\"|" "$XORG_CONF"
    echo "inland-tft35: updated X11 fbdev path to ${FB_DEV}" >&2
fi

echo "$FB_DEV"
HEOF
chmod +x "$HELPER"
echo "  Created ${HELPER}"

# Create systemd service
SYSTEMD_SVC="/etc/systemd/system/${SERVICE_NAME}.service"
cat > "$SYSTEMD_SVC" <<SEOF
[Unit]
Description=Configure Inland TFT35 SPI display at boot
After=basic.target
Before=display-manager.service lightdm.service gdm.service

[Service]
Type=oneshot
ExecStart=${HELPER}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SEOF
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service" 2>/dev/null || true
echo "  Enabled ${SERVICE_NAME}.service"
STEP=$((STEP + 1))

# ── 6. Configure X11 display ────────────────────────────────────────

echo "[$STEP/$TOTAL] Installing display packages & configuring X11 ..."

# Ensure the fbdev X11 driver is installed (not always present by default)
if command -v apt-get >/dev/null 2>&1; then
    apt-get install -y -qq xserver-xorg-video-fbdev 2>/dev/null || \
        echo "  Warning: could not install xserver-xorg-video-fbdev"
fi

XORG_CONF_DIR="/etc/X11/xorg.conf.d"
XORG_CONF="$XORG_CONF_DIR/99-spi-display.conf"
mkdir -p "$XORG_CONF_DIR"
cat > "$XORG_CONF" <<'XEOF'
# Route X11 to the fbtft SPI framebuffer via the fbdev driver.
# The inland-tft35-display.service updates the fbdev path at boot.

Section "Device"
    Identifier  "InlandTFT35"
    Driver      "fbdev"
    Option      "fbdev"  "/dev/fb0"
EndSection

Section "Screen"
    Identifier  "SPI-Screen"
    Device      "InlandTFT35"
EndSection

Section "ServerLayout"
    Identifier  "Layout"
    Screen      "SPI-Screen"
EndSection
XEOF
echo "  Created ${XORG_CONF}"
STEP=$((STEP + 1))

# ── 7. Configure touchscreen input ──────────────────────────────────

if [ "$TOUCH" -eq 1 ]; then
    echo "[$STEP/$TOTAL] Configuring touchscreen input ..."

    # Ensure the evdev X11 input driver is installed (for CalibrationMatrix)
    if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y -qq xserver-xorg-input-evdev 2>/dev/null || \
            echo "  Warning: could not install xserver-xorg-input-evdev"
    fi

    # Calibration matrix based on rotation
    case "$ROTATE" in
        0)   CAL_MATRIX="1 0 0 0 1 0 0 0 1" ;;
        90)  CAL_MATRIX="0 1 0 -1 0 1 0 0 1" ;;
        180) CAL_MATRIX="-1 0 1 0 -1 1 0 0 1" ;;
        270) CAL_MATRIX="0 -1 1 1 0 0 0 0 1" ;;
    esac

    TOUCH_XORG="$XORG_CONF_DIR/99-touch-calibration.conf"
    cat > "$TOUCH_XORG" <<TEOF
# XPT2046/ADS7846 resistive touchscreen calibration
# Rotation: ${ROTATE}°

Section "InputClass"
    Identifier      "XPT2046 Touchscreen"
    MatchProduct    "ADS7846 Touchscreen"
    MatchDevicePath "/dev/input/event*"
    Driver          "evdev"

    # Calibration matrix for ${ROTATE}° rotation
    Option "CalibrationMatrix" "${CAL_MATRIX}"

    Option "InvertY"    "false"
    Option "InvertX"    "false"
    Option "SwapAxes"   "false"
EndSection
TEOF
    echo "  Created ${TOUCH_XORG}"

    # udev rule to tag the XPT2046 as a touchscreen for libinput
    TOUCH_UDEV="/etc/udev/rules.d/99-xpt2046.rules"
    cat > "$TOUCH_UDEV" <<'UEOF'
# Tag ADS7846/XPT2046 as a touchscreen so libinput handles it correctly
ACTION=="add|change", KERNEL=="event*", ATTRS{name}=="ADS7846 Touchscreen", \
    ENV{ID_INPUT_TOUCHSCREEN}="1"
UEOF
    echo "  Created ${TOUCH_UDEV}"
    STEP=$((STEP + 1))
fi

# ── Done ─────────────────────────────────────────────────────────────

echo ""
echo "Installation complete!  Reboot to activate."
echo ""
echo "  sudo reboot"
echo ""
echo "After reboot, verify with:"
echo "  lsmod | grep fb_ili9486"
echo "  ls /dev/fb*"
echo "  dmesg | grep ili9486"
echo "  cat /proc/bus/input/devices | grep -A5 ADS7846"
echo ""
echo "Run the test script:"
echo "  sudo ./scripts/test-display.sh"
echo ""
echo "If touch coordinates are off, calibrate:"
echo "  sudo apt-get install -y xinput-calibrator"
echo "  DISPLAY=:0 xinput_calibrator"
echo ""
echo "To uninstall:"
echo "  sudo ./uninstall.sh"
