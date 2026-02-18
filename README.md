# Inland TFT35 ILI9481 — Userspace GPIO Parallel Display Driver

Userspace translation daemon for the **Inland 3.5" TFT Touch Shield** (and
compatible Kuman / MCUfriend / Banggood / Sainsmart 3.5" boards) that use an
**ILI9481** controller on an **8-bit 8080-I parallel GPIO bus** through the
original **26-pin** Raspberry Pi header.

The daemon mirrors the HDMI framebuffer (`/dev/fb0`) to the TFT panel by
reading pixels, converting them to **RGB565**, and bit-banging them out over
GPIO using direct MMIO register writes. Each 16-bit pixel is sent as two
8-bit bus cycles (high byte first).

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

### 26-pin = 8-bit bus mode

Because the shield only occupies **pins 1–26** of the Pi header, it has
only **17 usable GPIOs**. With 5 control signals (RST, CS, DC, WR, RD) that
leaves only 12 data lines at most. But crucially, the ILI9481 controller
hardware only supports **8-bit or 16-bit** parallel bus widths — there is
no 12-bit bus mode. The IM strapping pins on the PCB are wired for
**8-bit 8080-I mode**, using DB0–DB7 only.

This means:

- The ILI9481 is operated in **RGB565** mode (COLMOD = 0x55) with 65,536 colours
- Each pixel is **16 bits** (R5 G6 B5), sent as **two 8-bit bus cycles**
- Only **13 GPIOs** are needed: 8 data (DB0–DB7) + 5 control
- GPIO 14, 15, 2, 7 are **free** for UART, I²C, or SPI touch

> **This is why all 16-bit drivers (Waveshare, LCD-show, old FBTFT overlays)
> fail on this board — they assume 16 data lines which aren't available on
> the 26-pin header.**

### Board components

| Component          | Detail                                              |
| ------------------ | --------------------------------------------------- |
| **Display panel**  | 3.5" 320×480 TFT, ILI9481 controller                |
| **Color depth**    | RGB565 (65,536 colours) via 8-bit bus mode          |
| **Interface**      | 8-bit 8080-I parallel bus (DB0–DB7)                 |
| **Level shifting** | U1–U4: 74HC245 / 74HCT245 bus transceivers          |
| **Touch**          | U5: XPT2046 / ADS7846 (shared SPI pins, unreliable) |
| **Backlight**      | Always-on 3.3 V, no PWM control                     |

### 8080 parallel bus signals

| Signal  | Function                                               |
| ------- | ------------------------------------------------------ |
| DB0–DB7 | 8-bit pixel data bus                                   |
| WR      | Write strobe (active-low; data latches on rising edge) |
| RS / DC | Register select: LOW = command, HIGH = pixel data      |
| RST     | Hardware reset (active-low)                            |
| CS      | Chip select (active-low)                               |
| RD      | Read strobe — unused, held HIGH                        |

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
| Pixel format      | Converts 32bpp XRGB8888 → 16bpp RGB565          |
| Scaling           | Nearest-neighbor from HDMI resolution → 480×320 |
| Bus interface     | 8-bit 8080-I parallel with precomputed LUT      |
| Service lifecycle | systemd unit, auto-start on boot                |

### How it works

1. The daemon opens `/dev/fb0` (HDMI framebuffer) and mmaps it read-only.
2. GPIO pins are configured as outputs via MMIO writes to `/dev/gpiomem`.
3. The ILI9481 is hardware-reset and sent its full initialization sequence
   with COLMOD = 0x55 (RGB565 mode, 2 bytes per pixel over 8-bit bus).
4. Every frame interval (1000/fps ms):
   - Read the HDMI framebuffer
   - Convert 32bpp XRGB8888 → 16bpp RGB565
   - Nearest-neighbor scale to 480×320 (or 320×480 depending on rotation)
   - Set CASET/PASET/RAMWR window
   - Stream all 153,600 pixels via GPIO bit-banging
5. On SIGTERM/SIGINT, the display is powered off cleanly (DISPOFF + SLPIN).

### Pixel write path

Each RGB565 pixel requires two 8-bit bus writes:

1. Look up SET/CLR masks from a precomputed 256-entry LUT for DB0–DB7
2. Write GPSET0/GPCLR0 to place the **high byte** (R[4:0] G[5:3]) on DB0–DB7
3. Assert WR low (GPCLR0), DMB barrier (≥ 15 ns), release WR high (GPSET0)
4. Write GPSET0/GPCLR0 to place the **low byte** (G[2:0] B[4:0]) on DB0–DB7
5. Assert WR low, DMB, release WR high — rising edge latches the pixel

### ILI9481 initialization sequence

On startup the daemon:

1. Pulses RST low 20 ms → high 120 ms (hardware reset)
2. Sends the full initialization command sequence:
   - Software reset (0x01)
   - Sleep Out (0x11)
   - Power Control (0xD0, 0xD1, 0xD2)
   - Panel Drive (0xC0), Frame Rate (0xC5)
   - Gamma (0xC8, 12 bytes)
   - **Pixel Format (0x3A, 0x55 = RGB565)**
   - Display On (0x29)
3. Writes MADCTL (0x36) for the selected rotation

---

## Target Hardware

- **Display:** 320×480 TFT, ILI9481 controller, RGB565 (8-bit bus)
- **Interface:** 8-bit 8080-I parallel over 26-pin GPIO header
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

### Data bus (DB0–DB7)

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

### Free GPIOs (not used in 8-bit mode)

| GPIO (BCM) | Pi Pin | Alt function |
| ---------- | ------ | ------------ |
| 14         | 8      | UART TX      |
| 15         | 10     | UART RX      |
| 2          | 3      | I²C SDA      |
| 7          | 26     | SPI CE1      |

> **Important:** Waveshare, LCD-show, and FBTFT flexfb pin maps **do not apply**
> to this board. Those projects target 40-pin boards with 8-bit or 16-bit SPI/
> parallel interfaces.

---

## Diagnostics

If the screen stays white (or shows garbled output), use these tools:

### Test pattern

Fills the screen with solid red, green, blue, white, and black (3 seconds
each). If **any** colour appears, the GPIO pin map and init sequence are
correct.

```bash
sudo ili9481-fb --test-pattern
```

### GPIO probe

Toggles each configured GPIO pin HIGH for 3 seconds, printing the pin name.
Use a multimeter to verify which physical header pin each GPIO maps to.

```bash
sudo ili9481-fb --gpio-probe
```

### Diagnostic script

Runs a comprehensive system check (daemon status, GPIO access, fb0, service
log, pin state snapshot, etc.):

```bash
sudo ./scripts/tft-diagnose.sh
```

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
    gpio_mmio.c / .h            # MMIO GPIO bus — LUT, 8-bit writes
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
| Bits per pixel          | 16 (RGB565, sent as 2×8 bits) |
| Bus cycles per frame    | 307,200 (2 per pixel)         |
| Target throughput       | 25–30 FPS                     |
| Effective FPS (typical) | 5–15 FPS (GPIO MMIO overhead) |

The daemon uses precomputed lookup tables to minimise per-pixel GPIO register
writes. The effective framerate is constrained by MMIO register access latency
and is well-suited for consoles, static UIs, and lightweight desktops.

---

## Limitations

- Refresh rate is constrained by GPIO MMIO overhead (~5–15 FPS depending on Pi
  model). 8-bit mode requires 2 bus cycles per pixel (307,200 /WR pulses per
  frame), which is slower than 16-bit mode but the only option on 26-pin boards.
- Not suitable for video playback or fast animation.
- 65,536 colours (RGB565).
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
