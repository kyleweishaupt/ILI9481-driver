#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# test-display.sh — Validate Inland TFT35 / MPI3501 fbtft display setup
#
# Usage:  sudo ./scripts/test-display.sh [--pattern]
#
# Checks that the fb_ili9486 driver is loaded, the framebuffer exists,
# touch input is available, and fbcon is mapped correctly.  Optionally
# paints an RGBW colour bar test pattern to the display.

set -euo pipefail

PAINT_PATTERN=0
for arg in "$@"; do
    case "$arg" in
        --pattern) PAINT_PATTERN=1 ;;
        --help|-h)
            echo "Usage: sudo $0 [--pattern]"
            echo "  --pattern  Paint RGBW test bars to the framebuffer"
            exit 0 ;;
    esac
done

RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
RST='\033[0m'

pass() { echo -e "${GRN}[PASS]${RST} $*"; PASSES=$((PASSES + 1)); }
fail() { echo -e "${RED}[FAIL]${RST} $*"; ERRORS=$((ERRORS + 1)); }
info() { echo -e "${YEL}[INFO]${RST} $*"; }

ERRORS=0
PASSES=0

echo "=== Inland TFT35 Display Test ==="
echo ""

# ── 1. Check fb_ili9486 module is loaded ─────────────────────────────

if lsmod | grep -q 'fb_ili9486\|fbtft'; then
    pass "fbtft driver is loaded (fb_ili9486 / fbtft)"
    lsmod | grep -E 'fb_ili9486|fbtft' | while IFS= read -r line; do
        echo "     $line"
    done
else
    fail "fbtft driver is NOT loaded"
    info "Check: dmesg | grep -i fbtft"
    info "Verify config.txt has: dtoverlay=piscreen (or waveshare35a)"
fi

# ── 2. Find fbtft framebuffer ────────────────────────────────────────

FB_DEV=""
FB_NAME=""
for fb in /sys/class/graphics/fb*; do
    [ -d "$fb" ] || continue
    fb_name=$(cat "$fb/name" 2>/dev/null || true)
    if echo "$fb_name" | grep -qi "ili9486"; then
        FB_DEV="/dev/$(basename "$fb")"
        FB_NAME="$fb_name"
        break
    fi
done

if [ -n "$FB_DEV" ]; then
    pass "Framebuffer device: ${FB_DEV} (${FB_NAME})"
else
    fail "No fbtft framebuffer found (expected name containing 'ili9486')"
    info "Check: ls /sys/class/graphics/fb*/name"
    info "Check: dmesg | grep -i 'fbtft\|ili9486'"
fi

# ── 3. Check dmesg for driver messages ──────────────────────────────

if dmesg 2>/dev/null | grep -qi "ili9486\|fbtft"; then
    pass "Driver messages present in kernel log"
    dmesg | grep -iE "ili9486|fbtft" | tail -5 | while IFS= read -r line; do
        echo "     $line"
    done
else
    info "No fbtft/ili9486 messages in dmesg (ring buffer may have rotated)"
fi

# ── 4. Check ADS7846 touch input device ─────────────────────────────

TOUCH_DEV=""
if [ -f /proc/bus/input/devices ]; then
    if grep -qi "ADS7846" /proc/bus/input/devices; then
        pass "Touch input: ADS7846 Touchscreen found"
        TOUCH_DEV=$(grep -A4 "ADS7846" /proc/bus/input/devices \
                    | grep -o 'event[0-9]*' | head -1 || true)
        [ -n "$TOUCH_DEV" ] && echo "     Input device: /dev/input/${TOUCH_DEV}"
    else
        fail "ADS7846 touch input device not found"
        info "Check wiring (IRQ=GPIO17, SPI0 CE1)"
        info "Check: cat /proc/bus/input/devices"
    fi
else
    info "Cannot check touch input (/proc/bus/input/devices not available)"
fi

# ── 5. Check fbcon mapping ──────────────────────────────────────────

