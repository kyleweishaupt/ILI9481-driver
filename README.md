# ILI9481 DRM/KMS Display Driver

A native Linux DRM/KMS driver for SPI-connected display panels using the
**Ilitek ILI9481** controller (320×480, 16-bit RGB565). This is an
out-of-tree replacement for the removed `fbtft` driver, targeting
Raspberry Pi but usable on any Linux SPI host with kernel ≥ 6.2.

## Features

- Full DRM/KMS device (`/dev/dri/card*`) — works with Wayland, X11, Plymouth
- Legacy fbdev emulation (`/dev/fb*`) via `drm_fbdev_generic`
- Hardware rotation (0°, 90°, 180°, 270°)
- Optional backlight integration
- DKMS support — module rebuilds automatically on kernel upgrades
- Device Tree overlay with runtime parameter overrides

## Supported Hardware

| Board                 | Status                              |
| --------------------- | ----------------------------------- |
| Raspberry Pi 5        | ✅ Tested                           |
| Raspberry Pi 4B       | ✅ Tested                           |
| Raspberry Pi 3B+      | ✅ Tested                           |
| Raspberry Pi Zero 2W  | ✅ Expected to work                 |
| Other Linux SPI hosts | Should work with correct DT binding |

**Kernel requirement:** ≥ 6.2 (uses `drm_gem_dma_helper.h` and
`DRM_MIPI_DBI_SIMPLE_DISPLAY_PIPE_FUNCS`)

## Install (pre-built — no compiling needed)

