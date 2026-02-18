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

echo "=== Inland TFT35 Display Diagnostic ==="
echo ""

# ── Determine config paths ──────────────────────────────────────────

CONFIG="/boot/config.txt"
if [ -d "/boot/firmware" ]; then
    CONFIG="/boot/firmware/config.txt"
fi

# ═════════════════════════════════════════════════════════════════════
# 1. Check for fbtft blacklists (most common cause of white screen)
# ═════════════════════════════════════════════════════════════════════

BLACKLISTED=0
for conf in /etc/modprobe.d/*.conf; do
    [ -f "$conf" ] || continue
    if grep -qE '^blacklist\s+(fbtft|fb_ili9486)' "$conf" 2>/dev/null; then
        fail "fbtft is BLACKLISTED in $conf"
        grep -E '^blacklist\s+(fbtft|fb_ili9486)' "$conf" | while IFS= read -r line; do
            echo "     $line"
        done
        BLACKLISTED=1
    fi
done
if [ "$BLACKLISTED" -eq 0 ]; then
    pass "No fbtft blacklists found in /etc/modprobe.d/"
fi

# Check initramfs for cached blacklists (use ls to avoid glob expansion in [ ])
if ls /boot/firmware/initramfs* /boot/initrd* >/dev/null 2>&1; then
    if lsinitramfs /boot/firmware/initramfs* 2>/dev/null | grep -q modprobe; then
        info "initramfs exists — if blacklists were recently removed, run:"
        info "  sudo update-initramfs -u"
    fi
fi

# ═════════════════════════════════════════════════════════════════════
# 2. Check kernel module availability
# ═════════════════════════════════════════════════════════════════════

if modinfo fb_ili9486 >/dev/null 2>&1; then
    pass "Kernel module fb_ili9486 is available"
elif modinfo fbtft >/dev/null 2>&1; then
    pass "Kernel module fbtft is available (fb_ili9486 may be built-in)"
else
    fail "Neither fb_ili9486 nor fbtft kernel modules found"
    info "Your kernel may not include fbtft. Check: uname -r"
fi

# ═════════════════════════════════════════════════════════════════════
# 3. Check if fb_ili9486 / fbtft module is loaded
# ═════════════════════════════════════════════════════════════════════

if lsmod | grep -q 'fb_ili9486\|fbtft'; then
    pass "fbtft driver is loaded"
    lsmod | grep -E 'fb_ili9486|fbtft' | while IFS= read -r line; do
        echo "     $line"
    done
else
    fail "fbtft driver is NOT loaded"
    info "This means the overlay did not probe the driver at boot."
    info "Check: dmesg | grep -i 'fbtft\|ili9486\|spi'"
fi

# ═════════════════════════════════════════════════════════════════════
# 4. Find fbtft framebuffer
# ═════════════════════════════════════════════════════════════════════

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
    # List what framebuffers DO exist
    for fb in /sys/class/graphics/fb*; do
        [ -d "$fb" ] || continue
        echo "     $(basename "$fb"): $(cat "$fb/name" 2>/dev/null || echo '(unknown)')"
    done
fi

# ═════════════════════════════════════════════════════════════════════
# 5. Check dmesg for driver messages
# ═════════════════════════════════════════════════════════════════════

if dmesg 2>/dev/null | grep -qi "ili9486\|fbtft"; then
    pass "Driver messages present in kernel log"
    dmesg | grep -iE "ili9486|fbtft" | tail -5 | while IFS= read -r line; do
        echo "     $line"
    done
else
    info "No fbtft/ili9486 messages in dmesg (ring buffer may have rotated)"
    # Check for SPI errors that might explain why fbtft didn't load
    if dmesg 2>/dev/null | grep -qi "spi.*error\|spi.*fail"; then
        fail "SPI errors found in dmesg:"
        dmesg | grep -iE "spi.*(error|fail)" | tail -3 | while IFS= read -r line; do
            echo "     $line"
        done
    fi
fi

# ═════════════════════════════════════════════════════════════════════
# 6. Check config.txt for correct overlay + settings
# ═════════════════════════════════════════════════════════════════════

if [ -f "$CONFIG" ]; then
    # Check overlay
    if grep -q '^dtoverlay=piscreen\|^dtoverlay=waveshare35a' "$CONFIG"; then
        OVERLAY_LINE=$(grep '^dtoverlay=piscreen\|^dtoverlay=waveshare35a' "$CONFIG" | head -1)
        pass "Overlay configured: ${OVERLAY_LINE}"
    else
        fail "No piscreen/waveshare35a overlay in ${CONFIG}"
        info "Run: sudo ./install.sh"
    fi

    # Check vc4-kms-v3d is disabled
    if grep -q '^dtoverlay=vc4-kms-v3d' "$CONFIG"; then
        fail "vc4-kms-v3d is ACTIVE (must be commented out for fbtft)"
        info "Run: sudo ./install.sh (it handles this automatically)"
    else
        pass "vc4-kms-v3d is disabled"
    fi

    # Check display_auto_detect
    if grep -q '^display_auto_detect=1' "$CONFIG"; then
        fail "display_auto_detect is ACTIVE (should be commented out)"
        info "Run: sudo ./install.sh"
    else
        pass "display_auto_detect is disabled"
    fi

    # Check SPI
    if grep -q '^dtparam=spi=on' "$CONFIG"; then
        pass "SPI is enabled"
    else
        fail "SPI is NOT enabled in ${CONFIG}"
    fi
fi

# ═════════════════════════════════════════════════════════════════════
# 7. Check display backend (Wayland vs X11)
# ═════════════════════════════════════════════════════════════════════

if command -v raspi-config >/dev/null 2>&1; then
    WAYLAND_STATUS=$(raspi-config nonint get_wayland 2>/dev/null || echo "unknown")
    if [ "$WAYLAND_STATUS" = "0" ]; then
        fail "Wayland is ACTIVE — fbtft requires X11"
        info "fbtft creates legacy framebuffers, not DRM devices."
        info "Wayland compositors (labwc) will crash without DRM."
        info "Fix: sudo raspi-config → Advanced → Wayland → X11"
        info "  or re-run: sudo ./install.sh"
    elif [ "$WAYLAND_STATUS" = "1" ]; then
        pass "Display backend is X11"
    else
        info "Could not determine display backend"
    fi
fi

# ═════════════════════════════════════════════════════════════════════
# 8. Check ADS7846 touch input device
# ═════════════════════════════════════════════════════════════════════

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
fi

# ═════════════════════════════════════════════════════════════════════
# 9. Check fbcon mapping
# ═════════════════════════════════════════════════════════════════════

if [ -n "$FB_DEV" ]; then
    FB_NUM=$(basename "$FB_DEV" | sed 's/fb//')
    FBCON_MAP=$(cat /proc/cmdline 2>/dev/null | grep -o 'fbcon=map:[^ ]*' || true)
    if [ -n "$FBCON_MAP" ]; then
        # fbcon=map:10 means console 0→fb1, console 1→fb0
        MAP_FIRST=$(echo "$FBCON_MAP" | sed 's/fbcon=map:\(.\).*/\1/')
        if [ "$MAP_FIRST" = "$FB_NUM" ]; then
            pass "fbcon cmdline maps console 0 to fb${FB_NUM} (correct)"
        else
            fail "fbcon cmdline maps console 0 to fb${MAP_FIRST} but fbtft is fb${FB_NUM}"
            info "Fix: edit ${CMDLINE:-/boot/firmware/cmdline.txt} → fbcon=map:${FB_NUM}0"
        fi
    else
        fail "No fbcon=map: in cmdline (console defaults to fb0, display likely white!)"
        info "Fix: re-run sudo ./install.sh (it now adds fbcon=map:10)"
    fi

    # Also check runtime mapping via con2fbmap
    if command -v con2fbmap >/dev/null 2>&1; then
        CON1_FB=$(con2fbmap 1 2>/dev/null | grep -o '[0-9]*$' || true)
        if [ -n "$CON1_FB" ]; then
            if [ "$CON1_FB" = "$FB_NUM" ]; then
                pass "Console 1 runtime-mapped to fb${FB_NUM} via con2fbmap"
            else
                fail "Console 1 runtime-mapped to fb${CON1_FB} (expected fb${FB_NUM})"
            fi
        fi
    fi

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

