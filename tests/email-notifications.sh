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

for command_name in base64 flock timeout yq; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'Missing test dependency: %s\n' "$command_name" >&2
        exit 2
    }
done

mkdir -p "${TEST_DIRECTORY}/bin"
cat >"${TEST_DIRECTORY}/bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail

upload_file=""
while (( $# > 0 )); do
    case "$1" in
        --upload-file)
            upload_file="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

[[ -n "$upload_file" && -r "$upload_file" ]]
printf '%s\n' '--- MESSAGE ---' >>"$WATCHDOG_TEST_MAILBOX"
cat -- "$upload_file" >>"$WATCHDOG_TEST_MAILBOX"
FAKE_CURL
chmod 0755 "${TEST_DIRECTORY}/bin/curl"

cat >"${TEST_DIRECTORY}/bin/remediate" <<'REMEDIATE'
#!/usr/bin/env bash
set -euo pipefail

if [[ -f "$WATCHDOG_TEST_ALLOW_RECOVERY" ]]; then
    touch "$WATCHDOG_TEST_HEALTHY_FILE"
fi
REMEDIATE
chmod 0755 "${TEST_DIRECTORY}/bin/remediate"

export PATH="${TEST_DIRECTORY}/bin:${PATH}"
export WATCHDOG_TEST_MAILBOX="${TEST_DIRECTORY}/mailbox.eml"
export WATCHDOG_TEST_ALLOW_RECOVERY="${TEST_DIRECTORY}/allow-recovery"
export WATCHDOG_TEST_HEALTHY_FILE="${TEST_DIRECTORY}/healthy"

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

notifications:
  email:
    enabled: true
    smtp:
      url: smtps://smtp.example.test:465
      from: watchdog@example.test
      tls_required: true
      insecure_skip_verify: false
      timeout: 5
    recipients:
      - operator@example.test
    failure:
      subject: "FAILURE {{service}}"
      body: "failure event={{event}} action={{action_status}} detail={{detail}}"
    recovery:
      subject: "RECOVERY {{service}}"
      body: "recovery event={{event}} action={{action_status}} detail={{detail}}"

services:
  - name: email-transition
    check:
      type: command
      attempts: 1
      retry_delay: 0
      commands:
        - command: [test, -f, ${TEST_DIRECTORY}/healthy]
    actions:
      cooldown: 0
      verify_after: 0
      commands:
        - command: [remediate]
EOF

set +e
bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/config.yaml" -s email-transition
first_status=$?
set -e

[[ "$first_status" == 1 ]]
[[ "$(<"${TEST_DIRECTORY}/state/email-transition.state")" == unavailable ]]
[[ "$(grep -c '^Subject:' "$WATCHDOG_TEST_MAILBOX")" == 1 ]]
grep -F 'action=email event=failure' "${TEST_DIRECTORY}/watchdog.log" >/dev/null

set +e
bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/config.yaml" -s email-transition
second_status=$?
set -e

[[ "$second_status" == 1 ]]
[[ "$(<"${TEST_DIRECTORY}/state/email-transition.state")" == unavailable ]]
[[ "$(grep -c '^Subject:' "$WATCHDOG_TEST_MAILBOX")" == 1 ]]

touch "$WATCHDOG_TEST_ALLOW_RECOVERY"
set +e
bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/config.yaml" -s email-transition
third_status=$?
set -e

[[ "$third_status" == 1 ]]
[[ "$(<"${TEST_DIRECTORY}/state/email-transition.state")" == healthy ]]
[[ "$(grep -c '^Subject:' "$WATCHDOG_TEST_MAILBOX")" == 2 ]]
grep -F 'action=email event=recovery' "${TEST_DIRECTORY}/watchdog.log" >/dev/null

bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/config.yaml" -s email-transition
[[ "$(grep -c '^Subject:' "$WATCHDOG_TEST_MAILBOX")" == 2 ]]

printf 'Email notification test passed.\n'
