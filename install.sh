#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# install.sh — Inland TFT35 ILI9481 (16-bit parallel GPIO) installer
#
# Builds a self-contained out-of-tree kernel module (ili9481-gpio) from the
# local driver/ directory, generates a device-tree overlay, configures boot
# parameters, and optionally sets up ADS7846/XPT2046 touch support.
#
# Targets: Raspberry Pi OS Trixie (Debian 13, kernel 6.12+, 64-bit)
#
# Usage:  sudo ./install.sh [OPTIONS]

set -euo pipefail

# =====================================================================
# Defaults
# =====================================================================

ROTATE=270
FPS=30
TOUCH=1
TOUCH_IRQ=17
TOUCH_XOHMS=150
TOUCH_PMAX=255
FB_MAP=10

# =====================================================================
# Argument parsing
# =====================================================================

for arg in "$@"; do
    case "$arg" in
        --rotate=*)    ROTATE="${arg#*=}" ;;
        --fps=*)       FPS="${arg#*=}" ;;
        --no-touch)    TOUCH=0 ;;
        --touch-irq=*) TOUCH_IRQ="${arg#*=}" ;;
        --help|-h)
            echo "Usage: sudo ./install.sh [OPTIONS]"
            echo "  --rotate=DEG      Display rotation: 0, 90, 180, 270 (default: 270)"
            echo "  --fps=N           Framebuffer refresh rate (default: 30)"
            echo "  --no-touch        Skip XPT2046/ADS7846 touch setup"
            echo "  --touch-irq=GPIO  Touch IRQ GPIO (default: 17)"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            exit 1
            ;;
    esac
done

# =====================================================================
# Sanity checks
# =====================================================================

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: sudo ./install.sh"
    exit 1
fi

case "$ROTATE" in
    0|90|180|270) ;;
    *)
        echo "Invalid --rotate value: $ROTATE (must be 0, 90, 180, or 270)"
        exit 1
        ;;
esac

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
    echo "Could not find boot config files."
    echo "Expected: $CONFIG and $CMDLINE"
    exit 1
fi

# =====================================================================
# Helpers
# =====================================================================

matrix_for_rotation() {
    case "$1" in
        0)   echo "1 0 0 0 1 0 0 0 1" ;;
        90)  echo "0 1 0 -1 0 1 0 0 1" ;;
        180) echo "-1 0 1 0 -1 1 0 0 1" ;;
        270) echo "0 -1 1 1 0 0 0 0 1" ;;
    esac
}

ensure_line() {
    local file="$1" line="$2"
    grep -qxF "$line" "$file" || echo "$line" >> "$file"
}

remove_lines() {
    local file="$1"; shift
    for pattern in "$@"; do
        sed -i "$pattern" "$file"
    done
}

# =====================================================================
# Banner
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DRIVER_DIR="${SCRIPT_DIR}/driver"

echo "Inland TFT35 ILI9481 installer (self-contained driver)"
echo "Config:   $CONFIG"
echo "Cmdline:  $CMDLINE"
echo "Rotation: $ROTATE"
echo "FPS:      $FPS"
echo "Touch:    $([ "$TOUCH" -eq 1 ] && echo yes || echo no)"
echo

KERNEL_RELEASE="$(uname -r)"
KERNEL_BUILD_DIR="/lib/modules/${KERNEL_RELEASE}/build"

# =====================================================================
# [1/9] Install required packages
# =====================================================================

echo "[1/9] Installing required packages"
apt-get update
apt-get install -y \
    build-essential \
    flex \
    bison \
    bc \
    libssl-dev \
    device-tree-compiler \
    fbset \
    xserver-xorg-video-fbdev \
    xserver-xorg-input-evdev \
    xinput

if [ ! -f "${KERNEL_BUILD_DIR}/Makefile" ]; then
    echo "Kernel headers for ${KERNEL_RELEASE} not found. Attempting install..."
    apt-get install -y "linux-headers-${KERNEL_RELEASE}"
fi

if [ ! -f "${KERNEL_BUILD_DIR}/Makefile" ]; then
    echo "Error: kernel headers still missing for ${KERNEL_RELEASE}."
    echo "Install them manually, then re-run this script."
    echo "  sudo apt install linux-headers-${KERNEL_RELEASE}"
    exit 1