# ═════════════════════════════════════════════════════════════════════
# 10. Check systemd services
# ═════════════════════════════════════════════════════════════════════

# Setup service
if systemctl is-enabled inland-tft35-display.service >/dev/null 2>&1; then
    pass "inland-tft35-display.service is enabled"
    if systemctl is-active inland-tft35-display.service >/dev/null 2>&1; then
        pass "inland-tft35-display.service ran successfully"
    else
        SVC_STATUS=$(systemctl is-active inland-tft35-display.service 2>/dev/null || echo "unknown")
        if [ "$SVC_STATUS" = "inactive" ]; then
            info "inland-tft35-display.service has not run yet (reboot needed?)"
        else
            fail "inland-tft35-display.service status: ${SVC_STATUS}"
            info "Check: sudo journalctl -u inland-tft35-display.service"
        fi
    fi
else
    fail "inland-tft35-display.service is not enabled"
    info "Run: sudo ./install.sh"
fi

# Flush daemon (critical for screen updates)
if systemctl is-enabled inland-tft35-flush.service >/dev/null 2>&1; then
    pass "inland-tft35-flush.service is enabled"
    if systemctl is-active inland-tft35-flush.service >/dev/null 2>&1; then
        pass "inland-tft35-flush.service is RUNNING (defio active)"
    else
        fail "inland-tft35-flush.service is NOT running!"
        info "Without the flush daemon, fbtft may never send data to the LCD."
        info "Check: sudo journalctl -u inland-tft35-flush.service"
        info "Fix:   sudo systemctl restart inland-tft35-flush.service"
    fi
