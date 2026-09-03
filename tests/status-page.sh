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

touch "${TEST_DIRECTORY}/healthy"
cat >"${TEST_DIRECTORY}/config.yaml" <<EOF
settings:
  log_file: ${TEST_DIRECTORY}/watchdog.log
  lock_file: ${TEST_DIRECTORY}/watchdog.lock
  state_directory: ${TEST_DIRECTORY}/state
  default_attempts: 1
  default_retry_delay: 0
status_page:
  enabled: true
  output_directory: ${TEST_DIRECTORY}/status
  html_filename: index.html
  json_filename: status.json
  title: Test Status
  auto_refresh: 0
services:
  - name: status-service
    check:
      type: command
      commands:
        - command: [test, -f, ${TEST_DIRECTORY}/healthy]
EOF

bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/config.yaml" -s status-service
[[ -f "${TEST_DIRECTORY}/status/index.html" && -f "${TEST_DIRECTORY}/status/status.json" ]]
grep -F '<title>Test Status</title>' "${TEST_DIRECTORY}/status/index.html" >/dev/null
grep -F 'status-service' "${TEST_DIRECTORY}/status/index.html" >/dev/null
grep -F '"overall_status": "operational"' "${TEST_DIRECTORY}/status/status.json" >/dev/null
tail -c 1 "${TEST_DIRECTORY}/status/index.html" | od -An -t x1 | grep -F '0a' >/dev/null

printf 'Status page test passed.\n'
