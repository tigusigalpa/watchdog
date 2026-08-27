#!/usr/bin/env bash
# Universal one-shot watchdog for HTTP endpoints, TCP ports, and commands.
# Requires Bash >= 4.3, curl, yq v4, flock, and GNU timeout/coreutils.

set -uo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="${0##*/}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly WATCHDOG_VERSION="1.0.6"

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
CURRENT_ACTION_STATUS="not-attempted"

EMAIL_ENABLED=0
EMAIL_SMTP_URL=""
EMAIL_FROM=""
EMAIL_USERNAME=""
EMAIL_PASSWORD=""
EMAIL_TLS_REQUIRED=1
EMAIL_INSECURE_SKIP_VERIFY=0
EMAIL_TIMEOUT=30
EMAIL_RECIPIENTS_COUNT=0
EMAIL_FAILURE_SUBJECT=""
EMAIL_FAILURE_BODY=""
EMAIL_RECOVERY_SUBJECT=""
EMAIL_RECOVERY_BODY=""

ACTION_ATTEMPTED=0
UNHEALTHY_FOUND=0

usage() {
    cat <<EOF
Usage:
  ${SCRIPT_NAME} [-c /path/to/config.yaml] [-s service_name] [-n]
  ${SCRIPT_NAME} -V | --version

Options:
  -c FILE   YAML configuration file.
  -s NAME   Check only one configured service.
  -n        Dry run: perform checks, but do not run actions, hooks, or write state.
  -V        Show version information.
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

# Invoked indirectly by the EXIT trap.
# shellcheck disable=SC2317
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

validate_email_configuration() {
    local enabled value value_type password_env password recipients_type
    local recipient recipient_index timeout_value

    enabled="$(yaml_read '.notifications.email.enabled // false')"
    case "$enabled" in
        false) return 0 ;;
        true) ;;
        *) die "notifications.email.enabled must be true or false." ;;
    esac

    validate_string '.notifications.email.smtp.url' 'notifications.email.smtp.url'
    validate_string '.notifications.email.smtp.from' 'notifications.email.smtp.from'
    validate_string '.notifications.email.failure.subject' 'notifications.email.failure.subject'
    validate_string '.notifications.email.failure.body' 'notifications.email.failure.body'
    validate_string '.notifications.email.recovery.subject' 'notifications.email.recovery.subject'
    validate_string '.notifications.email.recovery.body' 'notifications.email.recovery.body'

    value="$(yaml_read '.notifications.email.smtp.url')"
    [[ "$value" =~ ^smtps?://[^[:space:]]+$ ]] ||
        die "notifications.email.smtp.url must start with smtp:// or smtps:// and contain no spaces."
    value="$(yaml_read '.notifications.email.smtp.from')"
    [[ "$value" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]] ||
        die "notifications.email.smtp.from must be one email address."

    for value in failure recovery; do
        value_type="$(yaml_read ".notifications.email.${value}.subject")"
        [[ "$value_type" != *$'\n'* && "$value_type" != *$'\r'* ]] ||
            die "notifications.email.${value}.subject must be a single line."
    done

    value_type="$(yaml_read '.notifications.email.smtp.username | type')"
    [[ "$value_type" == "!!null" ]] ||
        validate_string '.notifications.email.smtp.username' 'notifications.email.smtp.username'
    value_type="$(yaml_read '.notifications.email.smtp.password_env | type')"
    [[ "$value_type" == "!!null" ]] ||
        validate_string '.notifications.email.smtp.password_env' 'notifications.email.smtp.password_env'
    value_type="$(yaml_read '.notifications.email.smtp.password | type')"
    [[ "$value_type" == "!!null" ]] ||
        validate_string '.notifications.email.smtp.password' 'notifications.email.smtp.password'

    password_env="$(yaml_read '.notifications.email.smtp.password_env // ""')"
    password="$(yaml_read '.notifications.email.smtp.password // ""')"
    [[ -z "$password_env" || -z "$password" ]] ||
        die "Use only one of notifications.email.smtp.password_env or password."
    if [[ -n "$password_env" ]]; then
        [[ "$password_env" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
            die "notifications.email.smtp.password_env is not a valid environment variable name."
    fi

    value_type="$(yaml_read '.notifications.email.smtp.tls_required // true')"
    [[ "$value_type" == true || "$value_type" == false ]] ||
        die "notifications.email.smtp.tls_required must be true or false."
    value_type="$(yaml_read '.notifications.email.smtp.insecure_skip_verify // false')"
    [[ "$value_type" == true || "$value_type" == false ]] ||
        die "notifications.email.smtp.insecure_skip_verify must be true or false."

    timeout_value="$(yaml_read '.notifications.email.smtp.timeout // 30')"
    if ! is_positive_integer "$timeout_value" || (( 10#$timeout_value > 60 )); then
        die "notifications.email.smtp.timeout must be from 1 through 60 seconds."
    fi

    recipients_type="$(yaml_read '.notifications.email.recipients | type')"
    [[ "$recipients_type" == "!!seq" ]] ||
        die "notifications.email.recipients must be a YAML array."
    EMAIL_RECIPIENTS_COUNT="$(yaml_read '.notifications.email.recipients | length')"
    (( EMAIL_RECIPIENTS_COUNT > 0 )) ||
        die "notifications.email.recipients must not be empty."
    for ((recipient_index = 0; recipient_index < EMAIL_RECIPIENTS_COUNT; recipient_index++)); do
        validate_string ".notifications.email.recipients[$recipient_index]" \
            "notifications.email.recipients[$recipient_index]"
        recipient="$(yaml_read ".notifications.email.recipients[$recipient_index]")"
        [[ "$recipient" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]] ||
            die "Invalid email address in notifications.email.recipients[$recipient_index]."
    done
}

validate_webhook_configuration() {
    local webhooks_type webhook enabled value value_type env_name env_value priority

    webhooks_type="$(yaml_read '.notifications.webhooks | type')"
    [[ "$webhooks_type" == "!!null" ]] && return 0
    [[ "$webhooks_type" == "!!map" ]] || die "notifications.webhooks must be a YAML map."

    for webhook in telegram discord slack ntfy; do
        value_type="$(yaml_read ".notifications.webhooks.${webhook} | type")"
        [[ "$value_type" == "!!null" ]] && continue
        [[ "$value_type" == "!!map" ]] || die "notifications.webhooks.${webhook} must be a YAML map."
        enabled="$(yaml_read ".notifications.webhooks.${webhook}.enabled // false")"
        [[ "$enabled" == true || "$enabled" == false ]] ||
            die "notifications.webhooks.${webhook}.enabled must be true or false."
        [[ "$enabled" == true ]] || continue

        for value in failure recovery; do
            value_type="$(yaml_read ".notifications.webhooks.${webhook}.template.${value} | type")"
            [[ "$value_type" == "!!null" ]] ||
                validate_string ".notifications.webhooks.${webhook}.template.${value}" \
                    "notifications.webhooks.${webhook}.template.${value}"
        done

        case "$webhook" in
            telegram)
                validate_string '.notifications.webhooks.telegram.bot_token_env' 'notifications.webhooks.telegram.bot_token_env'
                validate_string '.notifications.webhooks.telegram.chat_id' 'notifications.webhooks.telegram.chat_id'
                env_name="$(yaml_read '.notifications.webhooks.telegram.bot_token_env')"
                value="$(yaml_read '.notifications.webhooks.telegram.chat_id')"
                [[ "$env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
                    die "notifications.webhooks.telegram.bot_token_env is not a valid environment variable name."
                [[ -n "$value" ]] || die "notifications.webhooks.telegram.chat_id must not be empty."
                value="$(yaml_read '.notifications.webhooks.telegram.thread_id // ""')"
                [[ -z "$value" || "$value" =~ ^[0-9]+$ ]] ||
                    die "notifications.webhooks.telegram.thread_id must be a positive integer."
                ;;
            discord|slack)
                validate_string ".notifications.webhooks.${webhook}.webhook_url_env" \
                    "notifications.webhooks.${webhook}.webhook_url_env"
                env_name="$(yaml_read ".notifications.webhooks.${webhook}.webhook_url_env")"
                [[ "$env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
                    die "notifications.webhooks.${webhook}.webhook_url_env is not a valid environment variable name."
                ;;
            ntfy)
                validate_string '.notifications.webhooks.ntfy.url' 'notifications.webhooks.ntfy.url'
                value="$(yaml_read '.notifications.webhooks.ntfy.url')"
                [[ "$value" =~ ^https?://[^[:space:]]+$ ]] ||
                    die "notifications.webhooks.ntfy.url must be an HTTP(S) URL without spaces."
                env_name="$(yaml_read '.notifications.webhooks.ntfy.token_env // ""')"
                [[ -z "$env_name" || "$env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
                    die "notifications.webhooks.ntfy.token_env is not a valid environment variable name."
                priority="$(yaml_read '.notifications.webhooks.ntfy.priority // "default"')"
                [[ "$priority" =~ ^[1-5]$ || "$priority" =~ ^(min|low|default|high|urgent|max)$ ]] ||
                    die "notifications.webhooks.ntfy.priority must be 1-5, min, low, default, high, urgent, or max."
                ;;
        esac

        # Dry runs are a safe way to validate that secrets supplied outside YAML
        # are available. Normal runs report missing values per webhook instead.
        if (( DRY_RUN == 1 )) && [[ -n "$env_name" ]]; then
            env_value="${!env_name:-}"
            [[ -n "$env_value" ]] ||
                die "notifications.webhooks.${webhook}: environment variable is empty or undefined: ${env_name}"
            if [[ "$webhook" == discord || "$webhook" == slack ]]; then
                [[ "$env_value" =~ ^https?://[^[:space:]]+$ ]] ||
                    die "notifications.webhooks.${webhook}: URL in ${env_name} must be an HTTP(S) URL without spaces."
            fi
        fi
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
                        if ! [[ "$status_code" =~ ^[0-9]{3}$ ]] ||
                           (( 10#$status_code < 100 || 10#$status_code > 599 )); then
                            die "Service '${name}': invalid success HTTP status: ${status_code}"
                        fi
                    done
                fi
                ;;
            tcp)
                validate_string ".services[$index].check.host" "Service '${name}': check.host"
                value="$(yaml_read ".services[$index].check.host")"
                [[ -n "$value" && "$value" != *[[:space:]]* ]] ||
                    die "Service '${name}': check.host must not be empty or contain spaces."
                port="$(yaml_read ".services[$index].check.port")"
                if ! is_positive_integer "$port" || (( 10#$port > 65535 )); then
                    die "Service '${name}': check.port must be from 1 through 65535."
                fi
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

    validate_email_configuration
    validate_webhook_configuration
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

configure_email() {
    local enabled password_env password

    enabled="$(yaml_read '.notifications.email.enabled // false')"
    [[ "$enabled" == true ]] || return 0
    EMAIL_ENABLED=1
    EMAIL_SMTP_URL="$(yaml_read '.notifications.email.smtp.url')"
    EMAIL_FROM="$(yaml_read '.notifications.email.smtp.from')"
    EMAIL_USERNAME="$(yaml_read '.notifications.email.smtp.username // ""')"
    EMAIL_TLS_REQUIRED=0
    EMAIL_INSECURE_SKIP_VERIFY=0
    [[ "$(yaml_read '.notifications.email.smtp.tls_required // true')" == true ]] &&
        EMAIL_TLS_REQUIRED=1
    [[ "$(yaml_read '.notifications.email.smtp.insecure_skip_verify // false')" == true ]] &&
        EMAIL_INSECURE_SKIP_VERIFY=1
    EMAIL_TIMEOUT="$(yaml_read '.notifications.email.smtp.timeout // 30')"
    EMAIL_RECIPIENTS_COUNT="$(yaml_read '.notifications.email.recipients | length')"
    EMAIL_FAILURE_SUBJECT="$(yaml_read '.notifications.email.failure.subject')"
    EMAIL_FAILURE_BODY="$(yaml_read '.notifications.email.failure.body')"
    EMAIL_RECOVERY_SUBJECT="$(yaml_read '.notifications.email.recovery.subject')"
    EMAIL_RECOVERY_BODY="$(yaml_read '.notifications.email.recovery.body')"

    password_env="$(yaml_read '.notifications.email.smtp.password_env // ""')"
    password="$(yaml_read '.notifications.email.smtp.password // ""')"
    if [[ -n "$password_env" ]]; then
        EMAIL_PASSWORD="${!password_env:-}"
        [[ -n "$EMAIL_PASSWORD" ]] ||
            die "SMTP password environment variable is empty or undefined: ${password_env}"
    else
        EMAIL_PASSWORD="$password"
    fi

    [[ -z "$EMAIL_USERNAME" || -n "$EMAIL_PASSWORD" ]] ||
        die "SMTP username is configured, but no password is available."
    [[ -n "$EMAIL_USERNAME" || -z "$EMAIL_PASSWORD" ]] ||
        die "SMTP password is configured, but smtp.username is empty."
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

render_email_template() {
    local template="$1"
    local event="$2"
    local timestamp="$3"
    local detail
    detail="$(sanitize_detail "$CHECK_DETAIL")"

    template="${template//\{\{service\}\}/$CURRENT_SERVICE}"
    template="${template//\{\{event\}\}/$event}"
    template="${template//\{\{timestamp\}\}/$timestamp}"
    template="${template//\{\{check_type\}\}/$CURRENT_CHECK_TYPE}"
    template="${template//\{\{detail\}\}/$detail}"
    template="${template//\{\{http_status\}\}/${CHECK_HTTP_STATUS:-n/a}}"
    template="${template//\{\{check_exit\}\}/${CHECK_EXIT_CODE:-n/a}}"
    template="${template//\{\{action_status\}\}/$CURRENT_ACTION_STATUS}"
    printf '%s' "$template"
}

escape_html() {
    local value="$1"
    value="${value//&/\&amp;}"
    value="${value//</\&lt;}"
    value="${value//>/\&gt;}"
    printf '%s' "$value"
}

escape_json() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\t'/\\t}"
    printf '%s' "$value"
}

render_webhook_template() {
    local format="$1" template="$2" event="$3" timestamp="$4"
    local service detail check_type http_status check_exit action_status

    service="$CURRENT_SERVICE"
    detail="$(sanitize_detail "$CHECK_DETAIL")"
    check_type="$CURRENT_CHECK_TYPE"
    http_status="${CHECK_HTTP_STATUS:-n/a}"
    check_exit="${CHECK_EXIT_CODE:-n/a}"
    action_status="$CURRENT_ACTION_STATUS"
    case "$format" in
        html)
            service="$(escape_html "$service")"; detail="$(escape_html "$detail")"
            check_type="$(escape_html "$check_type")"; http_status="$(escape_html "$http_status")"
            check_exit="$(escape_html "$check_exit")"; action_status="$(escape_html "$action_status")"
            ;;
        json)
            service="$(escape_json "$service")"; detail="$(escape_json "$detail")"
            check_type="$(escape_json "$check_type")"; http_status="$(escape_json "$http_status")"
            check_exit="$(escape_json "$check_exit")"; action_status="$(escape_json "$action_status")"
            ;;
    esac
    template="${template//\{\{service\}\}/$service}"
    template="${template//\{\{event\}\}/$event}"
    template="${template//\{\{timestamp\}\}/$timestamp}"
    template="${template//\{\{check_type\}\}/$check_type}"
    template="${template//\{\{detail\}\}/$detail}"
    template="${template//\{\{http_status\}\}/$http_status}"
    template="${template//\{\{check_exit\}\}/$check_exit}"
    template="${template//\{\{action_status\}\}/$action_status}"
    printf '%s' "$template"
}

webhook_template() {
    local webhook="$1" event="$2" fallback value value_type
    case "${webhook}:${event}" in
        telegram:failure) fallback=$'🚨 <b>{{service}}</b> DOWN\n\nType: {{check_type}}\nDetail: {{detail}}\nTime: {{timestamp}}' ;;
        telegram:recovery) fallback=$'✅ <b>{{service}}</b> UP\n\nRecovered at {{timestamp}}' ;;
        discord:failure) fallback='{"content":"🚨 **{{service}}** is unavailable: {{detail}}"}' ;;
        discord:recovery) fallback='{"content":"✅ **{{service}}** recovered"}' ;;
        slack:failure) fallback='{"text":"🚨 {{service}} DOWN: {{detail}}"}' ;;
        slack:recovery) fallback='{"text":"✅ {{service}} recovered"}' ;;
        ntfy:failure) fallback='🚨 {{service}} unavailable: {{detail}}' ;;
        ntfy:recovery) fallback='✅ {{service}} recovered' ;;
        *) return 1 ;;
    esac
    value_type="$(yaml_read ".notifications.webhooks.${webhook}.template.${event} | type")"
    if [[ "$value_type" == "!!null" ]]; then
        value="$fallback"
    else
        value="$(yaml_read ".notifications.webhooks.${webhook}.template.${event}")"
    fi
    printf '%s' "$value"
}

send_single_webhook() {
    local webhook="$1" event="$2" env_name="" secret="" url="" template text timestamp
    local response_file response http_status curl_status thread_id priority
    local -a curl_command

    case "$webhook" in
        telegram) env_name="$(yaml_read '.notifications.webhooks.telegram.bot_token_env')" ;;
        discord|slack) env_name="$(yaml_read ".notifications.webhooks.${webhook}.webhook_url_env")" ;;
        ntfy) env_name="$(yaml_read '.notifications.webhooks.ntfy.token_env // ""')" ;;
    esac
    if [[ -n "$env_name" ]]; then
        secret="${!env_name:-}"
        if [[ -z "$secret" ]]; then
            log ERROR "service=${CURRENT_SERVICE} webhook=${webhook} result=webhook-failed reason=missing-env:${env_name} event=${event}"
            return 1
        fi
    fi

    timestamp="$(date '+%Y-%m-%d %H:%M:%S%z')"
    template="$(webhook_template "$webhook" "$event")" || return 1
    response_file="${TEMP_DIRECTORY}/webhook-${webhook}-${RANDOM}.response"
    curl_command=(curl --silent --show-error --output "$response_file" --write-out '%{http_code}' --connect-timeout 10 --max-time 30)
    case "$webhook" in
        telegram)
            text="$(render_webhook_template html "$template" "$event" "$timestamp")"
            url="https://api.telegram.org/bot${secret}/sendMessage"
            thread_id="$(yaml_read '.notifications.webhooks.telegram.thread_id // ""')"
            curl_command+=(--request POST --data-urlencode "chat_id=$(yaml_read '.notifications.webhooks.telegram.chat_id')" --data-urlencode "text=${text}" --data-urlencode 'parse_mode=HTML')
            [[ -z "$thread_id" ]] || curl_command+=(--data-urlencode "message_thread_id=${thread_id}")
            ;;
        discord|slack)
            text="$(render_webhook_template json "$template" "$event" "$timestamp")"
            url="$secret"
            curl_command+=(--request POST --header 'Content-Type: application/json' --data "$text")
            ;;
        ntfy)
            text="$(render_webhook_template plain "$template" "$event" "$timestamp")"
            url="$(yaml_read '.notifications.webhooks.ntfy.url')"
            priority="$(yaml_read '.notifications.webhooks.ntfy.priority // "default"')"
            curl_command+=(--request POST --header 'Title: watchdog' --header "Priority: ${priority}" --data-binary "$text")
            [[ -z "$secret" ]] || curl_command+=(--header "Authorization: Bearer ${secret}")
            ;;
    esac

    http_status="$("${curl_command[@]}" "$url" 2>/dev/null)"
    curl_status=$?
    response=""; [[ -s "$response_file" ]] && response="$(<"$response_file")"
    rm -f -- "$response_file"
    if (( curl_status == 0 )) && [[ "$http_status" =~ ^2[0-9][0-9]$ ]]; then
        if [[ "$webhook" != telegram || "$response" =~ \"ok\"[[:space:]]*:[[:space:]]*true ]]; then
            log INFO "service=${CURRENT_SERVICE} webhook=${webhook} result=webhook-sent event=${event} http_status=${http_status}"
            return 0
        fi
    fi
    log ERROR "service=${CURRENT_SERVICE} webhook=${webhook} result=webhook-failed event=${event} curl_exit=${curl_status} http_status=${http_status:-000}"
    return 1
}

send_webhook_notification() {
    local event="$1" webhook enabled failed=0
    for webhook in telegram discord slack ntfy; do
        enabled="$(yaml_read ".notifications.webhooks.${webhook}.enabled // false")"
        [[ "$enabled" == true ]] || continue
        send_single_webhook "$webhook" "$event" || failed=1
    done
    return "$failed"
}

send_email_notification() {
    local event="$1"
    local timestamp subject_template body_template subject body encoded_subject
    local message_file recipient recipients_header="" output command_status recipient_index
    local -a curl_command

    (( EMAIL_ENABLED == 1 )) || return 0
    case "$event" in
        failure)
            subject_template="$EMAIL_FAILURE_SUBJECT"
            body_template="$EMAIL_FAILURE_BODY"
            ;;
        recovery)
            subject_template="$EMAIL_RECOVERY_SUBJECT"
            body_template="$EMAIL_RECOVERY_BODY"
            ;;
        *)
            log ERROR "service=${CURRENT_SERVICE} result=email-failed reason=unknown-event event=${event}"
            return 1
            ;;
    esac

    timestamp="$(date '+%Y-%m-%d %H:%M:%S%z')"
    subject="$(render_email_template "$subject_template" "$event" "$timestamp")"
    subject="${subject//$'\r'/ }"
    subject="${subject//$'\n'/ }"
    body="$(render_email_template "$body_template" "$event" "$timestamp")"
    encoded_subject="$(printf '%s' "$subject" | base64 | tr -d '\r\n')"
    message_file="${TEMP_DIRECTORY}/email-${RANDOM}-${RANDOM}.eml"

    curl_command=(
        curl
        --silent
        --show-error
        --url "$EMAIL_SMTP_URL"
        --connect-timeout "$EMAIL_TIMEOUT"
        --max-time "$EMAIL_TIMEOUT"
        --mail-from "$EMAIL_FROM"
    )
    (( EMAIL_TLS_REQUIRED == 1 )) && curl_command+=(--ssl-reqd)
    (( EMAIL_INSECURE_SKIP_VERIFY == 1 )) && curl_command+=(--insecure)
    if [[ -n "$EMAIL_USERNAME" ]]; then
        curl_command+=(--user "${EMAIL_USERNAME}:${EMAIL_PASSWORD}")
    fi

    for ((recipient_index = 0; recipient_index < EMAIL_RECIPIENTS_COUNT; recipient_index++)); do
        recipient="$(yaml_read ".notifications.email.recipients[$recipient_index]")"
        curl_command+=(--mail-rcpt "$recipient")
        [[ -z "$recipients_header" ]] || recipients_header+=", "
        recipients_header+="$recipient"
    done

    {
        printf 'From: %s\r\n' "$EMAIL_FROM"
        printf 'To: %s\r\n' "$recipients_header"
        printf 'Subject: =?UTF-8?B?%s?=\r\n' "$encoded_subject"
        printf 'Date: %s\r\n' "$(date -R)"
        printf 'MIME-Version: 1.0\r\n'
        printf 'Content-Type: text/plain; charset=UTF-8\r\n'
        printf 'Content-Transfer-Encoding: 8bit\r\n'
        printf '\r\n%s\r\n' "$body"
    } >"$message_file"

    log INFO "service=${CURRENT_SERVICE} action=email event=${event} recipients=${EMAIL_RECIPIENTS_COUNT}"
    output="$("${curl_command[@]}" --upload-file "$message_file" 2>&1)"
    command_status=$?
    rm -f -- "$message_file"
    output="$(sanitize_detail "$output")"

    if (( command_status == 0 )); then
        log INFO "service=${CURRENT_SERVICE} result=email-sent event=${event} recipients=${EMAIL_RECIPIENTS_COUNT}"
        return 0
    fi
    log ERROR "service=${CURRENT_SERVICE} result=email-failed event=${event} curl_exit=${command_status} error=${output:-unknown}"
    return 1
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
    # $1 and $2 are intentionally expanded by the inner Bash process.
    # shellcheck disable=SC2016
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
            WATCHDOG_TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S%z')"
            export WATCHDOG_TIMESTAMP
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
    if [[ -r "$file" ]]; then
        IFS= read -r state <"$file" || true
    fi
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
    if [[ -r "$file" ]]; then
        IFS= read -r last_action <"$file" || true
    fi
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
    local previous hook_expression notification_event
    (( DRY_RUN == 0 )) || return 0
    previous="$(read_state "$service_name")"
    [[ "$previous" != "$new_state" ]] || return 0
    hook_expression=""
    notification_event=""
    if [[ "$new_state" == unavailable ]]; then
        hook_expression='.hooks.on_failure'
        notification_event=failure
    elif [[ "$new_state" == healthy && "$previous" == unavailable ]]; then
        hook_expression='.hooks.on_recovery'
        notification_event=recovery
    fi
    if [[ -n "$notification_event" ]]; then
        send_email_notification "$notification_event" ||
            log ERROR "service=${service_name} result=state-email-failed state=${new_state}"
        send_webhook_notification "$notification_event" ||
            log ERROR "service=${service_name} result=state-webhook-failed state=${new_state}"
    fi
    if [[ -n "$hook_expression" ]]; then
        run_configured_sequence "$hook_expression" "${new_state}" "$service_name" ||
            log ERROR "service=${service_name} result=state-hook-failed state=${new_state}"
    fi
    write_state "$service_name" "$new_state"
    log INFO "service=${service_name} action=state previous=${previous} current=${new_state}"
}