fi

# =====================================================================
# [2/9] Build and install ili9481-gpio kernel module
# =====================================================================

echo "[2/9] Building and installing ili9481-gpio driver"

if [ ! -f "${DRIVER_DIR}/ili9481-gpio.c" ]; then
    echo "Error: driver source not found at ${DRIVER_DIR}/ili9481-gpio.c"
    exit 1
fi

make -C "${KERNEL_BUILD_DIR}" M="${DRIVER_DIR}" clean   2>/dev/null || true
make -C "${KERNEL_BUILD_DIR}" M="${DRIVER_DIR}" modules
make -C "${KERNEL_BUILD_DIR}" M="${DRIVER_DIR}" modules_install

# =====================================================================
# [3/9] Generate and compile device-tree overlay
# =====================================================================

echo "[3/9] Writing and compiling overlay"

cat > "${OVERLAYS_DIR}/inland-ili9481-overlay.dts" <<EOF
/dts-v1/;
/plugin/;

/ {
    compatible = "brcm,bcm2835";

    fragment@0 {
        target-path = "/";
        __overlay__ {
            inland_tft35: ili9481@0 {
                compatible = "inland,ili9481-gpio";
                status     = "okay";

                rotate = <${ROTATE}>;
                fps    = <${FPS}>;

                rst-gpios = <&gpio 27 1>;
                dc-gpios  = <&gpio 22 0>;
                wr-gpios  = <&gpio 17 1>;

                data-gpios = <
                    &gpio  7 0
                    &gpio  8 0
                    &gpio 25 0
                    &gpio 24 0
                    &gpio 23 0
                    &gpio 18 0
                    &gpio 15 0
                    &gpio 14 0

                    &gpio 12 0
                    &gpio 16 0
                    &gpio 20 0
                    &gpio 21 0
                    &gpio  5 0
                    &gpio  6 0
                    &gpio 13 0
                    &gpio 19 0
                >;
            };
        };
    };
};
EOF

dtc -@ -I dts -O dtb \
    -o "${OVERLAYS_DIR}/inland-ili9481-overlay.dtbo" \
    "${OVERLAYS_DIR}/inland-ili9481-overlay.dts"

# =====================================================================
# [4/9] Update module dependencies and autoload
# =====================================================================

echo "[4/9] Updating module dependencies and load hints"
depmod -a

cat > /etc/modules-load.d/inland-tft35.conf <<'EOF'
ili9481-gpio
EOF

if [ "$TOUCH" -eq 1 ]; then
    ensure_line /etc/modules-load.d/inland-tft35.conf "ads7846"
fi

# =====================================================================
# [5/9] Clean stale config entries
# =====================================================================

echo "[5/9] Cleaning old config entries"
remove_lines "$CONFIG" \
    '/^# Inland TFT35 SPI display/d' \
    '/^# Inland TFT35 ILI9481 display/d' \
    '/^# BEGIN inland-tft35$/,/^# END inland-tft35$/d' \
    '/^dtoverlay=piscreen/d' \
    '/^dtoverlay=waveshare35a/d' \
    '/^dtoverlay=ili9481/d' \
    '/^dtoverlay=inland-ili9481-overlay/d' \
    '/^dtoverlay=ads7846,/d' \
    '/^dtoverlay=xpt2046,/d'

# =====================================================================
# [6/9] Configure boot display and touch
# =====================================================================

echo "[6/9] Configuring boot display and touch"

sed -i 's/^dtoverlay=vc4-kms-v3d/#dtoverlay=vc4-kms-v3d/'     "$CONFIG"
sed -i 's/^dtoverlay=vc4-fkms-v3d/#dtoverlay=vc4-fkms-v3d/'   "$CONFIG"
sed -i 's/^display_auto_detect=1/#display_auto_detect=1/'       "$CONFIG"

if ! grep -q '^\[all\]$' "$CONFIG"; then
    printf '\n[all]\n' >> "$CONFIG"
fi

cat >> "$CONFIG" <<'EOF'

# BEGIN inland-tft35
disable_fw_kms_setup=1
dtoverlay=inland-ili9481-overlay
EOF

