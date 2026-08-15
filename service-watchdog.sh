#!/usr/bin/env bash
# Universal one-shot watchdog for HTTP endpoints, TCP ports, and commands.
# Requires Bash >= 4.3, curl, yq v4, flock, and GNU timeout/coreutils.

set -uo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_FILE="${WATCHDOG_CONFIG:-${SCRIPT_DIR}/config.yaml}"
ONLY_SERVICE=""
DRY_RUN=0

LOG_FILE=""
LOCK_FILE=""
STATE_DIRECTORY=""
TEMP_DIRECTORY=""

DEFAULT_TIMEOUT=10
DEFAULT_ATTEMPTS=2
DEFAULT_RETRY_DELAY=2
DEFAULT_ACTION_TIMEOUT=120
DEFAULT_ACTION_COOLDOWN=300

CHECK_DETAIL=""
CHECK_HTTP_STATUS=""
CHECK_EXIT_CODE=""
CURRENT_SERVICE=""
CURRENT_CHECK_TYPE=""

ACTION_ATTEMPTED=0
UNHEALTHY_FOUND=0

usage() {
    cat <<EOF
Usage:
  ${SCRIPT_NAME} [-c /path/to/config.yaml] [-s service_name] [-n]

Options:
  -c FILE   YAML configuration file.
  -s NAME   Check only one configured service.
  -n        Dry run: perform checks, but do not run actions, hooks, or write state.
  -h        Show this help.

Environment:
  WATCHDOG_CONFIG   Alternative default configuration path.
EOF
}

bootstrap_log() {
    local level="$1"
    shift
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$level" "$*" >&2
}

log() {
    local level="$1"
    shift
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$level" "$*" >>"$LOG_FILE"
}

die() {
    local message="$1"
    if [[ -n "${LOG_FILE:-}" && -w "$LOG_FILE" ]]; then
        log CRITICAL "$message"
    else
        bootstrap_log CRITICAL "$message"
    fi
    exit 2
}

cleanup() {
    if [[ -n "${TEMP_DIRECTORY:-}" && -d "$TEMP_DIRECTORY" ]]; then
        rm -rf -- "$TEMP_DIRECTORY"
    fi
}

trap cleanup EXIT
trap 'die "Execution interrupted by signal."' HUP INT TERM

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

yaml_read() {
    yq eval -r "$1" "$CONFIG_FILE"
}

is_positive_integer() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 > 0 ))
}

is_non_negative_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

validate_string() {
    local expression="$1"
    local description="$2"
    local value_type
    value_type="$(yaml_read "${expression} | type" 2>/dev/null)" ||
        die "Cannot read ${description}."
    [[ "$value_type" == "!!str" ]] || die "${description} must be a string."
}

validate_command_sequence() {
    local expression="$1"
    local description="$2"
    local allow_empty="${3:-false}"
    local sequence_type sequence_count command_index command_type command_length
    local argument_index argument_type working_directory_type timeout_value

    sequence_type="$(yaml_read "${expression} | type" 2>/dev/null)" ||
        die "Cannot read ${description}."
    [[ "$sequence_type" == "!!seq" ]] || die "${description} must be a YAML array."

    sequence_count="$(yaml_read "${expression} | length")"
    if (( sequence_count == 0 )); then
        [[ "$allow_empty" == "true" ]] || die "${description} must not be empty."
        return 0
    fi

    for ((command_index = 0; command_index < sequence_count; command_index++)); do
        command_type="$(yaml_read "${expression}[$command_index].command | type")"
        [[ "$command_type" == "!!seq" ]] ||
            die "${description}[$command_index].command must be an array."
        command_length="$(yaml_read "${expression}[$command_index].command | length")"
        (( command_length > 0 )) ||
            die "${description}[$command_index].command must not be empty."

        for ((argument_index = 0; argument_index < command_length; argument_index++)); do
            argument_type="$(yaml_read "${expression}[$command_index].command[$argument_index] | type")"
            case "$argument_type" in
                "!!str"|"!!int"|"!!float"|"!!bool") ;;
                *) die "${description}[$command_index].command[$argument_index] must be scalar." ;;
            esac
        done

        working_directory_type="$(yaml_read "${expression}[$command_index].working_directory | type")"
        if [[ "$working_directory_type" != "!!null" ]]; then
            validate_string "${expression}[$command_index].working_directory" \
                "${description}[$command_index].working_directory"
            [[ -d "$(yaml_read "${expression}[$command_index].working_directory")" ]] ||
                die "${description}[$command_index].working_directory does not exist."
        fi

        timeout_value="$(yaml_read "${expression}[$command_index].timeout // ${DEFAULT_ACTION_TIMEOUT}")"
        is_positive_integer "$timeout_value" ||
            die "${description}[$command_index].timeout must be a positive integer."
    done
}

