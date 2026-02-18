#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# tft-diagnose.sh — Diagnostics for ILI9481 userspace framebuffer daemon
#
# Checks: daemon service, GPIO access, source framebuffer, binary,
# configuration, display daemon log, and optional touch.
#
# Usage: sudo ./scripts/tft-diagnose.sh

set -euo pipefail

# =====================================================================
# Formatters
# =====================================================================

RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
CYN='\033[0;36m'
RST='\033[0m'

PASSES=0
FAILS=0
WARNS=0

pass() { echo -e "${GRN}[PASS]${RST} $*"; PASSES=$((PASSES + 1)); }
fail() { echo -e "${RED}[FAIL]${RST} $*"; FAILS=$((FAILS + 1)); }
warn() { echo -e "${YEL}[WARN]${RST} $*"; WARNS=$((WARNS + 1)); }
info() { echo -e "${CYN}[INFO]${RST} $*"; }

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: sudo ./scripts/tft-diagnose.sh"
    exit 1
fi

echo "=== ILI9481 Userspace Daemon Diagnostics ==="
echo

# =====================================================================
# [1] Binary
# =====================================================================

echo "[1] Daemon binary"
DAEMON=/usr/local/bin/ili9481-fb
if [ -x "$DAEMON" ]; then
    pass "Found daemon at ${DAEMON}"
else
    fail "Daemon binary not found at ${DAEMON}"
fi
echo

# =====================================================================
# [2] Configuration file
# =====================================================================

echo "[2] Configuration"
CONF=/etc/ili9481.conf
if [ -f "$CONF" ]; then
    pass "Config file ${CONF} exists"
    info "Contents:"
    sed 's/^/    /' "$CONF"
else
    warn "No config file at ${CONF} — daemon will use defaults"
fi
echo

# =====================================================================
# [3] /dev/gpiomem access
# =====================================================================

echo "[3] GPIO access"
if [ -e /dev/gpiomem ]; then
    pass "/dev/gpiomem exists"
    perms=$(stat -c '%a' /dev/gpiomem)
    owner=$(stat -c '%U:%G' /dev/gpiomem)
    info "  permissions: ${perms}  owner: ${owner}"
else
    fail "/dev/gpiomem does not exist — MMIO GPIO will not work"
fi
echo

# =====================================================================
# [4] Source framebuffer
# =====================================================================

echo "[4] Source framebuffer"
FB_DEV=/dev/fb0
if [ -e "$FB_DEV" ]; then
    pass "${FB_DEV} exists"
    for fb_dir in /sys/class/graphics/fb*; do
        [ -d "$fb_dir" ] || continue
        fb_name=$(cat "$fb_dir/name" 2>/dev/null || echo "unknown")
        fb_res=""
        if [ -f "$fb_dir/virtual_size" ]; then
            fb_res=$(cat "$fb_dir/virtual_size" 2>/dev/null || echo "?")
        fi
        fb_bpp=""
        if [ -f "$fb_dir/bits_per_pixel" ]; then
            fb_bpp=$(cat "$fb_dir/bits_per_pixel" 2>/dev/null || echo "?")
        fi
        info "  $(basename "$fb_dir"): ${fb_name}  ${fb_res}  ${fb_bpp}bpp"
    done
else
    fail "${FB_DEV} not found"
fi
echo

# =====================================================================
# [5] Pi model check
# =====================================================================

echo "[5] Pi model"
if [ -f /proc/device-tree/model ]; then
    model=$(tr -d '\0' < /proc/device-tree/model)
    info "Model: ${model}"
    if echo "$model" | grep -qi 'Pi 5'; then
        fail "Pi 5 detected — MMIO GPIO driver does NOT support RP1"
    else
        pass "Not a Pi 5 — BCM283x MMIO GPIO is supported"
    fi
else
    warn "Cannot determine Pi model"
fi
echo

