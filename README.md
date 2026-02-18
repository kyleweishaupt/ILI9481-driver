# Inland TFT35 ILI9481 — Self-Contained GPIO Parallel Driver

Linux framebuffer driver for the **Inland 3.5" TFT Touch Shield** (and compatible
Kedei-style boards) that use an **ILI9481** controller on a **16-bit 8080-parallel
GPIO bus** with 74HC245 level shifters.

---

## What This Board Actually Is

Although marketed as a simple "3.5-inch TFT for Raspberry Pi", this shield is
**not a DPI display, not SPI, and not DSI**. It is a **16-bit 8080-parallel TFT
shield**, electrically equivalent to the older Kedei 3.5" v1–v3 shields.

### Board components

**Display panel:**
- 3.5" 320×480 TFT, a-Si active matrix
- Controller: **ILI9481** (command-set compatible with ILI9486)
- Color depth: **RGB565** (16 bits/pixel)
- Interface: **16-bit 8080-style parallel bus**
- Backlight: always-on 3.3 V, no PWM control

**Adapter board:**
- **U1–U4: 74HC245 / 74HCT245** bus transceivers — level-shift the Pi's 3.3 V GPIO
  signals to the 5 V levels required by the LCD panel, and buffer/protect the Pi GPIO
- **U5: XPT2046 / ADS7846** resistive touch controller over SPI; on the Inland
  variant the SPI chip-select lines share pins with the parallel data bus, making
  touch support unreliable — see [Touch support](#touch-support) below
- **U6–U7:** discrete support components (decoupling caps, voltage filtering)

**GPIO header:** the shield piggybacks directly onto the Pi 40-pin header. All
display signals are delivered through GPIO bit-banging — no HDMI, no SPI
framebuffer.

### 8080 parallel bus signals

| Signal   | Function |
|----------|----------|
| DB0–DB15 | 16-bit pixel data bus |
| WR       | Write strobe (active-low; ILI9481 latches data on the rising edge) |
| RS / DC  | Register select: LOW = command, HIGH = pixel data |
| RST      | Hardware reset (active-low) |
| RD       | Read strobe — unused by this driver |
| CS       | Chip select — hardwired on this board |

ILI9481 timing requirements: **tWRL ≥ 15 ns, tWRH ≥ 15 ns** (WR pulse low and
high widths). The kernel's `ndelay(15)` call in the write path satisfies this.

---

## Why It Doesn't Work on Stock Raspberry Pi OS Trixie

Trixie (Debian 13, kernel 6.12+, 64-bit ARM64) broke compatibility with this board
on three fronts:

**1 — FBTFT removed.**  The `fbtft`, `fbtft_device`, and `fb_ili9481` kernel
modules that previously drove this class of display were removed from the Raspberry
Pi kernel after Bullseye. Without them, nothing initializes the ILI9481.

**2 — Device-tree overlays removed.**  Overlays such as `dtoverlay=piscreen`,
`dtoverlay=kedei`, and `dtoverlay=ili9481` no longer ship with Trixie. Without an
overlay, the kernel assigns no GPIO pins and registers no framebuffer.

**3 — 64-bit ABI.**  Any 32-bit ARMHF `.ko` compiled for an older kernel cannot
load into a 64-bit ARM64 kernel.

**Result:** the shield receives power but no initialization commands, so the LCD
stays white permanently.

---

## This Driver

`ili9481-gpio` is a self-contained, out-of-tree kernel module that **replaces the
legacy fbtft dependency entirely**. Written from scratch for **kernel 6.12+** using
modern Linux APIs:

| Feature           | Implementation                                   |
|-------------------|--------------------------------------------------|
| GPIO access       | `gpiod` descriptor API (`devm_gpiod_get_array`)  |
| Framebuffer       | `fbdev` with `fb_deferred_io`                    |
| Device binding    | Platform driver matched via DTS `compatible`     |
| Module lifecycle  | Single self-contained `.ko`, no fbtft dependency |

The driver registers `/dev/fbN` and provides a standard Linux framebuffer usable
with `fbcon`, X11 (`xf86-video-fbdev`), SDL, and direct `write()` / `mmap()`.

### ILI9481 initialization sequence

On probe the driver (`driver/ili9481-gpio.c:115–134`):

1. Pulses RST low 20 ms → high 20 ms (hardware reset)
2. Sends the full initialization command sequence:
   - Software reset (0x01)
   - Sleep Out (0x11)
   - Power Control (0xD0, 0xD1, 0xD2)
   - Panel Drive (0xC0), Frame Rate (0xC5)
   - Gamma (0xC8, 12 bytes)
   - Pixel Format (0x3A, 0x55 = RGB565)
   - Display On (0x29)
3. Writes MADCTL (0x36) for the selected rotation
4. Registers the framebuffer

The complete init table is in `driver/ili9481-gpio.h:93–124`.

---

## Target Hardware

- **Display:** 320×480 TFT, ILI9481 controller, RGB565
- **Interface:** 16-bit 8080 parallel over Raspberry Pi GPIO header
- **Level shifting:** 74HC245 / 74HCT245 bus transceivers (3.3 V → 5 V)
- **Touch (optional):** XPT2046 / ADS7846 over SPI
- **Board:** Raspberry Pi 3B / 3B+ / 4B with 40-pin header

---

## Quick Start

```bash
git clone https://github.com/<user>/ILI9481-driver.git
cd ILI9481-driver
sudo ./install.sh
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

---

## Verification

After installing and rebooting:

```bash
# Module loaded?
lsmod | grep ili9481_gpio

# Framebuffer registered?
ls -l /dev/fb*
cat /sys/class/graphics/fb0/name     # should print "ili9481"

# Kernel messages
dmesg | grep -i ili9481

# Full validation suite
sudo ./scripts/test-display.sh

# Write random noise to the display
sudo dd if=/dev/urandom of=/dev/fb0 bs=307200 count=1
```

If random colour noise appears on the panel, the driver and GPIO path are working.

---

## GPIO Pin Mapping

The mapping matches the standard Kedei / Inland wiring verified against the board
hardware. Edit `driver/dts/inland-ili9481.dts` (or the generated DTS produced by
`install.sh`) if your board differs.

| Signal | GPIO (BCM) | Direction | Polarity    |
|--------|------------|-----------|-------------|
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

> **Note:** The previous FBTFT overlay used GPIO 23 for both RST and DB4 — that
> conflict has been corrected. RST is now on GPIO 27 and the WR strobe (which the
> old overlay omitted entirely) is on GPIO 17.

---

## Touch Support

The XPT2046 / ADS7846 resistive touch controller communicates over SPI. `install.sh`
adds an `ads7846` kernel overlay and enables SPI when `--no-touch` is not passed.

**Hardware conflict:** GPIO 7 (DB0) is also SPI0 CE1, and GPIO 8 (DB1) is SPI0 CE0.
These pins are shared between the 16-bit parallel data bus and the SPI chip-select
outputs. On this Inland board variant the SPI signals are not cleanly routed at the
GPIO header, so **touch is unreliable**. If touch events are erratic or absent,
reinstall with `--no-touch`.

Touch calibration for X11 is written to
`/etc/X11/xorg.conf.d/99-inland-touch.conf`. The affine transformation matrix can
be tuned by re-running `install.sh --rotate=<DEG>`.

---

## Repository Layout

```
install.sh                      # Automated installer
uninstall.sh                    # Automated uninstaller
driver/
  ili9481-gpio.h                # Register defines, MADCTL values & init table
  ili9481-gpio.c                # Kernel module source
  Makefile                      # Kbuild makefile
  dts/
    inland-ili9481.dts          # Reference device-tree overlay
scripts/
  test-display.sh               # Post-install validation
  tft-diagnose.sh               # Boot-to-desktop diagnostics
```

---

## How It Works

1. `install.sh` generates a device-tree overlay from `driver/dts/inland-ili9481.dts`
   (substituting the chosen rotation and FPS), compiles it with `dtc`, and copies it
   to `/boot/firmware/overlays/`.
2. `config.txt` is updated to load `inland-ili9481-overlay` and disable KMS on boot.
3. On boot, `ili9481-gpio.ko` is loaded and matches
   `compatible = "inland,ili9481-gpio"` from the overlay.
4. The probe function acquires 19 GPIOs via the `gpiod` API
   (16 data lines + DC + WR + RST).
5. The ILI9481 is hardware-reset and sent its full initialization sequence.
6. A `framebuffer_alloc`'d fbdev device is registered with `fb_deferred_io`.
7. Every frame interval (`1000/fps` ms), dirty pages trigger a full-screen flush
   that bit-bangs all 153,600 pixels through the 16-bit parallel bus.
8. `fbcon` maps virtual consoles to the new framebuffer; X11 uses `fbdev`.

### Pixel write path

Each 16-bit pixel write (`driver/ili9481-gpio.c:64–78`):

1. Place 16-bit value on DB0–DB15 via `gpiod_set_array_value`
2. Assert WR low (gpiod logical-1 → pin LOW, active-low polarity)
3. Hold ≥ 15 ns (`ndelay(15)`)
4. De-assert WR high — rising edge latches the pixel into the ILI9481

---

## Timing & Performance

| Parameter               | Value                          |
|-------------------------|--------------------------------|
| WR pulse low (tWRL)     | ≥ 15 ns                        |
| WR pulse high (tWRH)    | ≥ 15 ns                        |
| Pixels per frame        | 153,600 (480 × 320)            |
| Bytes per frame         | 307,200 (RGB565)               |
| Target throughput       | 25–30 FPS (~7.7 MB/s)          |
| Effective FPS (typical) | 5–15 FPS (gpiod kernel overhead) |

The effective framerate falls below the target because each pixel requires multiple
kernel API calls through the `gpiod` descriptor layer. The display is well-suited
for consoles, static UIs, and lightweight desktops; it is not suitable for video or
fast animation.

---

## Limitations

- Refresh rate is constrained by GPIO bit-bang overhead through the gpiod API
  (~5–15 FPS depending on Pi model and kernel scheduling).
- Not suitable for video playback or fast animation.
- Touch is unreliable on the Inland board variant due to SPI/data-bus GPIO conflicts.
- Works well for consoles, static UIs, and lightweight desktops.
- For new projects, a SPI-based ILI9341/ILI9488 or a DSI touchscreen panel offers
  better compatibility, performance, and long-term kernel support.

---

## License

GPL-2.0-only — see `SPDX-License-Identifier` headers in each source file.
