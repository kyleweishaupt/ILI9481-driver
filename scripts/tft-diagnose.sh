#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# tft-diagnose.sh — Boot-to-desktop diagnostics for Inland ILI9481 display
#
# Checks overlay state, module state, framebuffer, fbcon, touch input,
# desktop backend, and performs a framebuffer write test.
#
# Usage: sudo ./scripts/tft-diagnose.sh

set -euo pipefail

# =====================================================================
# Formatters
# =====================================================================

RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
RST='\033[0m'

PASSES=0
FAILS=0

pass() { echo -e "${GRN}[PASS]${RST} $*"; PASSES=$((PASSES + 1)); }
fail() { echo -e "${RED}[FAIL]${RST} $*"; FAILS=$((FAILS + 1)); }
info() { echo -e "${YEL}[INFO]${RST} $*"; }

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: sudo ./scripts/tft-diagnose.sh"
    exit 1
fi

echo "=== Inland ILI9481 Boot-to-Desktop Diagnostics ==="
echo

# =====================================================================
# [1] Overlay state
# =====================================================================

echo "[1] Overlay state"
found_overlay=0
if [ -d /proc/device-tree/chosen/overlays ]; then
    while IFS= read -r -d '' name_file; do
        ov_name=$(tr -d '\000' < "$name_file" 2>/dev/null || true)
        if echo "$ov_name" | grep -qi 'inland-ili9481'; then
            found_overlay=1
            break
        fi
    done < <(find /proc/device-tree/chosen/overlays -type f -name name -print0 2>/dev/null)
fi
if [ "$found_overlay" -eq 1 ]; then
    pass "inland-ili9481-overlay is active"
else
    fail "inland-ili9481-overlay is not active"
fi
echo

# =====================================================================
# [2] Module state
# =====================================================================

echo "[2] Module state"
if lsmod | awk '{print $1}' | grep -qx "ili9481_gpio"; then
    pass "Loaded module: ili9481_gpio"
else
    fail "Missing module: ili9481_gpio"
fi
if lsmod | awk '{print $1}' | grep -qx ads7846; then
    pass "Loaded module: ads7846"
else
    info "ads7846 module not loaded"
fi
echo

# =====================================================================
# [3] Framebuffer
# =====================================================================

echo "[3] Framebuffer"
FB_DEV=""
for fb_dir in /sys/class/graphics/fb*; do
    [ -d "$fb_dir" ] || continue
    fb_name=$(cat "$fb_dir/name" 2>/dev/null || true)
    if echo "$fb_name" | grep -qi 'ili9481'; then
        FB_DEV="/dev/$(basename "$fb_dir")"
        break
    fi
done

if [ -n "$FB_DEV" ] && [ -e "$FB_DEV" ]; then
    pass "ILI9481 framebuffer detected at ${FB_DEV}"
else
    fail "ILI9481 framebuffer not detected"
fi
for fb_dir in /sys/class/graphics/fb*; do
    [ -d "$fb_dir" ] || continue
    fb_name=$(cat "$fb_dir/name" 2>/dev/null || true)
    echo "    $(basename "$fb_dir"): $fb_name"
done
echo

# =====================================================================
# [4] fbcon and desktop
# =====================================================================

echo "[4] fbcon and desktop"
if grep -q 'fbcon=map:' /proc/cmdline; then
    pass "fbcon map present on kernel command line"
else
    fail "fbcon map missing from kernel command line"
fi
if command -v raspi-config >/dev/null 2>&1; then
    backend="$(raspi-config nonint get_wayland 2>/dev/null || echo unknown)"
    if [ "$backend" = "1" ]; then
        pass "Desktop backend is X11"
    elif [ "$backend" = "0" ]; then
        fail "Desktop backend is Wayland"
    else
        info "Desktop backend could not be detected"
    fi
fi
if [ -f /etc/X11/xorg.conf.d/99-inland-fbdev.conf ]; then
    pass "X11 fbdev config exists"
else
    fail "X11 fbdev config missing"
fi
echo

# =====================================================================
# [5] Touch
# =====================================================================

echo "[5] Touch"
if [ -f /proc/bus/input/devices ] && grep -qiE 'ADS7846|XPT2046' /proc/bus/input/devices; then
    pass "Touch controller detected in input devices"
else
    fail "Touch controller not detected"
fi
echo

# =====================================================================
# [6] Framebuffer write test
# =====================================================================

echo "[6] Framebuffer write test"
if [ -n "$FB_DEV" ] && [ -e "$FB_DEV" ]; then
    if dd if=/dev/urandom of="$FB_DEV" bs=307200 count=1 status=none 2>/dev/null; then
        pass "Wrote one random frame to ${FB_DEV}"
    else
        fail "Framebuffer write failed"
    fi
else
    fail "Skipping write test because no ILI9481 framebuffer was found"
fi

echo
echo "=== Diagnostics Complete ==="
echo "Passes: ${PASSES}"
echo "Fails:  ${FAILS}"

if [ "$FAILS" -gt 0 ]; then
    exit 1
fi
