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

for command_name in yq curl flock timeout date hostname find; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'Missing test dependency: %s\n' "$command_name" >&2
        exit 2
    }
done

cat >"${TEST_DIRECTORY}/agent.yaml" <<EOF
settings:
  log_file: ${TEST_DIRECTORY}/agent.log
  lock_file: ${TEST_DIRECTORY}/agent.lock
  state_directory: ${TEST_DIRECTORY}/agent-state
  default_timeout: 2
  default_attempts: 1
  default_retry_delay: 0
  default_action_timeout: 2
  default_action_cooldown: 0
federation:
  enabled: true
  node_id: web-01
  agent:
    enabled: true
    transport: file
    report_path: ${TEST_DIRECTORY}/out/web-01.json
    heartbeat: true
  hub:
    enabled: false
services:
  - name: local-check
    check:
      type: command
      commands:
        - command: [true]
EOF

bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/agent.yaml"
[[ -f "${TEST_DIRECTORY}/out/web-01.json" ]]
[[ "$(yq eval -r '.node_id' "${TEST_DIRECTORY}/out/web-01.json")" == web-01 ]]
[[ "$(yq eval -r '.services[0].state' "${TEST_DIRECTORY}/out/web-01.json")" == healthy ]]

NOW="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
OLD="$(date -u -d '10 minutes ago' '+%Y-%m-%dT%H:%M:%SZ')"
mkdir -p "${TEST_DIRECTORY}/incoming"
cat >"${TEST_DIRECTORY}/incoming/web-01.json" <<EOF
{"node_id":"web-01","timestamp":"${NOW}","services":[{"name":"api","state":"healthy","last_transition":"${NOW}"}]}
EOF
cat >"${TEST_DIRECTORY}/incoming/web-02.json" <<EOF
{"node_id":"web-02","timestamp":"${OLD}","services":[{"name":"worker","state":"unavailable","last_transition":"${OLD}"}]}
EOF
cat >"${TEST_DIRECTORY}/hub.yaml" <<EOF
settings:
  log_file: ${TEST_DIRECTORY}/hub.log
  lock_file: ${TEST_DIRECTORY}/hub.lock
  state_directory: ${TEST_DIRECTORY}/hub-state
  default_timeout: 2
  default_attempts: 1
  default_retry_delay: 0
  default_action_timeout: 2
  default_action_cooldown: 0
federation:
  enabled: true
  hub:
    enabled: true
    incoming_dir: ${TEST_DIRECTORY}/incoming
    archive_dir: ${TEST_DIRECTORY}/archive
    max_report_age: 60
    archive_retention_days: 0
    expected_nodes: [web-01, web-02]
    notify_on:
      overall_change: false
      agent_offline: false
      any_service_change: false
services: []
EOF

set +e
bash "$WATCHDOG_SCRIPT" -c "${TEST_DIRECTORY}/hub.yaml"
hub_status=$?
set -e
[[ "$hub_status" == 1 ]]
[[ "$(yq eval -r '.last_overall_status' "${TEST_DIRECTORY}/hub-state/federation-hub-state.json")" == degraded ]]
[[ "$(yq eval -r '.agents."web-02".last_status' "${TEST_DIRECTORY}/hub-state/federation-hub-state.json")" == offline ]]
[[ "$(find "${TEST_DIRECTORY}/archive" -type f -name '*.json' | awk 'END { print NR }')" == 2 ]]
[[ ! -e "${TEST_DIRECTORY}/incoming/web-01.json" ]]
[[ ! -e "${TEST_DIRECTORY}/incoming/web-02.json" ]]

printf 'Federation test passed.\n'