validate_configuration() {
    local services_type service_count index name enabled check_type value value_type
    local status_count status_index status_code port actions_type hooks_type hook_name
    local -A seen_names=()

    yq eval '.' "$CONFIG_FILE" >/dev/null 2>&1 ||
        die "YAML is syntactically invalid: ${CONFIG_FILE}"

    services_type="$(yaml_read '.services | type')"
    [[ "$services_type" == "!!seq" ]] || die ".services must be a YAML array."
    service_count="$(yaml_read '.services | length')"
    (( service_count > 0 )) || die ".services must contain at least one service."

    for ((index = 0; index < service_count; index++)); do
        validate_string ".services[$index].name" ".services[$index].name"
        name="$(yaml_read ".services[$index].name")"
        [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
            die "Service name may contain only letters, digits, dots, underscores, and hyphens: ${name}"
        [[ -z "${seen_names[$name]:-}" ]] || die "Duplicate service name: ${name}"
        seen_names["$name"]=1

        enabled="$(yaml_read ".services[$index].enabled // true")"
        [[ "$enabled" == "true" || "$enabled" == "false" ]] ||
            die "Service '${name}': enabled must be true or false."

        validate_string ".services[$index].check.type" "Service '${name}': check.type"
        check_type="$(yaml_read ".services[$index].check.type")"
        case "$check_type" in
            http)
                validate_string ".services[$index].check.url" "Service '${name}': check.url"
                value="$(yaml_read ".services[$index].check.url")"
                [[ "$value" =~ ^https?://[^[:space:]]+$ ]] ||
                    die "Service '${name}': check.url must be an HTTP(S) URL without spaces."
                value="$(yaml_read ".services[$index].check.method // \"GET\"")"
                [[ "$value" == "GET" || "$value" == "HEAD" ]] ||
                    die "Service '${name}': check.method must be GET or HEAD."
                value="$(yaml_read ".services[$index].check.follow_redirects // true")"
                [[ "$value" == "true" || "$value" == "false" ]] ||
                    die "Service '${name}': check.follow_redirects must be true or false."
                value_type="$(yaml_read ".services[$index].check.success_status | type")"
                if [[ "$value_type" != "!!null" ]]; then
                    [[ "$value_type" == "!!seq" ]] ||
                        die "Service '${name}': check.success_status must be an array."
                    status_count="$(yaml_read ".services[$index].check.success_status | length")"
                    (( status_count > 0 )) ||
                        die "Service '${name}': check.success_status must not be empty."
                    for ((status_index = 0; status_index < status_count; status_index++)); do
                        status_code="$(yaml_read ".services[$index].check.success_status[$status_index]")"
                        [[ "$status_code" =~ ^[0-9]{3}$ ]] &&
                            (( 10#$status_code >= 100 && 10#$status_code <= 599 )) ||
                            die "Service '${name}': invalid success HTTP status: ${status_code}"
                    done
                fi
                ;;
            tcp)
                validate_string ".services[$index].check.host" "Service '${name}': check.host"
                value="$(yaml_read ".services[$index].check.host")"
                [[ -n "$value" && "$value" != *[[:space:]]* ]] ||
                    die "Service '${name}': check.host must not be empty or contain spaces."
                port="$(yaml_read ".services[$index].check.port")"
                is_positive_integer "$port" && (( 10#$port <= 65535 )) ||
                    die "Service '${name}': check.port must be from 1 through 65535."
                ;;
            command)
                validate_command_sequence ".services[$index].check.commands" \
                    "Service '${name}': check.commands"
                ;;
            *) die "Service '${name}': check.type must be http, tcp, or command." ;;
        esac

        for value in timeout attempts retry_delay; do
            case "$value" in
                timeout) status_code="$(yaml_read ".services[$index].check.timeout // ${DEFAULT_TIMEOUT}")" ;;
                attempts) status_code="$(yaml_read ".services[$index].check.attempts // ${DEFAULT_ATTEMPTS}")" ;;
                retry_delay) status_code="$(yaml_read ".services[$index].check.retry_delay // ${DEFAULT_RETRY_DELAY}")" ;;
            esac
            if [[ "$value" == "retry_delay" ]]; then
                is_non_negative_integer "$status_code" ||
                    die "Service '${name}': check.${value} must be a non-negative integer."
            else
                is_positive_integer "$status_code" ||
                    die "Service '${name}': check.${value} must be a positive integer."
            fi
        done

        actions_type="$(yaml_read ".services[$index].actions.commands | type")"
        if [[ "$actions_type" != "!!null" ]]; then
            validate_command_sequence ".services[$index].actions.commands" \
                "Service '${name}': actions.commands" true
        fi
        value="$(yaml_read ".services[$index].actions.cooldown // ${DEFAULT_ACTION_COOLDOWN}")"
        is_non_negative_integer "$value" ||
            die "Service '${name}': actions.cooldown must be a non-negative integer."
        value="$(yaml_read ".services[$index].actions.verify_after // 0")"
        is_non_negative_integer "$value" ||
            die "Service '${name}': actions.verify_after must be a non-negative integer."
    done

    hooks_type="$(yaml_read '.hooks | type')"
    if [[ "$hooks_type" != "!!null" ]]; then
        [[ "$hooks_type" == "!!map" ]] || die ".hooks must be a YAML map."
        for hook_name in on_failure on_recovery; do
            value_type="$(yaml_read ".hooks.${hook_name} | type")"
            if [[ "$value_type" != "!!null" ]]; then
                validate_command_sequence ".hooks.${hook_name}" ".hooks.${hook_name}" true
            fi
        done
    fi
}

