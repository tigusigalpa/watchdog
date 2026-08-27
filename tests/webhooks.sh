#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_DIR
readonly WATCHDOG_SCRIPT="${PROJECT_DIR}/service-watchdog.sh"
TEST_DIRECTORY="$(mktemp -d)"
SERVER_PID=""
PYTHON_BIN="${PYTHON_BIN:-python3}"

cleanup() {
    [[ -z "$SERVER_PID" ]] || kill "$SERVER_PID" 2>/dev/null || true
    [[ -z "$SERVER_PID" ]] || wait "$SERVER_PID" 2>/dev/null || true
    rm -rf -- "$TEST_DIRECTORY"
}
trap cleanup EXIT

for command_name in "$PYTHON_BIN" curl yq flock timeout; do
    command -v "$command_name" >/dev/null 2>&1 || { printf 'Missing test dependency: %s\n' "$command_name" >&2; exit 2; }
done

PORT="$("$PYTHON_BIN" - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"

"$PYTHON_BIN" - "$PORT" "${TEST_DIRECTORY}/requests.log" <<'PY' >"${TEST_DIRECTORY}/server.log" 2>&1 &
import http.server, sys
class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        size = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(size).decode("utf-8")
        with open(sys.argv[2], "a", encoding="utf-8") as out:
            out.write(self.path + "\t" + body + "\n")
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def log_message(self, *_): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
PY
SERVER_PID=$!

# The Telegram API hostname is fixed. This narrow test double verifies the
# Bot API request while the local server receives the other three webhooks.
mkdir -p "${TEST_DIRECTORY}/bin"
cat >"${TEST_DIRECTORY}/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
    [[ "$arg" == https://api.telegram.org/* ]] || continue
    printf '%q ' "$@" >>"$WATCHDOG_TEST_TELEGRAM_ARGS"; printf '\n' >>"$WATCHDOG_TEST_TELEGRAM_ARGS"
    for ((i = 1; i <= $#; i++)); do
        if [[ "${!i}" == --output ]]; then
            next=$((i + 1)); printf '%s' '{"ok":true}' >"${!next}"
        fi
    done
    printf '200'
    exit 0
done
exec "$WATCHDOG_TEST_REAL_CURL" "$@"
CURL
chmod 0755 "${TEST_DIRECTORY}/bin/curl"

export WATCHDOG_TEST_REAL_CURL="$(command -v curl)"
export WATCHDOG_TEST_TELEGRAM_ARGS="${TEST_DIRECTORY}/telegram.args"
export PATH="${TEST_DIRECTORY}/bin:${PATH}"
export WATCHDOG_TG_BOT_TOKEN='test-token'
export WATCHDOG_DISCORD_WEBHOOK_URL="http://127.0.0.1:${PORT}/discord"
export WATCHDOG_SLACK_WEBHOOK_URL="http://127.0.0.1:${PORT}/slack"
export WATCHDOG_NTFY_TOKEN='test-ntfy-token'

cat >"${TEST_DIRECTORY}/config.yaml" <<EOF
settings:
  log_file: ${TEST_DIRECTORY}/watchdog.log
  lock_file: ${TEST_DIRECTORY}/watchdog.lock
  state_directory: ${TEST_DIRECTORY}/state
  default_attempts: 1
  default_retry_delay: 0
  default_action_cooldown: 0
notifications:
  webhooks:
    telegram:
      enabled: true
      bot_token_env: WATCHDOG_TG_BOT_TOKEN
      chat_id: "-100123"
      thread_id: "42"
    discord:
      enabled: true
      webhook_url_env: WATCHDOG_DISCORD_WEBHOOK_URL
    slack:
      enabled: true
      webhook_url_env: WATCHDOG_SLACK_WEBHOOK_URL
    ntfy:
      enabled: true
      url: http://127.0.0.1:${PORT}/ntfy
      token_env: WATCHDOG_NTFY_TOKEN
      priority: urgent
services:
  - name: webhook-transition
    check:
      type: command
      attempts: 1
      commands:
        - command: [test, -f, ${TEST_DIRECTORY}/healthy]
    actions: { commands: [] }
EOF

set +e
bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/config.yaml" -s webhook-transition
status=$?
set -e
[[ "$status" == 1 ]]
[[ "$(grep -c 'result=webhook-sent event=failure' "${TEST_DIRECTORY}/watchdog.log")" == 4 ]]
grep -F 'message_thread_id=42' "$WATCHDOG_TEST_TELEGRAM_ARGS" >/dev/null
grep -F 'webhook-transition' "${TEST_DIRECTORY}/requests.log" >/dev/null

touch "${TEST_DIRECTORY}/healthy"
bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/config.yaml" -s webhook-transition
[[ "$(grep -c 'result=webhook-sent event=recovery' "${TEST_DIRECTORY}/watchdog.log")" == 4 ]]

printf 'Webhook notification test passed.\n'
