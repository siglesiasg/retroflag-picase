#!/usr/bin/env bash
# retroflag-picase installer (Debian 13 / kernel 6.x / Python 3.13)
#
# Idempotent: safe to re-run after editing config/retroflag.env or bumping code.
# Requires root (uses apt, edits /boot/firmware/config.txt, writes /etc/systemd).

set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/retroflag-picase"
VENV_DIR="${INSTALL_DIR}/venv"
ENV_FILE="/etc/default/retroflag-picase"
SERVICE_NAME="retroflag-led.service"
SYSTEMD_UNIT="/etc/systemd/system/${SERVICE_NAME}"
SHUTDOWN_HOOK="/usr/lib/systemd/system-shutdown/retroflag-picase.shutdown"
LOGIND_DROPIN="/etc/systemd/logind.conf.d/retroflag-picase.conf"
CONFIG_TXT="/boot/firmware/config.txt"
CMDLINE_TXT="/boot/firmware/cmdline.txt"
MARKER_BEGIN="# >>> retroflag-picase >>>"
MARKER_END="# <<< retroflag-picase <<<"
PWRKEY_AUTOSTART="/etc/xdg/autostart/pwrkey.desktop"
PWRKEY_DIVERT="/etc/xdg/autostart/pwrkey.desktop.retroflag-disabled"
BACKUP_SUFFIX=".retroflag-orig"

if [[ $EUID -ne 0 ]]; then
    echo "This installer must be run as root (try: sudo $0)" >&2
    exit 1
fi

if [[ ! -f "$CONFIG_TXT" ]]; then
    echo "Cannot find $CONFIG_TXT — is this a Raspberry Pi with the standard boot layout?" >&2
    exit 1
fi

echo "==> Installing OS packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
    python3-venv \
    python3-lgpio \
    raspi-utils-core

echo "==> Preparing ${ENV_FILE}"
if [[ ! -f "$ENV_FILE" ]]; then
    install -m 0644 "${REPO_DIR}/config/retroflag.env" "$ENV_FILE"
else
    echo "    (kept existing $ENV_FILE)"
fi

# shellcheck disable=SC1090
source "$ENV_FILE"
: "${BUTTON_GPIO:?BUTTON_GPIO missing from $ENV_FILE}"
: "${LED_GPIO:?LED_GPIO missing from $ENV_FILE}"
# Older installs predate POWEREN_GPIO; default to the RetroFlag wiring.
if ! grep -q '^POWEREN_GPIO=' "$ENV_FILE"; then
    printf '\n# Power enable pin (see README). Empty disables the feature.\nPOWEREN_GPIO=4\n' >>"$ENV_FILE"
    POWEREN_GPIO=4
    echo "    added POWEREN_GPIO=4 to $ENV_FILE"
fi
POWEREN_GPIO="${POWEREN_GPIO:-}"
# Older installs predate POWER_KEY_ACTION.
if ! grep -q '^POWER_KEY_ACTION=' "$ENV_FILE"; then
    printf '\n# reboot (stock RetroFlag behaviour) or poweroff. See README.\nPOWER_KEY_ACTION=reboot\n' >>"$ENV_FILE"
    POWER_KEY_ACTION=reboot
    echo "    added POWER_KEY_ACTION=reboot to $ENV_FILE"
fi
POWER_KEY_ACTION="${POWER_KEY_ACTION:-reboot}"
case "$POWER_KEY_ACTION" in
    reboot | poweroff) ;;
    *) echo "POWER_KEY_ACTION must be 'reboot' or 'poweroff', got '$POWER_KEY_ACTION'" >&2; exit 1 ;;
esac

echo "==> Deploying daemon to ${INSTALL_DIR}"
install -d -m 0755 "$INSTALL_DIR"
install -m 0755 "${REPO_DIR}/daemon/retroflag_led.py" "${INSTALL_DIR}/retroflag_led.py"

if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
    echo "==> Creating virtualenv (system-site-packages for lgpio)"
    python3 -m venv --system-site-packages "$VENV_DIR"
