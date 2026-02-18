#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# install.sh — Install Inland TFT35 / MPI3501 display + touch configuration
#
# Usage:  sudo ./install.sh [OPTIONS]
#
# Configures Raspberry Pi OS (Bookworm / Trixie) to use the built-in
# piscreen device-tree overlay and fb_ili9486 (fbtft) driver for the
# Inland TFT35" Touch Shield (MicroCenter) and compatible MPI3501 /
# Waveshare 3.5" (A) clone displays.
#
# No custom kernel module is compiled — the driver is already built
# into the stock kernel.
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

# Raspberry Pi OS Bookworm+ / Trixie uses /boot/firmware
if [ -d "/boot/firmware/overlays" ]; then
    OVERLAYS_DIR="/boot/firmware/overlays"
    CONFIG="/boot/firmware/config.txt"
    CMDLINE="/boot/firmware/cmdline.txt"
fi

STEP=1
TOTAL=10
[ "$TOUCH" -eq 0 ] && TOTAL=9

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

# ═════════════════════════════════════════════════════════════════════
# Step 1: Clean old artifacts from previous ili9481 driver
# ═════════════════════════════════════════════════════════════════════

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
for d in /usr/src/ili9481-*/; do
    [ -d "$d" ] && rm -rf "$d" && echo "  Removed $d"
done

# Remove old overlays
for f in ili9481.dtbo xpt2046.dtbo; do
    [ -f "$OVERLAYS_DIR/$f" ] && rm -f "$OVERLAYS_DIR/$f" && echo "  Removed $OVERLAYS_DIR/$f"
done

# Remove old systemd services
for svc in ili9481-display inland-tft35-display; do
    if [ -f "/etc/systemd/system/${svc}.service" ]; then
        systemctl disable "${svc}.service" 2>/dev/null || true
        rm -f "/etc/systemd/system/${svc}.service"
        echo "  Removed ${svc}.service"
    fi
done
systemctl daemon-reload 2>/dev/null || true

# Remove old helper scripts
rm -f /usr/local/bin/ili9481-find-card 2>/dev/null || true
rm -f /usr/local/bin/inland-tft35-setup 2>/dev/null || true

# Remove old X11/Wayland configs
rm -f /etc/X11/xorg.conf.d/99-ili9481.conf 2>/dev/null || true
rm -f /etc/X11/xorg.conf.d/99-spi-display.conf 2>/dev/null || true
rm -f /etc/X11/xorg.conf.d/99-touch-calibration.conf 2>/dev/null || true
rm -f /etc/X11/xorg.conf.d/99-xpt2046-touch.conf 2>/dev/null || true
rm -f /etc/environment.d/99-ili9481.conf 2>/dev/null || true
rm -f /etc/labwc/environment 2>/dev/null || true
rm -f /etc/udev/rules.d/99-xpt2046.rules 2>/dev/null || true

# Remove old config.txt entries
if [ -f "$CONFIG" ]; then
    sed -i '/^# ILI9481 SPI display driver/d' "$CONFIG"
    sed -i '/^dtoverlay=ili9481/d' "$CONFIG"
    sed -i '/^# XPT2046 resistive touchscreen/d' "$CONFIG"
    sed -i '/^dtoverlay=xpt2046/d' "$CONFIG"
    sed -i '/^# Enable DRM\/KMS (required for ILI9481 DRM driver)/d' "$CONFIG"
    sed -i '/^# Enable SPI bus (required for ILI9481 display)/d' "$CONFIG"
    sed -i '/^# Blacklist fbtft/d' "$CONFIG"
    # Also clean entries from previous runs of this script
    sed -i '/^# Inland TFT35 SPI display/d' "$CONFIG"
    sed -i '/^# Enable SPI bus (required for SPI display)/d' "$CONFIG"
    sed -i '/^# Disable firmware KMS setup (required for fbtft)/d' "$CONFIG"
    sed -i "/^dtoverlay=piscreen/d" "$CONFIG"
    sed -i "/^dtoverlay=waveshare35a/d" "$CONFIG"