process_service() {
    local index="$1"
    local enabled actions_count verify_after action_due=0
    CURRENT_SERVICE="$(yaml_read ".services[$index].name")"
    CURRENT_CHECK_TYPE="$(yaml_read ".services[$index].check.type")"
    CURRENT_ACTION_STATUS="not-attempted"
    CHECK_DETAIL=""
    CHECK_HTTP_STATUS=""
    CHECK_EXIT_CODE=""
    enabled="$(yaml_read ".services[$index].enabled // true")"

    [[ -z "$ONLY_SERVICE" || "$CURRENT_SERVICE" == "$ONLY_SERVICE" ]] || return 0
    if [[ "$enabled" != true ]]; then
        log INFO "service=${CURRENT_SERVICE} result=skipped reason=disabled"
        return 0
    fi

    log INFO "service=${CURRENT_SERVICE} action=service-start type=${CURRENT_CHECK_TYPE}"
    if check_with_retries "$index"; then
        CURRENT_ACTION_STATUS="not-required"
        handle_state_transition "$CURRENT_SERVICE" healthy
        log INFO "service=${CURRENT_SERVICE} result=healthy"
        return 0
    fi

    actions_count="$(yaml_read ".services[$index].actions.commands // [] | length")"
    if (( actions_count == 0 )); then
        CURRENT_ACTION_STATUS="not-configured"
    elif (( DRY_RUN == 1 )); then
        CURRENT_ACTION_STATUS="skipped-dry-run"
    elif action_is_due "$index" "$CURRENT_SERVICE"; then
        CURRENT_ACTION_STATUS="pending"
        action_due=1
    else
        CURRENT_ACTION_STATUS="cooldown"
    fi

    # Record and notify the incident before remediation. The state transition
    # guarantees that a continuing outage does not generate duplicate email.
    handle_state_transition "$CURRENT_SERVICE" unavailable

    if (( actions_count > 0 )); then
        if (( DRY_RUN == 1 )); then
            log WARN "service=${CURRENT_SERVICE} action=remediation result=skipped reason=dry-run"
        elif (( action_due == 1 )); then
            ACTION_ATTEMPTED=1
            record_action_attempt "$CURRENT_SERVICE"
            log WARN "service=${CURRENT_SERVICE} action=remediation-start commands=${actions_count}"
            if run_configured_sequence ".services[$index].actions.commands" remediation "$CURRENT_SERVICE"; then
                CURRENT_ACTION_STATUS="commands-succeeded"
            else
                CURRENT_ACTION_STATUS="command-failed"
            fi

            verify_after="$(yaml_read ".services[$index].actions.verify_after // 0")"
            (( verify_after > 0 )) && sleep "$verify_after"
            if check_with_retries "$index"; then
                CURRENT_ACTION_STATUS="successful"
                handle_state_transition "$CURRENT_SERVICE" healthy
                log WARN "service=${CURRENT_SERVICE} result=recovered-after-remediation"
                return 0
            fi
            if [[ "$CURRENT_ACTION_STATUS" == commands-succeeded ]]; then
                CURRENT_ACTION_STATUS="verification-failed"
            fi
        else
            log WARN "service=${CURRENT_SERVICE} action=remediation result=skipped reason=cooldown"
        fi
    fi

    UNHEALTHY_FOUND=1
    log ERROR "service=${CURRENT_SERVICE} result=unavailable detail=\"$(sanitize_detail "$CHECK_DETAIL")\""
    return 0
}

