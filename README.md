# Inland TFT35 / MPI3501 Display Driver for Raspberry Pi

Configuration and installer for the **Inland TFT35" Touch Shield**
(MicroCenter) and compatible **MPI3501 / Waveshare 3.5" LCD (A)** clone
displays on Raspberry Pi.

> **No custom kernel module is needed.** This repository uses the built-in
> `piscreen` device-tree overlay and `fb_ili9486` (fbtft) driver that ship
> with stock Raspberry Pi OS.

## Hardware

The Inland TFT35 is a 480×320 ILI9486 SPI LCD with an XPT2046 resistive
touch controller. The LCD is driven through **74HC595 shift registers** —
the Pi never communicates directly with the ILI9486 controller.

| Component | Controller                   | Interface                            |
| --------- | ---------------------------- | ------------------------------------ |
| Display   | ILI9486                      | SPI0 CE0 via 74HC595 shift registers |
| Touch     | XPT2046 (ADS7846-compatible) | SPI0 CE1                             |

### Pin Mapping (40-pin header)

| Signal    | RPi GPIO | Physical Pin | Notes                        |
| --------- | -------- | ------------ | ---------------------------- |
| SPI MOSI  | GPIO 10  | 19           | Data to display + touch      |
| SPI MISO  | GPIO 9   | 21           | Touch data back to Pi        |
| SPI SCLK  | GPIO 11  | 23           | SPI clock                    |
| SPI CE0   | GPIO 8   | 24           | Display chip select          |
| SPI CE1   | GPIO 7   | 26           | Touch chip select            |
| DC        | GPIO 24  | 18           | Data/Command select          |
| RST       | GPIO 25  | 22           | Display reset                |
| Touch IRQ | GPIO 17  | 11           | Touch interrupt (active low) |
| LED       | GPIO 22  | 15           | Backlight enable             |
| 5V        | —        | 2            | Power                        |
| GND       | —        | 6            | Ground                       |

> **Warning:** The old `ili9481` custom driver in this repository used
> incorrect GPIO pins (DC=GPIO22, RST=GPIO27). The correct pins for this
> hardware are DC=GPIO24, RST=GPIO25, matching the `piscreen` overlay.

## Supported Boards

| Board                | Status      |
| -------------------- | ----------- |
| Raspberry Pi 3B/3B+  | ✅ Tested   |
| Raspberry Pi 4B      | ✅ Expected |
| Raspberry Pi Zero 2W | ✅ Expected |
| Raspberry Pi 5       | ⚠️ Untested |

**OS requirement:** Raspberry Pi OS Bookworm or Trixie (with `piscreen.dtbo`
in the overlays directory).

## Important: Wayland vs X11

The fbtft driver creates a **legacy framebuffer** (`/dev/fbN`), not a
DRM/KMS device. This has critical implications:

- **Wayland compositors (labwc, wayfire, sway) will NOT work** — they
  require DRM devices.
- **X11 with the fbdev driver works** — this is what the installer
  configures.
- **The installer automatically switches from Wayland to X11** via
  `raspi-config` if Wayland is detected.
- **HDMI output is disabled** while the SPI display is active (because
  `vc4-kms-v3d` must be commented out for fbtft).

If you need HDMI back, run `sudo ./uninstall.sh` — it restores
`vc4-kms-v3d` and re-enables HDMI.

## Installation

```bash
git clone https://github.com/kyleweishaupt/ILI9481-driver.git
cd ILI9481-driver
sudo ./install.sh
sudo reboot
```

### Options

| Option           | Default  | Description                                      |
| ---------------- | -------- | ------------------------------------------------ |
| `--speed=HZ`     | 16000000 | SPI clock frequency (safe: 16 MHz, max: ~32 MHz) |
| `--rotate=DEG`   | 270      | Display rotation (0, 90, 180, 270)               |
| `--fps=N`        | 30       | Framerate hint                                   |
| `--no-touch`     | —        | Skip touchscreen configuration                   |
| `--overlay=NAME` | piscreen | Overlay name (fallback: waveshare35a)            |

Example with custom options:

```bash
sudo ./install.sh --speed=24000000 --rotate=90
```