fi

echo "  Old artifacts cleaned"
STEP=$((STEP + 1))

# ═════════════════════════════════════════════════════════════════════
# Step 2: Remove ALL fbtft/fb_ili9486 blacklists + update initramfs
# ═════════════════════════════════════════════════════════════════════

echo "[$STEP/$TOTAL] Removing fbtft blacklists ..."
BLACKLIST_CLEANED=0

# Remove our specific blacklist file
if [ -f /etc/modprobe.d/ili9481-blacklist.conf ]; then
    rm -f /etc/modprobe.d/ili9481-blacklist.conf
    echo "  Removed /etc/modprobe.d/ili9481-blacklist.conf"
    BLACKLIST_CLEANED=1
fi

# Scan ALL modprobe.d files for fbtft/fb_ili9486 blacklists
for conf in /etc/modprobe.d/*.conf; do
    [ -f "$conf" ] || continue
    if grep -qE '^blacklist\s+(fbtft|fb_ili9486|fb_ili9481)' "$conf" 2>/dev/null; then
        # Remove the offending lines rather than the whole file
        sed -i '/^blacklist\s\+fbtft/d' "$conf"
        sed -i '/^blacklist\s\+fb_ili9486/d' "$conf"
        sed -i '/^blacklist\s\+fb_ili9481/d' "$conf"
        echo "  Removed fbtft blacklist entries from $conf"
        BLACKLIST_CLEANED=1
        # If the file is now empty (only comments/blanks), remove it
        if ! grep -qE '^\s*[^#\s]' "$conf" 2>/dev/null; then
            rm -f "$conf"
            echo "  Removed empty $conf"
        fi
    fi
done

# CRITICAL: Update initramfs so the blacklist removal takes effect on boot.
# Without this, the initramfs still contains the cached blacklist and fbtft
# will remain blocked even though the file is gone from /etc/modprobe.d/.
if [ "$BLACKLIST_CLEANED" -eq 1 ]; then
    echo "  Updating initramfs (cached blacklists must be cleared) ..."
    if command -v update-initramfs >/dev/null 2>&1; then
        update-initramfs -u 2>&1 | tail -2
        echo "  initramfs updated"
    else
        echo "  Warning: update-initramfs not found — reboot may still use cached blacklist"
        echo "  Try: sudo apt-get install -y initramfs-tools && sudo update-initramfs -u"
    fi
else
    echo "  No fbtft blacklists found"
fi
STEP=$((STEP + 1))

# ═════════════════════════════════════════════════════════════════════
# Step 3: Pre-flight checks (overlay + kernel module)
# ═════════════════════════════════════════════════════════════════════

echo "[$STEP/$TOTAL] Verifying overlay and kernel module ..."

# Check overlay exists
DTBO_PATH="${OVERLAYS_DIR}/${OVERLAY}.dtbo"
if [ ! -f "$DTBO_PATH" ]; then
    echo "  Warning: ${DTBO_PATH} not found."
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
echo "  Overlay: ${DTBO_PATH} — OK"

# Check kernel module is available
MODULE_OK=0
if modinfo fb_ili9486 >/dev/null 2>&1; then
    echo "  Kernel module: fb_ili9486 — OK"
    MODULE_OK=1
elif modinfo fbtft >/dev/null 2>&1; then
    echo "  Kernel module: fbtft found (fb_ili9486 may be built-in)"
    MODULE_OK=1
fi
if [ "$MODULE_OK" -eq 0 ]; then
    echo "  Warning: Neither fb_ili9486 nor fbtft kernel modules found."
    echo "  Your kernel may not include fbtft support."
    echo "  Continuing anyway — the overlay will attempt to load the driver."
fi
STEP=$((STEP + 1))

# ═════════════════════════════════════════════════════════════════════
# Step 4: Configure config.txt
# ═════════════════════════════════════════════════════════════════════

echo "[$STEP/$TOTAL] Configuring ${CONFIG} ..."
if [ -f "$CONFIG" ]; then

    # ── 4a. Comment out vc4-kms-v3d / vc4-fkms-v3d everywhere ────────
    #   fbtft creates a legacy framebuffer; it cannot coexist as the
    #   primary display with KMS.  We comment out (not delete) so the
    #   uninstaller can restore the line.
    if grep -q '^dtoverlay=vc4-kms-v3d' "$CONFIG"; then
        sed -i 's/^dtoverlay=vc4-kms-v3d/#dtoverlay=vc4-kms-v3d/' "$CONFIG"
        echo "  Commented out dtoverlay=vc4-kms-v3d"
    fi
    if grep -q '^dtoverlay=vc4-fkms-v3d' "$CONFIG"; then
        sed -i 's/^dtoverlay=vc4-fkms-v3d/#dtoverlay=vc4-fkms-v3d/' "$CONFIG"
        echo "  Commented out dtoverlay=vc4-fkms-v3d"
    fi

    # ── 4b. Comment out display_auto_detect ──────────────────────────
    #   This auto-loads overlays for detected DSI/HDMI displays and
    #   can interfere with fbtft.
    if grep -q '^display_auto_detect=1' "$CONFIG"; then
        sed -i 's/^display_auto_detect=1/#display_auto_detect=1/' "$CONFIG"
        echo "  Commented out display_auto_detect=1"
    fi

    # ── 4c. Ensure SPI is enabled ────────────────────────────────────
    if ! grep -q '^dtparam=spi=on' "$CONFIG"; then
        # Insert before the first section header if one exists, otherwise append
        if grep -q '^\[' "$CONFIG"; then
            FIRST_SECTION=$(grep -n '^\[' "$CONFIG" | head -1 | cut -d: -f1)
            sed -i "${FIRST_SECTION}i\\
# Enable SPI bus (required for SPI display)\\
dtparam=spi=on\\
" "$CONFIG"
        else
            printf '\n# Enable SPI bus (required for SPI display)\ndtparam=spi=on\n' >> "$CONFIG"
        fi
        echo "  Added dtparam=spi=on"
    else
        echo "  dtparam=spi=on already present"
    fi

    # ── 4d. Ensure disable_fw_kms_setup=1 ────────────────────────────
    #   Prevents the firmware from creating a legacy framebuffer.
    #   Already set by default on Trixie; needed on Bookworm.
    if ! grep -q '^disable_fw_kms_setup=1' "$CONFIG"; then
        printf '\ndisable_fw_kms_setup=1\n' >> "$CONFIG"
        echo "  Added disable_fw_kms_setup=1"
    else
        echo "  disable_fw_kms_setup=1 already present"
    fi

    # ── 4e. Ensure [all] section at end of file ──────────────────────
    #   Trixie uses [cm4], [cm5], [all] sections.  Our overlay must go
    #   under [all] so it applies to every Pi model.
    if ! tail -30 "$CONFIG" | grep -q '^\[all\]'; then
        printf '\n[all]\n' >> "$CONFIG"
        echo "  Added [all] section"
    fi

    # ── 4f. Add piscreen overlay at end (under [all]) ────────────────
    OVERLAY_LINE="dtoverlay=${OVERLAY},speed=${SPI_SPEED},rotate=${ROTATE},fps=${FPS}"
    printf '\n# Inland TFT35 SPI display (fbtft / fb_ili9486)\n%s\n' "$OVERLAY_LINE" >> "$CONFIG"
    echo "  Added: ${OVERLAY_LINE}"

    # Clean up multiple consecutive blank lines
    sed -i '/^$/N;/^\n$/d' "$CONFIG"

    echo "  config.txt configured"
else
    echo "  Error: ${CONFIG} not found!"
    echo "  Cannot configure boot parameters."
    exit 1
fi
STEP=$((STEP + 1))

# ═════════════════════════════════════════════════════════════════════
# Step 5: Configure cmdline.txt
# ═════════════════════════════════════════════════════════════════════

echo "[$STEP/$TOTAL] Configuring ${CMDLINE} ..."
if [ -f "$CMDLINE" ]; then
    # Remove stale fbcon mapping
    sed -i 's/ fbcon=map:[^ ]*//g' "$CMDLINE"
    # Remove 'splash' — Plymouth only renders on HDMI/DSI, not SPI
    sed -i 's/ splash//g' "$CMDLINE"
    echo "  Cleaned cmdline.txt (removed stale fbcon/splash)"
