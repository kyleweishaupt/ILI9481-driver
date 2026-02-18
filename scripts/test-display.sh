#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only

set -euo pipefail

PAINT_PATTERN=0
for arg in "$@"; do
    case "$arg" in
        --pattern)
            PAINT_PATTERN=1
            ;;
        --help|-h)
            echo "Usage: sudo ./scripts/test-display.sh [--pattern]"
            exit 0
            ;;
    esac
done

RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
RST='\033[0m'

PASSES=0
FAILS=0

pass() { echo -e "${GRN}[PASS]${RST} $*"; PASSES=$((PASSES + 1)); }
fail() { echo -e "${RED}[FAIL]${RST} $*"; FAILS=$((FAILS + 1)); }
info() { echo -e "${YEL}[INFO]${RST} $*"; }

CONFIG="/boot/config.txt"
if [ -d "/boot/firmware" ]; then
    CONFIG="/boot/firmware/config.txt"
fi

echo "=== Inland TFT35 ILI9481 Validation ==="
echo

echo "[1] Kernel module availability"
if modinfo fb_ili9481 >/dev/null 2>&1; then
    pass "fb_ili9481 module is available"
else
    fail "fb_ili9481 module is not available"
fi
if modinfo fbtft >/dev/null 2>&1; then
    pass "fbtft module is available"
else
    fail "fbtft module is not available"
fi
if modinfo ads7846 >/dev/null 2>&1; then
    pass "ads7846 touch module is available"
else
    info "ads7846 module not available in modinfo output"
fi
echo

echo "[2] Loaded modules"
for module in fbtft fb_ili9481; do
    if lsmod | awk '{print $1}' | grep -qx "$module"; then
        pass "Loaded: $module"
    else
        fail "Missing from lsmod: $module"
    fi
done
if lsmod | awk '{print $1}' | grep -qx ads7846; then
    pass "Loaded: ads7846"
else
    info "ads7846 not currently loaded"
fi
echo

echo "[3] Overlay config"
if grep -q '^dtoverlay=inland-ili9481-overlay' "$CONFIG"; then
    pass "inland-ili9481-overlay present in config"
else
    fail "inland-ili9481-overlay missing from config"
fi
if grep -q '^dtoverlay=ads7846,' "$CONFIG"; then
    pass "ads7846 overlay present in config"
else
    info "ads7846 overlay not present in config"
fi
echo

echo "[4] Runtime overlays"
runtime_overlay=0
if [ -d /proc/device-tree/chosen/overlays ]; then
    while IFS= read -r -d '' name_file; do
        name=$(tr -d '\000' < "$name_file" 2>/dev/null || true)
        if echo "$name" | grep -qi 'inland-ili9481'; then
            runtime_overlay=1
            break
        fi
    done < <(find /proc/device-tree/chosen/overlays -type f -name name -print0 2>/dev/null)
fi
if [ "$runtime_overlay" -eq 1 ]; then
    pass "inland-ili9481-overlay active at runtime"
else
    fail "inland-ili9481-overlay not detected at runtime"
fi
echo

echo "[5] Framebuffer"
FB_DEV=""
for fb in /sys/class/graphics/fb*; do
    [ -d "$fb" ] || continue
    fb_name=$(cat "$fb/name" 2>/dev/null || true)
    if echo "$fb_name" | grep -qi 'ili9481'; then
        FB_DEV="/dev/$(basename "$fb")"
        pass "Found ILI9481 framebuffer: $FB_DEV ($fb_name)"
        break
    fi
done
if [ -z "$FB_DEV" ]; then
    fail "No framebuffer named ILI9481 found"
fi
echo

echo "[6] fbcon mapping"
if grep -q 'fbcon=map:' /proc/cmdline; then
    pass "Kernel cmdline includes fbcon mapping"
else
    fail "Kernel cmdline missing fbcon=map"
fi
echo

echo "[7] Touch input device"
if [ -f /proc/bus/input/devices ] && grep -qiE 'ADS7846|XPT2046' /proc/bus/input/devices; then
    pass "Touch input detected (ADS7846/XPT2046)"
    grep -A5 -iE 'ADS7846|XPT2046' /proc/bus/input/devices | sed 's/^/    /'
else
    fail "Touch input device not detected"
fi
echo

echo "[8] Desktop backend"
if command -v raspi-config >/dev/null 2>&1; then
    state="$(raspi-config nonint get_wayland 2>/dev/null || echo unknown)"
    if [ "$state" = "1" ]; then
        pass "Desktop backend is X11"
    elif [ "$state" = "0" ]; then
        fail "Desktop backend is Wayland (fbtft desktop output may fail)"
    else
        info "Could not determine desktop backend"
    fi
fi
if [ -f /etc/X11/xorg.conf.d/99-inland-fbdev.conf ]; then
    pass "X11 fbdev config file exists"
else
    fail "X11 fbdev config file missing"
fi
echo

if [ "$PAINT_PATTERN" -eq 1 ]; then
    echo "[9] Pattern write"
    if [ -n "$FB_DEV" ]; then
        if dd if=/dev/urandom of="$FB_DEV" bs=307200 count=1 status=none 2>/dev/null; then
            pass "Random test frame written to $FB_DEV"
        else
            fail "Could not write test frame to $FB_DEV"
        fi
    else
        fail "Cannot write pattern because framebuffer was not found"
    fi
    echo
fi

echo "=== Summary ==="
echo "Passes: $PASSES"
echo "Fails:  $FAILS"

if [ "$FAILS" -gt 0 ]; then
    exit 1
fi
