#!/bin/bash
# setup-onscreen-keyboard.sh — Install and configure an on-screen keyboard
#
# Installs 'onboard' (preferred) with auto-show on text input focus,
# and configures it for a small TFT display (480×320).
#
# Usage: sudo ./scripts/setup-onscreen-keyboard.sh

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: run as root:  sudo $0"
    exit 1
fi

# Determine the real user (not root)
REAL_USER="${SUDO_USER:-pi}"
REAL_HOME=$(eval echo "~$REAL_USER")

echo "════════════════════════════════════════════════════"
echo " On-Screen Keyboard Setup for ILI9481 Touchscreen"
echo "════════════════════════════════════════════════════"
echo ""

# ── 1. Install onboard ───────────────────────────────
echo "[1/5] Installing on-screen keyboard packages..."
apt-get update -qq
apt-get install -y -qq onboard onboard-common at-spi2-core dconf-cli
echo "  ✓ Installed onboard + AT-SPI accessibility bridge"

# ── 2. Configure onboard for small screen ────────────
echo ""
echo "[2/5] Configuring onboard for 480×320 display..."

# Use dconf to configure onboard settings for the real user
# Run dconf as the actual user, not root
DCONF_CMD="dbus-run-session dconf"

sudo -u "$REAL_USER" bash -c "
# Ensure dconf directory exists
mkdir -p '$REAL_HOME/.config/dconf'

# Write onboard settings via dconf
$DCONF_CMD write /org/onboard/auto-show/enabled true
$DCONF_CMD write /org/onboard/auto-show/widget-clearance \"[25.0, 55.0, 25.0, 40.0]\"

# Use the compact 'Phone' layout which fits small screens
$DCONF_CMD write /org/onboard/layout \"'Phone'\"

# Theme: dark is better on a small TFT
$DCONF_CMD write /org/onboard/theme \"'Droid'\"

# Window settings for a small screen
$DCONF_CMD write /org/onboard/window/docking/enabled true
$DCONF_CMD write /org/onboard/window/docking/edge \"'bottom'\"
$DCONF_CMD write /org/onboard/window/force-to-top true
$DCONF_CMD write /org/onboard/window/window-state-sticky true

# Keep keyboard transparent when not being used
$DCONF_CMD write /org/onboard/window/transparency 30.0
$DCONF_CMD write /org/onboard/window/inactive-transparency 50.0
$DCONF_CMD write /org/onboard/window/inactive-transparency-delay 3.0
$DCONF_CMD write /org/onboard/window/enable-inactive-transparency true

# Icon in the system tray for manual show/hide
$DCONF_CMD write /org/onboard/icon-palette/in-use false
$DCONF_CMD write /org/onboard/status-icon-provider \"'GtkStatusIcon'\"
$DCONF_CMD write /org/onboard/show-status-icon true

# Start minimized (auto-show will pop it up when needed)
$DCONF_CMD write /org/onboard/start-minimized true

# Enable word suggestions / auto-complete
$DCONF_CMD write /org/onboard/typing-helpers/auto-capitalization true
" 2>/dev/null || echo "  (dconf write partially failed — settings may need manual adjustment)"

echo "  ✓ Configured compact layout for small screen"

# ── 3. Enable accessibility (required for auto-show) ─
echo ""
echo "[3/5] Enabling accessibility support..."

# AT-SPI is needed for onboard to detect when a text field is focused
# and automatically show the keyboard

# Enable accessibility in the user's profile
PROFILE_FILE="$REAL_HOME/.profile"
if ! grep -q "ACCESSIBILITY_ENABLED" "$PROFILE_FILE" 2>/dev/null; then
    cat >> "$PROFILE_FILE" << 'EOF'

# Enable accessibility for on-screen keyboard auto-show
export GTK_MODULES=gail:atk-bridge
export QT_ACCESSIBILITY=1
export ACCESSIBILITY_ENABLED=1
EOF
    echo "  ✓ Added accessibility environment variables to .profile"
else
    echo "  Accessibility variables already in .profile"
fi

# Also add to .xsessionrc for X11 session
XSESSION_FILE="$REAL_HOME/.xsessionrc"
if ! grep -q "ACCESSIBILITY_ENABLED" "$XSESSION_FILE" 2>/dev/null; then
    cat >> "$XSESSION_FILE" << 'EOF'

# Enable accessibility for on-screen keyboard auto-show
export GTK_MODULES=gail:atk-bridge
export QT_ACCESSIBILITY=1
export ACCESSIBILITY_ENABLED=1
EOF
    chown "$REAL_USER:$REAL_USER" "$XSESSION_FILE"
    echo "  ✓ Added accessibility to .xsessionrc"
else
    echo "  Already configured in .xsessionrc"
fi

# Enable at-spi2 accessibility bus
if [ -f /etc/xdg/autostart/at-spi-dbus-bus.desktop ]; then
    # Make sure it's not disabled
    sed -i 's/^X-GNOME-Autostart-enabled=false/X-GNOME-Autostart-enabled=true/' \
        /etc/xdg/autostart/at-spi-dbus-bus.desktop 2>/dev/null || true
fi

echo "  ✓ AT-SPI accessibility bridge configured"

# ── 4. Auto-start onboard on login ───────────────────
echo ""
echo "[4/5] Setting up onboard auto-start..."

AUTOSTART_DIR="$REAL_HOME/.config/autostart"
mkdir -p "$AUTOSTART_DIR"

cat > "$AUTOSTART_DIR/onboard-autostart.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Name=Onboard On-Screen Keyboard
Comment=On-screen keyboard for touchscreen use
Exec=onboard
Icon=onboard
Terminal=false
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=3
EOF
chown -R "$REAL_USER:$REAL_USER" "$AUTOSTART_DIR"

echo "  ✓ Onboard will auto-start with desktop session"

# ── 5. Create toggle script ──────────────────────────
echo ""
echo "[5/5] Installing keyboard toggle script..."

cat > /usr/local/bin/toggle-keyboard << 'SCRIPT'
#!/bin/bash
# Toggle the on-screen keyboard visibility
# Can be bound to a panel button or a hardware key

if pgrep -x onboard > /dev/null; then
    # onboard is running — use dbus to toggle visibility
    dbus-send --type=method_call --dest=org.onboard.Onboard \
        /org/onboard/Onboard/Keyboard \
        org.onboard.Onboard.Keyboard.ToggleVisible 2>/dev/null \
    || {
        # Fallback: kill and restart
        pkill onboard
        sleep 0.5
        onboard &
    }
else
    # Not running — start it
    onboard &
fi
SCRIPT
chmod +x /usr/local/bin/toggle-keyboard

echo "  ✓ Installed /usr/local/bin/toggle-keyboard"

echo ""
echo "════════════════════════════════════════════════════"
echo " On-Screen Keyboard Setup Complete!"
echo ""
echo " Features:"
echo "   • Auto-shows when tapping text input fields"
echo "   • Docks to bottom of screen (compact phone layout)"
echo "   • Becomes transparent when inactive"
echo "   • System tray icon for manual show/hide"
echo ""
echo " Commands:"
echo "   Toggle:  toggle-keyboard"
echo "   Start:   onboard &"
echo "   Stop:    pkill onboard"
echo ""
echo " A logout/login (or reboot) is needed for"
echo " accessibility and auto-start to take effect."
echo "════════════════════════════════════════════════════"