else
    echo "  Warning: ${CMDLINE} not found."
fi
STEP=$((STEP + 1))

# ═════════════════════════════════════════════════════════════════════
# Step 6: Switch display backend from Wayland to X11
# ═════════════════════════════════════════════════════════════════════

echo "[$STEP/$TOTAL] Configuring display backend ..."

# fbtft creates a /dev/fbN device (legacy framebuffer), NOT a DRM device.
# Wayland compositors (labwc, wayfire, sway) require DRM/KMS and CANNOT
# drive a legacy framebuffer.  X11 with the fbdev driver CAN.
#
# Without this switch, labwc tries to start, finds no DRM device
# (because we disabled vc4-kms-v3d), and crashes.  Nothing renders
# on any display.  This is the #1 cause of "still white after install".

SWITCHED_TO_X11=0
if command -v raspi-config >/dev/null 2>&1; then
    # raspi-config nonint get_wayland returns 0 if Wayland is active
    WAYLAND_STATUS=$(raspi-config nonint get_wayland 2>/dev/null || echo "1")
    if [ "$WAYLAND_STATUS" = "0" ]; then
        echo "  Wayland is active — switching to X11 (required for fbtft) ..."
        raspi-config nonint do_wayland W1 2>/dev/null || {
            echo "  Warning: raspi-config failed to switch to X11."
            echo "  You MUST manually switch: sudo raspi-config → Advanced → Wayland → X11"
        }
        SWITCHED_TO_X11=1
        echo "  Switched display backend to X11"
    else
        echo "  Display backend is already X11 (or Wayland is not active)"
    fi
