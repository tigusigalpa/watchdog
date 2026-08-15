#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_DIR
readonly WATCHDOG_SCRIPT="${PROJECT_DIR}/service-watchdog.sh"
TEST_DIRECTORY="$(mktemp -d)"
SERVER_PID=""
PYTHON_BIN="${PYTHON_BIN:-python3}"

cleanup() {
    if [[ -n "$SERVER_PID" ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf -- "$TEST_DIRECTORY"
}
trap cleanup EXIT

for command_name in "$PYTHON_BIN" yq curl flock timeout; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'Missing test dependency: %s\n' "$command_name" >&2
        exit 2
    }
done

PORT="$("$PYTHON_BIN" - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"

mkdir -p "${TEST_DIRECTORY}/www"
printf 'ok\n' >"${TEST_DIRECTORY}/www/index.html"
"$PYTHON_BIN" -m http.server "$PORT" --bind 127.0.0.1 \
    --directory "${TEST_DIRECTORY}/www" >"${TEST_DIRECTORY}/server.log" 2>&1 &
SERVER_PID=$!

for _ in 1 2 3 4 5; do
    curl --silent --fail "http://127.0.0.1:${PORT}/" >/dev/null 2>&1 && break
    sleep 0.2
done

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
  - name: smoke-http
    check:
      type: http
      url: http://127.0.0.1:${PORT}/
      success_status: [200]
    actions:
      verify_after: 0
      commands:
        - command: [touch, ${TEST_DIRECTORY}/remediation-ran]
EOF

bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/config.yaml" -s smoke-http
[[ ! -e "${TEST_DIRECTORY}/remediation-ran" ]]
[[ "$(<"${TEST_DIRECTORY}/state/smoke-http.state")" == healthy ]]

kill "$SERVER_PID"
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

set +e
bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/config.yaml" -s smoke-http
watchdog_status=$?
set -e

[[ "$watchdog_status" == 1 ]]
[[ -e "${TEST_DIRECTORY}/remediation-ran" ]]
[[ "$(<"${TEST_DIRECTORY}/state/smoke-http.state")" == unavailable ]]

printf 'Smoke test passed.\n'