fi
"${VENV_DIR}/bin/pip" install --quiet --upgrade pip
"${VENV_DIR}/bin/pip" install --quiet 'gpiozero>=2.0'

echo "==> Updating ${CONFIG_TXT}"
# Remove any previous managed block, then append a fresh one.
if grep -qF "$MARKER_BEGIN" "$CONFIG_TXT"; then
    sed -i "/${MARKER_BEGIN}/,/${MARKER_END}/d" "$CONFIG_TXT"
fi

# Trim trailing blank lines then append.
sed -i -e :a -e '/^\s*$/{$d;N;ba' -e '}' "$CONFIG_TXT"

# GPIO 14/15 are UART0 TXD/RXD. On the stock Raspberry Pi OS image the
# firmware puts them in ALT mode (`pinctrl get 14` reports "a5 ... TXD1"), so
# the LED pin is owned by the UART and the daemon cannot drive it. Turning the
# UART off inside the managed block overrides the stock `enable_uart=1`
# because the firmware keeps the last assignment it reads.
UART_CONFLICT=0
if [[ "$LED_GPIO" == "14" || "$LED_GPIO" == "15" ]]; then
    UART_CONFLICT=1
fi

{
    printf '\n%s\n' "$MARKER_BEGIN"
    printf '[all]\n'
    printf '# Kernel-native power button — generates KEY_POWER, handled by systemd-logind.\n'
    printf 'dtoverlay=gpio-shutdown,gpio_pin=%s,active_low=1,gpio_pull=up\n' "$BUTTON_GPIO"
    if [[ -n "$POWEREN_GPIO" ]]; then
        printf '# Hold the case power rail from the very first boot stage.\n'
        printf 'gpio=%s=op,dh\n' "$POWEREN_GPIO"
    fi
    if [[ $UART_CONFLICT -eq 1 ]]; then
        printf '# GPIO %s belongs to UART0; release it so the LED daemon can drive the pin.\n' "$LED_GPIO"
        printf 'enable_uart=0\n'
    fi
    printf '%s\n' "$MARKER_END"
} >>"$CONFIG_TXT"
echo "    added gpio-shutdown (GPIO ${BUTTON_GPIO})"
if [[ -n "$POWEREN_GPIO" ]]; then
    echo "    added power-enable hold (GPIO ${POWEREN_GPIO})"
fi

# gpio-poweroff is deliberately NOT used. Its own documentation states that
# active_low needs a custom dt-blob.bin to avoid powering down mid-boot, that
# it makes reboot drop the pin too, and that it disables waking the Pi by
# pulling GPIO 3 low. The shutdown hook below does the same job safely.

echo "==> Installing shutdown hook"
install -D -m 0755 "${REPO_DIR}/systemd/retroflag-picase.shutdown" "$SHUTDOWN_HOOK"
echo "    ${SHUTDOWN_HOOK}"

if [[ $UART_CONFLICT -eq 1 ]]; then
    echo "==> Freeing UART0 (LED is on GPIO ${LED_GPIO})"
    echo "    enable_uart=0 added to ${CONFIG_TXT}"

    # The kernel console must go too, otherwise it keeps writing to the pin.
    if [[ -f "$CMDLINE_TXT" ]] && grep -qE 'console=(serial0|ttyS0|ttyAMA0)[^ ]*' "$CMDLINE_TXT"; then
        [[ -f "${CMDLINE_TXT}${BACKUP_SUFFIX}" ]] || cp -a "$CMDLINE_TXT" "${CMDLINE_TXT}${BACKUP_SUFFIX}"
        sed -i -E 's/[[:space:]]*console=(serial0|ttyS0|ttyAMA0)[^[:space:]]*//g' "$CMDLINE_TXT"
        echo "    serial console removed from ${CMDLINE_TXT} (backup: ${CMDLINE_TXT}${BACKUP_SUFFIX})"
    fi

    for getty in serial-getty@ttyS0.service serial-getty@ttyAMA0.service; do
        if systemctl list-unit-files "$getty" >/dev/null 2>&1; then
            systemctl disable --now "$getty" >/dev/null 2>&1 || true
        fi
        systemctl mask "$getty" >/dev/null 2>&1 || true
    done
    echo "    serial getty disabled and masked"
