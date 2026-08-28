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

mkdir -p "${TEST_DIRECTORY}/metrics"
touch "${TEST_DIRECTORY}/healthy"
cat >"${TEST_DIRECTORY}/config.yaml" <<EOF
settings:
  log_file: ${TEST_DIRECTORY}/watchdog.log
  lock_file: ${TEST_DIRECTORY}/watchdog.lock
  state_directory: ${TEST_DIRECTORY}/state
  default_attempts: 1
  default_retry_delay: 0
metrics:
  enabled: true
  textfile_directory: ${TEST_DIRECTORY}/metrics
  filename: watchdog.prom
  prefix: watchdog
  static_labels:
    instance: test-host
services:
  - name: prometheus-check
    check:
      type: command
      commands:
        - command: [test, -f, ${TEST_DIRECTORY}/healthy]
EOF

bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/config.yaml" -s prometheus-check
METRICS_FILE="${TEST_DIRECTORY}/metrics/watchdog.prom"
[[ -f "$METRICS_FILE" ]]
grep -F '# HELP watchdog_service_state' "$METRICS_FILE" >/dev/null
grep -F 'watchdog_service_state{service="prometheus-check",check_type="command",instance="test-host"} 0' "$METRICS_FILE" >/dev/null
grep -F 'watchdog_service_last_check_timestamp' "$METRICS_FILE" >/dev/null
tail -c 1 "$METRICS_FILE" | od -An -t x1 | grep -F '0a' >/dev/null

printf 'Prometheus metrics test passed.\n'
