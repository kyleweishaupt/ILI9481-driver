# Inland TFT35" Touch Shield for Raspberry Pi — Technical Analysis & Key Findings

This document summarizes the essential, distilled knowledge required to understand, operate, and correctly drive the **Inland 3.5" TFT Touch Shield for Raspberry Pi** on modern **Raspberry Pi OS Trixie (Debian 13, 64-bit, Kernel 6.12+)**.  
All unnecessary code, scripts, and overlays have been removed — this document focuses on the _architecture, function, requirements, and the electrical/driver model_.

---

## 1. What This Board Actually Is

Although marketed as a simple “3.5-inch TFT for Raspberry Pi”, the Inland board is **not a DPI display**, **not SPI**, and **not DSI**.  
Instead, it is a **16-bit 8080-parallel TFT shield**, electrically equivalent to the older **Kedei 3.5" v1–v3 shields**.

### Key Components (based on the PCB markings and layout):

**Display panel:**

- 3.5" 320×480 TFT
- Controller: **ILI9481**
- Interface: **16-bit 8080 Parallel bus**
- Backlight: Always on; no PWM input
- FPC cable connects display ↔ adapter board

**Adapter board chips:**

- **U1–U4: 74HC245 / 74HCT245 bus transceivers**
  - Convert Raspberry Pi’s **3.3V GPIO** signals to **5V levels** used by the LCD panel
  - Buffer & protect Pi GPIO
  - Provide the 16-bit data bus (DB0–DB15)

- **U5:**
  - Often an ADC or touch controller (XPT2046 / ADS7846 type) OR
  - A regulator/misc logic depending on variant
  - Inland variant does _not_ expose the SPI pins cleanly at the header, so touch support is unreliable/incomplete.

- **U6–U7:**
  - Discrete support components (oscillator caps, voltage filtering)

**GPIO Header (40-pin):**  
This shield _piggybacks_ directly onto the Pi GPIO header.  
No HDMI, no SPI framebuffer — **all display signals are delivered through GPIO bit-banging**.

---

## 2. How the Board Works Electrically

The board uses the **GPIO header as a 16-bit parallel data bus**.  
This allows the Pi to send pixel data using a pseudo-8080 interface:

- 16 data lines: DB0–DB15
- 1 register-select line (DC/RS)
- 1 reset line
- Optional write/read strobes (depending on panel mode)

### What this means in practice

- The Pi must toggle **20+ GPIO pins at high frequency**, which is slow in Linux space.
- Therefore the standard Linux framebuffer _cannot_ drive this natively.
- It requires a **special-purpose kernel module** from the older **FBTFT** stack.
- The kernel must “bit-bang” a full framebuffer through GPIO — this is why these displays were always relatively slow.

This also explains why the display always powers up blank/white until the driver initializes the panel.

---

## 3. Why It Doesn’t Work on Raspberry Pi OS Trixie (64-bit)

### ❌ Reason 1 — FBTFT was removed from mainline kernels

The Inland shield depends on modules such as:

- `fbtft`
- `fbtft_device`
- `fb_ili9481`

These were removed from the Raspberry Pi kernel after Bullseye.  
**Trixie (64-bit, kernel 6.12) no longer includes these drivers**, so the system cannot initialize the panel.

### ❌ Reason 2 — Device Tree overlay for parallel TFTs is not present

Trixie removed support for overlays like:

- `dtoverlay=piscreen`
- `dtoverlay=kedei`
- `dtoverlay=ili9481`

Without these, the kernel does not assign GPIO pins, nor register a framebuffer.

### ❌ Reason 3 — 64-bit kernel enforces stricter module ABI

Older compiled modules (32-bit ARMHF) cannot load into a 64-bit ARM64 kernel.

### ❌ Result

The shield receives **power**, but **no commands**, so the LCD stays **white** permanently.

---

## 4. What Is Required for Trixie Support

To operate this display on modern Raspberry Pi OS, several components must be manually installed or compiled.

### ✔ Requirement 1 — Out-of-tree FBTFT driver rebuild

You must compile:

- `fb_ili9481.ko`
- `fbtft.ko`
- `fbtft_device.ko`

Using kernel headers for **the exact running kernel**.

Trixie’s modular kernel system means mismatched modules will not load.

---

### ✔ Requirement 2 — A new Device Tree Overlay

Modern kernels need a custom `.dtbo` that:

- Defines the inland parallel GPIO mapping
- Tells Linux the bus width (`buswidth = <16>`)
- Loads the ili9481-compatible fbtft driver
- Registers the display as `/dev/fb0`

---

### ✔ Requirement 3 — Match GPIO mappings used by the board

The Inland shield uses a fixed mapping inherited from Kedei.  
The overlay must match the board’s electrical wiring exactly.

---

### ✔ Requirement 4 — Raspberry Pi OS configuration

The Trixie bootloader requires the overlay to be placed in:

`/boot/firmware/overlays/`

And enabled through:

`dtoverlay=inland-ili9481-overlay`

`ignore_lcd=1` or similar may be needed to bypass the Pi’s built-in LCD autodetection.

---

## 5. How the Driver Actually Talks to the Board

Internally the driver:

1. Configures 20 GPIO pins as output
2. Pulses write strobes to transfer pixel data
3. Initializes the ILI9481 with a known register sequence
4. Provides a Linux `fbdev` framebuffer to the OS
5. Writes pixel data into a memory buffer that the driver streams to the panel

Because all transmission is GPIO-based:

- Display refresh is slower than SPI-based IPS panels
- Heavy animations can choke
- Console and static UIs work well
- X11 works but with low FPS

---

## 6. Summary — Key Learnings

- The Inland TFT35" is **not plug-and-play** on modern Raspberry Pi OS.
- It is a **parallel 16-bit display requiring the deprecated FBTFT stack**.
- Trixie (Debian 13) removed all necessary drivers, overlays, and support.
- The white screen is expected until the correct driver initializes the ILI9481.
- To use it today, you _must_ rebuild the FBTFT modules and provide a matching overlay.
- Electrically, the shield uses 74HC245 bus transceivers to shift Pi GPIO to 5V levels for the LCD.
- Speed is limited by GPIO bit-banging and cannot compete with SPI/DPI/DSI panels.
- Once working, it provides a `/dev/fb0` framebuffer usable with console or simple GUIs.

---

## 7. Recommendation for Modern Projects

Unless you specifically need this board:

- A **SPI-based 3.5" ILI9341/ILI9488** or
- A **DSI-based 3–4" touchscreen**  
  or
- Any **standard DPI/DSI panel**

will offer far better compatibility, performance, and long-term support.

This shield is best suited for retro-compatibility, embedded demos, or educational use where rebuilding the framebuffer stack is acceptable.

---
