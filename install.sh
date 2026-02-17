#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# install.sh — Install ILI9481 DRM display driver
#
# Usage:  sudo ./install.sh
#
# This script installs the ILI9481 kernel module via DKMS so it is
# compiled against your running kernel (correct symbol versions) and
# automatically rebuilt on kernel upgrades.  Pre-compiled device-tree
# overlays are installed directly.  The script also blacklists the
# conflicting fbtft staging driver, enables SPI, and configures the
# display overlay to load on boot.

set -euo pipefail

# ── Checks ───────────────────────────────────────────────────────────

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root (sudo ./install.sh)"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DTBO="$SCRIPT_DIR/ili9481.dtbo"
TOUCH_DTBO="$SCRIPT_DIR/xpt2046.dtbo"
DTS_SRC="$SCRIPT_DIR/ili9481-overlay.dts"
TOUCH_DTS_SRC="$SCRIPT_DIR/xpt2046-overlay.dts"

# Source files for DKMS
SRC_FILES=(ili9481.c Makefile Kconfig dkms.conf)
for f in "$SCRIPT_DIR/ili9481.c" "$SCRIPT_DIR/dkms.conf"; do
    if [ ! -f "$f" ]; then
        echo "Error: Required file not found: $f"
        exit 1
    fi
done

# At least one of .dtbo or .dts must exist for the display overlay
if [ ! -f "$DTBO" ] && [ ! -f "$DTS_SRC" ]; then
    echo "Error: Neither ili9481.dtbo nor ili9481-overlay.dts found"
    exit 1
fi

# ── Parse dkms.conf ──────────────────────────────────────────────────

DKMS_NAME="ili9481"
DKMS_VERSION=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$SCRIPT_DIR/dkms.conf")
DKMS_SRC="/usr/src/${DKMS_NAME}-${DKMS_VERSION}"

# ── Determine paths ─────────────────────────────────────────────────

KVER="$(uname -r)"
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
TOTAL=9

echo "ILI9481 Display Driver Installer"
echo "================================"
echo ""
echo "Kernel:    $KVER"
echo "DKMS:      ${DKMS_NAME}/${DKMS_VERSION}"
echo "Overlay:   $OVERLAYS_DIR/ili9481.dtbo"
echo "Config:    $CONFIG"
echo ""

# ── 1. Blacklist conflicting fbtft staging driver ────────────────────

echo "[$STEP/$TOTAL] Blacklisting conflicting fbtft staging driver ..."
BLACKLIST_CONF="/etc/modprobe.d/ili9481-blacklist.conf"
cat > "$BLACKLIST_CONF" <<'EOF'
# Prevent the old fbtft staging driver from grabbing the ILI9481 device.
blacklist fb_ili9481
blacklist fbtft
EOF
echo "  Created $BLACKLIST_CONF"
STEP=$((STEP + 1))

# ── 2. Install dependencies ─────────────────────────────────────────

echo "[$STEP/$TOTAL] Installing DKMS, kernel headers, and device-tree compiler ..."
apt-get update -qq
apt-get install -y -qq dkms device-tree-compiler raspberrypi-kernel-headers 2>/dev/null \
  || apt-get install -y -qq dkms device-tree-compiler "linux-headers-${KVER}"
echo "  Done"
STEP=$((STEP + 1))

# ── Compile device-tree overlays if needed ───────────────────────────

echo "[$STEP/$TOTAL] Compiling device-tree overlays ..."
if [ -f "$DTS_SRC" ]; then
    # Suppress dtc warnings (phandle refs in overlays) but show errors
    if ! dtc -@ -Hepapr -I dts -O dtb -o "$DTBO" "$DTS_SRC" 2>/dev/null; then
        echo "  Error: dtc failed to compile ili9481-overlay.dts"
        echo "  Trying without -Hepapr..."
        dtc -@ -I dts -O dtb -o "$DTBO" "$DTS_SRC" 2>/dev/null || {
            echo "  Error: device-tree compilation failed. Check $DTS_SRC"
            exit 1
        }
    fi
    if [ ! -f "$DTBO" ]; then
        echo "  Error: ili9481.dtbo was not created"
        exit 1
    fi
    echo "  Compiled ili9481-overlay.dts → ili9481.dtbo"