# SPI uses GPIO 7 (CE1) and GPIO 8 (CE0) which conflict with DB0/DB1
# on the parallel data bus.  Only enable SPI when touch is requested;
# even then the kernel may report pin-mux conflicts on some boards.
if [ "$TOUCH" -eq 1 ]; then
    sed -i '/^# BEGIN inland-tft35$/a dtparam=spi=on' "$CONFIG"
fi

if [ "$TOUCH" -eq 1 ]; then
    echo "dtoverlay=ads7846,cs=1,speed=2000000,penirq=${TOUCH_IRQ},penirq_pull=2,xohms=${TOUCH_XOHMS},pmax=${TOUCH_PMAX}" >> "$CONFIG"
fi

cat >> "$CONFIG" <<'EOF'
# END inland-tft35
EOF

# =====================================================================
# [7/9] Configure fbcon mapping
# =====================================================================

echo "[7/9] Configuring fbcon mapping"

sed -i 's/ fbcon=map:[^ ]*//g'  "$CMDLINE"
sed -i 's/  */ /g'              "$CMDLINE"
sed -i 's/[[:space:]]*$//'      "$CMDLINE"
if ! grep -q 'fbcon=map:' "$CMDLINE"; then
    sed -i "1s/$/ fbcon=map:${FB_MAP}/" "$CMDLINE"
fi

# =====================================================================
# [8/9] X11 framebuffer and touch configuration
# =====================================================================

echo "[8/9] Installing X11 framebuffer and touch configuration"

mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/99-inland-fbdev.conf <<'EOF'
Section "Device"
    Identifier "InlandILI9481"
    Driver "fbdev"
    Option "fbdev" "/dev/fb0"
EndSection
EOF

TOUCH_MATRIX="$(matrix_for_rotation "$ROTATE")"
if [ "$TOUCH" -eq 1 ]; then
    cat > /etc/X11/xorg.conf.d/99-inland-touch.conf <<EOF
Section "InputClass"
    Identifier "InlandTouch"
    MatchProduct "ADS7846 Touchscreen"
    Driver "evdev"
    Option "CalibrationMatrix" "${TOUCH_MATRIX}"
    Option "EmulateThirdButton" "true"
EndSection
EOF
else
    rm -f /etc/X11/xorg.conf.d/99-inland-touch.conf
fi

# =====================================================================
# [9/9] Boot-time framebuffer mapping service
# =====================================================================

echo "[9/9] Enabling boot mapping service and selecting X11"

cat > /usr/local/bin/inland-tft35-boot <<'BOOTSCRIPT'
#!/bin/bash
set -euo pipefail

fb_number=""
for fb_dir in /sys/class/graphics/fb*; do
    [ -d "$fb_dir" ] || continue
    name_file="${fb_dir}/name"
    [ -f "$name_file" ] || continue
    if grep -qi 'ili9481' "$name_file"; then
        fb_number="$(basename "$fb_dir" | sed 's/fb//')"
        break
    fi
done

if [ -z "$fb_number" ]; then
    exit 0
fi

if command -v con2fbmap >/dev/null 2>&1; then
    for vt in 1 2 3 4 5 6; do
        con2fbmap "$vt" "$fb_number" >/dev/null 2>&1 || true
    done
fi

if [ -f /etc/X11/xorg.conf.d/99-inland-fbdev.conf ]; then
    sed -i "s#Option \"fbdev\" \"/dev/fb[0-9]*\"#Option \"fbdev\" \"/dev/fb${fb_number}\"#" \
        /etc/X11/xorg.conf.d/99-inland-fbdev.conf
fi
BOOTSCRIPT
chmod 755 /usr/local/bin/inland-tft35-boot

cat > /etc/systemd/system/inland-tft35-boot.service <<'EOF'
[Unit]
Description=Inland TFT35 framebuffer mapper
After=systemd-modules-load.service
Before=display-manager.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/inland-tft35-boot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable inland-tft35-boot.service

if command -v raspi-config >/dev/null 2>&1; then
    WAYLAND_STATE="$(raspi-config nonint get_wayland 2>/dev/null || echo unknown)"
    if [ "$WAYLAND_STATE" = "0" ]; then
        raspi-config nonint do_wayland W1 || true
    fi
fi

# =====================================================================
# Done
# =====================================================================

echo
echo "Install complete."
echo "Reboot now: sudo reboot"
