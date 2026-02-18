#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# test-display.sh — Validate the Inland TFT35 ILI9481 userspace driver installation
#
# Checks daemon binary, source framebuffer, systemd service, configuration,
# GPIO access, and optionally writes a test pattern to the source fb.
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

echo "=== Inland TFT35 ILI9481 Validation (Userspace Daemon) ==="
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
# [2] Source framebuffer (HDMI / vc4drmfb)
# =====================================================================

echo "[2] Source framebuffer"
FB_DEV=""
if [ -e /dev/fb0 ]; then
    FB_DEV="/dev/fb0"
    fb_name=$(cat /sys/class/graphics/fb0/name 2>/dev/null || echo "unknown")
    pass "Found source framebuffer: $FB_DEV ($fb_name)"
else
    fail "No framebuffer found at /dev/fb0"
fi

if [ -n "$FB_DEV" ] && command -v fbset >/dev/null 2>&1; then
    fb_info=$(fbset -fb "$FB_DEV" 2>/dev/null || true)
    if [ -n "$fb_info" ]; then
        info "fbset: $(echo "$fb_info" | head -3 | tr '\n' ' ')"
    fi
fi
echo

# =====================================================================
# [3] /dev/gpiomem access
# =====================================================================

echo "[3] GPIO access"
if [ -c /dev/gpiomem ]; then
    pass "/dev/gpiomem exists"
    if [ -r /dev/gpiomem ] && [ -w /dev/gpiomem ]; then
        pass "/dev/gpiomem is readable/writable"
    else
        fail "/dev/gpiomem is not readable/writable (check permissions / gpio group)"
    fi
else
    fail "/dev/gpiomem not found — GPIO MMIO will not work"
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
        fail "Desktop backend is Wayland (fbdev mirroring may not work)"
    else
        info "Could not determine desktop backend"
    fi
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
            info "If the daemon is running, random noise should appear on the TFT"
        else
            fail "Could not write test frame to $FB_DEV"
        fi
    else
        fail "Cannot write pattern — no framebuffer found"
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
