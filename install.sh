#!/usr/bin/env bash
set -euo pipefail

readonly SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly INSTALL_DIR="${INSTALL_DIR:-/opt/service-watchdog}"
readonly CONFIG_DIR="${CONFIG_DIR:-/etc/service-watchdog}"
readonly SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"

if (( EUID != 0 )); then
    printf 'Run this installer as root.\n' >&2
    exit 1
fi

install -d -m 0755 "$INSTALL_DIR" "$CONFIG_DIR"
install -m 0755 "${SOURCE_DIR}/service-watchdog.sh" "${INSTALL_DIR}/service-watchdog.sh"

if [[ ! -e "${CONFIG_DIR}/config.yaml" ]]; then
    install -m 0640 "${SOURCE_DIR}/config.example.yaml" "${CONFIG_DIR}/config.yaml"
    printf 'Created %s. Edit it before enabling the timer.\n' "${CONFIG_DIR}/config.yaml"
else
    printf 'Preserved existing %s.\n' "${CONFIG_DIR}/config.yaml"
fi

install -m 0644 "${SOURCE_DIR}/packaging/systemd/service-watchdog.service" \
    "${SYSTEMD_DIR}/service-watchdog.service"
install -m 0644 "${SOURCE_DIR}/packaging/systemd/service-watchdog.timer" \
    "${SYSTEMD_DIR}/service-watchdog.timer"

systemctl daemon-reload
printf '\nInstalled successfully. Next steps:\n'
printf '  1. Edit %s\n' "${CONFIG_DIR}/config.yaml"
printf '  2. Test: %s/service-watchdog.sh -c %s/config.yaml -n\n' "$INSTALL_DIR" "$CONFIG_DIR"
printf '  3. Enable: systemctl enable --now service-watchdog.timer\n'