configure_runtime() {
    local value directory

    value="$(yaml_read '.settings.default_timeout // 10')"
    is_positive_integer "$value" || die "settings.default_timeout must be positive."
    DEFAULT_TIMEOUT="$((10#$value))"
    value="$(yaml_read '.settings.default_attempts // 2')"
    is_positive_integer "$value" || die "settings.default_attempts must be positive."
    (( 10#$value <= 10 )) || die "settings.default_attempts must not exceed 10."
    DEFAULT_ATTEMPTS="$((10#$value))"
    value="$(yaml_read '.settings.default_retry_delay // 2')"
    is_non_negative_integer "$value" || die "settings.default_retry_delay must be non-negative."
    DEFAULT_RETRY_DELAY="$((10#$value))"
    value="$(yaml_read '.settings.default_action_timeout // 120')"
    is_positive_integer "$value" || die "settings.default_action_timeout must be positive."
    DEFAULT_ACTION_TIMEOUT="$((10#$value))"
    value="$(yaml_read '.settings.default_action_cooldown // 300')"
    is_non_negative_integer "$value" || die "settings.default_action_cooldown must be non-negative."
    DEFAULT_ACTION_COOLDOWN="$((10#$value))"

    LOG_FILE="$(yaml_read '.settings.log_file')"
    LOCK_FILE="$(yaml_read '.settings.lock_file')"
    STATE_DIRECTORY="$(yaml_read '.settings.state_directory')"
    for value in "$LOG_FILE" "$LOCK_FILE" "$STATE_DIRECTORY"; do
        [[ -n "$value" && "$value" == /* ]] ||
            die "settings.log_file, lock_file, and state_directory must be absolute paths."
    done

    for directory in "$(dirname -- "$LOG_FILE")" "$(dirname -- "$LOCK_FILE")" "$STATE_DIRECTORY"; do
        mkdir -p -- "$directory" || die "Cannot create directory: ${directory}"
    done
    touch -- "$LOG_FILE" || die "Cannot write log file: ${LOG_FILE}"
    chmod 0640 "$LOG_FILE" 2>/dev/null || true
    chmod 0750 "$STATE_DIRECTORY" 2>/dev/null || true
}

load_command() {
    local expression="$1"
    local -n result_ref="$2"
    local length index argument
    length="$(yaml_read "${expression} | length")"
    result_ref=()
    for ((index = 0; index < length; index++)); do
        argument="$(yaml_read "${expression}[$index]")"
        result_ref+=("$argument")
    done
}

format_command() {
    local -n command_ref="$1"
    local result="" argument quoted
    for argument in "${command_ref[@]}"; do
        printf -v quoted '%q' "$argument"
        [[ -z "$result" ]] || result+=" "
        result+="$quoted"
    done
    printf '%s' "$result"
}

sanitize_detail() {
    printf '%s' "$1" | tail -c 4096 | tr '\r\n' '  '
}

http_status_is_successful() {
    local index="$1"
    local status="$2"
    local count item_index expected
    count="$(yaml_read ".services[$index].check.success_status // [] | length")"
    if (( count == 0 )); then
        [[ "$status" =~ ^2[0-9][0-9]$ ]]
        return
    fi
    for ((item_index = 0; item_index < count; item_index++)); do
        expected="$(yaml_read ".services[$index].check.success_status[$item_index]")"
        [[ "$status" == "$expected" ]] && return 0
    done
    return 1
}

check_http() {
    local index="$1"
    local url method follow_redirects timeout_value error_file http_status curl_status error_output
    local -a curl_command
    url="$(yaml_read ".services[$index].check.url")"
    method="$(yaml_read ".services[$index].check.method // \"GET\"")"
    follow_redirects="$(yaml_read ".services[$index].check.follow_redirects // true")"
    timeout_value="$(yaml_read ".services[$index].check.timeout // ${DEFAULT_TIMEOUT}")"
    error_file="${TEMP_DIRECTORY}/http-${index}-${RANDOM}.err"

    curl_command=(curl --silent --show-error --output /dev/null --write-out '%{http_code}'
        --connect-timeout "$timeout_value" --max-time "$timeout_value" --request "$method")
    [[ "$follow_redirects" == "true" ]] && curl_command+=(--location --max-redirs 5)
    curl_command+=("$url")

    http_status="$("${curl_command[@]}" 2>"$error_file")"
    curl_status=$?
    error_output=""
    [[ -s "$error_file" ]] && error_output="$(sanitize_detail "$(<"$error_file")")"
    rm -f -- "$error_file"

    CHECK_HTTP_STATUS="$http_status"
    CHECK_EXIT_CODE="$curl_status"
    if (( curl_status != 0 )); then
        CHECK_DETAIL="curl_exit=${curl_status}; HTTP ${http_status:-000}; ${error_output:-unknown error}"
        return 1
    fi
    if http_status_is_successful "$index" "$http_status"; then
        CHECK_DETAIL="HTTP ${http_status}"
        return 0
    fi
    CHECK_DETAIL="unexpected HTTP ${http_status:-unknown}"
    return 1
}

check_tcp() {
    local index="$1"
    local host port timeout_value command_status
    host="$(yaml_read ".services[$index].check.host")"
    port="$(yaml_read ".services[$index].check.port")"
    timeout_value="$(yaml_read ".services[$index].check.timeout // ${DEFAULT_TIMEOUT}")"
    timeout --signal=TERM --kill-after=2s "$timeout_value" \
        bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$host" "$port" >/dev/null 2>&1
    command_status=$?
    CHECK_EXIT_CODE="$command_status"
    if (( command_status == 0 )); then
        CHECK_DETAIL="TCP ${host}:${port} accepts connections"
        return 0
    fi
    CHECK_DETAIL="TCP ${host}:${port} unavailable; exit=${command_status}"
    return 1
}

run_configured_sequence() {
    local expression="$1"
    local label="$2"
    local service_name="$3"
    local count command_index working_directory timeout_value output_file output command_status formatted
    local -a configured_command

    count="$(yaml_read "${expression} // [] | length")"
    (( count > 0 )) || return 0

    for ((command_index = 0; command_index < count; command_index++)); do
        load_command "${expression}[$command_index].command" configured_command
        working_directory="$(yaml_read "${expression}[$command_index].working_directory // \"/\"")"
        timeout_value="$(yaml_read "${expression}[$command_index].timeout // ${DEFAULT_ACTION_TIMEOUT}")"
        formatted="$(format_command configured_command)"
        output_file="${TEMP_DIRECTORY}/${label}-${RANDOM}.log"
        log WARN "service=${service_name} action=${label}-command index=${command_index} command=${formatted}"

        (
            cd -- "$working_directory" || exit 125
            export WATCHDOG_SERVICE="$service_name"
            export WATCHDOG_CHECK_TYPE="$CURRENT_CHECK_TYPE"
            export WATCHDOG_DETAIL="$CHECK_DETAIL"
            export WATCHDOG_HTTP_STATUS="$CHECK_HTTP_STATUS"
            export WATCHDOG_CHECK_EXIT="$CHECK_EXIT_CODE"
            export WATCHDOG_EVENT="$label"
            export WATCHDOG_TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S%z')"
            timeout --signal=TERM --kill-after=10s "$timeout_value" "${configured_command[@]}"
        ) >"$output_file" 2>&1
        command_status=$?
        output=""
        [[ -s "$output_file" ]] && output="$(sanitize_detail "$(<"$output_file")")"
        rm -f -- "$output_file"

        if (( command_status != 0 )); then
            log ERROR "service=${service_name} result=${label}-command-failed index=${command_index} exit=${command_status} output=${output:-none}"
            return 1
        fi
        log WARN "service=${service_name} result=${label}-command-success index=${command_index} output=${output:-none}"
    done
    return 0
}

check_command() {
    local index="$1"
    if run_configured_sequence ".services[$index].check.commands" check "$CURRENT_SERVICE"; then
        CHECK_EXIT_CODE=0
        CHECK_DETAIL="check command sequence succeeded"
        return 0
    fi
    CHECK_EXIT_CODE=1
    CHECK_DETAIL="check command sequence failed"
    return 1
}

perform_single_check() {
    local index="$1"
    case "$CURRENT_CHECK_TYPE" in
        http) check_http "$index" ;;
        tcp) check_tcp "$index" ;;
        command) check_command "$index" ;;
        *) return 1 ;;
    esac
}

check_with_retries() {
    local index="$1"
    local attempts retry_delay attempt
    attempts="$(yaml_read ".services[$index].check.attempts // ${DEFAULT_ATTEMPTS}")"
    retry_delay="$(yaml_read ".services[$index].check.retry_delay // ${DEFAULT_RETRY_DELAY}")"

    for ((attempt = 1; attempt <= attempts; attempt++)); do
        log INFO "service=${CURRENT_SERVICE} action=check attempt=${attempt}/${attempts} type=${CURRENT_CHECK_TYPE}"
        if perform_single_check "$index"; then
            log INFO "service=${CURRENT_SERVICE} result=check-success attempt=${attempt}/${attempts} detail=\"$(sanitize_detail "$CHECK_DETAIL")\""
            return 0
        fi
        log WARN "service=${CURRENT_SERVICE} result=check-failed attempt=${attempt}/${attempts} detail=\"$(sanitize_detail "$CHECK_DETAIL")\""
        if (( attempt < attempts && retry_delay > 0 )); then
            sleep "$retry_delay"
        fi
    done
    return 1
}

read_state() {
    local service_name="$1"
    local file="${STATE_DIRECTORY}/${service_name}.state" state=""
    [[ -r "$file" ]] && IFS= read -r state <"$file" || true
    case "$state" in healthy|unavailable) printf '%s' "$state" ;; *) printf unknown ;; esac
}

write_state() {
    local service_name="$1" state="$2"
    local file temporary
    file="${STATE_DIRECTORY}/${service_name}.state"
    temporary="${file}.tmp.$$"
    printf '%s\n' "$state" >"$temporary" || die "Cannot write state: ${temporary}"
    chmod 0640 "$temporary" 2>/dev/null || true
    mv -f -- "$temporary" "$file" || die "Cannot update state: ${file}"
}

action_is_due() {
    local index="$1" service_name="$2"
    local cooldown file last_action="" now
    cooldown="$(yaml_read ".services[$index].actions.cooldown // ${DEFAULT_ACTION_COOLDOWN}")"
    (( cooldown == 0 )) && return 0
    file="${STATE_DIRECTORY}/${service_name}.last-action"
    [[ -r "$file" ]] && IFS= read -r last_action <"$file" || true
    [[ "$last_action" =~ ^[0-9]+$ ]] || return 0
    now="$(date '+%s')"
    (( now - last_action >= cooldown ))
}

record_action_attempt() {
    local service_name="$1"
    local file temporary
    file="${STATE_DIRECTORY}/${service_name}.last-action"
    temporary="${file}.tmp.$$"
    printf '%s\n' "$(date '+%s')" >"$temporary" || die "Cannot write action state: ${temporary}"
    chmod 0640 "$temporary" 2>/dev/null || true
    mv -f -- "$temporary" "$file" || die "Cannot update action state: ${file}"
}

handle_state_transition() {
    local service_name="$1" new_state="$2"
    local previous hook_expression
    (( DRY_RUN == 0 )) || return 0
    previous="$(read_state "$service_name")"
    [[ "$previous" != "$new_state" ]] || return 0
    hook_expression=""
    [[ "$new_state" == unavailable ]] && hook_expression='.hooks.on_failure'
    [[ "$new_state" == healthy && "$previous" == unavailable ]] && hook_expression='.hooks.on_recovery'
    if [[ -n "$hook_expression" ]]; then
        run_configured_sequence "$hook_expression" "${new_state}" "$service_name" ||
            log ERROR "service=${service_name} result=state-hook-failed state=${new_state}"
    fi
    write_state "$service_name" "$new_state"
    log INFO "service=${service_name} action=state previous=${previous} current=${new_state}"
}

process_service() {
    local index="$1"
    local enabled actions_count verify_after final_state
    CURRENT_SERVICE="$(yaml_read ".services[$index].name")"
    CURRENT_CHECK_TYPE="$(yaml_read ".services[$index].check.type")"
    enabled="$(yaml_read ".services[$index].enabled // true")"

    [[ -z "$ONLY_SERVICE" || "$CURRENT_SERVICE" == "$ONLY_SERVICE" ]] || return 0
    if [[ "$enabled" != true ]]; then
        log INFO "service=${CURRENT_SERVICE} result=skipped reason=disabled"
        return 0
    fi

    log INFO "service=${CURRENT_SERVICE} action=service-start type=${CURRENT_CHECK_TYPE}"
    if check_with_retries "$index"; then
        handle_state_transition "$CURRENT_SERVICE" healthy
        log INFO "service=${CURRENT_SERVICE} result=healthy"
        return 0
    fi

    actions_count="$(yaml_read ".services[$index].actions.commands // [] | length")"
    if (( actions_count > 0 )); then
        if (( DRY_RUN == 1 )); then
            log WARN "service=${CURRENT_SERVICE} action=remediation result=skipped reason=dry-run"
        elif action_is_due "$index" "$CURRENT_SERVICE"; then
            ACTION_ATTEMPTED=1
            record_action_attempt "$CURRENT_SERVICE"
            log WARN "service=${CURRENT_SERVICE} action=remediation-start commands=${actions_count}"
            run_configured_sequence ".services[$index].actions.commands" remediation "$CURRENT_SERVICE" || true

            verify_after="$(yaml_read ".services[$index].actions.verify_after // 0")"
            (( verify_after > 0 )) && sleep "$verify_after"
            if check_with_retries "$index"; then
                handle_state_transition "$CURRENT_SERVICE" healthy
                log WARN "service=${CURRENT_SERVICE} result=recovered-after-remediation"
                return 0
            fi
        else
            log WARN "service=${CURRENT_SERVICE} action=remediation result=skipped reason=cooldown"
        fi
    fi

    UNHEALTHY_FOUND=1
    final_state=unavailable
    handle_state_transition "$CURRENT_SERVICE" "$final_state"
    log ERROR "service=${CURRENT_SERVICE} result=unavailable detail=\"$(sanitize_detail "$CHECK_DETAIL")\""
    return 0
}

main() {
    local option yq_version service_count index matched=0 name
    while getopts ':c:s:nh' option; do
        case "$option" in
            c) CONFIG_FILE="$OPTARG" ;;
            s) ONLY_SERVICE="$OPTARG" ;;
            n) DRY_RUN=1 ;;
            h) usage; exit 0 ;;
            :) bootstrap_log CRITICAL "Option -${OPTARG} requires a value."; exit 2 ;;
            \?) bootstrap_log CRITICAL "Unknown option: -${OPTARG}"; usage >&2; exit 2 ;;
        esac
    done

    [[ -f "$CONFIG_FILE" ]] || die "Configuration file not found: ${CONFIG_FILE}"
    for name in bash curl yq flock timeout date dirname mktemp tail tr mv env; do
        require_command "$name"
    done
    yq_version="$(yq --version 2>/dev/null)" || die "Cannot determine yq version."
    [[ "$yq_version" =~ version[[:space:]]+v?4\. ]] || die "Mike Farah yq v4 is required: ${yq_version}"

    validate_configuration
    configure_runtime
    TEMP_DIRECTORY="$(mktemp -d)" || die "Cannot create temporary directory."
    exec 9>"$LOCK_FILE" || die "Cannot open lock file: ${LOCK_FILE}"
    if ! flock --nonblock 9; then
        log WARN "action=lock result=already-running"
        exit 0
    fi

    log INFO "action=watchdog-start config=${CONFIG_FILE} dry_run=${DRY_RUN}"
    service_count="$(yaml_read '.services | length')"
    if [[ -n "$ONLY_SERVICE" ]]; then
        for ((index = 0; index < service_count; index++)); do
            name="$(yaml_read ".services[$index].name")"
            [[ "$name" == "$ONLY_SERVICE" ]] && matched=1
        done
        (( matched == 1 )) || die "Service not found: ${ONLY_SERVICE}"
    fi

    for ((index = 0; index < service_count; index++)); do
        process_service "$index"
    done

    if (( UNHEALTHY_FOUND == 1 || ACTION_ATTEMPTED == 1 )); then
        log WARN "action=watchdog-finish exit=1 unhealthy=${UNHEALTHY_FOUND} remediation=${ACTION_ATTEMPTED}"
        exit 1
    fi
    log INFO "action=watchdog-finish exit=0 unhealthy=0 remediation=0"
    exit 0
}

main "$@"
