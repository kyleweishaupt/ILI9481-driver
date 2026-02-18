# Inland TFT35 (ILI9481, 16-bit Parallel) Driver Notes for Raspberry Pi OS Trixie

This repository documents and diagnoses the **Inland TFT35” Touch Shield** class of displays using an **ILI9481** controller on a **16-bit 8080 parallel bus**.

## Correct Hardware Identification

This board is:

- **Not DPI/DSI**
- **Not SPI-driven LCD data path**
- **16-bit 8080 parallel TFT** with GPIO-to-LCD level shifting

Typical hardware:

- Panel: 3.5" TFT (320x480)
- LCD controller: ILI9481
- Adapter logic: SN74HC245/SN74HCT245 level shifters
- Touch controller: often XPT2046 (module-dependent)

## Why the Screen Stays White on Trixie

A white screen with backlight on means the LCD controller did not receive a valid initialization sequence.

On Raspberry Pi OS Trixie (kernel 6.12+), legacy fbtft support required by these parallel panels is not shipped in the same way older images did, so the panel can power up but remain uninitialized.

## Working Approach

Use out-of-tree `fbtft` (`fb_ili9481`) and a custom device-tree overlay for the board pin mapping.

### 1) Install build dependencies

```bash
sudo apt update
sudo apt install -y raspberrypi-kernel-headers git build-essential flex bison bc libssl-dev device-tree-compiler
```

### 2) Build and install `fbtft`

```bash
cd ~
git clone https://github.com/notro/fbtft.git
cd fbtft
make -C /lib/modules/$(uname -r)/build M=$(pwd) modules
sudo make -C /lib/modules/$(uname -r)/build M=$(pwd) modules_install
sudo depmod -a
```

### 3) Add overlay source

Create `/boot/firmware/overlays/inland-ili9481-overlay.dts` with:

```dts
/dts-v1/;
/plugin/;

/ {
    compatible = "brcm,bcm2835";

    fragment@0 {
        target-path = "/";
        __overlay__ {
            inland_ili9481: inland_ili9481@0 {
                compatible = "ilitek,ili9481";
                reg = <0>;
                buswidth = <16>;
                fps = <30>;

                reset-gpios = <&gpio 23 0>;
                dc-gpios    = <&gpio 22 0>;

                gpios = <
                    &gpio  7 0
                    &gpio  8 0
                    &gpio 25 0
                    &gpio 24 0
                    &gpio 23 0
                    &gpio 18 0
                    &gpio 15 0
                    &gpio 14 0

                    &gpio 12 0
                    &gpio 16 0
                    &gpio 20 0
                    &gpio 21 0
                    &gpio 5  0
                    &gpio 6  0
                    &gpio 13 0
                    &gpio 19 0
                >;
            };
        };
    };
};
```

### 4) Compile overlay

```bash
sudo dtc -@ -I dts -O dtb \
  -o /boot/firmware/overlays/inland-ili9481-overlay.dtbo \
  /boot/firmware/overlays/inland-ili9481-overlay.dts
```

### 5) Enable overlay in config

Append to `/boot/firmware/config.txt`:

```ini
dtoverlay=inland-ili9481-overlay
ignore_lcd=1
fbcon=map:10
```

### 6) Reboot

```bash
sudo reboot
```

## Quick Validation

- Confirm framebuffer: `ls -l /dev/fb*`
- Confirm module: `lsmod | grep -E 'fb_ili9481|fbtft'`
- Confirm boot logs: `dmesg | grep -iE 'ili9481|fbtft|fbcon'`

## Diagnostic Script

Use:

```bash
sudo ./scripts/tft-diagnose.sh
```

It checks:

- Overlay presence
- Required module state
- Framebuffer availability
- fbcon activity
- Basic framebuffer write path

## Notes

- Touch support (if present) is typically exposed through `xpt2046` over SPI.
- For touch, check: `ls /dev/input/event*` and `dmesg | grep -i xpt2046`

## License

This repository remains licensed under **GPL-2.0-only**.
