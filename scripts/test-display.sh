#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# test-display.sh — Validate the Inland TFT35 ILI9481 userspace driver installation
#
# Checks daemon binary, vfb module, framebuffer device, systemd service,
# configuration, and optionally writes a random test pattern.
#
# Usage: sudo ./scripts/test-display.sh [--pattern]

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

echo "=== Inland TFT35 ILI9481 Validation (Userspace Driver) ==="
echo

# =====================================================================
# [1] Daemon binary
# =====================================================================

echo "[1] Daemon binary"
if [ -x /usr/local/bin/ili9481-fb ]; then
    pass "ili9481-fb binary exists at /usr/local/bin/ili9481-fb"
else
    fail "ili9481-fb binary not found at /usr/local/bin/ili9481-fb"
fi
echo

# =====================================================================
# [2] vfb kernel module
# =====================================================================

echo "[2] Virtual framebuffer module"
if lsmod | awk '{print $1}' | grep -qx "vfb"; then
    pass "vfb module is loaded"
else
    fail "vfb module is not loaded (try: sudo modprobe vfb)"
fi
echo

# =====================================================================
# [3] Framebuffer device
# =====================================================================

echo "[3] Framebuffer device"
FB_DEV=""
for fb in /sys/class/graphics/fb*; do
    [ -d "$fb" ] || continue
    fb_name=$(cat "$fb/name" 2>/dev/null || true)
    if echo "$fb_name" | grep -qi 'Virtual FB\|vfb'; then
        FB_DEV="/dev/$(basename "$fb")"
        pass "Found virtual framebuffer: $FB_DEV ($fb_name)"
        break
    fi
done
if [ -z "$FB_DEV" ]; then
    # Fall back to /dev/fb1 if it exists
    if [ -e /dev/fb1 ]; then
        FB_DEV="/dev/fb1"
        pass "Found framebuffer device: $FB_DEV"
    else
        fail "No virtual framebuffer found"
    fi
fi

if [ -n "$FB_DEV" ] && command -v fbset >/dev/null 2>&1; then
    fb_info=$(fbset -fb "$FB_DEV" 2>/dev/null || true)
    if echo "$fb_info" | grep -q '480x320\|320x480'; then
        pass "Framebuffer resolution matches ILI9481 (480x320 or 320x480)"
    else
        info "Framebuffer info: $(echo "$fb_info" | head -2 | tr '\n' ' ')"
    fi
    if echo "$fb_info" | grep -q '16'; then
        pass "Framebuffer depth is 16bpp"
    else
        info "Could not confirm 16bpp depth"
    fi
fi
echo

# =====================================================================
# [4] Systemd service
# =====================================================================

echo "[4] Systemd service"
if systemctl is-active --quiet ili9481-fb.service 2>/dev/null; then
    pass "ili9481-fb.service is active"
else
    fail "ili9481-fb.service is not active"
fi
if systemctl is-enabled --quiet ili9481-fb.service 2>/dev/null; then
    pass "ili9481-fb.service is enabled"
else
    fail "ili9481-fb.service is not enabled"
fi
echo

# =====================================================================
# [5] Configuration file
# =====================================================================

echo "[5] Configuration"
if [ -f /etc/ili9481/ili9481.conf ]; then
    pass "Config file exists at /etc/ili9481/ili9481.conf"
    info "$(grep -E '^(rotation|fps|fb_device|enable_touch)' /etc/ili9481/ili9481.conf 2>/dev/null | head -5 | tr '\n' '; ')"
else
    fail "Config file missing at /etc/ili9481/ili9481.conf"
fi
if [ -f /etc/modprobe.d/vfb-ili9481.conf ]; then
    pass "vfb modprobe config exists"
else
    fail "vfb modprobe config missing at /etc/modprobe.d/vfb-ili9481.conf"
fi
echo

# =====================================================================
# [6] Desktop backend
# =====================================================================

echo "[6] Desktop backend"
if command -v raspi-config >/dev/null 2>&1; then
    state="$(raspi-config nonint get_wayland 2>/dev/null || echo unknown)"
    if [ "$state" = "1" ]; then
        pass "Desktop backend is X11"
    elif [ "$state" = "0" ]; then
        fail "Desktop backend is Wayland (fbdev display output may fail)"
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

# =====================================================================
# [7] Pattern write (optional)
# =====================================================================

if [ "$PAINT_PATTERN" -eq 1 ]; then
    echo "[7] Pattern write"
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

# =====================================================================
# [8] Journal check
# =====================================================================

echo "[8] Recent journal entries"
if journalctl -u ili9481-fb --no-pager -n 20 2>/dev/null | grep -q '.'; then
    pass "Journal entries found for ili9481-fb"
    journalctl -u ili9481-fb --no-pager -n 10 2>/dev/null | sed 's/^/    /'
else
    info "No journal entries found for ili9481-fb"
fi
echo

# =====================================================================
# Summary
# =====================================================================

echo "=== Summary ==="
echo "Passes: $PASSES"
echo "Fails:  $FAILS"

if [ "$FAILS" -gt 0 ]; then
    exit 1
fi
