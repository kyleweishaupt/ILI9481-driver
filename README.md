# Inland TFT35 ILI9481 — Self-Contained GPIO Parallel Driver

Linux framebuffer driver for the **Inland 3.5" TFT Touch Shield** (and compatible
Kedei-style boards) that use an **ILI9481** controller on a **16-bit 8080-parallel
GPIO bus** with 74HC245 level shifters.

## What this is

A self-contained, out-of-tree kernel module (`ili9481-gpio`) that replaces the
legacy `notro/fbtft` dependency entirely. Written from scratch for **kernel 6.12+**
using modern APIs:

| Feature           | Implementation                                  |
| ----------------- | ----------------------------------------------- |
| GPIO access       | `gpiod` descriptor API (`devm_gpiod_get_array`) |
| Framebuffer       | `fbdev` with `fb_deferred_io`                   |
| Device binding    | Platform driver via DTS `compatible`            |
| Time / scheduling | `timespec64`, standard workqueue                |
| Module lifecycle  | Single self-contained `.ko`                     |

The driver registers `/dev/fbN` and provides a standard Linux framebuffer that
works with `fbcon`, X11 (`xf86-video-fbdev`), and direct `write()` / `mmap()`.

## Target hardware

- **Display:** 320×480 TFT, ILI9481 controller
- **Interface:** 16-bit 8080 parallel over Raspberry Pi GPIO header
- **Level shifting:** 74HC245 / 74HCT245 bus transceivers (3.3 V → 5 V)
- **Touch (optional):** XPT2046 / ADS7846 over SPI
- **Board:** Raspberry Pi 3B/3B+/4B/5 with 40-pin header

## Quick start

```bash
# Clone the repository
git clone https://github.com/<user>/ILI9481-driver.git
cd ILI9481-driver

# Install (builds module, compiles overlay, configures boot)
sudo ./install.sh

# Reboot
sudo reboot
```

### Installer options

```
sudo ./install.sh [OPTIONS]

  --rotate=DEG      Display rotation: 0, 90, 180, 270 (default: 270)
  --fps=N           Framebuffer refresh rate (default: 30)
  --no-touch        Skip XPT2046/ADS7846 touch overlay
  --touch-irq=GPIO  Touch interrupt GPIO (default: 17)
```

### Uninstall

```bash
sudo ./uninstall.sh
sudo reboot
```

## Verification

After installing and rebooting:

```bash
# Module loaded?
lsmod | grep ili9481_gpio

# Framebuffer registered?
ls -l /dev/fb*
cat /sys/class/graphics/fb0/name     # should say "ili9481"

# Kernel logs
dmesg | grep -i ili9481

# Full validation suite
sudo ./scripts/test-display.sh

# Write random noise to the display
sudo dd if=/dev/urandom of=/dev/fb0 bs=307200 count=1
```

If random colour noise appears on the panel, the driver and GPIO path are working.

## GPIO pin mapping

The default mapping matches the standard Kedei / Inland wiring. Edit the
overlay in `driver/dts/inland-ili9481.dts` (or the generated DTS from
`install.sh`) if your board differs.

| Signal | GPIO (BCM) | Direction | Polarity    |
| ------ | ---------- | --------- | ----------- |
| RST    | 27         | Output    | Active-low  |
| DC/RS  | 22         | Output    | Active-high |
| WR     | 17         | Output    | Active-low  |
| DB0    | 7          | Output    | Active-high |
| DB1    | 8          | Output    | Active-high |
| DB2    | 25         | Output    | Active-high |
| DB3    | 24         | Output    | Active-high |
| DB4    | 23         | Output    | Active-high |
| DB5    | 18         | Output    | Active-high |
| DB6    | 15         | Output    | Active-high |
| DB7    | 14         | Output    | Active-high |
| DB8    | 12         | Output    | Active-high |
| DB9    | 16         | Output    | Active-high |
| DB10   | 20         | Output    | Active-high |
| DB11   | 21         | Output    | Active-high |
| DB12   | 5          | Output    | Active-high |
| DB13   | 6          | Output    | Active-high |
| DB14   | 13         | Output    | Active-high |
| DB15   | 19         | Output    | Active-high |

> **Note:** The previous overlay used GPIO 23 for both RST and DB4 — that
> conflict has been corrected. RST is now on GPIO 27 and WR (write strobe,
> which the old FBTFT overlay omitted) is on GPIO 17.

## Repository layout

```
install.sh                      # Automated installer
uninstall.sh                    # Automated uninstaller
driver/
  ili9481-gpio.h                # Register defines & init sequence table
  ili9481-gpio.c                # Kernel module source
  Makefile                      # Kbuild makefile
  dts/
    inland-ili9481.dts          # Reference device-tree overlay
scripts/
  test-display.sh               # Post-install validation
  tft-diagnose.sh               # Boot-to-desktop diagnostics
DEVICE.md                       # Hardware analysis notes
PLAN.md                         # Design rationale
```

## How it works

1. The device-tree overlay assigns GPIO pins and driver properties.
2. On boot, `ili9481-gpio.ko` is loaded and matches `compatible = "inland,ili9481-gpio"`.
3. The probe function acquires 19 GPIOs via the `gpiod` API (16 data + DC + WR + RST).
4. The ILI9481 is hardware-reset and sent an initialization register sequence.
5. A `framebuffer_alloc`'d fbdev device is registered with `fb_deferred_io`.
6. Every frame interval (`1000/fps` ms), dirty pages trigger a full-screen flush
   that bit-bangs all 153 600 pixels through the 16-bit parallel bus.
7. `fbcon` maps virtual consoles to the new framebuffer; X11 uses `fbdev` driver.

## Limitations

- Refresh rate is constrained by GPIO bit-bang speed (~5–15 FPS effective
  depending on Pi model and kernel overhead).
- Not suitable for video playback or fast animation.
- Works well for consoles, static UIs, and lightweight desktops.

## License

GPL-2.0-only — see `SPDX-License-Identifier` headers in each file.
