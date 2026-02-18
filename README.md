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

| Board                | Status                                 |
| -------------------- | -------------------------------------- |
| Raspberry Pi 3B/3B+  | ✅ Tested                              |
| Raspberry Pi 4B      | ✅ Expected                            |
| Raspberry Pi Zero 2W | ✅ Expected                            |
| Raspberry Pi 5       | ⚠️ May need kernel ≥ 6.6 fbtft support |

**OS requirement:** Raspberry Pi OS Bookworm or later (with `piscreen.dtbo`
in the overlays directory).

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
2. **Verifies** the `piscreen.dtbo` overlay exists in the boot partition
3. **Configures `/boot/firmware/config.txt`:**
   - Enables SPI (`dtparam=spi=on`)
   - Comments out `vc4-kms-v3d` (fbtft needs legacy framebuffers)
   - Adds `disable_fw_kms_setup=1`
   - Adds `dtoverlay=piscreen,speed=...,rotate=...,fps=...`
4. **Cleans `/boot/firmware/cmdline.txt`** (removes `splash` and stale `fbcon=map:`)
5. **Creates a systemd service** (`inland-tft35-display.service`) that at
   boot finds the fbtft framebuffer, rebinds fbcon, and updates the X11 config
6. **Installs `xserver-xorg-video-fbdev`** and creates X11 config
   (`/etc/X11/xorg.conf.d/99-spi-display.conf`) using the `fbdev` driver
7. **Installs `xserver-xorg-input-evdev`** and creates touch config
   (`/etc/X11/xorg.conf.d/99-touch-calibration.conf`)
   with rotation-appropriate calibration matrix + udev rule

## Uninstallation

```bash
sudo ./uninstall.sh
sudo reboot
```

This reverses all changes: removes the systemd service, X11/touch configs,
udev rules, and boot config entries. It also re-enables `vc4-kms-v3d` for
HDMI output and cleans up any leftover `ili9481` DKMS artifacts.

`dtparam=spi=on` is intentionally left intact since other hardware may
depend on it.

## Testing

```bash
sudo ./scripts/test-display.sh            # Run all checks
sudo ./scripts/test-display.sh --pattern  # Also paint RGBW test bars
```

The test script checks:

- `fb_ili9486` / fbtft module loaded
- Framebuffer device exists with correct name
- Kernel log messages present
- ADS7846 touch input device registered
- fbcon mapped to the SPI display
- `config.txt` overlay correctly configured

### Manual verification

```bash
# Module loaded?
lsmod | grep fb_ili9486

# Framebuffer exists?
ls /dev/fb*

# Driver messages?
dmesg | grep ili9486

# Touch device?
cat /proc/bus/input/devices | grep -A5 ADS7846

# Touch events?
sudo apt-get install -y evtest
sudo evtest  # select ADS7846 device
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

| Symptom                   | Cause                      | Fix                                                            |
| ------------------------- | -------------------------- | -------------------------------------------------------------- |
| White/blank screen        | `vc4-kms-v3d` still active | Re-run `sudo ./install.sh` — it comments out `vc4-kms-v3d`     |
| White/blank screen        | Wrong overlay              | Try `sudo ./install.sh --overlay=waveshare35a`                 |
| No framebuffer device     | Overlay not loaded         | Check `config.txt` has `dtoverlay=piscreen`; reboot            |
| Console on HDMI not SPI   | fbcon not rebound          | `systemctl status inland-tft35-display.service`                |
| Touch not working         | Wiring or overlay issue    | Check IRQ=GPIO17, CE1 wiring; verify `piscreen` includes touch |
| Touch coordinates wrong   | Needs calibration          | Run `xinput_calibrator` — see Touch Calibration above          |
| Slow/laggy display        | SPI speed too high         | Lower speed: `sudo ./install.sh --speed=12000000`              |
| `fb_ili9486` not in lsmod | fbtft blacklisted          | Remove `/etc/modprobe.d/*blacklist*fbtft*`; reboot             |

## Migrating from the old ili9481 driver

If you previously used the custom `ili9481` kernel module from this
repository:

1. The installer **automatically cleans up** old DKMS modules, overlays,
   blacklists, systemd services, and config entries
2. Simply run `sudo ./install.sh` — it handles the full migration
3. The old driver used incorrect GPIO pins (DC=22, RST=27) and required
   a custom kernel module. The new setup uses the correct pins (DC=24,
   RST=25) via the built-in `piscreen` overlay

## Repository Structure

```
├── install.sh              # Configuration installer
├── uninstall.sh            # Configuration uninstaller
├── scripts/
│   └── test-display.sh     # Display/touch validation script
├── .github/
│   └── workflows/
│       └── lint.yml        # ShellCheck CI
└── README.md               # This file
```

## How it works

Unlike the previous approach (custom out-of-tree DRM/KMS kernel module),
this setup relies entirely on drivers and overlays already built into the
Raspberry Pi OS kernel:

- **`piscreen` overlay**: Configures SPI0 with the ILI9486 fbtft driver
  and ADS7846 touch controller using the correct GPIO pins for MPI3501
  hardware (RST=25, DC=24, LED=22, IRQ=17)
- **`fb_ili9486` module**: Part of the fbtft staging driver tree, handles
  the ILI9486 initialization sequence and SPI framebuffer updates
- **`ads7846` module**: Standard kernel touchscreen driver for XPT2046

The `vc4-kms-v3d` overlay must be disabled because fbtft creates a legacy
framebuffer device (`/dev/fbN`) which is incompatible with the DRM/KMS
graphics stack. This means GPU-accelerated HDMI output is not available
when the SPI display is active.

## License

This project is licensed under **GPL-2.0-only**. See the
[SPDX identifier](https://spdx.org/licenses/GPL-2.0-only.html) in each
source file.
