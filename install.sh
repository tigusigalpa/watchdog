#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SOURCE_DIR
readonly INSTALL_DIR="${INSTALL_DIR:-/opt/service-watchdog}"
readonly CONFIG_DIR="${CONFIG_DIR:-/etc/service-watchdog}"
readonly SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
readonly LOG_DIR="${LOG_DIR:-/var/log/service-watchdog}"
readonly STATE_DIR="${STATE_DIR:-/var/lib/service-watchdog}"

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'Required command not found: %s\n' "$1" >&2
        return 1
    }
}

if (( EUID != 0 )); then
    printf 'Run this installer as root.\n' >&2
    exit 1
fi

if (( BASH_VERSINFO[0] < 4 ||
      (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
    printf 'Bash 4.3 or newer is required; found %s.\n' "$BASH_VERSION" >&2
    exit 1
fi

missing_dependency=0
for command_name in base64 curl flock install systemctl timeout yq; do
    require_command "$command_name" || missing_dependency=1
done
(( missing_dependency == 0 )) || exit 1

yq_version="$(yq --version 2>/dev/null)" || {
    printf 'Cannot determine yq version.\n' >&2
    exit 1
}
if [[ ! "$yq_version" =~ version[[:space:]]+v?4\. ]]; then
    printf 'Mike Farah yq v4 is required; found: %s\n' "$yq_version" >&2
    exit 1
fi

install -d -m 0755 "$INSTALL_DIR" "$CONFIG_DIR"
install -d -m 0750 "$LOG_DIR" "$STATE_DIR"
install -d -m 0755 /run/lock
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
printf '  Version: %s\n' "$("${INSTALL_DIR}/service-watchdog.sh" --version)"
printf '  Script:  %s/service-watchdog.sh\n' "$INSTALL_DIR"
printf '  Config:  %s/config.yaml\n' "$CONFIG_DIR"
printf '  Logs:    %s\n' "$LOG_DIR"
printf '  State:   %s\n\n' "$STATE_DIR"
printf '  1. Edit: sudoedit %s/config.yaml\n' "$CONFIG_DIR"
printf '  2. Test: %s/service-watchdog.sh -c %s/config.yaml -n\n' "$INSTALL_DIR" "$CONFIG_DIR"
printf '  3. Enable: systemctl enable --now service-watchdog.timer\n'
