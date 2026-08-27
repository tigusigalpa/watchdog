#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly WATCHDOG_SCRIPT="${PROJECT_DIR}/service-watchdog.sh"
TEST_DIRECTORY="$(mktemp -d)"

cleanup() { rm -rf -- "$TEST_DIRECTORY"; }
trap cleanup EXIT

for command_name in yq curl flock timeout; do
    command -v "$command_name" >/dev/null 2>&1 || { printf 'Missing test dependency: %s\n' "$command_name" >&2; exit 2; }
done

cat >"${TEST_DIRECTORY}/config.yaml" <<EOF
settings:
  log_file: ${TEST_DIRECTORY}/watchdog.log
  lock_file: ${TEST_DIRECTORY}/watchdog.lock
  state_directory: ${TEST_DIRECTORY}/state
  default_attempts: 1
  default_retry_delay: 0
  default_action_cooldown: 0
services:
  - name: escalation-transition
    check:
      type: command
      commands:
        - command: [test, -f, ${TEST_DIRECTORY}/healthy]
    actions:
      cooldown: 0
      commands:
        - command: [touch, ${TEST_DIRECTORY}/ordinary-action]
    escalation:
      enabled: true
      after_consecutive_unavailable: 3
      cooldown: 3600
      notify: false
      actions:
        commands:
          - command: [touch, ${TEST_DIRECTORY}/escalation-action]
      hooks:
        on_escalation:
          - command: [touch, ${TEST_DIRECTORY}/escalation-hook]
EOF

for _ in 1 2 3; do
    set +e
    bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/config.yaml" -s escalation-transition
    status=$?
    set -e
    [[ "$status" == 1 ]]
done

[[ "$(<"${TEST_DIRECTORY}/state/escalation-transition.unavailable-count")" == 3 ]]
[[ -e "${TEST_DIRECTORY}/ordinary-action" ]]
[[ -e "${TEST_DIRECTORY}/escalation-action" ]]
[[ -e "${TEST_DIRECTORY}/escalation-hook" ]]
grep -F 'event=escalation consecutive_unavailable=3' "${TEST_DIRECTORY}/watchdog.log" >/dev/null

touch "${TEST_DIRECTORY}/healthy"
bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/config.yaml" -s escalation-transition
[[ "$(<"${TEST_DIRECTORY}/state/escalation-transition.unavailable-count")" == 0 ]]
[[ ! -e "${TEST_DIRECTORY}/state/escalation-transition.last-escalation" ]]

printf 'Escalation test passed.\n'
