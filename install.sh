#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only

set -euo pipefail

ROTATE=270
FPS=30
TOUCH=1
TOUCH_IRQ=17
TOUCH_XOHMS=150
TOUCH_PMAX=255
FB_MAP=10
FBTFT_DIR="/usr/local/src/inland-fbtft"

for arg in "$@"; do
    case "$arg" in
        --rotate=*)
            ROTATE="${arg#*=}"
            ;;
        --fps=*)
            FPS="${arg#*=}"
            ;;
        --no-touch)
            TOUCH=0
            ;;
        --touch-irq=*)
            TOUCH_IRQ="${arg#*=}"
            ;;
        --help|-h)
            echo "Usage: sudo ./install.sh [OPTIONS]"
            echo "  --rotate=DEG      Display rotation: 0, 90, 180, 270 (default: 270)"
            echo "  --fps=N           Frame rate hint for overlay (default: 30)"
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

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: sudo ./install.sh"
    exit 1
fi

case "$ROTATE" in
    0|90|180|270)
        ;;
    *)
        echo "Invalid --rotate value: $ROTATE"
        exit 1
        ;;
esac

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

matrix_for_rotation() {
    case "$1" in
        0) echo "1 0 0 0 1 0 0 0 1" ;;
        90) echo "0 1 0 -1 0 1 0 0 1" ;;
        180) echo "-1 0 1 0 -1 1 0 0 1" ;;
        270) echo "0 -1 1 1 0 0 0 0 1" ;;
    esac
}

ensure_line() {
    local file="$1"
    local line="$2"
    grep -qxF "$line" "$file" || echo "$line" >> "$file"
}

remove_lines() {
    local file="$1"
    shift
    for pattern in "$@"; do
        sed -i "$pattern" "$file"
    done
}

echo "Inland TFT35 ILI9481 installer"
echo "Config: $CONFIG"
echo "Cmdline: $CMDLINE"
echo "Rotation: $ROTATE"
echo "FPS: $FPS"
echo "Touch: $([ "$TOUCH" -eq 1 ] && echo yes || echo no)"
echo

echo "[1/9] Installing required packages"
apt-get update
apt-get install -y \
    raspberrypi-kernel-headers \
    git \
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

echo "[2/9] Building and installing out-of-tree fbtft"
if [ -d "$FBTFT_DIR/.git" ]; then
    git -C "$FBTFT_DIR" pull --ff-only
else
    rm -rf "$FBTFT_DIR"
    git clone https://github.com/notro/fbtft.git "$FBTFT_DIR"
fi
make -C "/lib/modules/$(uname -r)/build" M="$FBTFT_DIR" modules
make -C "/lib/modules/$(uname -r)/build" M="$FBTFT_DIR" modules_install

echo "[3/9] Writing and compiling overlay"
cat > "${OVERLAYS_DIR}/inland-ili9481-overlay.dts" <<EOF
/dts-v1/;
/plugin/;

/ {
    compatible = "brcm,bcm2835";

    fragment@0 {
        target-path = "/";
        __overlay__ {
            inland_ili9481: inland_ili9481@0 {
                compatible = "ilitek,ili9481";
                reg = <0>;
                buswidth = <16>;
                rotate = <${ROTATE}>;
                fps = <${FPS}>;

                reset-gpios = <&gpio 23 0>;
                dc-gpios    = <&gpio 22 0>;

                gpios = <
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
                    &gpio 5  0
                    &gpio 6  0
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

echo "[4/9] Updating module dependencies and load hints"
depmod -a
cat > /etc/modules-load.d/inland-tft35.conf <<'EOF'
fbtft
fbtft_device
fb_ili9481
EOF
if [ "$TOUCH" -eq 1 ]; then
    ensure_line /etc/modules-load.d/inland-tft35.conf "ads7846"
fi

echo "[5/9] Cleaning old config entries"
remove_lines "$CONFIG" \
    '/^# Inland TFT35 SPI display/d' \
    '/^# Inland TFT35 ILI9481 display/d' \
    '/^dtoverlay=piscreen/d' \
    '/^dtoverlay=waveshare35a/d' \
    '/^dtoverlay=ili9481/d' \
    '/^dtoverlay=inland-ili9481-overlay/d' \
    '/^dtoverlay=ads7846,/d' \
    '/^dtoverlay=xpt2046,/d'

echo "[6/9] Configuring boot display and touch"
sed -i 's/^dtoverlay=vc4-kms-v3d/#dtoverlay=vc4-kms-v3d/' "$CONFIG"
sed -i 's/^dtoverlay=vc4-fkms-v3d/#dtoverlay=vc4-fkms-v3d/' "$CONFIG"
sed -i 's/^display_auto_detect=1/#display_auto_detect=1/' "$CONFIG"
ensure_line "$CONFIG" "dtparam=spi=on"
ensure_line "$CONFIG" "disable_fw_kms_setup=1"
ensure_line "$CONFIG" "# Inland TFT35 ILI9481 display"
ensure_line "$CONFIG" "dtoverlay=inland-ili9481-overlay"
if [ "$TOUCH" -eq 1 ]; then
    ensure_line "$CONFIG" "dtoverlay=ads7846,cs=1,speed=2000000,penirq=${TOUCH_IRQ},penirq_pull=2,xohms=${TOUCH_XOHMS},pmax=${TOUCH_PMAX}"
fi

echo "[7/9] Configuring fbcon mapping"
sed -i 's/ fbcon=map:[^ ]*//g' "$CMDLINE"
sed -i 's/  */ /g' "$CMDLINE"
sed -i 's/[[:space:]]*$//' "$CMDLINE"
if ! grep -q 'fbcon=map:' "$CMDLINE"; then
    sed -i "1s/$/ fbcon=map:${FB_MAP}/" "$CMDLINE"
fi

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

echo "[9/9] Enabling boot mapping service and selecting X11"
cat > /usr/local/bin/inland-tft35-boot <<'EOF'
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
    sed -i "s#Option \"fbdev\" \"/dev/fb[0-9]*\"#Option \"fbdev\" \"/dev/fb${fb_number}\"#" /etc/X11/xorg.conf.d/99-inland-fbdev.conf
fi
EOF
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

echo
echo "Install complete."
echo "Reboot now: sudo reboot"
