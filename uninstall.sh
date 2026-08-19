#!/usr/bin/env bash
# retroflag-picase uninstaller.

set -euo pipefail

INSTALL_DIR="/opt/retroflag-picase"
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
BACKUP_SUFFIX=".retroflag-orig"

if [[ $EUID -ne 0 ]]; then
    echo "This uninstaller must be run as root (try: sudo $0)" >&2
    exit 1
fi

echo "==> Stopping and disabling ${SERVICE_NAME}"
systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
rm -f "$SYSTEMD_UNIT"
systemctl daemon-reload

echo "==> Removing daemon files"
rm -rf "$INSTALL_DIR"
rm -f "$SHUTDOWN_HOOK"
if [[ -f "$LOGIND_DROPIN" ]]; then
    rm -f "$LOGIND_DROPIN"
    systemctl restart systemd-logind 2>/dev/null || true
    echo "    logind drop-in removed"
fi

echo "==> Removing ${ENV_FILE}"
rm -f "$ENV_FILE"

echo "==> Cleaning ${CONFIG_TXT}"
if [[ -f "$CONFIG_TXT" ]] && grep -qF "$MARKER_BEGIN" "$CONFIG_TXT"; then
    sed -i "/${MARKER_BEGIN}/,/${MARKER_END}/d" "$CONFIG_TXT"
    echo "    dtoverlay lines removed"
else
    echo "    nothing to remove"
fi

echo "==> Restoring ${PWRKEY_AUTOSTART}"
if dpkg-divert --list retroflag-picase | grep -q "$PWRKEY_AUTOSTART"; then
    dpkg-divert --package retroflag-picase --quiet --rename \
        --remove "$PWRKEY_AUTOSTART"
    echo "    divert removed"
else
    echo "    nothing to restore"
fi

echo "==> Restoring the serial console"
if [[ -f "${CMDLINE_TXT}${BACKUP_SUFFIX}" ]]; then
    mv "${CMDLINE_TXT}${BACKUP_SUFFIX}" "$CMDLINE_TXT"
    echo "    ${CMDLINE_TXT} restored from backup"
else
    echo "    no cmdline backup to restore"
fi
for getty in serial-getty@ttyS0.service serial-getty@ttyAMA0.service; do
    systemctl unmask "$getty" >/dev/null 2>&1 || true
done
echo "    serial getty unmasked"

cat <<EOF

Done. Reboot to fully release the GPIO pins:
    sudo reboot
EOF
