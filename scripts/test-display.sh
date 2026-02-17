#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# test-display.sh — Quick validation for the ILI9481 DRM display driver
#
# Usage:  sudo ./scripts/test-display.sh
#
# This script checks that the driver is loaded, the DRM device exists,
# and optionally paints a colour bar test pattern via the fbdev interface.

set -euo pipefail

RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
RST='\033[0m'

pass() { echo -e "${GRN}[PASS]${RST} $*"; }
fail() { echo -e "${RED}[FAIL]${RST} $*"; }
info() { echo -e "${YEL}[INFO]${RST} $*"; }

errors=0

# ── 1. Check module is loaded ───────────────────────────────────────
echo "=== ILI9481 Display Driver Test ==="
echo ""

if lsmod | grep -q '^ili9481'; then
    pass "Kernel module 'ili9481' is loaded"
else
    fail "Kernel module 'ili9481' is NOT loaded"
    info "Try: sudo modprobe ili9481"
    errors=$((errors + 1))
fi

# ── 2. Check DRM device ─────────────────────────────────────────────
DRM_CARD=""
for card in /sys/class/drm/card*; do
    [ -d "$card" ] || continue
    # Try module name first, then fall back to driver link
    driver=$(cat "$card/device/driver/module/name" 2>/dev/null || true)
    if [ -z "$driver" ]; then
        driver=$(basename "$(readlink -f "$card/device/driver/module")" 2>/dev/null || true)
    fi
    if [ "$driver" = "ili9481" ]; then
        DRM_CARD=$(basename "$card")
        break
    fi
done

if [ -n "$DRM_CARD" ]; then
    pass "DRM device found: /dev/dri/$DRM_CARD"
else
    fail "No DRM device found for ili9481"
    info "Check: ls -la /sys/class/drm/card*/device/driver/module 2>/dev/null"
    errors=$((errors + 1))
fi

# ── 3. Check fbdev device ───────────────────────────────────────────
FB_DEV=""
for fb in /sys/class/graphics/fb*; do
    [ -d "$fb" ] || continue
    fb_name=$(cat "$fb/name" 2>/dev/null || true)
    if echo "$fb_name" | grep -qi "ili9481\|dbi"; then
        FB_DEV="/dev/$(basename "$fb")"
        break
    fi
done

if [ -n "$FB_DEV" ]; then
    pass "Framebuffer device: $FB_DEV ($fb_name)"
else
    info "No ili9481 framebuffer found (fbdev emulation may not be active)"
fi

# ── 4. Check dmesg for driver messages ──────────────────────────────
if dmesg 2>/dev/null | grep -qi "ili9481"; then
    pass "Driver messages present in kernel log"
    dmesg | grep -i "ili9481" | tail -5 | while IFS= read -r line; do
        echo "     $line"
    done
else
    info "No ili9481 messages in dmesg (ring buffer may have rotated)"
fi

# ── 5. Check fbcon mapping ───────────────────────────────────────────
if [ -n "$FB_DEV" ]; then
    FB_NUM=$(basename "$FB_DEV" | sed 's/fb//')
    FBCON_MAP=$(cat /proc/cmdline 2>/dev/null | grep -o 'fbcon=map:[^ ]*' || true)
    if [ -n "$FBCON_MAP" ]; then
        MAP_NUM=$(echo "$FBCON_MAP" | sed 's/fbcon=map://')
        if [ "$MAP_NUM" != "$FB_NUM" ]; then
            fail "fbcon mapped to fb${MAP_NUM} but ILI9481 is fb${FB_NUM}"
            info "Fix: edit /boot/firmware/cmdline.txt (or /boot/cmdline.txt)"
            info "  Change fbcon=map:${MAP_NUM} → fbcon=map:${FB_NUM}"
            info "  Or remove fbcon=map: entirely and re-run sudo ./install.sh"
            errors=$((errors + 1))
        else
            pass "fbcon correctly mapped to fb${FB_NUM}"
        fi
    else
        info "No fbcon=map: in cmdline (console goes to first available fb)"
    fi
fi

# ── 6. Optional: paint test pattern via fbdev ────────────────────────
if [ -n "$FB_DEV" ] && [ -w "$FB_DEV" ]; then
    echo ""

    # Detect the actual fbdev bits-per-pixel
    FB_SYS="/sys/class/graphics/$(basename "$FB_DEV")"
    BPP_BITS=$(cat "$FB_SYS/bits_per_pixel" 2>/dev/null || echo "16")
    info "Framebuffer format: ${BPP_BITS} bits/pixel"

    info "Painting colour bar test pattern to $FB_DEV ..."

    # 320×480 @ RGB565 = 307200 bytes (native portrait)
    W=320; H=480; BPP=2
    STRIPE=$((H / 4))
    {
        # Red stripe   (RGB565 = 0xF800 → little-endian: 00 F8)
        printf '%0.s\x00\xF8' $(seq 1 $((W * STRIPE)))
        # Green stripe  (RGB565 = 0x07E0 → little-endian: E0 07)
        printf '%0.s\xE0\x07' $(seq 1 $((W * STRIPE)))
        # Blue stripe   (RGB565 = 0x001F → little-endian: 1F 00)
        printf '%0.s\x1F\x00' $(seq 1 $((W * STRIPE)))
        # White stripe  (RGB565 = 0xFFFF → little-endian: FF FF)
        printf '%0.s\xFF\xFF' $(seq 1 $((W * STRIPE)))
    } > "$FB_DEV"

    pass "Test pattern written — you should see Red/Green/Blue/White stripes"
else
    info "Skipping test pattern (no writable framebuffer device)"
fi

# ── Summary ──────────────────────────────────────────────────────────
echo ""
if [ $errors -eq 0 ]; then
    pass "All checks passed"
    exit 0
else
    fail "$errors check(s) failed"
    exit 1
fi
