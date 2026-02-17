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
2. Download the **ili9481-arm64-rpi-6.6.y** artifact (zip file)
3. Copy the zip to your Raspberry Pi and run:

```bash
unzip ili9481-arm64-rpi-6.6.y.zip
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
dtoverlay=ili9481,speed=16000000,rotate=90,dc=22,reset=27
```

| Parameter | Default  | Description                        |
| --------- | -------- | ---------------------------------- |
| `speed`   | 16000000 | SPI clock frequency in Hz          |
| `rotate`  | 0        | Display rotation (0, 90, 180, 270) |
| `dc`      | 22       | GPIO number for Data/Command pin   |
| `reset`   | 27       | GPIO number for Reset pin          |

### Touchscreen (XPT2046)

If your display includes a resistive touch panel driven by an XPT2046
controller on SPI0 CE1, uncomment `fragment@3` in `ili9481-overlay.dts`
or add a separate overlay. A standalone touch overlay is provided at
[`docs/xpt2046-overlay.dts`](docs/xpt2046-overlay.dts) for reference.

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
| 0°       | 0x48   | 320 × 480 (portrait)  |
| 90°      | 0x28   | 480 × 320 (landscape) |
| 180°     | 0x88   | 320 × 480 (portrait)  |
| 270°     | 0xE8   | 480 × 320 (landscape) |

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

## CI / GitHub Actions

Every push and pull request triggers a cross-compilation build via
GitHub Actions. The workflow:

1. Clones the Raspberry Pi kernel (`rpi-6.6.y` by default)
2. Cross-compiles the `.ko` module and `.dtbo` overlay for arm64
3. Uploads build artifacts (downloadable from the Actions tab)

Manual dispatch allows selecting `rpi-6.6.y` or `rpi-6.12.y`. See
[`.github/workflows/build.yml`](.github/workflows/build.yml) for details.

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

## Repository Structure

```
├── ili9481.c               # Kernel module source (DRM/KMS driver)
├── ili9481-overlay.dts     # Device Tree overlay source
├── Makefile                # Build system (module + overlay + install)
├── Kconfig                 # Kernel config entry
├── dkms.conf               # DKMS configuration
├── install.sh              # One-command installer for pre-built artifacts
├── scripts/
│   └── test-display.sh     # Display test script
├── docs/
│   └── xpt2046-overlay.dts # Standalone touchscreen overlay example
├── .github/
│   └── workflows/
│       └── build.yml       # CI cross-compilation workflow
└── README.md               # This file
```

## Troubleshooting

| Symptom                                     | Possible Cause                       | Fix                                                                        |
| ------------------------------------------- | ------------------------------------ | -------------------------------------------------------------------------- |
| White/blank screen                          | Wrong GPIO polarity or SPI speed     | Ensure reset-gpios uses active-low flag; lower `speed` to 16 MHz or less   |
| White/blank screen after install            | Stale/missing .dtbo overlay          | Re-run `sudo ./install.sh` to recompile overlays from .dts sources         |
| `modprobe: FATAL: Module ili9481 not found` | Module not installed or wrong kernel | Run `sudo make install` or `sudo make install-dkms`                        |
| Colors inverted                             | Missing inversion command            | Driver includes `ENTER_INVERT_MODE` by default; check your panel datasheet |
| `No such device` on `/dev/fb0`              | Overlay not loaded                   | Verify `dtoverlay=ili9481` is in `/boot/config.txt` and reboot             |
| Garbled display                             | Incorrect rotation                   | Try `rotate=0` (default) first                                             |
| Touch not working                           | XPT2046 overlay not loaded           | Verify `dtoverlay=xpt2046` is in `/boot/config.txt`; check wiring          |
| Touch coordinates misaligned                | Needs calibration                    | Run `DISPLAY=:0 xinput_calibrator` and update CalibrationMatrix            |
| Desktop appears on HDMI, not SPI display    | X11 not configured for ili9481       | Re-run install script (creates `/etc/X11/xorg.conf.d/99-ili9481.conf`)     |
| Mouse/keyboard laggy                        | SPI speed too high causing CPU load  | Lower `speed` parameter in `/boot/config.txt` overlay line                 |

## License

This driver is licensed under **GPL-2.0-only**. See the
[SPDX identifier](https://spdx.org/licenses/GPL-2.0-only.html) in each
source file.