else
    echo "  raspi-config not found — cannot auto-detect display backend"
    echo "  If you are using Wayland (labwc/wayfire), you MUST switch to X11:"
    echo "    sudo raspi-config → Advanced Options → Wayland → X11"
    echo "  fbtft does not create DRM devices; Wayland compositors will crash."
fi
STEP=$((STEP + 1))

# ═════════════════════════════════════════════════════════════════════
# Step 7: Create systemd service + helper script
# ═════════════════════════════════════════════════════════════════════

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
fb_name=""

# Wait for the fbtft framebuffer to appear
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
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
    # Dump diagnostics
    echo "inland-tft35: available framebuffers:" >&2
    for fb in /sys/class/graphics/fb*; do
        [ -d "$fb" ] && echo "  $(basename "$fb"): $(cat "$fb/name" 2>/dev/null)" >&2
    done
    echo "inland-tft35: fbtft in lsmod:" >&2
    lsmod 2>/dev/null | grep -iE 'fbtft|ili9486' >&2 || echo "  (none)" >&2
    echo "inland-tft35: checking for blacklists:" >&2
    grep -r 'blacklist.*fbtft\|blacklist.*fb_ili9486' /etc/modprobe.d/ 2>/dev/null >&2 || echo "  (none)" >&2
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

# Update X11 fbdev config with the correct device path
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
DefaultDependencies=no
After=sysinit.target
Before=display-manager.service lightdm.service gdm.service

[Service]
Type=oneshot
ExecStart=${HELPER}
RemainAfterExit=yes
TimeoutStartSec=45

