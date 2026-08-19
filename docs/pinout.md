# Pinout by case model

All RetroFlag cases compatible with this package use GPIO **BCM 3** for the button and GPIO **BCM 14** for the LED, except GPi Case variants (portables). The package assumes the standard pinout; if your model differs, edit `/etc/default/retroflag-picase` and re-run `sudo ./install.sh`.

| Model              | Button (BCM) | LED (BCM) | Power enable (BCM) | Notes |
|--------------------|--------------|-----------|---------------------|-------|
| NESPi Case+        | 3            | 14        | 4                   | Standard. |
| SuperPi Case (SNES)| 3            | 14        | 4                   | Standard. |
| MegaPi Case        | 3            | 14        | 4                   | Standard. |
| NESPi 4 Case (Pi 4)| 3            | 14        | 4                   | Fan has its own controller (no software needed). |
| GPi Case (Zero)    | —            | —         | —                   | Not supported: uses different hardware (26/27). |
| GPi Case 2 (CM4)   | 3            | 14        | 4                   | Same as standard. |

## What is the *power enable* pin?

A Raspberry Pi `poweroff` **does not cut power**: it leaves the SoC in halt
while the supply keeps running. Power is cut by the case circuit, and it does
so when `GPIO 4` stops being high — in the original RetroFlag script this is the
`powerenPin`, set HIGH at startup.

This package holds it high from the firmware stage (`gpio=4=op,dh` in
`config.txt`) and pulls it low at the end of shutdown from
`/usr/lib/systemd/system-shutdown/retroflag-picase.shutdown`, which only acts
when the verb is `poweroff`/`halt`, never on `reboot`.

## Why GPIO 3?

`GPIO 3` (physical pin 5) is the only header pin with the hardware ability to
**wake the Pi from `halt`**. Connecting it to the button lets the kernel fire
`KEY_POWER` (via `dtoverlay=gpio-shutdown`), and when waking from halt it is
the hardware itself that resumes the SoC — no dependency on userspace.

## Verify

With the Pi booted:

```bash
# The overlay must be active:
grep -E 'gpio-shutdown' /boot/firmware/config.txt

# The button must appear as an input device with KEY_POWER:
grep -A5 shutdown_button /proc/bus/input/devices

# Nothing must block the power key (see README):
systemd-inhibit --list | grep handle-power-key

# The LED service must be active and using the lgpio backend:
systemctl status retroflag-led.service
journalctl -u retroflag-led.service | grep "Pin factory"   # LGPIOFactory

# The LED pin must not be in UART mode or have another consumer:
pinctrl get 3,14          # 14 should say "output", not "TXD1"
gpioinfo | grep -E 'line +(3|14):'

# The power enable must be driven high:
pinctrl get 4             # "op ... hi", not "ip"

# The shutdown hook must exist and be executable:
ls -l /usr/lib/systemd/system-shutdown/retroflag-picase.shutdown
```
