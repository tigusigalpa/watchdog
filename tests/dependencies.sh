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
services:
  - name: db
    check:
      type: command
      commands:
        - command: [false]
  - name: api
    check:
      type: command
      commands:
        - command: [touch, ${TEST_DIRECTORY}/api-checked]
    actions:
      commands:
        - command: [touch, ${TEST_DIRECTORY}/api-remediated]
    depends_on:
      - name: db
        required: true
  - name: frontend
    check:
      type: command
      commands:
        - command: [touch, ${TEST_DIRECTORY}/frontend-checked]
    depends_on:
      - name: api
        required: true
  - name: soft-dependent
    check:
      type: command
      commands:
        - command: [touch, ${TEST_DIRECTORY}/soft-checked]
    depends_on:
      - name: db
        required: false
EOF

set +e
bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/config.yaml"
status=$?
set -e
[[ "$status" == 1 ]]
[[ "$(<"${TEST_DIRECTORY}/state/db.state")" == unavailable ]]
[[ "$(<"${TEST_DIRECTORY}/state/api.state")" == dependency_failed ]]
[[ "$(<"${TEST_DIRECTORY}/state/frontend.state")" == dependency_failed ]]
[[ ! -e "${TEST_DIRECTORY}/api-checked" && ! -e "${TEST_DIRECTORY}/api-remediated" ]]
[[ ! -e "${TEST_DIRECTORY}/frontend-checked" ]]
[[ -e "${TEST_DIRECTORY}/soft-checked" ]]
grep -F 'service=api dependency=db required=true dependency_state=unavailable action=skip' "${TEST_DIRECTORY}/watchdog.log" >/dev/null

printf 'Dependency chain test passed.\n'
