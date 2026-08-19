# retroflag-picase

> Modern safe-shutdown for [RetroFlag](https://github.com/RetroFlag/retroflag-picase) cases on **Raspberry Pi OS / Debian 13 (trixie)**, kernel 6.x, Python 3.13.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## Table of contents

- [Why rewrite it](#why-rewrite-it)
- [How it works](#how-it-works)
  - [The power key inhibitor](#the-power-key-inhibitor-important)
  - [Why `gpio-poweroff` is not used](#why-gpio-poweroff-is-not-used)
  - [The power cut](#the-power-cut-what-the-case-actually-does)
  - [Deliberate differences from the original](#deliberate-differences-from-the-original)
  - [The UART ↔ GPIO 14 conflict](#the-uart--gpio-14-conflict)
- [Pinout](#pinout)
- [Installation](#installation)
- [Uninstallation](#uninstallation)
- [Compatibility](#compatibility)
- [Credits](#credits)

## Why rewrite it

The official installer (`RetroFlag/retroflag-picase`) has been unchanged since 2019 and fails on modern systems:

| Original problem | Solution here |
|---|---|
| Uses `RPi.GPIO`, broken on Bookworm+ and unsupported on kernels ≥6.6 | `gpiozero` with `lgpio` backend (native Pi 5 and Pi 4 support) |
| Registers startup in `/etc/rc.local`, which **does not exist** on Debian 13 | `systemd` service with `Restart=always` |
| Downloads a custom `.dtbo` (`RetroFlag_pw_io.dtbo`) that no longer compiles | Standard kernel overlay (`gpio-shutdown`) |
| Button handled by a polling Python daemon | Button handled by the **kernel** (`KEY_POWER` event → `systemd-logind` → clean `poweroff`) |
| No uninstall | Idempotent `uninstall.sh` |

## How it works

```
┌──────────────────────────┐
│  Physical button  GPIO 3 │──┐
└──────────────────────────┘  │  dtoverlay=gpio-shutdown
                              ▼
                    Linux kernel ──► KEY_POWER ──► systemd-logind ──► systemctl reboot
                              │                                              │
                              │                    case microcontroller cuts power
                              ▼
                    retroflag-led.service  (systemd unit)
                              │
                              ▼
┌──────────────────────────┐
│  Red LED          GPIO 14│  solid ON at boot
└──────────────────────────┘  blinks on SIGTERM, then turns off
```

- **Button**: 100% kernel-native, no Python daemon. Reliable even if userspace hangs.
- **LED**: minimal Python daemon using `gpiozero` + `lgpio` backend — solid on at boot, blinks when shutdown begins.
- **Idempotency**: `install.sh` can be run N times without duplicating lines in `config.txt`.

### The power key inhibitor (important)

On **Raspberry Pi OS with desktop**, the `rpi-gui-nop` package autostarts via
`/etc/xdg/autostart/pwrkey.desktop`:

```
systemd-inhibit --what=handle-power-key rpi-gui-nop
```

This is a **block** inhibitor: `systemd-logind` receives the `KEY_POWER` event
(`Power key pressed short` in the journal) but **does nothing**, so the case
button never shuts the Pi down. `install.sh` neutralises it with `dpkg-divert`
(reversible from `uninstall.sh`).

Verify no inhibitor remains:

```bash
systemd-inhibit --list | grep handle-power-key   # should return nothing
```

### Why `gpio-poweroff` is not used

The `gpio-poweroff` overlay looks like the obvious choice for the cut signal,
but its own documentation advises against it here: with `active_low` a custom
`dt-blob.bin` is required to avoid a shutdown mid-boot, a `reboot` also pulls
the pin low (turning it into a poweroff), and it disables waking the Pi by
pulling `GPIO 3` low. It also holds the line for the entire uptime
(`gpioinfo` shows it as `consumer="power_ctrl"`), which would prevent the
daemon from driving the LED via the char device and force `gpiozero` to fall
back to the `NativeFactory` (mmap) backend.

A systemd shutdown hook is used instead.

### The power cut (what the case actually does)

This is where it is easy to get confused. A Raspberry Pi `poweroff` **does not
cut power**: it leaves the SoC in halt while the supply keeps running. Power is
cut by the case microcontroller.

The original RetroFlag script makes this clear — its `poweroff()` function
**does not power off**:

```python
def poweroff():
    while True:
        GPIO.wait_for_edge(powerPin, GPIO.FALLING)
        ...
        os.system("sudo shutdown -r now")   # reboot, not poweroff
```

The actual sequence is:

1. You press the button → the case micro **arms itself** and pulls `GPIO 3` low.
2. The system performs a clean shutdown and **resets the SoC** (`reboot`).
3. The micro cuts power during that reset window.

If in step 2 you do `poweroff` instead of `reboot`, the SoC stays in halt, the
micro never sees the reset, and the case stays powered. That is why the default is:

```sh
POWER_KEY_ACTION=reboot
```

`install.sh` translates this into a logind drop-in
(`/etc/systemd/logind.conf.d/retroflag-picase.conf`) with
`HandlePowerKey=reboot`, keeping the kernel-native approach. A long press still
does `poweroff`.

As a complement, `POWEREN_GPIO` (GPIO 4, the `powerenPin` from the original) is
held high from the very first firmware stage with `gpio=4=op,dh` and pulled low
at the end of shutdown from
`/usr/lib/systemd/system-shutdown/retroflag-picase.shutdown`.

> [!NOTE]
> Verified by hardware sweep: no GPIO pulled low alone cuts power. The cut
> always requires the micro to be armed by a button press.

> [!IMPORTANT]
> The **SAFE SHUTDOWN** switch on the case must be **ON**. With it OFF the
> micro does not wait for the software and no configuration will work.

### Deliberate differences from the original

| Original | Here | Reason |
|---|---|---|
| `enable_uart=1` | `enable_uart=0` | The original uses `RPi.GPIO`, which writes registers directly and ignores that GPIO 14 is TXD. With the `lgpio` char device the pin must be free from UART. |
| Button managed by a polling Python daemon | `dtoverlay=gpio-shutdown` + logind | Survives userspace hangs. |
| `shutdown -r now` | `HandlePowerKey=reboot` | Same effect, no daemon. |

### The UART ↔ GPIO 14 conflict

The base Raspberry Pi OS / Debian image ships with:

- `enable_uart=1` in `config.txt`
- `console=serial0,115200` in `cmdline.txt`
- `serial-getty@ttyS0.service`

GPIO 14 is **UART0 TXD**, the same pin as the case LED. With that configuration
the firmware leaves the pin in alternate mode (`pinctrl get 14` returns
`a5 ... TXD1`), the daemon cannot control it, and the serial console writes
traffic to the LED line throughout boot.

When `LED_GPIO` is 14 or 15, `install.sh` resolves this automatically:

1. adds `enable_uart=0` to its managed block in `config.txt`;
2. removes `console=serial0|ttyS0|ttyAMA0` from `cmdline.txt` (with a backup in
   `cmdline.txt.retroflag-orig`);
3. disables and masks `serial-getty@ttyS0` / `serial-getty@ttyAMA0`.

`uninstall.sh` reverses all three steps.

> [!WARNING]
> If you rely on the serial console to recover the Pi, it will no longer be
> available after installing. The `cmdline.txt` backup can be restored by
> mounting the SD card boot partition on another machine.

## Pinout

Assumes the standard RetroFlag NESPi+/SuperPi/MegaPi/**NESPi 4** pinout by default:

| Function | GPIO (BCM) | Physical pin |
|---|---|---|
| Power button | `GPIO 3`  | 5  |
| Power LED    | `GPIO 14` | 8  |
| Power enable | `GPIO 4`  | 7  |

If your case uses different pins, edit `/etc/default/retroflag-picase` after
installation and re-run `install.sh` — it regenerates `config.txt` and restarts
the LED service.

See [`docs/pinout.md`](docs/pinout.md) for the full per-model map.

## Installation

```bash
git clone https://github.com/YOUR_USERNAME/retroflag-picase
cd retroflag-picase
sudo ./install.sh
sudo reboot
```

> [!IMPORTANT]
> The reboot is required — `config.txt` and `cmdline.txt` changes only take
> effect at boot.

After reboot:

- LED solid ON.
- Pressing the case button triggers a clean shutdown; the case cuts power during
  the SoC reset.
- When shutdown begins the LED blinks at ~2 Hz for a few seconds, then goes off.
- Pressing the button while the Pi is halted powers it on (GPIO 3 has this
  hardware feature).

## Uninstallation

```bash
sudo ./uninstall.sh
sudo reboot
```

Removes the `config.txt` lines, stops and disables the service, and deletes the
binary and config.

## Compatibility

Tested on:

- Raspberry Pi 4B (BCM2711)
- Debian 13 (trixie) — `rpi-6.18` kernel
- Python 3.13
- `gpiozero` 2.x + `lgpio` backend (`python3-lgpio` package)

Should work unchanged on Pi 5, Pi Zero 2, Pi 3B/B+ (same overlays available).

## Credits

Based on the original concept from [RetroFlag/retroflag-picase](https://github.com/RetroFlag/retroflag-picase) (MIT).
Rewritten from scratch for Debian 13 + kernel 6.x + `gpiozero`.

## License

MIT — see [`LICENSE`](LICENSE).