### What the installer does

1. **Cleans old artifacts** from any previous `ili9481` DKMS driver
2. **Removes fbtft blacklists** from all of `/etc/modprobe.d/` and
   **rebuilds initramfs** (cached blacklists cause white screens!)
3. **Verifies** `piscreen.dtbo` overlay and `fb_ili9486` kernel module
4. **Configures `/boot/firmware/config.txt`:**
   - Enables SPI (`dtparam=spi=on`)
   - Comments out `vc4-kms-v3d` (fbtft needs legacy framebuffers)
   - Comments out `display_auto_detect` (prevents overlay conflicts)
   - Ensures `disable_fw_kms_setup=1`
   - Ensures `[all]` section exists for model-independent config
   - Adds `dtoverlay=piscreen,speed=...,rotate=...,fps=...`
5. **Cleans `/boot/firmware/cmdline.txt`** (removes `splash`, stale `fbcon=map:`)
6. **Switches from Wayland to X11** via `raspi-config` (fbtft requires X11)
7. **Creates a systemd service** (`inland-tft35-display.service`) that at
   boot finds the fbtft framebuffer, rebinds fbcon, updates X11 config
8. **Installs `xserver-xorg-video-fbdev`** + creates X11 config
9. **Installs `xserver-xorg-input-evdev`** + creates touch calibration config
   with rotation-appropriate calibration matrix + udev rule

## Uninstallation

```bash
sudo ./uninstall.sh
sudo reboot
```

This reverses all changes: removes the systemd service, X11/touch configs,
udev rules, and boot config entries. It re-enables `vc4-kms-v3d` and
`display_auto_detect` for HDMI output.

To restore Wayland after uninstalling:

```bash
sudo raspi-config   # → Advanced Options → Wayland → labwc (W2)
```

## Testing

```bash
sudo ./scripts/test-display.sh            # Run all diagnostic checks
sudo ./scripts/test-display.sh --pattern  # Also paint RGBW test bars
```

The test script checks:

- fbtft blacklists in `/etc/modprobe.d/`
- Kernel module availability
- fbtft module loaded
- Framebuffer device exists with correct name
- `config.txt` overlay, vc4, display_auto_detect, SPI settings
- Display backend (Wayland vs X11)
- ADS7846 touch input device
- fbcon mapping and vtconsole binding
- systemd service status

### Manual verification

```bash
# Module loaded?
lsmod | grep fb_ili9486

# Framebuffer exists?
ls /dev/fb*

# Driver messages?
dmesg | grep -i 'fbtft\|ili9486'

# Touch device?
cat /proc/bus/input/devices | grep -A5 ADS7846

# Systemd service?
sudo journalctl -u inland-tft35-display.service
```

## Touch Calibration

The installer sets a default calibration matrix based on the `--rotate`
value. If touch coordinates are misaligned:

```bash
sudo apt-get install -y xinput-calibrator
DISPLAY=:0 xinput_calibrator
```

Then update the matrix in `/etc/X11/xorg.conf.d/99-touch-calibration.conf`.

### Calibration matrices by rotation

| Rotation | Matrix                |
| -------- | --------------------- |
| 0°       | `1 0 0 0 1 0 0 0 1`   |
| 90°      | `0 1 0 -1 0 1 0 0 1`  |
| 180°     | `-1 0 1 0 -1 1 0 0 1` |
| 270°     | `0 -1 1 1 0 0 0 0 1`  |

## Troubleshooting