else
    if [ ! -f "$DTBO" ]; then
        echo "  Error: No .dts source or pre-compiled .dtbo found"
        exit 1
    fi
    echo "  Using pre-compiled ili9481.dtbo"
fi
if [ -f "$TOUCH_DTS_SRC" ]; then
    dtc -@ -Hepapr -I dts -O dtb -o "$TOUCH_DTBO" "$TOUCH_DTS_SRC" 2>/dev/null \
      || dtc -@ -I dts -O dtb -o "$TOUCH_DTBO" "$TOUCH_DTS_SRC" 2>/dev/null \
      || echo "  Warning: could not compile xpt2046-overlay.dts (touch may not work)"
    [ -f "$TOUCH_DTBO" ] && echo "  Compiled xpt2046-overlay.dts → xpt2046.dtbo"
else
    echo "  Using pre-compiled xpt2046.dtbo (or not present)"
fi
STEP=$((STEP + 1))

# ── 3. Build & install via DKMS ──────────────────────────────────────

echo "[$STEP/$TOTAL] Building kernel module via DKMS ..."
# Remove any previous registration
if dkms status "${DKMS_NAME}/${DKMS_VERSION}" 2>/dev/null | grep -q .; then
    dkms remove "${DKMS_NAME}/${DKMS_VERSION}" --all 2>/dev/null || true
fi
# Copy source to DKMS tree
mkdir -p "$DKMS_SRC"
for f in "${SRC_FILES[@]}"; do
    [ -f "$SCRIPT_DIR/$f" ] && cp -f "$SCRIPT_DIR/$f" "$DKMS_SRC/"
done
# Build and install in one step
dkms install "${DKMS_NAME}/${DKMS_VERSION}" -k "$KVER"
echo "  Module built and installed for kernel $KVER"
STEP=$((STEP + 1))

# ── 4. Install device-tree overlays ─────────────────────────────────

echo "[$STEP/$TOTAL] Installing device-tree overlays ..."
mkdir -p "$OVERLAYS_DIR"
cp -f "$DTBO" "$OVERLAYS_DIR/ili9481.dtbo"
if [ -f "$TOUCH_DTBO" ]; then
    cp -f "$TOUCH_DTBO" "$OVERLAYS_DIR/xpt2046.dtbo"
    echo "  Installed ili9481.dtbo and xpt2046.dtbo"
else
    echo "  Installed ili9481.dtbo (xpt2046.dtbo not found — touch skipped)"
fi
STEP=$((STEP + 1))

# ── 5. Configure config.txt ─────────────────────────────────────────

echo "[$STEP/$TOTAL] Configuring $CONFIG ..."
if [ -f "$CONFIG" ]; then
    changed=0

    # SPI
    if ! grep -q "^dtparam=spi=on" "$CONFIG"; then
        printf '\n# Enable SPI bus (required for ILI9481 display)\ndtparam=spi=on\n' >> "$CONFIG"
        echo "  Added dtparam=spi=on"
        changed=1
    fi

    # DRM/KMS
    if ! grep -q "^dtoverlay=vc4-kms-v3d" "$CONFIG" && \
       ! grep -q "^dtoverlay=vc4-fkms-v3d" "$CONFIG"; then
        printf '\n# Enable DRM/KMS (required for ILI9481 DRM driver)\ndtoverlay=vc4-kms-v3d\n' >> "$CONFIG"
        echo "  Added dtoverlay=vc4-kms-v3d"
        changed=1
    fi

    # ILI9481 overlay
    if ! grep -q "^dtoverlay=ili9481" "$CONFIG"; then
        printf '\n# ILI9481 SPI display driver\ndtoverlay=ili9481\n' >> "$CONFIG"
        echo "  Added dtoverlay=ili9481"
        changed=1
    fi

    # XPT2046 touch overlay
    if [ -f "$TOUCH_DTBO" ] && ! grep -q "^dtoverlay=xpt2046" "$CONFIG"; then
        printf '# XPT2046 resistive touchscreen\ndtoverlay=xpt2046\n' >> "$CONFIG"
        echo "  Added dtoverlay=xpt2046"
        changed=1
    fi

    [ "$changed" -eq 0 ] && echo "  Already configured — skipping."
