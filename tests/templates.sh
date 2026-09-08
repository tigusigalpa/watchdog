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

for command_name in "$PYTHON_BIN" yq curl flock timeout date mktemp; do
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

"$PYTHON_BIN" - "$PORT" >"${TEST_DIRECTORY}/server.log" 2>&1 <<'PY' &
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

class SlowHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        time.sleep(2)
        self.send_response(200)
        self.end_headers()
    def log_message(self, *_):
        pass

HTTPServer(("127.0.0.1", int(sys.argv[1])), SlowHandler).serve_forever()
PY
SERVER_PID=$!

server_ready=0
for _ in 1 2 3; do
    if curl --silent --max-time 3 "http://127.0.0.1:${PORT}/" >/dev/null 2>&1; then
        server_ready=1
        break
    fi
    sleep 0.1
done
(( server_ready == 1 )) || { printf 'Slow HTTP test server did not start.\n' >&2; exit 1; }

cat >"${TEST_DIRECTORY}/deep.yaml" <<EOF
settings:
  log_file: ${TEST_DIRECTORY}/watchdog.log
  lock_file: ${TEST_DIRECTORY}/watchdog.lock
  state_directory: ${TEST_DIRECTORY}/state
  default_timeout: 5
  default_attempts: 1
  default_retry_delay: 0
  default_action_timeout: 5
  default_action_cooldown: 0
templates:
  default:
    check: { type: http, timeout: 1, attempts: 1 }
services:
  - name: inherited-timeout
    template: default
    check: { url: http://127.0.0.1:${PORT}/ }
EOF

set +e
bash "$WATCHDOG_SCRIPT" -n -c "${TEST_DIRECTORY}/deep.yaml"
watchdog_status=$?
set -e
[[ "$watchdog_status" == 1 ]]
grep -F 'template=default service=inherited-timeout mode=deep result=merged' "${TEST_DIRECTORY}/watchdog.log" >/dev/null
grep -F 'curl_exit=28' "${TEST_DIRECTORY}/watchdog.log" >/dev/null

cat >"${TEST_DIRECTORY}/shallow.yaml" <<EOF
settings:
  log_file: ${TEST_DIRECTORY}/shallow.log
  lock_file: ${TEST_DIRECTORY}/shallow.lock
  state_directory: ${TEST_DIRECTORY}/shallow-state
  default_timeout: 5
  default_attempts: 1
  default_retry_delay: 0
  default_action_timeout: 5
  default_action_cooldown: 0
templates:
  default:
    check: { type: http, timeout: 1 }
services:
  - name: shallow-replacement
    template: default
    template_mode: shallow
    check: { type: http, url: http://127.0.0.1:${PORT}/ }
EOF

set +e
bash "$WATCHDOG_SCRIPT" -n -c "${TEST_DIRECTORY}/shallow.yaml"
watchdog_status=$?
set -e
[[ "$watchdog_status" == 0 ]]
grep -F 'template=default service=shallow-replacement mode=shallow result=merged' "${TEST_DIRECTORY}/shallow.log" >/dev/null
grep -F 'service=shallow-replacement result=healthy' "${TEST_DIRECTORY}/shallow.log" >/dev/null

printf 'Template expansion test passed.\n'
