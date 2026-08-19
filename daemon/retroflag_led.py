#!/usr/bin/env python3
"""
retroflag-picase LED daemon.

- On start: turn LED solid ON.
- On SIGTERM (systemd shutdown): blink LED for a bounded time, then turn it OFF
  and exit so the shutdown is not delayed.

Uses gpiozero with the lgpio backend, which works on kernel 6.x
(including Pi 4 and Pi 5) — RPi.GPIO is deprecated and unreliable there.
"""

from __future__ import annotations

import logging
import os
import signal
import sys
import threading
import time

# Must be set before gpiozero imports its pin factories, otherwise it silently
# falls back to the experimental mmap-based NativeFactory.
os.environ.setdefault("GPIOZERO_PIN_FACTORY", "lgpio")

from gpiozero import LED  # noqa: E402

LOG = logging.getLogger("retroflag-led")


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        LOG.warning("Invalid %s=%r, using default %d", name, raw, default)
        return default


class LedController:
    def __init__(self, gpio: int, blink_hz: float) -> None:
        self._led = LED(gpio)
        self._blink_period = 1.0 / max(blink_hz, 0.1)
        self._stop = threading.Event()

    @property
    def pin_factory(self):  # noqa: ANN201
        return self._led.pin_factory

    def on(self) -> None:
        self._led.on()

    def blink_for(self, seconds: float) -> None:
        half = self._blink_period / 2.0
        deadline = time.monotonic() + seconds
        state = True
        while not self._stop.is_set() and time.monotonic() < deadline:
            if state:
                self._led.on()
            else:
                self._led.off()
            state = not state
            self._stop.wait(half)

    def stop_blink(self) -> None:
        self._stop.set()

    def close(self) -> None:
        try:
            self._led.off()
            self._led.close()
        except Exception:  # noqa: BLE001
            pass


def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    led_gpio = _env_int("LED_GPIO", 14)
    blink_hz = _env_int("LED_SHUTDOWN_BLINK_HZ", 2)
    blink_secs = _env_int("LED_SHUTDOWN_BLINK_SECS", 5)

    LOG.info(
        "Starting on GPIO %d, shutdown blink %d Hz for %ds",
        led_gpio,
        blink_hz,
        blink_secs,
    )
    controller = LedController(led_gpio, float(blink_hz))
    LOG.info("Pin factory: %s", type(controller.pin_factory).__name__)
    controller.on()

    shutting_down = threading.Event()

    def _on_term(signum, _frame):  # noqa: ANN001
        LOG.info("Received signal %d, entering shutdown blink", signum)
        shutting_down.set()

    signal.signal(signal.SIGTERM, _on_term)
    signal.signal(signal.SIGINT, _on_term)

    # Idle loop until systemd sends SIGTERM at shutdown.
    while not shutting_down.is_set():
        time.sleep(1.0)

    try:
        controller.blink_for(float(blink_secs))
    finally:
        controller.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
