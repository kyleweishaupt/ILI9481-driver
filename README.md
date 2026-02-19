# Inland 3.5" TFT Display Driver (MPI3501 / ILI9486 SPI)

Userspace framebuffer mirror daemon for the **Inland 3.5" TFT Touch Shield**
(MPI3501) and compatible Kuman / Waveshare / Elegoo / Banggood / Sainsmart
3.5" SPI-based boards that use an **ILI9486** (or ILI9488) controller over
**SPI with 16-bit register width**.

The daemon (`fbcp`) mirrors the HDMI framebuffer (`/dev/fb0`) to the TFT
display via `/dev/spidev0.0`, converting and scaling pixels to RGB565
480×320. The display shows the full boot process (kernel messages, systemd
startup) and then the desktop.

---

## What This Display Actually Is

Despite some documentation calling it "ILI9481 parallel", this specific
board (and most Inland / MPI3501 3.5" shields) uses:

| Detail              | Value                                                |
| ------------------- | ---------------------------------------------------- |
| **Controller**      | ILI9486 (or ILI9488/ILI9486L)                        |
| **Interface**       | SPI (4-wire, mode 0)                                 |
| **Register width**  | 16-bit — every command/data byte is sent as `0x00 byte` |
| **Pixel format**    | RGB565 (16 bits/pixel), raw bytes after RAMWR         |
| **SPI device**      | `/dev/spidev0.0` (CE0)                                |
| **DC (RS) pin**     | GPIO 24 (active-high = data, low = command)           |
| **RST pin**         | GPIO 25 (active-low hardware reset)                   |
| **SPI clock**       | 16 MHz recommended (tested at 8 MHz)                  |
| **Touch**           | XPT2046 on `/dev/spidev0.1` (CE1), separate SPI bus  |
| **Resolution**      | 480×320 (landscape) / 320×480 (portrait)              |
| **Backlight**       | Always-on 3.3 V, no PWM control                      |

### Key discovery: 16-bit SPI register width

The ILI9486 on these boards uses **16-bit SPI register width** (regwidth=16).
This means:

- **Command bytes** are sent as: DC=LOW, SPI sends `0x00 <cmd>`
- **Parameter bytes** are sent as: DC=HIGH, SPI sends `0x00 <param>`
- **Pixel data** (after RAMWR 0x2C) is sent as **raw bytes** with no padding

This matches the kernel's `fb_ili9486` FBTFT driver behavior and is the
reason why standard ILI9481 or plain 8-bit ILI9486 drivers fail — they
don't pad commands to 16 bits.

### Why the screen goes white

If the display shows all **white**, it means:

1. The controller is powered but has received **no valid init commands**
2. The SPI communication failed (wrong speed, mode, or pin configuration)
3. Some other driver corrupted the SPI GPIO pins (GPIO 8/9/10/11)

White = no init. Black = init worked but no pixel data.

---

## Critical: vc4-fkms-v3d Required

This driver reads from `/dev/fb0` to mirror the desktop. On Raspberry Pi OS
with **full KMS** (`vc4-kms-v3d`), the Wayland compositor renders directly
to DRM/GPU buffers and **never writes to `/dev/fb0`**. Result: fb0 is all
zeros = black screen on the TFT.

**Fix**: Use `vc4-fkms-v3d` (fake KMS) instead. With fkms, the firmware
compositor keeps `/dev/fb0` in sync with the actual HDMI output.

In `/boot/firmware/config.txt`:
```ini
# REQUIRED — use fkms, NOT full kms
dtoverlay=vc4-fkms-v3d

# Ensure SPI is enabled
dtparam=spi=on

# Force HDMI output even without a monitor
hdmi_force_hotplug=1
```

> **Do NOT use `vc4-kms-v3d`** — it will result in a working display init
> (test colors appear) but a black screen when mirroring the desktop.

---

## Quick Start

```bash
cd ~/ili9481-driver
sudo ./install.sh
sudo reboot
```

The installer will:
1. Build `fbcp` from source
2. Install it to `/usr/local/bin/fbcp`
3. Switch `config.txt` from `vc4-kms-v3d` to `vc4-fkms-v3d`
4. Configure `cmdline.txt` for boot-time display (`fbcon=map:0`, remove `quiet splash`)
5. Enable `fbcp.service` (auto-start on boot)

### Boot display

After installation, the TFT shows:
- **Kernel boot messages** (via fbcon mapped to fb0)
- **systemd startup** progress
- **Desktop** (mirrored from HDMI framebuffer)

### Uninstall

```bash
sudo ./uninstall.sh
sudo reboot
```

---

## Touch Support

The XPT2046 touch controller uses a separate SPI channel (`/dev/spidev0.1`,
CE1) and does **not** conflict with the display SPI. Touch can be enabled
at install time:

```bash
sudo ./install.sh --touch
```

When enabled, the daemon spawns a touch polling thread that:
1. Reads raw X/Y from the XPT2046 via SPI
2. Applies EWMA noise filtering
3. Reports events via a virtual uinput touchscreen device

Touch calibration uses a default identity matrix. For accurate touch,
calibrate with `xinput_calibrator` or `libinput-calibration-matrix`.

---

## Service Management

```bash
# Status
sudo systemctl status fbcp.service

# Logs (live)
journalctl -u fbcp.service -f

# Stop
sudo systemctl stop fbcp.service

# Restart
sudo systemctl restart fbcp.service
```

---

## How fbcp Works

### Initialization

1. Opens `/dev/gpiochip0`, requests GPIO 24 (DC) and 25 (RST) as outputs
2. Opens `/dev/spidev0.0`, configures SPI mode 0, 8 bits, 8 MHz clock
3. Hardware reset: RST high → low (50 ms) → high (150 ms)
4. Sends ILI9486 init sequence with **16-bit register width** padding
5. Fills screen R/G/B as visual confirmation
6. Opens `/dev/fb0`, mmaps it read-only

### Frame loop

Each frame (at configured FPS):
1. Read pixels from mmap'd fb0
2. Scale from source resolution (e.g., 640×480) to 480×320 nearest-neighbor
3. Convert pixel format if needed (32bpp XRGB8888 → 16bpp RGB565, byte-swap)
4. Set CASET/PASET window (full screen)
5. Send RAMWR (0x2C), then stream all pixel data as raw SPI bytes
6. Sleep until next frame tick (clock_nanosleep)

### Performance

At 8 MHz SPI, each frame is ~307 KB of pixel data = ~0.3s per frame ≈ 3 FPS.
Increasing SPI clock to 16 MHz doubles throughput to ~6 FPS. Higher clocks
may work but depend on wiring quality.

| SPI Clock | Approx FPS | Status     |
| --------- | ---------- | ---------- |
| 8 MHz     | ~3         | Stable     |
| 16 MHz    | ~6         | Recommended|
| 32 MHz    | ~10-12     | Test first |

---

## Configuration

### Command-line options (fbcp)

```
fbcp [--src=DEV] [--spi=DEV] [--gpio=CHIP] [--fps=N]

  --src=DEV    Source framebuffer (default: /dev/fb0)
  --spi=DEV    SPI device (default: /dev/spidev0.0)
  --gpio=CHIP  GPIO chip device (default: /dev/gpiochip0)
  --fps=N      Target framerate, 1–60 (default: 15)
```

### config.txt settings

```ini
# Required
dtparam=spi=on
dtoverlay=vc4-fkms-v3d
hdmi_force_hotplug=1

# Optional — enable second SPI chip-select for touch
dtoverlay=spi0-2cs
```

### cmdline.txt additions (set by installer)

```
fbcon=map:0                     # Map text console to fb0 (visible on TFT)
video=HDMI-A-1:640x480@60D     # Force HDMI framebuffer at boot
```

Remove `quiet` and `splash` to see boot messages on the TFT.

---

## GPIO Pin Usage

### SPI display (active during operation)

| Function | GPIO (BCM) | Pi Pin | Notes              |
| -------- | ---------- | ------ | ------------------ |
| SPI MOSI | 10         | 19     | Data to display    |
| SPI SCLK | 11         | 23     | SPI clock          |
| SPI CE0  | 8          | 24     | Display chip select|
| SPI MISO | 9          | 21     | Not used by display|
| DC (RS)  | 24         | 18     | Command/data select|
| RST      | 25         | 22     | Hardware reset     |

### SPI touch (when enabled)

| Function | GPIO (BCM) | Pi Pin | Notes               |
| -------- | ---------- | ------ | ------------------- |
| SPI CE1  | 7          | 26     | Touch chip select   |
| SPI MISO | 9          | 21     | Touch data from XPT |

Touch shares MOSI/SCLK/MISO with the display SPI bus but uses a separate
chip select (CE1).

---

## Troubleshooting

| Symptom | Cause | Fix |
| ------- | ----- | --- |
| All white | No init commands reached the controller | Check SPI enabled, correct spidev device, pin functions: `pinctrl get 8 9 10 11` |
| Test colors (R/G/B) then black | fb0 has no content (Wayland + full KMS) | Switch to `vc4-fkms-v3d` in config.txt |
| Test colors then desktop appears | Working correctly | — |
| Service won't start | SPI device missing | Check `ls /dev/spidev0.0`, ensure `dtparam=spi=on` and `dtoverlay=spi0-2cs` |
| Low FPS | SPI clock too low | Increase SPI_HZ in fbcp.c (try 16000000) |
| Garbled/shifted image | Wrong init sequence or rotation | Check MADCTL value, try different rotation |

### Diagnostic commands

```bash
# Verify SPI is working
ls -l /dev/spidev0.*

# Check SPI pin functions (should be ALT0)
pinctrl get 8 9 10 11

# Check fb0 has content (should NOT be all zeros)
sudo hexdump -C /dev/fb0 | head -5

# Write test noise to fb0 — should appear on TFT
sudo dd if=/dev/urandom of=/dev/fb0 bs=307200 count=1

# Full diagnostic script
sudo ./scripts/tft-diagnose.sh
```

---

## Repository Layout

```
src/
  fbcp.c                        # SPI display mirror daemon (ACTIVE DRIVER)
  bus/
    gpio_mmio.c / .h            # MMIO GPIO bus (parallel variant, unused)
    timing.h                    # DMB barrier helpers
  display/
    ili9481.c / .h              # ILI9481 parallel init (unused for SPI boards)
    framebuffer.c / .h          # fb0 mirror: mmap, convert, scale, flush
  touch/
    xpt2046.c / .h              # SPI touch reader
    uinput_touch.c / .h         # uinput virtual touchscreen
  core/
    service_main.c              # Parallel daemon entry point (unused)
    config.c / .h               # INI config parser + CLI args
    logging.c / .h              # stderr + syslog logging
include/
  ili9481_hw.h                  # Register defines (parallel variant)
config/
  ili9481.conf                  # Config file for parallel daemon
systemd/
  fbcp.service                  # systemd unit file (SPI driver)
  ili9481-fb.service            # systemd unit file (parallel variant)
install.sh                      # Automated installer
uninstall.sh                    # Automated uninstaller
Makefile                        # Build system
scripts/
  test-display.sh               # Post-install validation
  tft-diagnose.sh               # Diagnostics
```

> **Note:** The `src/bus/`, `src/display/`, and `src/core/` directories contain
> an alternative **8-bit 8080-I parallel GPIO** driver (`ili9481-fb`) designed
> for boards that use the ILI9481 controller with a parallel data bus. This
> driver is **not** used for the Inland MPI3501 SPI boards — use `fbcp` instead.

---

## Limitations

- Refresh rate is limited by SPI bandwidth (~3 FPS at 8 MHz, ~6 at 16 MHz)
- Not suitable for video playback or fast animation
- 65,536 colours (RGB565)
- Requires `vc4-fkms-v3d` — full KMS (`vc4-kms-v3d`) leaves fb0 empty
- Pi 5 is untested (different GPIO chip)
- Backlight is always on (no dimming control)

---

## License

GPL-2.0-only — see `SPDX-License-Identifier` headers in each source file.