else
    echo "  Warning: $CONFIG not found — configure manually."
fi
STEP=$((STEP + 1))

# ── 6. Configure fbcon ───────────────────────────────────────────────

echo "[$STEP/$TOTAL] Configuring framebuffer console ..."
if [ -f "$CMDLINE" ]; then
    # Remove any old fbcon=map: setting first
    sed -i 's/ fbcon=map:[0-9]*//g' "$CMDLINE"
    # Map console to the ILI9481 framebuffer.
    # The ili9481 DRM driver claims fb0, so map console to fb0.
    sed -i 's/$/ fbcon=map:0/' "$CMDLINE"
    echo "  Set fbcon=map:0 in $CMDLINE"
else
    echo "  Warning: $CMDLINE not found — add 'fbcon=map:0' manually."
fi
STEP=$((STEP + 1))

# ── 7. Configure X11 to use ILI9481 as primary display ──────────────

echo "[$STEP/$TOTAL] Configuring display output ..."
XORG_CONF_DIR="/etc/X11/xorg.conf.d"
XORG_CONF="$XORG_CONF_DIR/99-ili9481.conf"
mkdir -p "$XORG_CONF_DIR"
cat > "$XORG_CONF" <<'XEOF'
# Route X11 display output to the ILI9481 SPI display.
# The DRM driver creates /dev/dri/cardN — modesetting picks it up by name.

Section "Device"
    Identifier  "ILI9481"
    Driver      "modesetting"
    Option      "kmsdev" ""
    # The kmsdev path is filled at boot by the udev helper below.
    # If only the SPI display is wanted, you can hardcode e.g. /dev/dri/card1
EndSection

# Prefer the ILI9481 output over HDMI
Section "Screen"
    Identifier  "SPI-Screen"
    Device      "ILI9481"
EndSection

Section "ServerLayout"
    Identifier  "Layout"
    Screen      "SPI-Screen"
EndSection
XEOF
echo "  Created $XORG_CONF"

# Also install a helper script that finds the correct DRM card at boot
HELPER="/usr/local/bin/ili9481-find-card"
cat > "$HELPER" <<'HEOF'
#!/bin/bash
# Find the /dev/dri/cardN belonging to the ili9481 driver.
# Wait up to 30 seconds for the module to load (it loads via DT overlay
# and DKMS, which can take 10-15s on a Pi 3).
TIMEOUT=30
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    for card in /sys/class/drm/card*/device/driver/module; do
        [ -e "$card" ] || continue
        mod=$(basename "$(readlink -f "$card")" 2>/dev/null)
        if [ "$mod" = "ili9481" ]; then
            CARD="/dev/dri/$(basename "$(dirname "$(dirname "$(dirname "$card")")")")"
            # Update the X11 config with the correct card path
            if [ -f /etc/X11/xorg.conf.d/99-ili9481.conf ]; then
                sed -i "s|\"kmsdev\".*|\"kmsdev\" \"$CARD\"|" /etc/X11/xorg.conf.d/99-ili9481.conf
            fi
            echo "$CARD"
            exit 0
        fi
    done
    sleep 1
    ELAPSED=$((ELAPSED + 1))
done
echo "ili9481 DRM card not found after ${TIMEOUT}s" >&2
exit 1
HEOF
chmod +x "$HELPER"
echo "  Created $HELPER"