fi

echo "==> Releasing the power key for systemd-logind"
# Raspberry Pi OS desktop ships rpi-gui-nop, which autostarts
#   systemd-inhibit --what=handle-power-key rpi-gui-nop
# That is a *block* inhibitor: logind logs "Power key pressed short" and then
# does nothing, so the case button never powers the Pi off.
if [[ -f "$PWRKEY_AUTOSTART" ]]; then
    dpkg-divert --package retroflag-picase --quiet --rename \
        --divert "$PWRKEY_DIVERT" --add "$PWRKEY_AUTOSTART"
    echo "    diverted $PWRKEY_AUTOSTART"
fi
# Kill any inhibitor already running so no logout/reboot is required.
pkill -f 'systemd-inhibit --what=handle-power-key' 2>/dev/null || true

if systemd-inhibit --list 2>/dev/null | grep -q 'handle-power-key'; then
    echo "    WARNING: something still blocks handle-power-key:" >&2
    systemd-inhibit --list | grep 'handle-power-key' >&2
fi

echo "==> Configuring the power key action (${POWER_KEY_ACTION})"
# The stock RetroFlag script runs `shutdown -r now` on the button: the case
# microcontroller is what cuts power, and it expects the SoC to reset. A plain
# poweroff leaves the SoC halted and the case stays powered.
install -d -m 0755 "$(dirname "$LOGIND_DROPIN")"
cat >"$LOGIND_DROPIN" <<EOF
[Login]
HandlePowerKey=${POWER_KEY_ACTION}
HandlePowerKeyLongPress=poweroff
EOF
systemctl restart systemd-logind
echo "    ${LOGIND_DROPIN}"

echo "==> Installing systemd unit"
install -m 0644 "${REPO_DIR}/systemd/${SERVICE_NAME}" "$SYSTEMD_UNIT"
systemctl daemon-reload
systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true
systemctl enable "$SERVICE_NAME" >/dev/null
# Restart if already running so it picks up new env / code.
if systemctl is-active --quiet "$SERVICE_NAME"; then
    systemctl restart "$SERVICE_NAME"
else
    systemctl start "$SERVICE_NAME" || true
fi

sleep 2
if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "    WARNING: ${SERVICE_NAME} is not running:" >&2
    journalctl -u "$SERVICE_NAME" -n 15 --no-pager >&2
elif ! journalctl -u "$SERVICE_NAME" -b --no-pager | grep -q 'Pin factory: LGPIOFactory'; then
    echo "    WARNING: the daemon is not using the lgpio backend." >&2
fi

cat <<EOF

Done.

Next step (REQUIRED — the firmware changes only apply at boot):
    sudo reboot

After reboot:
  * LED (GPIO ${LED_GPIO}) will be solid ON.
  * Pressing the case button (GPIO ${BUTTON_GPIO}) triggers a clean poweroff.
  * On shutdown the LED blinks for a few seconds and then goes off.
  * At the end of the poweroff GPIO ${POWEREN_GPIO:-<disabled>} is driven low so the case cuts power.
  * The button also wakes the Pi from halt (hardware feature of GPIO 3).

Verify service any time with:
    systemctl status ${SERVICE_NAME}
    journalctl -u ${SERVICE_NAME} -e
EOF

if [[ $UART_CONFLICT -eq 1 ]]; then
    cat <<EOF

NOTE: the serial console was disabled because the LED shares GPIO ${LED_GPIO} with UART0.
      To recover it, run ./uninstall.sh, or restore ${CMDLINE_TXT}${BACKUP_SUFFIX}
      from another machine by mounting the boot partition of the SD card.
EOF
fi