The easiest way to install. Pre-built drivers for Raspberry Pi (arm64) are
available from the
[GitHub Actions](https://github.com/kyleweishaupt/ILI9481-driver/actions)
build artifacts.

1. Go to the latest successful **Build ILI9481 Kernel Module** workflow run
2. Download the **ili9481-arm64-rpi-6.12.y** artifact (zip file)
3. Copy the zip to your Raspberry Pi and run:

```bash
unzip ili9481-arm64-rpi-6.12.y.zip
sudo bash install.sh
sudo reboot
```

The install script copies the kernel module and device-tree overlay to the
correct locations and adds `dtoverlay=ili9481` to `/boot/config.txt`
automatically.

> **Note:** The pre-built module is compiled against a specific kernel
> version. If your running kernel doesn't match, you may need to build
> from source instead (see Quick Start below) or use DKMS.

## Wiring

Default pin assignment (matches the included device-tree overlay):

| Signal    | RPi GPIO | Physical Pin | Display Pin        |
| --------- | -------- | ------------ | ------------------ |
| SPI MOSI  | GPIO 10  | 19           | SDA / SDI          |
| SPI SCLK  | GPIO 11  | 23           | SCL / SCK          |
| SPI CE0   | GPIO 8   | 24           | CS                 |
| DC        | GPIO 22  | 15           | DC / RS            |
| RESET     | GPIO 27  | 13           | RST                |
| GND       | —        | 6            | GND                |
| 3.3 V     | —        | 1            | VCC                |
| Backlight | —        | —            | LED (3.3 V or PWM) |

> **Tip:** If your panel has a separate **LED** pin for the backlight,
> connect it to 3.3 V for always-on, or to a GPIO for software control
> (add a `backlight` phandle in the device-tree).

## Quick Start (on-device build)

```bash
# Install build dependencies
sudo apt-get install -y raspberrypi-kernel-headers build-essential \
  device-tree-compiler git

# Clone the repository
git clone https://github.com/kyleweishaupt/ILI9481-driver.git
cd ILI9481-driver

# Build the module and device-tree overlay
make

# Install (copies ili9481.ko + ili9481.dtbo)
sudo make install

# Enable the overlay
echo "dtoverlay=ili9481" | sudo tee -a /boot/config.txt

# Reboot
sudo reboot
```

After reboot the display should show the kernel console. Verify with:

```bash
dmesg | grep ili9481
ls /dev/dri/card*
cat /sys/class/drm/card*/status
```

## Cross-Compilation (e.g. from x86 host)

```bash
# Install cross-compiler
sudo apt-get install -y gcc-aarch64-linux-gnu device-tree-compiler

# Point KDIR at a prepared Raspberry Pi kernel tree
make KDIR=~/rpi-kernel ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
```

The resulting `ili9481.ko` and `ili9481.dtbo` can be copied to the Pi.

## DKMS Installation

DKMS automatically rebuilds the module when the kernel is upgraded:

```bash
# Install DKMS
sudo apt-get install -y dkms

# Register, build, and install via DKMS
sudo make install-dkms

# To remove later:
sudo make uninstall-dkms
```

## Device Tree Configuration

### Basic (add to `/boot/config.txt`)

```ini
dtoverlay=ili9481
```

### With Optional Parameters

```ini
dtoverlay=ili9481,speed=12000000,rotate=90,dc=22,reset=27
```

| Parameter | Default  | Description                        |
| --------- | -------- | ---------------------------------- |
| `speed`   | 12000000 | SPI clock frequency in Hz          |
| `rotate`  | 0        | Display rotation (0, 90, 180, 270) |
| `dc`      | 22       | GPIO number for Data/Command pin   |
| `reset`   | 27       | GPIO number for Reset pin          |

### Touchscreen (XPT2046)

If your display includes a resistive touch panel driven by an XPT2046
controller on SPI0 CE1, uncomment `fragment@3` in `ili9481-overlay.dts`
or add a separate overlay. A standalone touch overlay is provided at
[`xpt2046-overlay.dts`](xpt2046-overlay.dts) for reference.

The default touch wiring assumes:

| Signal  | GPIO    | Physical Pin |
| ------- | ------- | ------------ |
| IRQ     | GPIO 25 | 22           |
| SPI CE1 | GPIO 7  | 26           |

## Rotation

Set the `rotation` device-tree property (0, 90, 180, 270). The driver
translates this to the ILI9481 MADCTL register:

| Rotation | MADCTL | Effective Resolution  |
| -------- | ------ | --------------------- |
| 0°       | 0x0A   | 320 × 480 (portrait)  |
| 90°      | 0x28   | 480 × 320 (landscape) |
| 180°     | 0x09   | 320 × 480 (portrait)  |
| 270°     | 0x2B   | 480 × 320 (landscape) |

## Testing & Validation

After installation, verify the driver is working:

```bash
# Check kernel log
dmesg | grep -i ili9481

# List DRM devices
ls -l /dev/dri/

# Show modes (install libdrm-tests if needed)
sudo apt-get install -y libdrm-tests
modetest -M ili9481

# Display a test pattern (fill screen red via fbdev)
sudo apt-get install -y fbset
cat /dev/urandom | head -c $((320*480*2)) > /dev/fb0

# Or use the included test script
sudo ./scripts/test-display.sh
```

## Migrating from fbtft

If you previously used the `fbtft_device` or `fb_ili9481` kernel module:

1. Remove any `fbtft`-related overlays or `dtoverlay=` lines from
   `/boot/config.txt`
2. Blacklist the old module: `echo "blacklist fb_ili9481" | sudo tee /etc/modprobe.d/blacklist-fbtft.conf`
3. Install this driver (see Quick Start above)
4. Applications that used `/dev/fb0` will continue to work via the
   DRM fbdev compatibility layer
5. For modern applications, use the DRM/KMS device directly
   (`/dev/dri/card*`)

## Uninstalling

A dedicated uninstall script cleanly reverses all changes made by the
installer:

```bash
sudo ./uninstall.sh
sudo reboot
```

This removes the DKMS module, device-tree overlays, boot config entries,
X11 display configuration, touchscreen settings, and the systemd helper
service. SPI and DRM/KMS settings are preserved since other hardware may
depend on them.

## Repository Structure

```
├── ili9481.c               # Kernel module source (DRM/KMS driver)
├── ili9481-overlay.dts     # Device Tree overlay source
├── xpt2046-overlay.dts     # XPT2046 touchscreen overlay source
├── Makefile                # Build system (module + overlay + install)
├── Kconfig                 # Kernel config entry
├── dkms.conf               # DKMS configuration
├── install.sh              # One-command installer
├── uninstall.sh            # One-command uninstaller
├── scripts/
│   └── test-display.sh     # Display test script
└── README.md               # This file
```

## Troubleshooting

| Symptom                                     | Possible Cause                       | Fix                                                                                                                                              |
| ------------------------------------------- | ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| White/blank screen                          | Init sequence skipped (MISO float)   | Update driver to v1.1+; re-run `sudo ./install.sh` and reboot                                                                                    |
| White screen persists after update          | Old module still loaded (DKMS cache) | `sudo ./uninstall.sh && sudo ./install.sh && sudo reboot`                                                                                        |
| White/blank screen after install            | Stale/missing .dtbo overlay          | Re-run `sudo ./install.sh` to recompile overlays from .dts sources                                                                               |
| No boot logo on SPI display                 | Plymouth `splash` in cmdline.txt     | Re-run `sudo ./install.sh` (it removes `splash`; fbcon mapping is handled dynamically by `ili9481-display.service`)                              |
| Console appears on HDMI, not SPI display    | fbcon not rebound to ILI9481 fb       | Re-run `sudo ./install.sh`; verify `ili9481-display.service` is enabled and started                                                               |
| `modprobe: FATAL: Module ili9481 not found` | Module not installed or wrong kernel | Run `sudo ./install.sh` or `sudo make install-dkms`                                                                                              |
| Colors inverted                             | Panel-specific inversion behavior     | Check your panel datasheet; adjust inversion command in `ili9481.c` if needed                                                                     |
| `No such device` on `/dev/fb0`              | Overlay not loaded                   | Verify `dtoverlay=ili9481` is in `/boot/config.txt` and reboot                                                                                   |
| Garbled display                             | Incorrect rotation                   | Try `rotate=0` (default) first                                                                                                                   |
| Touch not working                           | XPT2046 overlay not loaded           | Verify `dtoverlay=xpt2046` is in `/boot/config.txt`; check wiring                                                                                |
| Touch coordinates misaligned                | Needs calibration                    | Run `DISPLAY=:0 xinput_calibrator` and update CalibrationMatrix                                                                                  |
| Desktop/Wayland on HDMI, not SPI display    | Wayland compositor using card0 (vc4) | Re-run install script; verify `WLR_DRM_DEVICES=/dev/dri/card1` in `/etc/environment.d/99-ili9481.conf` and `/etc/labwc/environment`, then reboot |
| Desktop/X11 on HDMI, not SPI display        | X11 modesetting using wrong DRM card | Re-run install script; verify `Option "kmsdev" "/dev/dri/card1"` in `/etc/X11/xorg.conf.d/99-ili9481.conf`                                       |
| Mouse/keyboard laggy                        | SPI speed too high causing CPU load  | Lower `speed` parameter in `/boot/config.txt` overlay line                                                                                       |

## License

This driver is licensed under **GPL-2.0-only**. See the
[SPDX identifier](https://spdx.org/licenses/GPL-2.0-only.html) in each
source file.