else
    fail "inland-tft35-flush.service is not enabled"
    info "The defio flush daemon is CRITICAL for the display to work."
    info "Re-run: sudo ./install.sh"
fi

# ═════════════════════════════════════════════════════════════════════
# 11. Check X11 / LightDM
# ═════════════════════════════════════════════════════════════════════

if pgrep -x Xorg >/dev/null 2>&1 || pgrep -x X >/dev/null 2>&1; then
    pass "X11 server is running"
    # Check which fb device X is using
    X_FBDEV=$(grep -o '/dev/fb[0-9]*' /var/log/Xorg.0.log 2>/dev/null | head -1 || true)
    [ -n "$X_FBDEV" ] && info "X11 is using: ${X_FBDEV}"
elif pgrep -x labwc >/dev/null 2>&1 || pgrep -x wayfire >/dev/null 2>&1; then
    fail "Wayland compositor is running (labwc/wayfire) — fbtft requires X11!"
    info "Fix: sudo raspi-config → Advanced → Wayland → X11"
else
    info "No display server detected (X11 or Wayland)"
    info "The display should still show a text console (fbcon)"
fi

if pgrep -x lightdm >/dev/null 2>&1; then
    pass "LightDM display manager is running"
else
    info "LightDM is not running — check: sudo systemctl status lightdm"
fi

# ═════════════════════════════════════════════════════════════════════
# 12. Check GPIO pin states (DC, RST, LED)
# ═════════════════════════════════════════════════════════════════════

