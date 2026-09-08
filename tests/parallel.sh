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

for command_name in bash yq curl flock timeout date mktemp; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'Missing test dependency: %s\n' "$command_name" >&2
        exit 2
    }
done

cat >"${TEST_DIRECTORY}/config.yaml" <<EOF
settings:
  log_file: ${TEST_DIRECTORY}/watchdog.log
  lock_file: ${TEST_DIRECTORY}/watchdog.lock
  state_directory: ${TEST_DIRECTORY}/state
  default_timeout: 5
  default_attempts: 1
  default_retry_delay: 0
  default_action_timeout: 5
  default_action_cooldown: 0

parallel:
  enabled: true
  max_jobs: 3
  timeout: 5
  temp_dir: ${TEST_DIRECTORY}/parallel-tmp

services:
  - name: slow-one
    check: { type: command, commands: [{ command: [bash, -c, "sleep 1"] }] }
  - name: slow-two
    check: { type: command, commands: [{ command: [bash, -c, "sleep 1"] }] }
  - name: slow-three
    check: { type: command, commands: [{ command: [bash, -c, "sleep 1"] }] }
EOF

bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/config.yaml"
for service_name in slow-one slow-two slow-three; do
    [[ "$(<"${TEST_DIRECTORY}/state/${service_name}.state")" == healthy ]]
done

duration_line="$(grep 'phase=check mode=parallel completed=3' "${TEST_DIRECTORY}/watchdog.log")"
[[ "$duration_line" =~ duration_ms=([0-9]+) ]]
(( BASH_REMATCH[1] < 2500 )) || {
    printf 'Parallel check batch was unexpectedly slow: %sms\n' "${BASH_REMATCH[1]}" >&2
    exit 1
}

printf 'Parallel checks test passed.\n'