# Run the helper at boot before the display manager starts
SYSTEMD_SVC="/etc/systemd/system/ili9481-display.service"
cat > "$SYSTEMD_SVC" <<SEOF
[Unit]
Description=Configure ILI9481 SPI display as primary
After=basic.target
Before=display-manager.service lightdm.service gdm.service

[Service]
Type=oneshot
ExecStart=$HELPER
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SEOF
systemctl daemon-reload
systemctl enable ili9481-display.service 2>/dev/null || true
echo "  Enabled ili9481-display.service"
STEP=$((STEP + 1))

# ── 8. Configure touchscreen input ──────────────────────────────────

echo "[$STEP/$TOTAL] Configuring touchscreen input ..."

# libinput / evdev config for XPT2046
TOUCH_XORG="/etc/X11/xorg.conf.d/99-xpt2046-touch.conf"
cat > "$TOUCH_XORG" <<'TEOF'
# XPT2046 resistive touchscreen input configuration
# Adjust CalibrationMatrix if touch coordinates are misaligned.

Section "InputClass"
    Identifier      "XPT2046 Touchscreen"
    MatchProduct    "ADS7846 Touchscreen"
    MatchDevicePath "/dev/input/event*"
    Driver          "evdev"

    # Identity matrix (no transformation) — adjust after calibration:
    #   For 0°   rotation: 1 0 0 0 1 0 0 0 1
    #   For 90°  rotation: 0 1 0 -1 0 1 0 0 1
    #   For 180° rotation: -1 0 1 0 -1 1 0 0 1
    #   For 270° rotation: 0 -1 1 1 0 0 0 0 1
    Option "CalibrationMatrix" "1 0 0 0 1 0 0 0 1"

    Option "InvertY"    "false"
    Option "InvertX"    "false"
    Option "SwapAxes"   "false"
EndSection
TEOF
echo "  Created $TOUCH_XORG"

# udev rule to tag the XPT2046 as a touchscreen for libinput
TOUCH_UDEV="/etc/udev/rules.d/99-xpt2046.rules"
cat > "$TOUCH_UDEV" <<'UEOF'
# Tag ADS7846/XPT2046 as a touchscreen so libinput handles it correctly
ACTION=="add|change", KERNEL=="event*", ATTRS{name}=="ADS7846 Touchscreen", \
    ENV{ID_INPUT_TOUCHSCREEN}="1"
UEOF
echo "  Created $TOUCH_UDEV"
STEP=$((STEP + 1))

# ── Done ─────────────────────────────────────────────────────────────

echo ""
echo "Installation complete!  Reboot to activate."
echo ""
echo "  sudo reboot"
echo ""
echo "After reboot, verify with:"
echo "  dmesg | grep ili9481"
echo "  cat /proc/bus/input/devices | grep -A5 -i touch"
echo "  ls -l /dev/dri/card*"
echo ""
echo "If the display works but touch coordinates are off, calibrate:"
echo "  sudo apt-get install -y xinput-calibrator"
echo "  DISPLAY=:0 xinput_calibrator"
echo ""
echo "To uninstall:"
echo "  sudo dkms remove ${DKMS_NAME}/${DKMS_VERSION} --all"
echo "  sudo rm -rf $DKMS_SRC"
echo "  sudo rm -f $OVERLAYS_DIR/ili9481.dtbo $OVERLAYS_DIR/xpt2046.dtbo"
echo "  sudo rm -f $BLACKLIST_CONF"
echo "  sudo rm -f $XORG_CONF $TOUCH_XORG $TOUCH_UDEV"
echo "  sudo rm -f $HELPER $SYSTEMD_SVC"
echo "  sudo systemctl disable ili9481-display.service 2>/dev/null"
echo "  # Remove dtoverlay=ili9481, dtoverlay=xpt2046, dtparam=spi=on from $CONFIG"
echo "  # Remove fbcon=map:0 from $CMDLINE"
