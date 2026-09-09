#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_DIR
readonly WATCHDOG_SCRIPT="${PROJECT_DIR}/service-watchdog.sh"
TEST_DIRECTORY="$(mktemp -d)"

cleanup() {
    rm -rf -- "$TEST_DIRECTORY"
}
trap cleanup EXIT

for command_name in bash yq curl flock timeout date mktemp awk df; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'Missing test dependency: %s\n' "$command_name" >&2
        exit 2
    }
done

mkdir -p "${TEST_DIRECTORY}/state"
printf 'unavailable\n' >"${TEST_DIRECTORY}/state/conditional-file.state"
touch "${TEST_DIRECTORY}/allow-check"

cat >"${TEST_DIRECTORY}/config.yaml" <<EOF
settings:
  log_file: ${TEST_DIRECTORY}/watchdog.log
  lock_file: ${TEST_DIRECTORY}/watchdog.lock
  state_directory: ${TEST_DIRECTORY}/state
  default_timeout: 2
  default_attempts: 1
  default_retry_delay: 0
  default_action_timeout: 5
  default_action_cooldown: 0

services:
  - name: conditional-file
    check:
      type: command
      commands:
        - command: [bash, -c, "touch ${TEST_DIRECTORY}/file-check-ran"]
    only_if:
      - type: file_exists
        path: ${TEST_DIRECTORY}/allow-check
        invert: true

  - name: load-allowed
    check:
      type: command
      commands:
        - command: [bash, -c, "touch ${TEST_DIRECTORY}/load-allowed-ran"]
    only_if:
      - type: load_average
        max_1min: 999.0

  - name: load-blocked
    check:
      type: command
      commands:
        - command: [bash, -c, "touch ${TEST_DIRECTORY}/load-blocked-ran"]
    only_if:
      - type: load_average
        max_1min: 0.0
EOF

bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/config.yaml"
[[ ! -e "${TEST_DIRECTORY}/file-check-ran" ]]
[[ "$(<"${TEST_DIRECTORY}/state/conditional-file.state")" == unavailable ]]
[[ -e "${TEST_DIRECTORY}/load-allowed-ran" ]]
[[ ! -e "${TEST_DIRECTORY}/load-blocked-ran" ]]
grep -F 'service=conditional-file only_if=false' "${TEST_DIRECTORY}/watchdog.log" >/dev/null
grep -F 'service=load-allowed only_if=true conditions=1' "${TEST_DIRECTORY}/watchdog.log" >/dev/null

rm -f -- "${TEST_DIRECTORY}/allow-check"
bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/config.yaml" -s conditional-file
[[ -e "${TEST_DIRECTORY}/file-check-ran" ]]
[[ "$(<"${TEST_DIRECTORY}/state/conditional-file.state")" == healthy ]]

printf 'Conditional checks test passed.\n'
