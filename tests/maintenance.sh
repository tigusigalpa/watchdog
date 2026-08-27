#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly WATCHDOG_SCRIPT="${PROJECT_DIR}/service-watchdog.sh"
TEST_DIRECTORY="$(mktemp -d)"

cleanup() { rm -rf -- "$TEST_DIRECTORY"; }
trap cleanup EXIT

for command_name in date yq curl flock timeout; do
    command -v "$command_name" >/dev/null 2>&1 || { printf 'Missing test dependency: %s\n' "$command_name" >&2; exit 2; }
done

TODAY="$(LC_ALL=C date '+%a')"
cat >"${TEST_DIRECTORY}/config.yaml" <<EOF
settings:
  log_file: ${TEST_DIRECTORY}/watchdog.log
  lock_file: ${TEST_DIRECTORY}/watchdog.lock
  state_directory: ${TEST_DIRECTORY}/state
  default_attempts: 1
  default_retry_delay: 0
  default_action_cooldown: 0
hooks:
  on_failure:
    - command: [touch, ${TEST_DIRECTORY}/failure-hook]
services:
  - name: maintenance-transition
    check:
      type: command
      commands:
        - command: [false]
    actions:
      commands:
        - command: [touch, ${TEST_DIRECTORY}/remediation-ran]
    maintenance:
      windows:
        - name: active-test-window
          days: "${TODAY}"
          time: "00:00-23:59"
EOF

set +e
bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/config.yaml" -s maintenance-transition
status=$?
set -e
[[ "$status" == 1 ]]
[[ ! -e "${TEST_DIRECTORY}/remediation-ran" ]]
[[ ! -e "${TEST_DIRECTORY}/failure-hook" ]]
[[ -e "${TEST_DIRECTORY}/state/maintenance-transition.maintenance-deferred-failure" ]]

# Removing the active window simulates the first scheduler invocation after it.
sed -i '/    maintenance:/,$d' "${TEST_DIRECTORY}/config.yaml"
set +e
bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/config.yaml" -s maintenance-transition
status=$?
set -e
[[ "$status" == 1 ]]
[[ -e "${TEST_DIRECTORY}/failure-hook" ]]
[[ ! -e "${TEST_DIRECTORY}/state/maintenance-transition.maintenance-deferred-failure" ]]

printf 'Maintenance window test passed.\n'