if command -v pinctrl >/dev/null 2>&1; then
    for pin_info in "24:DC" "25:RST" "22:LED"; do
        pin=${pin_info%%:*}
        label=${pin_info##*:}
        state=$(pinctrl get "$pin" 2>/dev/null || true)
        if [ -n "$state" ]; then
            func=$(echo "$state" | grep -oE 'a[0-9]+|op|ip|no' | head -1)
            level=$(echo "$state" | grep -oE 'hi|lo' | head -1)
            if [ "$func" = "op" ] || echo "$func" | grep -q 'a[0-9]'; then
                pass "GPIO ${pin} (${label}): ${func} ${level}"
            else
                fail "GPIO ${pin} (${label}): expected output, got ${func} ${level}"
                info "fbtft may not have configured this pin correctly"
            fi
        fi
    done
elif command -v raspi-gpio >/dev/null 2>&1; then
    for pin_info in "24:DC" "25:RST" "22:LED"; do
        pin=${pin_info%%:*}
        label=${pin_info##*:}
        state=$(raspi-gpio get "$pin" 2>/dev/null || true)
        [ -n "$state" ] && info "GPIO ${pin} (${label}): ${state}"
    done
fi

# ═════════════════════════════════════════════════════════════════════
# 13. SPI transfer check (look for errors in dmesg)
# ═════════════════════════════════════════════════════════════════════

if dmesg 2>/dev/null | grep -qiE 'spi.*(error|fail|timeout)|dma.*(error|fail)'; then
    fail "SPI/DMA errors found in kernel log:"
    dmesg | grep -iE 'spi.*(error|fail|timeout)|dma.*(error|fail)' | tail -5 | while IFS= read -r line; do
        echo "     $line"
    done
else
    pass "No SPI/DMA errors in kernel log"
fi

# ═════════════════════════════════════════════════════════════════════
# 14. HARDWARE WRITE TEST (--pattern flag or always for write test)
# ═════════════════════════════════════════════════════════════════════

if [ "$PAINT_PATTERN" -eq 1 ] && [ -n "$FB_DEV" ] && [ -w "$FB_DEV" ]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  HARDWARE WRITE TEST — Watch the SPI display screen!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    FB_SYS="/sys/class/graphics/$(basename "$FB_DEV")"
    FB_SIZE=$(( $(cat "$FB_SYS/virtual_size" 2>/dev/null | cut -d, -f1) * \
                $(cat "$FB_SYS/virtual_size" 2>/dev/null | cut -d, -f2) * \
                $(cat "$FB_SYS/bits_per_pixel" 2>/dev/null) / 8 )) 2>/dev/null || FB_SIZE=307200
    NPIXELS=$((FB_SIZE / 2))

    # --- Test A: write() syscall (triggers fb_sys_write → defio) ---
    info "Test A: Writing random static via write() to ${FB_DEV}..."
    dd if=/dev/urandom of="$FB_DEV" bs=1024 count=$((FB_SIZE / 1024)) 2>/dev/null
    sleep 2
    echo "     >>> Did the screen show colourful static/noise? <<<"
    echo ""

    # --- Test B: mmap write (triggers page fault → defio) ---
    info "Test B: Writing BLUE via mmap to ${FB_DEV}..."
    python3 -c "
import mmap, os
fd = os.open('$FB_DEV', os.O_RDWR)
m = mmap.mmap(fd, 0)
blue = b'\x1f\x00' * (m.size() // 2)
m[:len(blue)] = blue
m.close()
os.close(fd)
print('     mmap write complete')
" 2>/dev/null || info "Python mmap write failed (python3 may not be available)"
    sleep 2
    echo "     >>> Did the screen turn solid BLUE? <<<"
    echo ""

    # --- Test C: solid RED ---
    info "Test C: Writing RED via write() to ${FB_DEV}..."
    python3 -c "
import os
fb = os.open('$FB_DEV', os.O_WRONLY)
os.write(fb, b'\x00\xf8' * $NPIXELS)
os.close(fb)
" 2>/dev/null || printf '%0.s\x00\xF8' $(seq 1 "$NPIXELS") > "$FB_DEV" 2>/dev/null
    sleep 2
    echo "     >>> Did the screen turn solid RED? <<<"
    echo ""

    # --- Test D: solid GREEN ---
    info "Test D: Writing GREEN via write() to ${FB_DEV}..."
    python3 -c "
import os
fb = os.open('$FB_DEV', os.O_WRONLY)
os.write(fb, b'\xe0\x07' * $NPIXELS)
os.close(fb)
" 2>/dev/null || printf '%0.s\xE0\x07' $(seq 1 "$NPIXELS") > "$FB_DEV" 2>/dev/null
    sleep 2
    echo "     >>> Did the screen turn solid GREEN? <<<"
    echo ""

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  RESULTS:"
    echo ""
    echo "  If you saw colour changes → display hardware WORKS."
    echo "    The issue is what's being rendered (fbcon/X11 config)."
    echo ""
    echo "  If the screen stayed WHITE the entire time:"
    echo "    → fbtft is NOT sending SPI data to the LCD."
    echo "    → Check: sudo journalctl -u inland-tft35-flush.service"
    echo "    → Check: dmesg | grep -iE 'spi.*err|dma.*err|fbtft'"
    echo "    → The SPI bus or LCD hardware may have a fault."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

elif [ "$PAINT_PATTERN" -eq 1 ]; then
    info "Skipping hardware write test (no writable framebuffer device)"
fi

# ═════════════════════════════════════════════════════════════════════
# Summary
# ═════════════════════════════════════════════════════════════════════

echo ""
echo "Results: ${PASSES} passed, ${ERRORS} failed"
echo ""
if [ "$ERRORS" -eq 0 ]; then
    pass "All checks passed"
    if [ "$PAINT_PATTERN" -eq 0 ]; then
        echo ""
        echo "If the screen is still white, run the hardware write test:"
        echo "  sudo ./scripts/test-display.sh --pattern"
    fi
    exit 0
else
    fail "${ERRORS} check(s) failed — review output above"
    echo ""
    echo "Common fixes:"
    echo "  White screen?  → sudo ./install.sh && sudo reboot"
    echo "  Flush daemon?  → sudo systemctl restart inland-tft35-flush.service"
    echo "  Blacklisted?   → sudo rm /etc/modprobe.d/*fbtft* && sudo update-initramfs -u && sudo reboot"
    echo "  Wayland?       → sudo raspi-config → Advanced → Wayland → X11"
    echo ""
    echo "Run hardware write test:"
    echo "  sudo ./scripts/test-display.sh --pattern"
    exit 1
fi
