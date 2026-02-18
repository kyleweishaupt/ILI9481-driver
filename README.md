# Inland TFT35 ILI9481 — Userspace GPIO Parallel Display Driver

Userspace translation daemon for the **Inland 3.5" TFT Touch Shield** (and
compatible Kuman / MCUfriend / Banggood / Sainsmart 3.5" boards) that use an
**ILI9481** controller on a **12-bit 8080-parallel GPIO bus** through the
original **26-pin** Raspberry Pi header.

The daemon mirrors the HDMI framebuffer (`/dev/fb0`) to the TFT panel by
reading pixels, converting them to **RGB444**, and bit-banging them out over
GPIO using direct MMIO register writes.

---

## What This Board Actually Is

Although marketed as a simple "3.5-inch TFT for Raspberry Pi", this shield is
**not a DPI display, not SPI, and not DSI**. It is a **parallel MCU-style TFT
shield** designed for the original 26-pin GPIO header.

### Board family

This driver supports all boards in the following family:

- **MCUfriend RPi shields** (3.5" 320×480)
- **Banggood / Kuman 3.5" TFT shields**
- **Sainsmart / QVGA 320×480 TFT shields**
- **Inland rebrands** of the same design

These boards **all** use:

- ILI9481 or ILI9486 controller (16-bit parallel capable)
- 8080 write-only parallel bus
- 74HC245 / 74HCT245 bus transceivers
- XPT2046 / ADS7846 SPI resistive touch (some variants)
- **26-pin header only** — they do NOT use pins 27–40

### 26-pin = 12 data bits, not 16

Because the shield only occupies **pins 1–26** of the Pi header, it can
physically wire only **12 data lines** (DB0–DB11). Pins for DB12–DB15 would
require the extended 40-pin header and are **not connected**.

This means:

- The ILI9481 must be operated in **RGB444** mode (COLMOD = 0x03), not RGB565
- Each pixel is 12 bits: **R[3:0] G[3:0] B[3:0]**
- Any driver assuming 16-bit RGB565 will produce a **white screen** because
  the top 4 data bits float high

> **This is exactly why Waveshare pin maps, LCD-show scripts, old FBTFT
> overlays, and all 16-bit drivers fail on this board.**

### Board components

| Component          | Detail                                              |
| ------------------ | --------------------------------------------------- |
| **Display panel**  | 3.5" 320×480 TFT, ILI9481 controller                |
| **Color depth**    | RGB444 (12 bits/pixel) — limited by 12 wired lines  |
| **Interface**      | 12-bit 8080-style parallel bus (DB0–DB11)           |
| **Level shifting** | U1–U4: 74HC245 / 74HCT245 bus transceivers          |
| **Touch**          | U5: XPT2046 / ADS7846 (shared SPI pins, unreliable) |
| **Backlight**      | Always-on 3.3 V, no PWM control                     |

### 8080 parallel bus signals

| Signal   | Function                                               |
| -------- | ------------------------------------------------------ |
| DB0–DB11 | 12-bit pixel data bus                                  |
| WR       | Write strobe (active-low; data latches on rising edge) |
| RS / DC  | Register select: LOW = command, HIGH = pixel data      |
| RST      | Hardware reset (active-low)                            |
| CS       | Chip select (active-low)                               |
| RD       | Read strobe — unused, held HIGH                        |

---

## Why It Doesn't Work on Stock Raspberry Pi OS Trixie

Trixie (Debian 13, kernel 6.12+, 64-bit ARM64) broke compatibility on three
fronts:

1. **FBTFT removed** — The `fbtft`, `fbtft_device`, and `fb_ili9481` kernel
   modules were removed from the Raspberry Pi kernel after Bullseye.
2. **Device-tree overlays removed** — Overlays like `piscreen`, `kedei`,
   `ili9481` no longer ship. KMS/DRM overlays do not support parallel GPIO
   panels.
3. **64-bit ABI** — Any 32-bit `.ko` compiled for an older kernel cannot load.

**Result:** the shield receives power but no initialization commands, so the LCD
stays **white** permanently.

---

## This Driver

`ili9481-fb` is a **userspace daemon** that replaces the legacy FBTFT dependency
entirely. It avoids all kernel hooks and is maintainable across future kernels:

| Feature           | Implementation                                  |
| ----------------- | ----------------------------------------------- |
| GPIO access       | MMIO via `/dev/gpiomem` (BCM283x registers)     |
| Pixel source      | Mirrors `/dev/fb0` (HDMI via vc4drmfb)          |
| Pixel format      | Converts 32bpp XRGB8888 → 12bpp RGB444          |
| Scaling           | Nearest-neighbor from HDMI resolution → 480×320 |
| Bus interface     | 12-bit 8080 parallel with precomputed LUTs      |
| Service lifecycle | systemd unit, auto-start on boot                |

### How it works

1. The daemon opens `/dev/fb0` (HDMI framebuffer) and mmaps it read-only.
2. GPIO pins are configured as outputs via MMIO writes to `/dev/gpiomem`.
3. The ILI9481 is hardware-reset and sent its full initialization sequence
   with COLMOD = 0x03 (RGB444 mode).
4. Every frame interval (1000/fps ms):
   - Read the HDMI framebuffer
   - Convert 32bpp XRGB8888 → 12bpp RGB444
   - Nearest-neighbor scale to 480×320 (or 320×480 depending on rotation)
   - Set CASET/PASET/RAMWR window
   - Stream all 153,600 pixels via GPIO bit-banging
5. On SIGTERM/SIGINT, the display is powered off cleanly (DISPOFF + SLPIN).

### Pixel write path

Each 12-bit pixel write:

1. Look up SET/CLR masks from precomputed LUTs (256-entry for DB0–DB7,
   16-entry for DB8–DB11)
2. Write GPSET0/GPCLR0 to place the 12-bit value on the data bus
3. Assert WR low (GPCLR)
4. DMB barrier (≥ 15 ns hold time)
5. Release WR high — rising edge latches the pixel into the ILI9481

### ILI9481 initialization sequence

On startup the daemon:

1. Pulses RST low 20 ms → high 120 ms (hardware reset)
2. Sends the full initialization command sequence:
   - Software reset (0x01)
   - Sleep Out (0x11)
   - Power Control (0xD0, 0xD1, 0xD2)
   - Panel Drive (0xC0), Frame Rate (0xC5)
   - Gamma (0xC8, 12 bytes)
   - **Pixel Format (0x3A, 0x03 = RGB444)**
   - Display On (0x29)
3. Writes MADCTL (0x36) for the selected rotation

---

## Target Hardware

- **Display:** 320×480 TFT, ILI9481 controller, RGB444
- **Interface:** 12-bit 8080 parallel over 26-pin GPIO header
- **Level shifting:** 74HC245 / 74HCT245 bus transceivers (3.3 V → 5 V)
- **Touch (optional):** XPT2046 / ADS7846 over SPI (unreliable, shared pins)
- **Boards:** Raspberry Pi 1/2/3/4/Zero/Zero 2 W — **NOT Pi 5**

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
  --touch           Enable XPT2046 touch (WARNING: conflicts with data bus)
  --no-touch        Skip touch setup (default)
  --x11-on-tft      Redirect X11 desktop to TFT (disables HDMI desktop)
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
# Daemon running?
systemctl status ili9481-fb.service

# Source framebuffer present?
ls -l /dev/fb0
cat /sys/class/graphics/fb0/name     # should print "vc4drmfb" or similar

# Daemon log messages
journalctl -u ili9481-fb -n 20

# Full validation suite
sudo ./scripts/test-display.sh

# Write random noise to HDMI fb — should appear on TFT within one frame
sudo dd if=/dev/urandom of=/dev/fb0 bs=307200 count=1
```

If random colour noise appears on the TFT panel, the daemon is correctly
mirroring the HDMI framebuffer via GPIO.

---

## GPIO Pin Mapping (26-Pin Header)

The mapping matches the standard Inland / Kuman / MCUfriend wiring for
**26-pin** TFT shields. All pins are within the original 26-pin GPIO header.

### Control signals

| Signal | GPIO (BCM) | Pi Pin | Direction | Polarity    |
| ------ | ---------- | ------ | --------- | ----------- |
| RST    | 25         | 22     | Output    | Active-low  |
| CS     | 8          | 24     | Output    | Active-low  |
| DC/RS  | 24         | 18     | Output    | Active-high |
| WR     | 23         | 16     | Output    | Active-low  |
| RD     | 18         | 12     | Output    | Held HIGH   |

### Data bus — Lower byte (DB0–DB7)

| Signal | GPIO (BCM) | Pi Pin |
| ------ | ---------- | ------ |
| DB0    | 9          | 21     |
| DB1    | 11         | 23     |
| DB2    | 10         | 19     |
| DB3    | 22         | 15     |
| DB4    | 27         | 13     |
| DB5    | 17         | 11     |
| DB6    | 4          | 7      |
| DB7    | 3          | 5      |

### Data bus — Upper nibble (DB8–DB11)

| Signal | GPIO (BCM) | Pi Pin |
| ------ | ---------- | ------ |
| DB8    | 14         | 8      |
| DB9    | 15         | 10     |
| DB10   | 2          | 3      |
| DB11   | 7          | 26     |

### Not connected (absent on 26-pin header)

| Signal | Would need | Note                                      |
| ------ | ---------- | ----------------------------------------- |
| DB12   | Pin 32     | GPIO 12 — not available on 26-pin shields |
| DB13   | Pin 33     | GPIO 13 — not available                   |
| DB14   | Pin 35     | GPIO 19 — not available                   |
| DB15   | Pin 36     | GPIO 16 — not available                   |

> **Important:** Waveshare, LCD-show, and FBTFT flexfb pin maps **do not apply**
> to this board. Those projects target 40-pin boards with 8-bit or 16-bit SPI/
> parallel interfaces.

---

## Touch Support

The XPT2046 / ADS7846 resistive touch controller communicates over SPI. On
these 26-pin boards, the SPI chip-select lines **share pins with the parallel
data bus**, making touch unreliable.

Use `--touch` at install time to enable it, but expect conflicts. If touch
events are erratic or absent, reinstall with `--no-touch` (the default).

---

## Repository Layout

```
install.sh                      # Automated installer
uninstall.sh                    # Automated uninstaller
include/
  ili9481_hw.h                  # Register defines, pin constants, MADCTL values
src/
  bus/
    gpio_mmio.c / .h            # MMIO GPIO bus — LUTs, 12-bit writes
    timing.h                    # DMB barrier, busy-wait ndelay
  display/
    ili9481.c / .h              # Init sequence, CASET/PASET/RAMWR flush
    framebuffer.c / .h          # Mirror fb0: mmap, convert, scale, flush loop
  touch/
    xpt2046.c / .h              # SPI touch reader (optional)
    uinput_touch.c / .h         # uinput virtual touchscreen (optional)
  core/
    service_main.c              # Daemon entry point, signal handling
    config.c / .h               # INI config parser + CLI args
    logging.c / .h              # stderr + syslog logging
config/
  ili9481.conf                  # Default configuration file
systemd/
  ili9481-fb.service            # systemd unit file
scripts/
  test-display.sh               # Post-install validation
  tft-diagnose.sh               # Boot-to-desktop diagnostics
Makefile                        # Build system
```

---

## Timing & Performance

| Parameter               | Value                         |
| ----------------------- | ----------------------------- |
| WR pulse low (tWRL)     | ≥ 15 ns                       |
| WR pulse high (tWRH)    | ≥ 15 ns                       |
| Pixels per frame        | 153,600 (480 × 320)           |
| Bits per pixel          | 12 (RGB444)                   |
| Target throughput       | 25–30 FPS                     |
| Effective FPS (typical) | 5–15 FPS (GPIO MMIO overhead) |

The daemon uses precomputed lookup tables to minimise per-pixel GPIO register
writes. The effective framerate is constrained by MMIO register access latency
and is well-suited for consoles, static UIs, and lightweight desktops.

---

## Limitations

- Refresh rate is constrained by GPIO MMIO overhead (~5–15 FPS depending on Pi
  model).
- Not suitable for video playback or fast animation.
- Only 12 bits per pixel (4096 colours) — limited by the 26-pin header wiring.
- Touch is unreliable on boards where SPI shares pins with the data bus.
- Pi 5 is **not supported** (RP1 has a different GPIO register layout).
- For new projects, SPI-based ILI9341/ILI9488 or DSI panels offer better
  performance and kernel support.

---

## Why Userspace?

This is the only viable modern approach because:

- Trixie (Bookworm+) removed FBTFT from the kernel
- KMS/DRM overlays no longer support parallel GPIO panels
- Kernel headers change and will keep changing
- Display overlays relying on SPI or 8/16-bit parallel FBTFT cannot be built or
  loaded on current kernels

The daemon approach avoids all kernel hooks and is maintainable on future
kernels without recompilation against kernel headers.

---

## License

GPL-2.0-only — see `SPDX-License-Identifier` headers in each source file.