if [ -n "$FB_DEV" ]; then
    FB_NUM=$(basename "$FB_DEV" | sed 's/fb//')
    FBCON_MAP=$(cat /proc/cmdline 2>/dev/null | grep -o 'fbcon=map:[^ ]*' || true)
    if [ -n "$FBCON_MAP" ]; then
        MAP_NUM=$(echo "$FBCON_MAP" | sed 's/fbcon=map://')
        if [ "$MAP_NUM" != "$FB_NUM" ]; then
            fail "fbcon mapped to fb${MAP_NUM} but fbtft is fb${FB_NUM}"
            info "The inland-tft35-display.service should handle this at boot."
            info "Check: systemctl status inland-tft35-display.service"
        else
            pass "fbcon correctly mapped to fb${FB_NUM}"
        fi
    else
        info "No fbcon=map: in cmdline (fbcon uses first available fb)"
    fi

    # Check vtconsole binding
    for vtcon in /sys/class/vtconsole/vtcon*; do
        [ -d "$vtcon" ] || continue
        vtname=$(cat "$vtcon/name" 2>/dev/null || true)
        bound=$(cat "$vtcon/bind" 2>/dev/null || true)
        if echo "$vtname" | grep -qi "frame buffer"; then
            if [ "$bound" = "1" ]; then
                pass "fbcon is bound ($(basename "$vtcon"): ${vtname})"
            else
                info "fbcon is unbound ($(basename "$vtcon"): ${vtname})"
            fi
        fi
    done
fi

# ── 6. Check config.txt for overlay ─────────────────────────────────

CONFIG="/boot/config.txt"
if [ -d "/boot/firmware" ]; then
    CONFIG="/boot/firmware/config.txt"
fi

if [ -f "$CONFIG" ]; then
    if grep -q "^dtoverlay=piscreen\|^dtoverlay=waveshare35a" "$CONFIG"; then
        OVERLAY_LINE=$(grep "^dtoverlay=piscreen\|^dtoverlay=waveshare35a" "$CONFIG" | head -1)
        pass "Overlay configured: ${OVERLAY_LINE}"
    else
        fail "No piscreen/waveshare35a overlay in ${CONFIG}"
        info "Run: sudo ./install.sh"
    fi

    if grep -q "^dtoverlay=vc4-kms-v3d" "$CONFIG"; then
        fail "vc4-kms-v3d is active (must be commented out for fbtft)"
        info "Run: sudo ./install.sh (it handles this automatically)"
    fi
fi

# ── 7. Optional: paint RGBW test pattern ─────────────────────────────

if [ "$PAINT_PATTERN" -eq 1 ] && [ -n "$FB_DEV" ] && [ -w "$FB_DEV" ]; then
    echo ""
    FB_SYS="/sys/class/graphics/$(basename "$FB_DEV")"
    BPP_BITS=$(cat "$FB_SYS/bits_per_pixel" 2>/dev/null || echo "16")
    info "Framebuffer format: ${BPP_BITS} bits/pixel"
    info "Painting RGBW colour bar test pattern to ${FB_DEV} ..."

    # 320x480 @ RGB565 = 307200 bytes (native portrait)
    W=320; H=480
    STRIPE=$((H / 4))
    {
        # Red stripe   (RGB565 = 0xF800 -> little-endian: 00 F8)
        printf '%0.s\x00\xF8' $(seq 1 $((W * STRIPE)))
        # Green stripe  (RGB565 = 0x07E0 -> little-endian: E0 07)
        printf '%0.s\xE0\x07' $(seq 1 $((W * STRIPE)))
        # Blue stripe   (RGB565 = 0x001F -> little-endian: 1F 00)
        printf '%0.s\x1F\x00' $(seq 1 $((W * STRIPE)))
        # White stripe  (RGB565 = 0xFFFF -> little-endian: FF FF)
        printf '%0.s\xFF\xFF' $(seq 1 $((W * STRIPE)))
    } > "$FB_DEV"

    pass "Test pattern written — you should see Red/Green/Blue/White stripes"
elif [ "$PAINT_PATTERN" -eq 1 ]; then
    info "Skipping test pattern (no writable framebuffer device)"
fi

# ── Summary ──────────────────────────────────────────────────────────

echo ""
echo "Results: ${PASSES} passed, ${ERRORS} failed"
echo ""
if [ "$ERRORS" -eq 0 ]; then
    pass "All checks passed"
    exit 0
else
    fail "${ERRORS} check(s) failed — review output above"
    exit 1
fi