[Install]
WantedBy=sysinit.target
SEOF
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service" 2>/dev/null || true
echo "  Enabled ${SERVICE_NAME}.service"
STEP=$((STEP + 1))

# ═════════════════════════════════════════════════════════════════════
# Step 8: Install packages + configure X11
# ═════════════════════════════════════════════════════════════════════

echo "[$STEP/$TOTAL] Installing display packages & configuring X11 ..."

if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq 2>/dev/null || true
    apt-get install -y -qq xserver-xorg-video-fbdev 2>/dev/null || \
        echo "  Warning: could not install xserver-xorg-video-fbdev"
fi

XORG_CONF_DIR="/etc/X11/xorg.conf.d"
mkdir -p "$XORG_CONF_DIR"

XORG_CONF="$XORG_CONF_DIR/99-spi-display.conf"
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

# ═════════════════════════════════════════════════════════════════════
# Step 9: Configure touchscreen input (optional)
# ═════════════════════════════════════════════════════════════════════

if [ "$TOUCH" -eq 1 ]; then
    echo "[$STEP/$TOTAL] Configuring touchscreen input ..."

    if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y -qq xserver-xorg-input-evdev 2>/dev/null || \
            echo "  Warning: could not install xserver-xorg-input-evdev"
    fi

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

    TOUCH_UDEV="/etc/udev/rules.d/99-xpt2046.rules"
    cat > "$TOUCH_UDEV" <<'UEOF'
# Tag ADS7846/XPT2046 as a touchscreen so libinput handles it correctly
ACTION=="add|change", KERNEL=="event*", ATTRS{name}=="ADS7846 Touchscreen", \
    ENV{ID_INPUT_TOUCHSCREEN}="1"
UEOF
    echo "  Created ${TOUCH_UDEV}"
    STEP=$((STEP + 1))
fi

# ═════════════════════════════════════════════════════════════════════
# Step 10: Post-install summary
# ═════════════════════════════════════════════════════════════════════

echo ""
echo "[$STEP/$TOTAL] Installation complete!"
echo ""
echo "┌─────────────────────────────────────────────────────────────┐"
echo "│  REBOOT NOW:  sudo reboot                                  │"
echo "└─────────────────────────────────────────────────────────────┘"
echo ""
echo "What was configured:"
echo "  • vc4-kms-v3d commented out (fbtft needs legacy framebuffer)"
echo "  • display_auto_detect disabled (prevents overlay conflicts)"
echo "  • Overlay: dtoverlay=${OVERLAY},speed=${SPI_SPEED},rotate=${ROTATE},fps=${FPS}"
if [ "$BLACKLIST_CLEANED" -eq 1 ]; then
    echo "  • fbtft blacklists REMOVED + initramfs rebuilt"
fi
if [ "$SWITCHED_TO_X11" -eq 1 ]; then
    echo "  • Display backend switched from Wayland to X11"
fi
echo "  • systemd service: ${SERVICE_NAME}.service"
echo "  • X11 config: /etc/X11/xorg.conf.d/99-spi-display.conf"
if [ "$TOUCH" -eq 1 ]; then
    echo "  • Touch config: /etc/X11/xorg.conf.d/99-touch-calibration.conf"
fi
echo ""
echo "⚠  HDMI output is DISABLED while the SPI display is active."
echo "   To restore HDMI, run: sudo ./uninstall.sh"
echo ""
echo "After reboot, verify with:"
echo "  lsmod | grep fb_ili9486"
echo "  ls /dev/fb*"
echo "  dmesg | grep -i 'fbtft\|ili9486'"
echo "  sudo ./scripts/test-display.sh"
echo ""
echo "If the screen is still white after reboot, check:"
echo "  sudo journalctl -u ${SERVICE_NAME}.service"
echo "  dmesg | grep -i 'fbtft\|ili9486\|spi'"
echo "  grep -r blacklist /etc/modprobe.d/ | grep -i fbtft"