| Symptom                   | Cause                                             | Fix                                                                           |
| ------------------------- | ------------------------------------------------- | ----------------------------------------------------------------------------- |
| White/blank screen        | fbtft blacklisted (cached in initramfs)           | `sudo rm /etc/modprobe.d/*fbtft*; sudo update-initramfs -u; sudo reboot`      |
| White/blank screen        | Wayland active (no DRM device for labwc)          | `sudo raspi-config` → Advanced → Wayland → X11; or re-run `sudo ./install.sh` |
| White/blank screen        | `vc4-kms-v3d` still active                        | Re-run `sudo ./install.sh`                                                    |
| White/blank screen        | `display_auto_detect` loading conflicting overlay | Re-run `sudo ./install.sh` (it disables auto-detect)                          |
| White/blank screen        | Wrong overlay                                     | Try `sudo ./install.sh --overlay=waveshare35a`                                |
| No framebuffer device     | Overlay not loaded                                | Check `config.txt` has `dtoverlay=piscreen` under `[all]`; reboot             |
| Console on HDMI not SPI   | fbcon not rebound                                 | `systemctl status inland-tft35-display.service`                               |
| Touch not working         | Wiring or overlay issue                           | Check IRQ=GPIO17, CE1 wiring                                                  |
| Touch coordinates wrong   | Needs calibration                                 | Run `xinput_calibrator` — see Touch Calibration above                         |
| Slow/laggy display        | SPI speed too high                                | `sudo ./install.sh --speed=12000000`                                          |
| `fb_ili9486` not in lsmod | Module not in kernel                              | `modinfo fb_ili9486` — if missing, kernel may not have fbtft                  |
| Desktop doesn't appear    | xserver-xorg-video-fbdev missing                  | `sudo apt-get install xserver-xorg-video-fbdev`                               |
| Service failed            | Framebuffer not created                           | `sudo journalctl -u inland-tft35-display.service`                             |

### Nuclear option (if nothing works)

If the display is still white after running `install.sh` and rebooting:

```bash
# 1. Check for ANY blacklists
grep -r 'blacklist.*fbtft\|blacklist.*fb_ili9486' /etc/modprobe.d/

# 2. Remove them ALL
sudo rm -f /etc/modprobe.d/*blacklist*fbtft* /etc/modprobe.d/ili9481*

# 3. Rebuild initramfs (CRITICAL — cached blacklists cause white screens)
sudo update-initramfs -u

# 4. Verify config.txt (should show piscreen overlay, vc4 commented out)
cat /boot/firmware/config.txt | grep -E 'piscreen|vc4|display_auto|spi'

# 5. Check display backend
raspi-config nonint get_wayland  # 0=Wayland, 1=X11

# 6. Reboot
sudo reboot

# 7. After reboot, run diagnostics
sudo ./scripts/test-display.sh
```

## Migrating from the old ili9481 driver

If you previously used the custom `ili9481` kernel module from this
repository:

1. The installer **automatically cleans up** old DKMS modules, overlays,
   blacklists, systemd services, and config entries
2. Simply run `sudo ./install.sh` — it handles the full migration
3. The old driver used incorrect GPIO pins (DC=22, RST=27) and required
   a custom kernel module. The new setup uses the correct pins (DC=24,
   RST=25) via the built-in `piscreen` overlay
4. **The old installer blacklisted fbtft** — the new installer removes
   the blacklist AND rebuilds initramfs to clear the cached version

## Repository Structure

```
├── install.sh              # Configuration installer
├── uninstall.sh            # Configuration uninstaller
├── scripts/
│   └── test-display.sh     # Display/touch diagnostic script
├── .github/
│   └── workflows/
│       └── lint.yml        # ShellCheck CI
└── README.md               # This file
```

## How it works

This setup relies entirely on drivers and overlays already built into
the Raspberry Pi OS kernel:

- **`piscreen` overlay**: Configures SPI0 with the ILI9486 fbtft driver
  and ADS7846 touch controller using the correct GPIO pins for MPI3501
  hardware (RST=25, DC=24, LED=22, IRQ=17)
- **`fb_ili9486` module**: Part of the fbtft staging driver tree, handles
  the ILI9486 initialization sequence and SPI framebuffer updates
- **`ads7846` module**: Standard kernel touchscreen driver for XPT2046

The `vc4-kms-v3d` overlay must be disabled because fbtft creates a legacy
framebuffer device (`/dev/fbN`). Wayland compositors require DRM/KMS
devices and will crash without one, so the installer switches to X11
with the `fbdev` driver to render on the fbtft framebuffer.

## License

This project is licensed under **GPL-2.0-only**. See the
[SPDX identifier](https://spdx.org/licenses/GPL-2.0-only.html) in each
source file.