main() {
    local option yq_version service_count index matched=0 name

    if [[ "${1:-}" == "--version" ]]; then
        printf '%s %s\n' "$SCRIPT_NAME" "$WATCHDOG_VERSION"
        exit 0
    fi

    while getopts ':c:s:nhV' option; do
        case "$option" in
            c) CONFIG_FILE="$OPTARG" ;;
            s) ONLY_SERVICE="$OPTARG" ;;
            n) DRY_RUN=1 ;;
            V) printf '%s %s\n' "$SCRIPT_NAME" "$WATCHDOG_VERSION"; exit 0 ;;
            h) usage; exit 0 ;;
            :) bootstrap_log CRITICAL "Option -${OPTARG} requires a value."; exit 2 ;;
            \?) bootstrap_log CRITICAL "Unknown option: -${OPTARG}"; usage >&2; exit 2 ;;
        esac
    done

    [[ -f "$CONFIG_FILE" ]] || die "Configuration file not found: ${CONFIG_FILE}"
    for name in bash base64 curl yq flock timeout date dirname mktemp tail tr mv env; do
        require_command "$name"
    done
    yq_version="$(yq --version 2>/dev/null)" || die "Cannot determine yq version."
    [[ "$yq_version" =~ version[[:space:]]+v?4\. ]] || die "Mike Farah yq v4 is required: ${yq_version}"

    validate_configuration
    configure_runtime
    configure_email
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
