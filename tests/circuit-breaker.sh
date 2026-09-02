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
  - name: broken-service
    check:
      type: command
      commands:
        - command: [false]
    actions:
      cooldown: 0
      commands:
        - command: [touch, ${TEST_DIRECTORY}/remediation-ran]
    circuit_breaker:
      enabled: true
      failure_threshold: 2
      open_duration: 3600
      half_open_verify_after: 0
      notify: false
EOF

for _ in 1 2; do
    set +e
    bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/config.yaml" -s broken-service
    status=$?
    set -e
    [[ "$status" == 1 ]]
done
[[ "$(<"${TEST_DIRECTORY}/state/broken-service.circuit-state")" == open ]]
[[ "$(<"${TEST_DIRECTORY}/state/broken-service.circuit-failure-count")" == 2 ]]

rm -f -- "${TEST_DIRECTORY}/remediation-ran"
set +e
bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/config.yaml" -s broken-service
status=$?
set -e
[[ "$status" == 1 ]]
[[ ! -e "${TEST_DIRECTORY}/remediation-ran" ]]
grep -F 'circuit_state=open action=skipped reason=circuit_breaker' "${TEST_DIRECTORY}/watchdog.log" >/dev/null

printf 'Circuit breaker test passed.\n'