# =====================================================================
# [6] Systemd service
# =====================================================================

echo "[6] Systemd service"
UNIT=ili9481-fb.service
if systemctl list-unit-files | grep -q "$UNIT"; then
    pass "Unit ${UNIT} is installed"
    state=$(systemctl is-active "$UNIT" 2>/dev/null || true)
    enabled=$(systemctl is-enabled "$UNIT" 2>/dev/null || true)
    info "  active: ${state}   enabled: ${enabled}"
    if [ "$state" = "active" ]; then
        pass "Daemon is currently running"
        pid=$(systemctl show -p MainPID --value "$UNIT" 2>/dev/null || echo "?")
        info "  PID: ${pid}"
    else
        fail "Daemon is not running (state: ${state})"
    fi
else
    warn "Systemd unit ${UNIT} not installed (not fatal if running manually)"
fi
echo

# =====================================================================
# [7] Recent daemon log
# =====================================================================

echo "[7] Recent daemon log (last 20 lines)"
if journalctl -u "$UNIT" -n 20 --no-pager 2>/dev/null; then
    :
else
    info "  (no journal entries — daemon may not have been started via systemd)"
fi
echo

# =====================================================================
# [8] GPIO pin state (quick snapshot)
# =====================================================================

echo "[8] GPIO pin state snapshot"
if command -v pinctrl >/dev/null 2>&1; then
    # Raspberry Pi OS Bookworm+ has 'pinctrl'
    info "Control pins (RST=25 CS=8 DC=24 WR=23 RD=18):"
    for pin in 25 8 24 23 18; do
        state=$(pinctrl get "$pin" 2>/dev/null || echo "N/A")
        printf "    GPIO %-2d : %s\n" "$pin" "$state"
    done
    info "Data pins (DB0-DB7 = GPIO 9,11,10,22,27,17,4,3):"
    for pin in 9 11 10 22 27 17 4 3; do
        state=$(pinctrl get "$pin" 2>/dev/null || echo "N/A")
        printf "    GPIO %-2d : %s\n" "$pin" "$state"
    done
elif [ -d /sys/class/gpio ]; then
    info "pinctrl not available — checking sysfs"
    for pin in 25 8 24 23 18 9 11 10 22 27 17 4 3; do
        if [ -d "/sys/class/gpio/gpio${pin}" ]; then
            dir=$(cat "/sys/class/gpio/gpio${pin}/direction" 2>/dev/null || echo "?")
            val=$(cat "/sys/class/gpio/gpio${pin}/value" 2>/dev/null || echo "?")
            printf "    GPIO %-2d : dir=%s val=%s\n" "$pin" "$dir" "$val"
        fi
    done
else
    warn "Cannot inspect GPIO state (no pinctrl or sysfs)"
fi
echo

# =====================================================================
# [9] Touch (optional)
# =====================================================================

echo "[9] Touch"
if [ -f /proc/bus/input/devices ] && grep -qiE 'ADS7846|XPT2046' /proc/bus/input/devices; then
    pass "Touch controller detected in input devices"
else
    info "Touch controller not detected (optional)"
fi
echo

# =====================================================================
# [10] Quick self-test suggestion
# =====================================================================

echo "[10] Suggested next steps"
if [ -x "$DAEMON" ]; then
    echo "  Run a test pattern (requires root / gpio group):"
    echo "    sudo ${DAEMON} --test-pattern"
    echo ""
    echo "  Run a GPIO probe (toggle pins for multimeter):"
    echo "    sudo ${DAEMON} --gpio-probe"
fi
echo

# =====================================================================
# Summary
# =====================================================================

echo "=== Diagnostics Complete ==="
echo -e "Passes: ${GRN}${PASSES}${RST}   Fails: ${RED}${FAILS}${RST}   Warnings: ${YEL}${WARNS}${RST}"

if [ "$FAILS" -gt 0 ]; then
    exit 1
fi
