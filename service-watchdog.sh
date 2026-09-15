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
EXPANDED_CONFIG_FILE=""

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
MAINTENANCE_ACTIVE=0
MAINTENANCE_WINDOW_NAME=""
ESCALATION_CONSECUTIVE_UNAVAILABLE=0
ESCALATION_COUNT=0
METRICS_ENABLED=0
METRICS_DIRECTORY=""
METRICS_FILENAME="watchdog.prom"
METRICS_PREFIX="watchdog"
STATUS_PAGE_ENABLED=0
STATUS_PAGE_DIRECTORY=""
STATUS_PAGE_HTML_FILENAME="index.html"
STATUS_PAGE_JSON_FILENAME=""
FEDERATION_AGENT_ENABLED=0
FEDERATION_HUB_ENABLED=0
FEDERATION_NODE_ID=""
FEDERATION_AGENT_TRANSPORT=""
FEDERATION_AGENT_HUB_URL=""
FEDERATION_AGENT_TOKEN_ENV=""
FEDERATION_AGENT_TIMEOUT=10
FEDERATION_AGENT_REPORT_PATH=""
FEDERATION_AGENT_HEARTBEAT=1
FEDERATION_HUB_INCOMING_DIRECTORY=""
FEDERATION_HUB_ARCHIVE_DIRECTORY=""
FEDERATION_HUB_MAX_REPORT_AGE=300
FEDERATION_HUB_ARCHIVE_RETENTION_DAYS=0
FEDERATION_HUB_STATE_FILE=""
FEDERATION_HUB_OVERALL_STATUS="unknown"
FEDERATION_HUB_UNHEALTHY_SERVICES=""
FEDERATION_HUB_OFFLINE_NODES=""
FEDERATION_STATE_CHANGED=0
PARALLEL_ENABLED=0
PARALLEL_MAX_JOBS=0
PARALLEL_TIMEOUT=0
PARALLEL_TEMP_BASE=""
PARALLEL_CHECK_MODE=0
PARALLEL_ATTEMPTS_MADE=0
PROCESS_RESULT="unknown"
declare -A SERVICE_INDEX=()
declare -A DEPENDENCY_NAMES=()
declare -A DEPENDENCY_REQUIRED=()
declare -A RESOLVED_STATE=()
declare -A SERVICE_LEVEL=()
declare -A PRELOADED_CHECK_STATE=()
declare -A PRELOADED_CHECK_DETAIL=()
declare -A PRELOADED_CHECK_HTTP_STATUS=()
declare -A PRELOADED_CHECK_EXIT_CODE=()
declare -A PRELOADED_CHECK_ATTEMPTS=()
declare -A CONDITION_SKIPPED=()
declare -A CONDITION_EVALUATED=()
SERVICE_ORDER=()
TEMPLATE_EXPANSION_LOG=()
TEMPLATE_WARNING_LOG=()

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
CONDITION_DETAIL=""
CONDITION_ERROR=0

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
    if [[ -n "${EXPANDED_CONFIG_FILE:-}" && -f "$EXPANDED_CONFIG_FILE" ]]; then
        rm -f -- "$EXPANDED_CONFIG_FILE"
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

validate_templates() {
    local templates_type template_count template_index template_name template_name_type template_type
    local reserved_field reserved_type warning service_count service_index service_name
    local template_reference template_reference_type mode mode_type template_exists

    templates_type="$(yaml_read '.templates | type' 2>/dev/null)" || die "Cannot read templates."
    case "$templates_type" in
        "!!null") template_count=0 ;;
        "!!map") template_count="$(yaml_read '.templates | length')" ;;
        *) die "templates must be a YAML map." ;;
    esac
    for ((template_index = 0; template_index < template_count; template_index++)); do
        template_name_type="$(yaml_read ".templates | to_entries[$template_index].key | type")"
        [[ "$template_name_type" == "!!str" ]] || die "Template names must be strings."
        template_name="$(yaml_read ".templates | to_entries[$template_index].key")"
        [[ "$template_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "Invalid template name: ${template_name}"
        template_type="$(yaml_read ".templates | to_entries[$template_index].value | type")"
        [[ "$template_type" == "!!map" ]] || die "Template '${template_name}' must be a YAML map."
        for reserved_field in name template template_mode; do
            reserved_type="$(yaml_read ".templates[\"${template_name}\"].${reserved_field} | type")"
            if [[ "$reserved_type" != "!!null" ]]; then
                warning="template=${template_name} warning=template_contains_${reserved_field} ignored=true"
                TEMPLATE_WARNING_LOG+=("$warning")
                bootstrap_log WARN "$warning"
            fi
        done
    done

    service_count="$(yaml_read '.services | length')"
    for ((service_index = 0; service_index < service_count; service_index++)); do
        service_name="$(yaml_read ".services[$service_index].name // \"index-${service_index}\"")"
        template_reference_type="$(yaml_read ".services[$service_index].template | type")"
        [[ "$template_reference_type" == "!!null" ]] && continue
        [[ "$template_reference_type" == "!!str" ]] || die "Service '${service_name}': template must be a string."
        template_reference="$(yaml_read ".services[$service_index].template")"
        [[ "$template_reference" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "Service '${service_name}': template must be a valid template name."
        [[ "$templates_type" == "!!map" ]] || die "result=config-error reason=missing_template service=${service_name} template=${template_reference}"
        template_exists="$(yaml_read ".templates | has(\"${template_reference}\")")"
        [[ "$template_exists" == true ]] || die "result=config-error reason=missing_template service=${service_name} template=${template_reference}"
        mode_type="$(yaml_read ".services[$service_index].template_mode | type")"
        [[ "$mode_type" == "!!null" || "$mode_type" == "!!str" ]] || die "Service '${service_name}': template_mode must be deep or shallow."
        mode="$(yaml_read ".services[$service_index].template_mode // \"deep\"")"
        [[ "$mode" == deep || "$mode" == shallow ]] || die "result=config-error reason=invalid_template_mode service=${service_name} mode=${mode}"
    done
}

expand_templates() {
    local service_count service_index service_name template_name mode fields_inherited merge_expression

    [[ "$(yaml_read '.templates | type')" == "!!map" ]] || return 0
    EXPANDED_CONFIG_FILE="$(mktemp "${TMPDIR:-/tmp}/service-watchdog.templates.XXXXXX.yaml")" || die "Cannot create expanded template configuration."
    yq eval '.' "$CONFIG_FILE" >"$EXPANDED_CONFIG_FILE" || die "Cannot expand templates."
    service_count="$(yq eval -r '.services | length' "$EXPANDED_CONFIG_FILE")"
    for ((service_index = 0; service_index < service_count; service_index++)); do
        template_name="$(yq eval -r ".services[$service_index].template // \"\"" "$EXPANDED_CONFIG_FILE")"
        [[ -n "$template_name" ]] || continue
        service_name="$(yq eval -r ".services[$service_index].name" "$EXPANDED_CONFIG_FILE")"
        mode="$(yq eval -r ".services[$service_index].template_mode // \"deep\"" "$EXPANDED_CONFIG_FILE")"
        fields_inherited="$(yq eval -r "((.templates[\"${template_name}\"] | del(.name, .template, .template_mode) | keys) - (.services[$service_index] | del(.template, .template_mode) | keys)) | length" "$EXPANDED_CONFIG_FILE")"
        case "$mode" in
            deep) merge_expression="(.templates[\"${template_name}\"] | del(.name, .template, .template_mode)) * (.services[$service_index] | del(.template, .template_mode))" ;;
            shallow) merge_expression="(.templates[\"${template_name}\"] | del(.name, .template, .template_mode)) + (.services[$service_index] | del(.template, .template_mode))" ;;
            *) die "result=config-error reason=invalid_template_mode service=${service_name} mode=${mode}" ;;
        esac
        yq eval -i ".services[$service_index] = (${merge_expression})" "$EXPANDED_CONFIG_FILE" || die "Cannot merge template '${template_name}' for service '${service_name}'."
        TEMPLATE_EXPANSION_LOG+=("template=${template_name} service=${service_name} mode=${mode} result=merged fields_inherited=${fields_inherited}")
    done
    yq eval -i 'del(.templates)' "$EXPANDED_CONFIG_FILE" || die "Cannot finalize expanded template configuration."
    CONFIG_FILE="$EXPANDED_CONFIG_FILE"
}

log_template_expansions() {
    local entry
    for entry in "${TEMPLATE_WARNING_LOG[@]}"; do
        log WARN "$entry"
    done
    for entry in "${TEMPLATE_EXPANSION_LOG[@]}"; do
        log INFO "$entry"
    done
}

is_positive_integer() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 > 0 ))
}

is_non_negative_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

is_non_negative_number() {
    [[ "$1" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]
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

        for value in failure recovery escalation circuit_open circuit_close; do
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

validate_maintenance_configuration() {
    local index="$1" service_name="$2" maintenance_type timezone windows_type count window
    local days time start end day normalized_day

    maintenance_type="$(yaml_read ".services[$index].maintenance | type")"
    [[ "$maintenance_type" == "!!null" ]] && return 0
    [[ "$maintenance_type" == "!!map" ]] || die "Service '${service_name}': maintenance must be a YAML map."
    timezone="$(yaml_read ".services[$index].maintenance.timezone // \"\"")"
    if [[ -n "$timezone" ]]; then
        [[ "$timezone" != *[[:space:]]* ]] || die "Service '${service_name}': maintenance.timezone must not contain spaces."
        TZ="$timezone" date '+%H:%M' >/dev/null 2>&1 ||
            die "Service '${service_name}': maintenance.timezone is invalid: ${timezone}"
        [[ "$timezone" == UTC || -r "/usr/share/zoneinfo/${timezone}" ]] ||
            die "Service '${service_name}': maintenance.timezone is not an installed IANA time zone: ${timezone}"
    fi
    windows_type="$(yaml_read ".services[$index].maintenance.windows | type")"
    [[ "$windows_type" == "!!seq" ]] || die "Service '${service_name}': maintenance.windows must be a YAML array."
    count="$(yaml_read ".services[$index].maintenance.windows | length")"
    for ((window = 0; window < count; window++)); do
        validate_string ".services[$index].maintenance.windows[$window].days" \
            "Service '${service_name}': maintenance.windows[$window].days"
        validate_string ".services[$index].maintenance.windows[$window].time" \
            "Service '${service_name}': maintenance.windows[$window].time"
        days="$(yaml_read ".services[$index].maintenance.windows[$window].days")"
        time="$(yaml_read ".services[$index].maintenance.windows[$window].time")"
        [[ "$time" =~ ^[0-9]{2}:[0-9]{2}-[0-9]{2}:[0-9]{2}$ ]] ||
            die "Service '${service_name}': maintenance.windows[$window].time must use HH:MM-HH:MM."
        start="${time%-*}"; end="${time#*-}"
        [[ "${start%:*}" =~ ^(0[0-9]|1[0-9]|2[0-3])$ && "${start#*:}" =~ ^[0-5][0-9]$ &&
           "${end%:*}" =~ ^(0[0-9]|1[0-9]|2[0-3])$ && "${end#*:}" =~ ^[0-5][0-9]$ &&
           "$start" < "$end" ]] ||
            die "Service '${service_name}': maintenance.windows[$window].time must be a same-day interval with start before end."
        [[ -n "$days" ]] || die "Service '${service_name}': maintenance.windows[$window].days must not be empty."
        [[ "$days" == "*" ]] && continue
        IFS=',' read -r -a day_list <<<"$days"
        for day in "${day_list[@]}"; do
            normalized_day="${day,,}"
            case "$normalized_day" in mon|tue|wed|thu|fri|sat|sun) ;; *)
                die "Service '${service_name}': invalid maintenance day '${day}'." ;;
            esac
        done
    done
}

validate_only_if_configuration() {
    local index="$1" service_name="$2" conditions_type condition_count condition type value value_type
    local argument_count argument_index exit_count exit_index days time start end day normalized_day timezone
    local threshold_count
    local -a condition_days=()

    conditions_type="$(yaml_read ".services[$index].only_if | type")"
    [[ "$conditions_type" == "!!null" ]] && return 0
    [[ "$conditions_type" == "!!seq" ]] || die "Service '${service_name}': only_if must be a YAML array."
    condition_count="$(yaml_read ".services[$index].only_if | length")"
    for ((condition = 0; condition < condition_count; condition++)); do
        validate_string ".services[$index].only_if[$condition].type" "Service '${service_name}': only_if[$condition].type"
        type="$(yaml_read ".services[$index].only_if[$condition].type")"
        value="$(yaml_read ".services[$index].only_if[$condition].invert // false")"
        [[ "$value" == true || "$value" == false ]] || die "Service '${service_name}': only_if[$condition].invert must be true or false."
        case "$type" in
            command)
                value_type="$(yaml_read ".services[$index].only_if[$condition].command | type")"
                [[ "$value_type" == "!!seq" ]] || die "Service '${service_name}': only_if[$condition].command must be an array."
                argument_count="$(yaml_read ".services[$index].only_if[$condition].command | length")"
                (( argument_count > 0 )) || die "Service '${service_name}': only_if[$condition].command must not be empty."
                for ((argument_index = 0; argument_index < argument_count; argument_index++)); do
                    value_type="$(yaml_read ".services[$index].only_if[$condition].command[$argument_index] | type")"
                    case "$value_type" in "!!str"|"!!int"|"!!float"|"!!bool") ;; *)
                        die "Service '${service_name}': only_if[$condition].command[$argument_index] must be scalar." ;;
                    esac
                done
                value="$(yaml_read ".services[$index].only_if[$condition].timeout // 10")"
                is_positive_integer "$value" || die "Service '${service_name}': only_if[$condition].timeout must be a positive integer."
                value_type="$(yaml_read ".services[$index].only_if[$condition].exit_code | type")"
                case "$value_type" in
                    "!!null") ;;
                    "!!int")
                        value="$(yaml_read ".services[$index].only_if[$condition].exit_code")"
                        if ! is_non_negative_integer "$value" || (( 10#$value > 255 )); then
                            die "Service '${service_name}': only_if[$condition].exit_code must be from 0 through 255."
                        fi
                        ;;
                    "!!seq")
                        exit_count="$(yaml_read ".services[$index].only_if[$condition].exit_code | length")"
                        (( exit_count > 0 )) || die "Service '${service_name}': only_if[$condition].exit_code must not be empty."
                        for ((exit_index = 0; exit_index < exit_count; exit_index++)); do
                            value_type="$(yaml_read ".services[$index].only_if[$condition].exit_code[$exit_index] | type")"
                            [[ "$value_type" == "!!int" ]] || die "Service '${service_name}': only_if[$condition].exit_code[$exit_index] must be an integer."
                            value="$(yaml_read ".services[$index].only_if[$condition].exit_code[$exit_index]")"
                            if ! is_non_negative_integer "$value" || (( 10#$value > 255 )); then
                                die "Service '${service_name}': only_if[$condition].exit_code[$exit_index] must be from 0 through 255."
                            fi
                        done
                        ;;
                    *) die "Service '${service_name}': only_if[$condition].exit_code must be an integer or array." ;;
                esac
                ;;
            file_exists)
                validate_string ".services[$index].only_if[$condition].path" "Service '${service_name}': only_if[$condition].path"
                value="$(yaml_read ".services[$index].only_if[$condition].path")"
                [[ "$value" == /* ]] || die "Service '${service_name}': only_if[$condition].path must be absolute."
                ;;
            time_window)
                validate_string ".services[$index].only_if[$condition].days" "Service '${service_name}': only_if[$condition].days"
                validate_string ".services[$index].only_if[$condition].time" "Service '${service_name}': only_if[$condition].time"
                days="$(yaml_read ".services[$index].only_if[$condition].days")"
                time="$(yaml_read ".services[$index].only_if[$condition].time")"
                [[ "$time" =~ ^[0-9]{2}:[0-9]{2}-[0-9]{2}:[0-9]{2}$ ]] || die "Service '${service_name}': only_if[$condition].time must use HH:MM-HH:MM."
                start="${time%-*}"; end="${time#*-}"
                [[ "${start%:*}" =~ ^(0[0-9]|1[0-9]|2[0-3])$ && "${start#*:}" =~ ^[0-5][0-9]$ && "${end%:*}" =~ ^(0[0-9]|1[0-9]|2[0-3])$ && "${end#*:}" =~ ^[0-5][0-9]$ && "$start" < "$end" ]] || die "Service '${service_name}': only_if[$condition].time must be a same-day interval with start before end."
                [[ -n "$days" ]] || die "Service '${service_name}': only_if[$condition].days must not be empty."
                if [[ "$days" != "*" ]]; then
                    IFS=',' read -r -a condition_days <<<"$days"
                    for day in "${condition_days[@]}"; do
                        normalized_day="${day,,}"
                        case "$normalized_day" in mon|tue|wed|thu|fri|sat|sun) ;; *) die "Service '${service_name}': invalid only_if day '${day}'." ;; esac
                    done
                fi
                value_type="$(yaml_read ".services[$index].only_if[$condition].timezone | type")"
                if [[ "$value_type" != "!!null" ]]; then
                    validate_string ".services[$index].only_if[$condition].timezone" "Service '${service_name}': only_if[$condition].timezone"
                    timezone="$(yaml_read ".services[$index].only_if[$condition].timezone")"
                    [[ "$timezone" != *[[:space:]]* ]] || die "Service '${service_name}': only_if[$condition].timezone must not contain spaces."
                    TZ="$timezone" date '+%H:%M' >/dev/null 2>&1 || die "Service '${service_name}': only_if[$condition].timezone is invalid: ${timezone}"
                    [[ "$timezone" == UTC || -r "/usr/share/zoneinfo/${timezone}" ]] || die "Service '${service_name}': only_if[$condition].timezone is not an installed IANA time zone: ${timezone}"
                fi
                ;;
            load_average)
                threshold_count=0
                for value in max_1min max_5min max_15min; do
                    value_type="$(yaml_read ".services[$index].only_if[$condition].${value} | type")"
                    [[ "$value_type" == "!!null" ]] && continue
                    [[ "$value_type" == "!!int" || "$value_type" == "!!float" ]] || die "Service '${service_name}': only_if[$condition].${value} must be a number."
                    type="$(yaml_read ".services[$index].only_if[$condition].${value}")"
                    is_non_negative_number "$type" || die "Service '${service_name}': only_if[$condition].${value} must be non-negative."
                    ((threshold_count++))
                done
                (( threshold_count > 0 )) || die "Service '${service_name}': only_if[$condition].load_average needs at least one maximum."
                ;;
            filesystem)
                validate_string ".services[$index].only_if[$condition].path" "Service '${service_name}': only_if[$condition].path"
                value="$(yaml_read ".services[$index].only_if[$condition].path")"
                [[ "$value" == /* ]] || die "Service '${service_name}': only_if[$condition].path must be absolute."
                threshold_count=0
                for value in min_free_gb min_free_percent; do
                    value_type="$(yaml_read ".services[$index].only_if[$condition].${value} | type")"
                    [[ "$value_type" == "!!null" ]] && continue
                    [[ "$value_type" == "!!int" || "$value_type" == "!!float" ]] || die "Service '${service_name}': only_if[$condition].${value} must be a number."
                    type="$(yaml_read ".services[$index].only_if[$condition].${value}")"
                    is_non_negative_number "$type" || die "Service '${service_name}': only_if[$condition].${value} must be non-negative."
                    if [[ "$value" == min_free_percent ]] && ! awk -v threshold="$type" 'BEGIN { exit !(threshold <= 100) }'; then
                        die "Service '${service_name}': only_if[$condition].min_free_percent must not exceed 100."
                    fi
                    ((threshold_count++))
                done
                (( threshold_count > 0 )) || die "Service '${service_name}': only_if[$condition].filesystem needs min_free_gb or min_free_percent."
                ;;
            *) die "Service '${service_name}': only_if[$condition].type must be command, file_exists, time_window, load_average, or filesystem." ;;
        esac
    done
}

validate_escalation_configuration() {
    local index="$1" service_name="$2" escalation_type enabled value value_type hooks_type

    escalation_type="$(yaml_read ".services[$index].escalation | type")"
    [[ "$escalation_type" == "!!null" ]] && return 0
    [[ "$escalation_type" == "!!map" ]] || die "Service '${service_name}': escalation must be a YAML map."
    enabled="$(yaml_read ".services[$index].escalation.enabled // false")"
    [[ "$enabled" == true || "$enabled" == false ]] ||
        die "Service '${service_name}': escalation.enabled must be true or false."
    [[ "$enabled" == true ]] || return 0
    value="$(yaml_read ".services[$index].escalation.after_consecutive_unavailable")"
    is_positive_integer "$value" ||
        die "Service '${service_name}': escalation.after_consecutive_unavailable must be a positive integer."
    value="$(yaml_read ".services[$index].escalation.cooldown // 0")"
    is_non_negative_integer "$value" || die "Service '${service_name}': escalation.cooldown must be non-negative."
    value="$(yaml_read ".services[$index].escalation.notify // true")"
    [[ "$value" == true || "$value" == false ]] ||
        die "Service '${service_name}': escalation.notify must be true or false."
    value_type="$(yaml_read ".services[$index].escalation.actions.commands | type")"
    if [[ "$value_type" != "!!null" ]]; then
        validate_command_sequence ".services[$index].escalation.actions.commands" \
            "Service '${service_name}': escalation.actions.commands" true
    fi
    hooks_type="$(yaml_read ".services[$index].escalation.hooks.on_escalation | type")"
    if [[ "$hooks_type" != "!!null" ]]; then
        validate_command_sequence ".services[$index].escalation.hooks.on_escalation" \
            "Service '${service_name}': escalation.hooks.on_escalation" true
    fi
}

validate_circuit_breaker_configuration() {
    local index="$1" service_name="$2" type enabled value value_type
    type="$(yaml_read ".services[$index].circuit_breaker | type")"
    [[ "$type" == "!!null" ]] && return 0
    [[ "$type" == "!!map" ]] || die "Service '${service_name}': circuit_breaker must be a YAML map."
    enabled="$(yaml_read ".services[$index].circuit_breaker.enabled")"
    [[ "$enabled" == true || "$enabled" == false ]] || die "Service '${service_name}': circuit_breaker.enabled must be true or false."
    [[ "$enabled" == true ]] || return 0
    value="$(yaml_read ".services[$index].circuit_breaker.failure_threshold")"
    is_positive_integer "$value" || die "Service '${service_name}': circuit_breaker.failure_threshold must be a positive integer."
    value="$(yaml_read ".services[$index].circuit_breaker.open_duration")"
    is_positive_integer "$value" || die "Service '${service_name}': circuit_breaker.open_duration must be a positive integer."
    value="$(yaml_read ".services[$index].circuit_breaker.half_open_verify_after // 0")"
    is_non_negative_integer "$value" || die "Service '${service_name}': circuit_breaker.half_open_verify_after must be non-negative."
    value="$(yaml_read ".services[$index].circuit_breaker.notify // true")"
    [[ "$value" == true || "$value" == false ]] || die "Service '${service_name}': circuit_breaker.notify must be true or false."
    value_type="$(yaml_read ".services[$index].circuit_breaker.hooks.on_open | type")"
    [[ "$value_type" == "!!null" ]] || validate_command_sequence ".services[$index].circuit_breaker.hooks.on_open" "Service '${service_name}': circuit_breaker.hooks.on_open" true
    value_type="$(yaml_read ".services[$index].circuit_breaker.hooks.on_close | type")"
    [[ "$value_type" == "!!null" ]] || validate_command_sequence ".services[$index].circuit_breaker.hooks.on_close" "Service '${service_name}': circuit_breaker.hooks.on_close" true
}

validate_metrics_configuration() {
    local enabled value labels_type count index key value_type
    enabled="$(yaml_read '.metrics.enabled // false')"
    [[ "$enabled" == true || "$enabled" == false ]] || die "metrics.enabled must be true or false."
    [[ "$enabled" == true ]] || return 0
    validate_string '.metrics.textfile_directory' 'metrics.textfile_directory'
    value="$(yaml_read '.metrics.textfile_directory')"
    [[ "$value" == /* ]] || die "metrics.textfile_directory must be an absolute path."
    validate_string '.metrics.filename' 'metrics.filename'
    value="$(yaml_read '.metrics.filename')"
    [[ -n "$value" && "$value" != */* ]] || die "metrics.filename must be a file name, not a path."
    validate_string '.metrics.prefix' 'metrics.prefix'
    value="$(yaml_read '.metrics.prefix')"
    [[ "$value" =~ ^[A-Za-z_:][A-Za-z0-9_:]*$ ]] || die "metrics.prefix is not a valid Prometheus metric prefix."
    labels_type="$(yaml_read '.metrics.static_labels | type')"
    [[ "$labels_type" == "!!null" ]] && return 0
    [[ "$labels_type" == "!!map" ]] || die "metrics.static_labels must be a YAML map."
    count="$(yaml_read '.metrics.static_labels | length')"
    for ((index = 0; index < count; index++)); do
        key="$(yaml_read ".metrics.static_labels | to_entries[$index].key")"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "Invalid Prometheus static label name: ${key}"
        value_type="$(yaml_read ".metrics.static_labels | to_entries[$index].value | type")"
        [[ "$value_type" == "!!str" || "$value_type" == "!!int" || "$value_type" == "!!float" || "$value_type" == "!!bool" ]] ||
            die "metrics.static_labels.${key} must be scalar."
    done
}

validate_status_page_configuration() {
    local enabled value theme_key type refresh
    enabled="$(yaml_read '.status_page.enabled // false')"
    [[ "$enabled" == true || "$enabled" == false ]] || die "status_page.enabled must be true or false."
    [[ "$enabled" == true ]] || return 0
    validate_string '.status_page.output_directory' 'status_page.output_directory'
    value="$(yaml_read '.status_page.output_directory')"
    [[ "$value" == /* ]] || die "status_page.output_directory must be an absolute path."
    for theme_key in html_filename json_filename title description logo_url footer; do
        type="$(yaml_read ".status_page.${theme_key} | type")"
        [[ "$type" == "!!null" ]] || validate_string ".status_page.${theme_key}" "status_page.${theme_key}"
    done
    for theme_key in html_filename json_filename; do
        value="$(yaml_read ".status_page.${theme_key} // \"\"")"
        [[ -z "$value" || "$value" != */* ]] || die "status_page.${theme_key} must be a file name, not a path."
    done
    for theme_key in primary danger warning bg card text muted; do
        value="$(yaml_read ".status_page.theme.${theme_key} // \"\"")"
        [[ -z "$value" || "$value" =~ ^[0-9A-Fa-f]{6}$ ]] || die "status_page.theme.${theme_key} must be a six-character hex color."
    done
    refresh="$(yaml_read '.status_page.auto_refresh // 0')"
    is_non_negative_integer "$refresh" || die "status_page.auto_refresh must be non-negative."
}

validate_parallel_configuration() {
    local value value_type
    value_type="$(yaml_read '.parallel | type')"
    [[ "$value_type" == "!!null" || "$value_type" == "!!map" ]] || die "parallel must be a YAML map."
    value="$(yaml_read '.parallel.enabled // false')"
    [[ "$value" == true || "$value" == false ]] || die "parallel.enabled must be true or false."
    value="$(yaml_read '.parallel.max_jobs // 0')"
    is_non_negative_integer "$value" || die "parallel.max_jobs must be a non-negative integer."
    value="$(yaml_read '.parallel.timeout // 0')"
    is_non_negative_integer "$value" || die "parallel.timeout must be a non-negative integer."
    value_type="$(yaml_read '.parallel.temp_dir | type')"
    [[ "$value_type" == "!!null" || "$value_type" == "!!str" ]] || die "parallel.temp_dir must be a string."
    if [[ "$value_type" == "!!str" ]]; then
        value="$(yaml_read '.parallel.temp_dir')"
        [[ -z "$value" || "$value" == /* ]] || die "parallel.temp_dir must be an absolute path."
    fi
}

federation_validate_config() {
    local type enabled value value_type count index node_id
    local -A seen_nodes=()

    type="$(yaml_read '.federation | type')"
    [[ "$type" == "!!null" ]] && return 0
    [[ "$type" == "!!map" ]] || die "federation must be a YAML map."
    enabled="$(yaml_read '.federation.enabled // false')"
    [[ "$enabled" == true || "$enabled" == false ]] || die "federation.enabled must be true or false."
    [[ "$enabled" == true ]] || return 0

    value_type="$(yaml_read '.federation.node_id | type')"
    [[ "$value_type" == "!!null" || "$value_type" == "!!str" ]] || die "federation.node_id must be a string."
    if [[ "$value_type" == "!!str" ]]; then
        node_id="$(yaml_read '.federation.node_id')"
        [[ "$node_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "federation.node_id contains unsupported characters."
    fi

    for type in agent hub; do
        value_type="$(yaml_read ".federation.${type} | type")"
        [[ "$value_type" == "!!null" || "$value_type" == "!!map" ]] || die "federation.${type} must be a YAML map."
        value="$(yaml_read ".federation.${type}.enabled // false")"
        [[ "$value" == true || "$value" == false ]] || die "federation.${type}.enabled must be true or false."
    done

    enabled="$(yaml_read '.federation.agent.enabled // false')"
    if [[ "$enabled" == true ]]; then
        value="$(yaml_read '.federation.agent.transport // "http"')"
        [[ "$value" == http || "$value" == file ]] || die "federation.agent.transport must be http or file."
        value="$(yaml_read '.federation.agent.timeout // 10')"
        is_positive_integer "$value" || die "federation.agent.timeout must be a positive integer."
        value="$(yaml_read '.federation.agent.heartbeat // true')"
        [[ "$value" == true || "$value" == false ]] || die "federation.agent.heartbeat must be true or false."
        if [[ "$(yaml_read '.federation.agent.transport // "http"')" == http ]]; then
            validate_string '.federation.agent.hub_url' 'federation.agent.hub_url'
            value="$(yaml_read '.federation.agent.hub_url')"
            [[ "$value" =~ ^https?://[^[:space:]]+$ ]] || die "federation.agent.hub_url must be an HTTP(S) URL without spaces."
            validate_string '.federation.agent.token_env' 'federation.agent.token_env'
            value="$(yaml_read '.federation.agent.token_env')"
            [[ "$value" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "federation.agent.token_env is not a valid environment variable name."
        else
            validate_string '.federation.agent.report_path' 'federation.agent.report_path'
            value="$(yaml_read '.federation.agent.report_path')"
            [[ "$value" == /* ]] || die "federation.agent.report_path must be an absolute path."
        fi
    fi

    enabled="$(yaml_read '.federation.hub.enabled // false')"
    if [[ "$enabled" == true ]]; then
        for value in incoming_dir archive_dir; do
            validate_string ".federation.hub.${value}" "federation.hub.${value}"
            node_id="$(yaml_read ".federation.hub.${value}")"
            [[ "$node_id" == /* ]] || die "federation.hub.${value} must be an absolute path."
        done
        value="$(yaml_read '.federation.hub.max_report_age // 300')"
        is_positive_integer "$value" || die "federation.hub.max_report_age must be a positive integer."
        value="$(yaml_read '.federation.hub.archive_retention_days // 0')"
        is_non_negative_integer "$value" || die "federation.hub.archive_retention_days must be a non-negative integer."
        value_type="$(yaml_read '.federation.hub.expected_nodes | type')"
        [[ "$value_type" == "!!null" || "$value_type" == "!!seq" ]] || die "federation.hub.expected_nodes must be a YAML array."
        if [[ "$value_type" == "!!seq" ]]; then
            count="$(yaml_read '.federation.hub.expected_nodes | length')"
            for ((index = 0; index < count; index++)); do
                validate_string ".federation.hub.expected_nodes[$index]" "federation.hub.expected_nodes[$index]"
                node_id="$(yaml_read ".federation.hub.expected_nodes[$index]")"
                [[ "$node_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "Invalid federation expected node: ${node_id}"
                [[ -z "${seen_nodes[$node_id]:-}" ]] || die "Duplicate federation expected node: ${node_id}"
                seen_nodes["$node_id"]=1
            done
        fi
        for value in overall_change agent_offline any_service_change; do
            node_id="$(yaml_read ".federation.hub.notify_on.${value} // true")"
            [[ "$node_id" == true || "$node_id" == false ]] || die "federation.hub.notify_on.${value} must be true or false."
        done
        value_type="$(yaml_read '.federation.hub.templates | type')"
        [[ "$value_type" == "!!null" || "$value_type" == "!!map" ]] || die "federation.hub.templates must be a YAML map."
        for type in overall_failure overall_recovery agent_offline; do
            value_type="$(yaml_read ".federation.hub.templates.${type} | type")"
            [[ "$value_type" == "!!null" || "$value_type" == "!!map" ]] || die "federation.hub.templates.${type} must be a YAML map."
            for value in subject body; do
                value_type="$(yaml_read ".federation.hub.templates.${type}.${value} | type")"
                [[ "$value_type" == "!!null" || "$value_type" == "!!str" ]] || die "federation.hub.templates.${type}.${value} must be a string."
            done
        done
    fi

    [[ "$(yaml_read '.federation.agent.enabled // false')" == true && "$(yaml_read '.federation.hub.enabled // false')" == true ]] &&
        die "federation.agent and federation.hub must use separate watchdog instances."
}

build_dependency_graph() {
    local service_count index service_name dependencies_type dependency_count dependency dependency_name required
    local candidate candidate_dependencies candidate_dependency progress blocked

    SERVICE_INDEX=(); DEPENDENCY_NAMES=(); DEPENDENCY_REQUIRED=(); SERVICE_LEVEL=(); SERVICE_ORDER=()
    service_count="$(yaml_read '.services | length')"
    for ((index = 0; index < service_count; index++)); do
        service_name="$(yaml_read ".services[$index].name")"
        SERVICE_INDEX["$service_name"]="$index"
        DEPENDENCY_NAMES["$service_name"]=""
    done
    for ((index = 0; index < service_count; index++)); do
        service_name="$(yaml_read ".services[$index].name")"
        dependencies_type="$(yaml_read ".services[$index].depends_on | type")"
        [[ "$dependencies_type" == "!!null" ]] && continue
        [[ "$dependencies_type" == "!!seq" ]] || die "Service '${service_name}': depends_on must be a YAML array."
        dependency_count="$(yaml_read ".services[$index].depends_on | length")"
        for ((dependency = 0; dependency < dependency_count; dependency++)); do
            validate_string ".services[$index].depends_on[$dependency].name" \
                "Service '${service_name}': depends_on[$dependency].name"
            dependency_name="$(yaml_read ".services[$index].depends_on[$dependency].name")"
            [[ -n "${SERVICE_INDEX[$dependency_name]:-}" ]] ||
                die "result=config-error reason=missing_dependency service=${service_name} dependency=${dependency_name}"
            required="$(yaml_read ".services[$index].depends_on[$dependency].required // true")"
            [[ "$required" == true || "$required" == false ]] ||
                die "Service '${service_name}': depends_on[$dependency].required must be true or false."
            DEPENDENCY_NAMES["$service_name"]+=" ${dependency_name}"
            DEPENDENCY_REQUIRED["${service_name}:${dependency_name}"]="$required"
        done
    done

    local -A completed=()
    local candidate_level dependency_level
    while (( ${#SERVICE_ORDER[@]} < service_count )); do
        progress=0
        for ((index = 0; index < service_count; index++)); do
            candidate="$(yaml_read ".services[$index].name")"
            [[ -z "${completed[$candidate]:-}" ]] || continue
            candidate_dependencies="${DEPENDENCY_NAMES[$candidate]:-}"
            blocked=0
            for candidate_dependency in $candidate_dependencies; do
                [[ -n "${completed[$candidate_dependency]:-}" ]] || { blocked=1; break; }
            done
            (( blocked == 0 )) || continue
            candidate_level=0
            for candidate_dependency in $candidate_dependencies; do
                dependency_level="${SERVICE_LEVEL[$candidate_dependency]:-0}"
                (( candidate_level < dependency_level + 1 )) && candidate_level=$((dependency_level + 1))
            done
            completed["$candidate"]=1
            SERVICE_LEVEL["$candidate"]="$candidate_level"
            SERVICE_ORDER+=("$candidate")
            progress=1
        done
        (( progress == 1 )) || die "result=config-error reason=circular_dependency cycle=dependency-graph"
    done
}

validate_configuration() {
    local services_type service_count index name enabled check_type value value_type
    local status_count status_index status_code port actions_type hooks_type hook_name
    local -A seen_names=()

    yq eval '.' "$CONFIG_FILE" >/dev/null 2>&1 ||
        die "YAML is syntactically invalid: ${CONFIG_FILE}"

    validate_parallel_configuration
    federation_validate_config

    services_type="$(yaml_read '.services | type')"
    [[ "$services_type" == "!!seq" ]] || die ".services must be a YAML array."
    service_count="$(yaml_read '.services | length')"
    if (( service_count == 0 )) && [[ "$(yaml_read '.federation.hub.enabled // false')" != true ]]; then
        die ".services must contain at least one service."
    fi

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

        value_type="$(yaml_read ".services[$index].parallel | type")"
        [[ "$value_type" == "!!null" || "$value_type" == "!!bool" ]] ||
            die "Service '${name}': parallel must be true or false."

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
        validate_only_if_configuration "$index" "$name"
        validate_maintenance_configuration "$index" "$name"
        validate_escalation_configuration "$index" "$name"
        validate_circuit_breaker_configuration "$index" "$name"
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
    validate_metrics_configuration
    validate_status_page_configuration
    build_dependency_graph
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

configure_parallel() {
    local value configured_directory
    [[ "$(yaml_read '.parallel.enabled // false')" == true ]] && PARALLEL_ENABLED=1
    value="$(yaml_read '.parallel.max_jobs // 0')"
    PARALLEL_MAX_JOBS="$((10#$value))"
    value="$(yaml_read '.parallel.timeout // 0')"
    PARALLEL_TIMEOUT="$((10#$value))"
    configured_directory="$(yaml_read '.parallel.temp_dir // ""')"
    if [[ -n "$configured_directory" ]] && mkdir -p -- "$configured_directory" 2>/dev/null && [[ -w "$configured_directory" ]]; then
        PARALLEL_TEMP_BASE="$configured_directory"
    else
        [[ -z "$configured_directory" ]] || log WARN "phase=check mode=parallel temp_dir=${configured_directory} result=fallback-to-tmp"
        PARALLEL_TEMP_BASE="/tmp"
    fi
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

configure_metrics() {
    [[ "$(yaml_read '.metrics.enabled // false')" == true ]] || return 0
    METRICS_ENABLED=1
    METRICS_DIRECTORY="$(yaml_read '.metrics.textfile_directory')"
    METRICS_FILENAME="$(yaml_read '.metrics.filename')"
    METRICS_PREFIX="$(yaml_read '.metrics.prefix')"
    [[ "$METRICS_FILENAME" == *.prom ]] ||
        log WARN "result=metrics-warning reason=filename-not-prom filename=${METRICS_FILENAME}"
}

configure_status_page() {
    [[ "$(yaml_read '.status_page.enabled // false')" == true ]] || return 0
    STATUS_PAGE_ENABLED=1
    STATUS_PAGE_DIRECTORY="$(yaml_read '.status_page.output_directory')"
    STATUS_PAGE_HTML_FILENAME="$(yaml_read '.status_page.html_filename // "index.html"')"
    STATUS_PAGE_JSON_FILENAME="$(yaml_read '.status_page.json_filename // ""')"
}

configure_federation() {
    local value

    [[ "$(yaml_read '.federation.enabled // false')" == true ]] || return 0
    FEDERATION_NODE_ID="$(yaml_read '.federation.node_id // ""')"
    [[ -n "$FEDERATION_NODE_ID" ]] || FEDERATION_NODE_ID="$(hostname -s)"

    if [[ "$(yaml_read '.federation.agent.enabled // false')" == true ]]; then
        FEDERATION_AGENT_ENABLED=1
        FEDERATION_AGENT_TRANSPORT="$(yaml_read '.federation.agent.transport // "http"')"
        FEDERATION_AGENT_HUB_URL="$(yaml_read '.federation.agent.hub_url // ""')"
        FEDERATION_AGENT_TOKEN_ENV="$(yaml_read '.federation.agent.token_env // ""')"
        value="$(yaml_read '.federation.agent.timeout // 10')"
        FEDERATION_AGENT_TIMEOUT="$((10#$value))"
        FEDERATION_AGENT_REPORT_PATH="$(yaml_read '.federation.agent.report_path // ""')"
        if [[ "$(yaml_read '.federation.agent.heartbeat // true')" == true ]]; then
            FEDERATION_AGENT_HEARTBEAT=1
        else
            FEDERATION_AGENT_HEARTBEAT=0
        fi
    fi

    if [[ "$(yaml_read '.federation.hub.enabled // false')" == true ]]; then
        FEDERATION_HUB_ENABLED=1
        FEDERATION_HUB_INCOMING_DIRECTORY="$(yaml_read '.federation.hub.incoming_dir')"
        FEDERATION_HUB_ARCHIVE_DIRECTORY="$(yaml_read '.federation.hub.archive_dir')"
        value="$(yaml_read '.federation.hub.max_report_age // 300')"
        FEDERATION_HUB_MAX_REPORT_AGE="$((10#$value))"
        value="$(yaml_read '.federation.hub.archive_retention_days // 0')"
        FEDERATION_HUB_ARCHIVE_RETENTION_DAYS="$((10#$value))"
        FEDERATION_HUB_STATE_FILE="${STATE_DIRECTORY}/federation-hub-state.json"
    fi
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

apply_condition_invert() {
    local index="$1" condition="$2" raw_result="$3" invert
    invert="$(yaml_read ".services[$index].only_if[$condition].invert // false")"
    if [[ "$invert" == true ]]; then
        CONDITION_DETAIL+=" invert=true"
        if (( raw_result == 0 )); then
            return 1
        fi
        return 0
    fi
    return "$raw_result"
}

condition_expected_exit_matches() {
    local index="$1" condition="$2" exit_code="$3" value_type expected count item
    value_type="$(yaml_read ".services[$index].only_if[$condition].exit_code | type")"
    if [[ "$value_type" == "!!null" ]]; then
        [[ "$exit_code" == 0 ]]
        return
    fi
    if [[ "$value_type" == "!!int" ]]; then
        expected="$(yaml_read ".services[$index].only_if[$condition].exit_code")"
        [[ "$exit_code" == "$expected" ]]
        return
    fi
    count="$(yaml_read ".services[$index].only_if[$condition].exit_code | length")"
    for ((item = 0; item < count; item++)); do
        expected="$(yaml_read ".services[$index].only_if[$condition].exit_code[$item]")"
        [[ "$exit_code" == "$expected" ]] && return 0
    done
    return 1
}

condition_expected_exit_description() {
    local index="$1" condition="$2" value_type count item result=""
    value_type="$(yaml_read ".services[$index].only_if[$condition].exit_code | type")"
    [[ "$value_type" == "!!null" ]] && { printf '0'; return; }
    [[ "$value_type" == "!!int" ]] && { yaml_read ".services[$index].only_if[$condition].exit_code"; return; }
    count="$(yaml_read ".services[$index].only_if[$condition].exit_code | length")"
    for ((item = 0; item < count; item++)); do
        if [[ -n "$result" ]]; then
            result+=","
        fi
        result+="$(yaml_read ".services[$index].only_if[$condition].exit_code[$item]")"
    done
    printf '[%s]' "$result"
}

evaluate_single_condition() {
    local index="$1" condition="$2" type raw_result=1 timeout_value command_status formatted
    local path days time timezone day now start end normalized_day matched_day
    local load_1 load_5 load_15 field threshold current value_type
    local free_bytes free_percent df_values min_free_gb min_free_percent
    local -a condition_command=() condition_days=()

    CONDITION_DETAIL=""
    CONDITION_ERROR=0
    type="$(yaml_read ".services[$index].only_if[$condition].type")"
    case "$type" in
        command)
            load_command ".services[$index].only_if[$condition].command" condition_command
            formatted="$(format_command condition_command)"
            timeout_value="$(yaml_read ".services[$index].only_if[$condition].timeout // 10")"
            timeout --signal=TERM --kill-after=2s "$timeout_value" "${condition_command[@]}" >/dev/null 2>&1
            command_status=$?
            if (( command_status == 124 || command_status == 137 )); then
                CONDITION_ERROR=1
                CONDITION_DETAIL="command ${formatted} reason=timeout"
            else
                CONDITION_DETAIL="command ${formatted} exit=${command_status} expected=$(condition_expected_exit_description "$index" "$condition")"
                condition_expected_exit_matches "$index" "$condition" "$command_status" && raw_result=0
            fi
            ;;
        file_exists)
            path="$(yaml_read ".services[$index].only_if[$condition].path")"
            CONDITION_DETAIL="file_exists path=${path}"
            [[ -e "$path" ]] && raw_result=0
            ;;
        time_window)
            days="$(yaml_read ".services[$index].only_if[$condition].days")"
            time="$(yaml_read ".services[$index].only_if[$condition].time")"
            timezone="$(yaml_read ".services[$index].only_if[$condition].timezone // \"\"")"
            if [[ -n "$timezone" ]]; then
                day="$(TZ="$timezone" LC_ALL=C date '+%a')"
                now="$(TZ="$timezone" date '+%H:%M')"
            else
                day="$(LC_ALL=C date '+%a')"
                now="$(date '+%H:%M')"
            fi
            day="${day,,}"
            matched_day=0
            if [[ "$days" == "*" ]]; then
                matched_day=1
            else
                IFS=',' read -r -a condition_days <<<"$days"
                for normalized_day in "${condition_days[@]}"; do
                    [[ "${normalized_day,,}" == "$day" ]] && matched_day=1
                done
            fi
            start="${time%-*}"; end="${time#*-}"
            CONDITION_DETAIL="time_window days=${days} time=${time} current=${day}_${now}${timezone:+ timezone=${timezone}}"
            if (( matched_day == 1 )) && [[ "$now" > "$start" || "$now" == "$start" ]] && [[ "$now" < "$end" ]]; then
                raw_result=0
            fi
            ;;
        load_average)
            if [[ ! -r /proc/loadavg ]] || ! read -r load_1 load_5 load_15 _ </proc/loadavg; then
                CONDITION_ERROR=1
                CONDITION_DETAIL="load_average reason=unavailable"
                apply_condition_invert "$index" "$condition" "$raw_result"
                return
            fi
            raw_result=0
            for field in max_1min max_5min max_15min; do
                value_type="$(yaml_read ".services[$index].only_if[$condition].${field} | type")"
                [[ "$value_type" == "!!null" ]] && continue
                threshold="$(yaml_read ".services[$index].only_if[$condition].${field}")"
                case "$field" in max_1min) current="$load_1" ;; max_5min) current="$load_5" ;; *) current="$load_15" ;; esac
                if ! awk -v current="$current" -v maximum="$threshold" 'BEGIN { exit !(current <= maximum) }'; then
                    raw_result=1
                    CONDITION_DETAIL="load_average ${field}=${threshold} current=${current}"
                    break
                fi
                CONDITION_DETAIL="load_average ${field}=${threshold} current=${current}"
            done
            ;;
        filesystem)
            path="$(yaml_read ".services[$index].only_if[$condition].path")"
            df_values="$(df -B1 --output=avail,pcent -- "$path" 2>/dev/null | awk 'NR == 2 { gsub(/%/, "", $2); print $1, $2 }')"
            read -r free_bytes free_percent <<<"$df_values"
            if ! [[ "$free_bytes" =~ ^[0-9]+$ && "$free_percent" =~ ^[0-9]+$ ]]; then
                CONDITION_ERROR=1
                CONDITION_DETAIL="filesystem path=${path} reason=unavailable"
                apply_condition_invert "$index" "$condition" "$raw_result"
                return
            fi
            raw_result=0
            value_type="$(yaml_read ".services[$index].only_if[$condition].min_free_gb | type")"
            if [[ "$value_type" != "!!null" ]]; then
                min_free_gb="$(yaml_read ".services[$index].only_if[$condition].min_free_gb")"
                if ! awk -v bytes="$free_bytes" -v minimum="$min_free_gb" 'BEGIN { exit !(bytes >= minimum * 1024 * 1024 * 1024) }'; then
                    raw_result=1
                    CONDITION_DETAIL="filesystem path=${path} min_free_gb=${min_free_gb} current_free_gb=$(awk -v bytes="$free_bytes" 'BEGIN { printf "%.2f", bytes / 1024 / 1024 / 1024 }')"
                fi
            fi
            value_type="$(yaml_read ".services[$index].only_if[$condition].min_free_percent | type")"
            if [[ "$value_type" != "!!null" ]] && (( raw_result == 0 )); then
                min_free_percent="$(yaml_read ".services[$index].only_if[$condition].min_free_percent")"
                if ! awk -v percent="$free_percent" -v minimum="$min_free_percent" 'BEGIN { exit !(percent >= minimum) }'; then
                    raw_result=1
                    CONDITION_DETAIL="filesystem path=${path} min_free_percent=${min_free_percent} current_free_percent=${free_percent}"
                fi
            fi
            [[ -n "$CONDITION_DETAIL" ]] || CONDITION_DETAIL="filesystem path=${path} current_free_percent=${free_percent}"
            ;;
        *)
            CONDITION_ERROR=1
            CONDITION_DETAIL="condition type=${type} reason=unsupported"
            ;;
    esac
    apply_condition_invert "$index" "$condition" "$raw_result"
}

evaluate_conditions() {
    local index="$1" service_name="$2" count condition
    count="$(yaml_read ".services[$index].only_if // [] | length")"
    (( count > 0 )) || return 0
    for ((condition = 0; condition < count; condition++)); do
        if evaluate_single_condition "$index" "$condition"; then
            continue
        fi
        if (( CONDITION_ERROR == 1 )); then
            log WARN "service=${service_name} only_if=error condition=\"$(sanitize_detail "$CONDITION_DETAIL")\" condition_index=$((condition + 1)) action=skipped"
        else
            log INFO "service=${service_name} only_if=false condition=\"$(sanitize_detail "$CONDITION_DETAIL")\" condition_index=$((condition + 1)) action=skipped"
        fi
        return 1
    done
    log INFO "service=${service_name} only_if=true conditions=${count}"
    return 0
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
    template="${template//\{\{consecutive_unavailable\}\}/$ESCALATION_CONSECUTIVE_UNAVAILABLE}"
    template="${template//\{\{escalation_count\}\}/$ESCALATION_COUNT}"
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
    local service detail check_type http_status check_exit action_status consecutive_unavailable escalation_count

    service="$CURRENT_SERVICE"
    detail="$(sanitize_detail "$CHECK_DETAIL")"
    check_type="$CURRENT_CHECK_TYPE"
    http_status="${CHECK_HTTP_STATUS:-n/a}"
    check_exit="${CHECK_EXIT_CODE:-n/a}"
    action_status="$CURRENT_ACTION_STATUS"
    consecutive_unavailable="$ESCALATION_CONSECUTIVE_UNAVAILABLE"
    escalation_count="$ESCALATION_COUNT"
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
    template="${template//\{\{consecutive_unavailable\}\}/$consecutive_unavailable}"
    template="${template//\{\{escalation_count\}\}/$escalation_count}"
    printf '%s' "$template"
}

webhook_template() {
    local webhook="$1" event="$2" fallback value value_type
    case "${webhook}:${event}" in
        telegram:failure) fallback=$'🚨 <b>{{service}}</b> DOWN\n\nType: {{check_type}}\nDetail: {{detail}}\nTime: {{timestamp}}' ;;
        telegram:recovery) fallback=$'✅ <b>{{service}}</b> UP\n\nRecovered at {{timestamp}}' ;;
        telegram:escalation) fallback=$'⚠️ <b>ESCALATION:</b> {{service}} has been unavailable for {{consecutive_unavailable}} consecutive checks.' ;;
        telegram:circuit_open) fallback='⚠️ <b>CIRCUIT BREAKER OPEN:</b> {{service}}' ;;
        telegram:circuit_close) fallback='✅ <b>CIRCUIT BREAKER CLOSED:</b> {{service}}' ;;
        discord:failure) fallback='{"content":"🚨 **{{service}}** is unavailable: {{detail}}"}' ;;
        discord:recovery) fallback='{"content":"✅ **{{service}}** recovered"}' ;;
        discord:escalation) fallback='{"content":"⚠️ **ESCALATION:** {{service}} has been unavailable for {{consecutive_unavailable}} consecutive checks."}' ;;
        discord:circuit_open) fallback='{"content":"⚠️ **CIRCUIT BREAKER OPEN:** {{service}}"}' ;;
        discord:circuit_close) fallback='{"content":"✅ **CIRCUIT BREAKER CLOSED:** {{service}}"}' ;;
        slack:failure) fallback='{"text":"🚨 {{service}} DOWN: {{detail}}"}' ;;
        slack:recovery) fallback='{"text":"✅ {{service}} recovered"}' ;;
        slack:escalation) fallback='{"text":"⚠️ ESCALATION: {{service}} has been unavailable for {{consecutive_unavailable}} consecutive checks."}' ;;
        slack:circuit_open) fallback='{"text":"⚠️ CIRCUIT BREAKER OPEN: {{service}}"}' ;;
        slack:circuit_close) fallback='{"text":"✅ CIRCUIT BREAKER CLOSED: {{service}}"}' ;;
        ntfy:failure) fallback='🚨 {{service}} unavailable: {{detail}}' ;;
        ntfy:recovery) fallback='✅ {{service}} recovered' ;;
        ntfy:escalation) fallback='⚠️ ESCALATION: {{service}} has been unavailable for {{consecutive_unavailable}} consecutive checks.' ;;
        ntfy:circuit_open) fallback='⚠️ CIRCUIT BREAKER OPEN: {{service}}' ;;
        ntfy:circuit_close) fallback='✅ CIRCUIT BREAKER CLOSED: {{service}}' ;;
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

send_email_message() {
    local event="$1" subject="$2" body="$3"
    local encoded_subject message_file recipient recipients_header="" output command_status recipient_index
    local -a curl_command

    (( EMAIL_ENABLED == 1 )) || return 0
    subject="${subject//$'\r'/ }"
    subject="${subject//$'\n'/ }"
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
    [[ -z "$EMAIL_USERNAME" ]] || curl_command+=(--user "${EMAIL_USERNAME}:${EMAIL_PASSWORD}")
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

send_email_notification() {
    local event="$1"
    local timestamp subject_template body_template subject body

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
        escalation)
            subject_template="[ESCALATION] ${EMAIL_FAILURE_SUBJECT}"
            body_template=$'⚠️ ESCALATION — service {{service}} has been unavailable for {{consecutive_unavailable}} consecutive checks.\n\n{{detail}}\n\n'
            body_template+="$EMAIL_FAILURE_BODY"
            ;;
        circuit_open)
            subject_template="[CIRCUIT BREAKER OPEN] ${CURRENT_SERVICE}"
            body_template='Circuit breaker opened after repeated failed remediation. Service: {{service}}. Detail: {{detail}}'
            ;;
        circuit_close)
            subject_template="[CIRCUIT BREAKER CLOSED] ${CURRENT_SERVICE}"
            body_template='Circuit breaker closed because the service is healthy again. Service: {{service}}.'
            ;;
        *)
            log ERROR "service=${CURRENT_SERVICE} result=email-failed reason=unknown-event event=${event}"
            return 1
            ;;
    esac

    timestamp="$(date '+%Y-%m-%d %H:%M:%S%z')"
    subject="$(render_email_template "$subject_template" "$event" "$timestamp")"
    body="$(render_email_template "$body_template" "$event" "$timestamp")"
    send_email_message "$event" "$subject" "$body"
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
        if (( PARALLEL_CHECK_MODE == 1 )) && [[ "$label" == check ]]; then
            printf 'service=%s action=%s-command index=%s command=%s\n' "$service_name" "$label" "$command_index" "$formatted"
        else
            log WARN "service=${service_name} action=${label}-command index=${command_index} command=${formatted}"
        fi

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
            if (( PARALLEL_CHECK_MODE == 1 )) && [[ "$label" == check ]]; then
                printf 'service=%s result=%s-command-failed index=%s exit=%s output=%s\n' "$service_name" "$label" "$command_index" "$command_status" "${output:-none}"
            else
                log ERROR "service=${service_name} result=${label}-command-failed index=${command_index} exit=${command_status} output=${output:-none}"
            fi
            return 1
        fi
        if (( PARALLEL_CHECK_MODE == 1 )) && [[ "$label" == check ]]; then
            printf 'service=%s result=%s-command-success index=%s output=%s\n' "$service_name" "$label" "$command_index" "${output:-none}"
        else
            log WARN "service=${service_name} result=${label}-command-success index=${command_index} output=${output:-none}"
        fi
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
        record_check_attempt "$CURRENT_SERVICE"
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

check_with_retries_parallel() {
    local index="$1" attempts retry_delay attempt
    attempts="$(yaml_read ".services[$index].check.attempts // ${DEFAULT_ATTEMPTS}")"
    retry_delay="$(yaml_read ".services[$index].check.retry_delay // ${DEFAULT_RETRY_DELAY}")"
    PARALLEL_ATTEMPTS_MADE=0
    for ((attempt = 1; attempt <= attempts; attempt++)); do
        PARALLEL_ATTEMPTS_MADE="$attempt"
        printf 'service=%s action=check attempt=%s/%s type=%s\n' "$CURRENT_SERVICE" "$attempt" "$attempts" "$CURRENT_CHECK_TYPE"
        if perform_single_check "$index"; then
            printf 'service=%s result=check-success attempt=%s/%s detail="%s"\n' "$CURRENT_SERVICE" "$attempt" "$attempts" "$(sanitize_detail "$CHECK_DETAIL")"
            return 0
        fi
        printf 'service=%s result=check-failed attempt=%s/%s detail="%s"\n' "$CURRENT_SERVICE" "$attempt" "$attempts" "$(sanitize_detail "$CHECK_DETAIL")"
        (( attempt < attempts && retry_delay > 0 )) && sleep "$retry_delay"
    done
    return 1
}

parallel_timeout_for_service() {
    local index="$1" type timeout_value
    type="$(yaml_read ".services[$index].check.timeout | type")"
    if [[ "$type" == "!!null" ]]; then printf '%s' "$PARALLEL_TIMEOUT"; else
        timeout_value="$(yaml_read ".services[$index].check.timeout")"; printf '%s' "$timeout_value"
    fi
}

write_parallel_result() {
    local result_file="$1" state="$2" detail="$3" http_status="$4" exit_code="$5" attempts="$6" temporary detail_encoded
    temporary="${result_file}.tmp.${BASHPID}"
    detail_encoded="$(printf '%s' "$detail" | base64 | tr -d '\n')"
    { printf 'state=%s\n' "$state"; printf 'detail_b64=%s\n' "$detail_encoded"; printf 'http_status=%s\n' "$http_status"; printf 'check_exit=%s\n' "$exit_code"; printf 'attempts=%s\n' "$attempts"; printf 'timestamp=%s\n' "$(date '+%s')"; } >"$temporary" && mv -f -- "$temporary" "$result_file"
}

_run_single_check_bg() {
    local index="$1" service_name="$2" result_file="$3" log_file="$4" timeout_value worker_pid timer_pid="" check_state=unavailable
    # Check helpers use TEMP_DIRECTORY for curl and command output. Shadow it
    # for this worker so concurrent checks never share temporary files.
    local TEMP_DIRECTORY="${TEMP_DIRECTORY}/${service_name}.${BASHPID}"
    (
        exec >"$log_file" 2>&1
        CURRENT_SERVICE="$service_name"; CURRENT_CHECK_TYPE="$(yaml_read ".services[$index].check.type")"
        CHECK_DETAIL=""; CHECK_HTTP_STATUS=""; CHECK_EXIT_CODE=""; PARALLEL_CHECK_MODE=1
        mkdir -p -- "$TEMP_DIRECTORY" || exit 1
        timeout_value="$(parallel_timeout_for_service "$index")"; worker_pid="$BASHPID"
        if (( timeout_value > 0 )); then
            ( sleep "$timeout_value"; write_parallel_result "$result_file" unavailable "check timed out (parallel check timeout)" "" 124 "$PARALLEL_ATTEMPTS_MADE"; kill -KILL "$worker_pid" 2>/dev/null || true ) &
            timer_pid=$!
        fi
        check_with_retries_parallel "$index" && check_state=healthy
        [[ -z "$timer_pid" ]] || { kill "$timer_pid" 2>/dev/null || true; wait "$timer_pid" 2>/dev/null || true; }
        write_parallel_result "$result_file" "$check_state" "$CHECK_DETAIL" "$CHECK_HTTP_STATUS" "$CHECK_EXIT_CODE" "$PARALLEL_ATTEMPTS_MADE"
        rm -rf -- "$TEMP_DIRECTORY"
    )
}

should_run_parallel() {
    local index="$1" value value_type
    (( PARALLEL_ENABLED == 1 )) || return 1
    value_type="$(yaml_read ".services[$index].parallel | type")"
    if [[ "$value_type" == "!!null" ]]; then
        value=true
    else
        value="$(yaml_read ".services[$index].parallel")"
    fi
    [[ "$value" == true ]]
}

collect_check_results() {
    local -n services_ref="$1"
    local service_name result_file log_file line key value detail_encoded
    for service_name in "${services_ref[@]}"; do
        result_file="${TEMP_DIRECTORY}/${service_name}.result"
        PRELOADED_CHECK_STATE["$service_name"]=unavailable; PRELOADED_CHECK_DETAIL["$service_name"]="check process did not write result"
        PRELOADED_CHECK_HTTP_STATUS["$service_name"]=""; PRELOADED_CHECK_EXIT_CODE["$service_name"]=""; PRELOADED_CHECK_ATTEMPTS["$service_name"]=0
        if [[ ! -r "$result_file" ]]; then log WARN "service=${service_name} phase=check mode=parallel result=missing temp_file_missing=true action=marked_unavailable"; continue; fi
        detail_encoded=""
        while IFS='=' read -r key value; do
            case "$key" in state) PRELOADED_CHECK_STATE["$service_name"]="$value" ;; detail_b64) detail_encoded="$value" ;; http_status) PRELOADED_CHECK_HTTP_STATUS["$service_name"]="$value" ;; check_exit) PRELOADED_CHECK_EXIT_CODE["$service_name"]="$value" ;; attempts) PRELOADED_CHECK_ATTEMPTS["$service_name"]="$value" ;; esac
        done <"$result_file"
        [[ -z "$detail_encoded" ]] || PRELOADED_CHECK_DETAIL["$service_name"]="$(printf '%s' "$detail_encoded" | base64 --decode 2>/dev/null || true)"
        [[ "${PRELOADED_CHECK_STATE[$service_name]}" == healthy || "${PRELOADED_CHECK_STATE[$service_name]}" == unavailable ]] || { PRELOADED_CHECK_STATE["$service_name"]=unavailable; PRELOADED_CHECK_DETAIL["$service_name"]="invalid parallel check result"; }
        log INFO "service=${service_name} phase=check mode=parallel result=${PRELOADED_CHECK_STATE[$service_name]} detail=\"$(sanitize_detail "${PRELOADED_CHECK_DETAIL[$service_name]}")\""
        log_file="${TEMP_DIRECTORY}/${service_name}.log"
        if [[ -r "$log_file" ]]; then
            while IFS= read -r line; do
                log INFO "service=${service_name} phase=check mode=parallel worker_log=\"$(sanitize_detail "$line")\""
            done <"$log_file"
        fi
        rm -f -- "$result_file" "$log_file"
    done
}

run_checks_parallel() {
    local -n services_ref="$1"
    local service_name index result_file log_file started_ms completed_ms failed=0
    started_ms="$(date '+%s%3N')"; log INFO "phase=check mode=parallel max_jobs=${PARALLEL_MAX_JOBS} services=${#services_ref[@]}"
    for service_name in "${services_ref[@]}"; do
        index="${SERVICE_INDEX[$service_name]}"
        while (( PARALLEL_MAX_JOBS > 0 && $(jobs -pr | wc -l) >= PARALLEL_MAX_JOBS )); do wait -n 2>/dev/null || true; done
        result_file="${TEMP_DIRECTORY}/${service_name}.result"; log_file="${TEMP_DIRECTORY}/${service_name}.log"
        _run_single_check_bg "$index" "$service_name" "$result_file" "$log_file" &
        log INFO "service=${service_name} phase=check mode=parallel pid=$!"
    done
    wait || true; collect_check_results "$1"
    for service_name in "${services_ref[@]}"; do [[ "${PRELOADED_CHECK_STATE[$service_name]}" == healthy ]] || ((failed++)); done
    completed_ms="$(date '+%s%3N')"; log INFO "phase=check mode=parallel completed=${#services_ref[@]} failed=${failed} duration_ms=$((completed_ms - started_ms))"
}

service_is_selected() {
    local service_name="$1"
    [[ -z "$ONLY_SERVICE" || "$service_name" == "$ONLY_SERVICE" ]] && return 0
    service_is_required_for "$ONLY_SERVICE" "$service_name"
}

use_preloaded_check_result() {
    local service_name="$1" attempts attempt
    [[ -n "${PRELOADED_CHECK_STATE[$service_name]+present}" ]] || return 1
    CHECK_DETAIL="${PRELOADED_CHECK_DETAIL[$service_name]}"
    CHECK_HTTP_STATUS="${PRELOADED_CHECK_HTTP_STATUS[$service_name]}"
    CHECK_EXIT_CODE="${PRELOADED_CHECK_EXIT_CODE[$service_name]}"
    attempts="${PRELOADED_CHECK_ATTEMPTS[$service_name]:-0}"
    [[ "$attempts" =~ ^[0-9]+$ ]] || attempts=0
    for ((attempt = 0; attempt < attempts; attempt++)); do record_check_attempt "$service_name"; done
    log INFO "service=${service_name} action=check result=${PRELOADED_CHECK_STATE[$service_name]} source=parallel detail=\"$(sanitize_detail "$CHECK_DETAIL")\""
    [[ "${PRELOADED_CHECK_STATE[$service_name]}" == healthy ]]
}

process_parallel_level() {
    local level="$1" service_name index enabled
    local -a checked_services=() level_services=() sequential_checks=() parallel_checks=()
    for service_name in "${SERVICE_ORDER[@]}"; do
        [[ "${SERVICE_LEVEL[$service_name]}" == "$level" ]] || continue; service_is_selected "$service_name" || continue
        level_services+=("$service_name"); index="${SERVICE_INDEX[$service_name]}"; enabled="$(yaml_read ".services[$index].enabled // true")"
        [[ "$enabled" == true ]] || continue
        required_dependency_is_unavailable "$service_name" >/dev/null && continue
        if ! evaluate_conditions "$index" "$service_name"; then
            CONDITION_SKIPPED["$service_name"]=1
            continue
        fi
        CONDITION_EVALUATED["$service_name"]=1
        checked_services+=("$service_name")
        should_run_parallel "$index" && parallel_checks+=("$service_name") || sequential_checks+=("$service_name")
    done
    (( ${#parallel_checks[@]} == 0 )) || run_checks_parallel parallel_checks
    for service_name in "${sequential_checks[@]}"; do index="${SERVICE_INDEX[$service_name]}"; _run_single_check_bg "$index" "$service_name" "${TEMP_DIRECTORY}/${service_name}.result" "${TEMP_DIRECTORY}/${service_name}.log"; done
    (( ${#sequential_checks[@]} == 0 )) || collect_check_results sequential_checks
    for service_name in "${level_services[@]}"; do index="${SERVICE_INDEX[$service_name]}"; process_service "$index"; RESOLVED_STATE["$service_name"]="$PROCESS_RESULT"; done
}

read_state() {
    local service_name="$1"
    local file="${STATE_DIRECTORY}/${service_name}.state" state=""
    if [[ -r "$file" ]]; then
        IFS= read -r state <"$file" || true
    fi
    case "$state" in healthy|unavailable|dependency_failed) printf '%s' "$state" ;; *) printf unknown ;; esac
}

write_state() {
    local service_name="$1" state="$2"
    local file temporary
    [[ "$(read_state "$service_name")" == "$state" ]] || FEDERATION_STATE_CHANGED=1
    file="${STATE_DIRECTORY}/${service_name}.state"
    temporary="${file}.tmp.$$"
    printf '%s\n' "$state" >"$temporary" || die "Cannot write state: ${temporary}"
    chmod 0640 "$temporary" 2>/dev/null || true
    mv -f -- "$temporary" "$file" || die "Cannot update state: ${file}"
}

format_federation_timestamp() {
    local epoch="$1"
    if ! [[ "$epoch" =~ ^[0-9]+$ ]] || (( 10#$epoch == 0 )); then
        printf ''
        return 0
    fi
    date -u -d "@${epoch}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf ''
}

federation_agent_overall_status() {
    local service_count index service_name state has_degraded=0
    service_count="$(yaml_read '.services | length')"
    for ((index = 0; index < service_count; index++)); do
        service_name="$(yaml_read ".services[$index].name")"
        state="$(read_state "$service_name")"
        [[ "$state" == unavailable ]] && { printf 'major_outage'; return 0; }
        [[ "$state" == dependency_failed || "$state" == unknown ]] && has_degraded=1
    done
    if (( has_degraded == 1 )); then
        printf 'degraded'
    else
        printf 'operational'
    fi
}

federation_agent_build_report() {
    local service_count index service_name check_type state last_check last_transition overall hostname_value
    service_count="$(yaml_read '.services | length')"
    overall="$(federation_agent_overall_status)"
    hostname_value="$(hostname 2>/dev/null || hostname -s)"
    printf '{\n  "node_id": "%s",\n  "timestamp": "%s",\n  "hostname": "%s",\n' \
        "$(escape_json "$FEDERATION_NODE_ID")" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(escape_json "$hostname_value")"
    printf '  "watchdog_version": "%s",\n  "overall_status": "%s",\n  "services": [\n' \
        "$(escape_json "$WATCHDOG_VERSION")" "$overall"
    for ((index = 0; index < service_count; index++)); do
        service_name="$(yaml_read ".services[$index].name")"
        check_type="$(yaml_read ".services[$index].check.type")"
        state="$(read_state "$service_name")"
        last_check="$(read_service_marker_number "$service_name" last-check 0)"
        last_transition="$(read_service_marker_number "$service_name" last-transition 0)"
        printf '    {"name":"%s","state":"%s","check_type":"%s","last_check":"%s","last_transition":"%s","detail":""}%s\n' \
            "$(escape_json "$service_name")" "$state" "$(escape_json "$check_type")" \
            "$(format_federation_timestamp "$last_check")" "$(format_federation_timestamp "$last_transition")" \
            "$([[ $index -lt $((service_count - 1)) ]] && printf ',')"
    done
    printf '  ]\n}\n'
}

federation_agent_should_report() {
    local service_count index service_name state overall marker previous=""
    (( FEDERATION_AGENT_HEARTBEAT == 1 )) && return 0
    service_count="$(yaml_read '.services | length')"
    for ((index = 0; index < service_count; index++)); do
        service_name="$(yaml_read ".services[$index].name")"
        state="$(read_state "$service_name")"
        [[ "$state" == unavailable || "$state" == dependency_failed ]] && return 0
    done
    marker="${STATE_DIRECTORY}/federation-last-report-overall"
    if [[ -r "$marker" ]]; then
        IFS= read -r previous <"$marker" || true
    fi
    overall="$(federation_agent_overall_status)"
    [[ -z "$previous" || "$previous" != "$overall" || "$FEDERATION_STATE_CHANGED" == 1 ]]
}

federation_agent_record_report() {
    local overall="$1" file temporary
    file="${STATE_DIRECTORY}/federation-last-report-overall"
    temporary="${file}.tmp.$$"
    printf '%s\n' "$overall" >"$temporary" || return 1
    chmod 0640 "$temporary" 2>/dev/null || true
    mv -f -- "$temporary" "$file"
}

federation_agent_send_report() {
    local report report_file response_file error_file http_status curl_status token="" result duration_start duration_end
    local overall bytes temporary
    local -a curl_command

    (( FEDERATION_AGENT_ENABLED == 1 )) || return 0
    if (( DRY_RUN == 1 )); then
        log INFO "federation=agent node=${FEDERATION_NODE_ID} result=skipped reason=dry_run"
        return 0
    fi
    if ! federation_agent_should_report; then
        log INFO "federation=agent node=${FEDERATION_NODE_ID} result=skipped reason=heartbeat_disabled all_healthy=true"
        return 0
    fi
    report="$(federation_agent_build_report)"
    overall="$(federation_agent_overall_status)"
    bytes="${#report}"
    duration_start="$(date '+%s%3N')"
    if [[ "$FEDERATION_AGENT_TRANSPORT" == file ]]; then
        if ! mkdir -p -- "$(dirname -- "$FEDERATION_AGENT_REPORT_PATH")" 2>/dev/null; then
            log ERROR "federation=agent node=${FEDERATION_NODE_ID} transport=file result=failed reason=directory path=${FEDERATION_AGENT_REPORT_PATH}"
            return 0
        fi
        temporary="${FEDERATION_AGENT_REPORT_PATH}.tmp.$$"
        if printf '%s\n' "$report" >"$temporary" && chmod 0640 "$temporary" 2>/dev/null && mv -f -- "$temporary" "$FEDERATION_AGENT_REPORT_PATH"; then
            federation_agent_record_report "$overall" || log WARN "federation=agent node=${FEDERATION_NODE_ID} result=marker-write-failed"
            log INFO "federation=agent node=${FEDERATION_NODE_ID} transport=file result=written path=${FEDERATION_AGENT_REPORT_PATH} bytes=${bytes}"
        else
            rm -f -- "$temporary"
            log ERROR "federation=agent node=${FEDERATION_NODE_ID} transport=file result=failed path=${FEDERATION_AGENT_REPORT_PATH}"
        fi
        return 0
    fi

    token="${!FEDERATION_AGENT_TOKEN_ENV:-}"
    if [[ -z "$token" ]]; then
        log ERROR "federation=agent node=${FEDERATION_NODE_ID} transport=http result=failed reason=missing-env:${FEDERATION_AGENT_TOKEN_ENV}"
        return 0
    fi
    report_file="${TEMP_DIRECTORY}/federation-report.json"
    response_file="${TEMP_DIRECTORY}/federation-response.txt"
    error_file="${TEMP_DIRECTORY}/federation-error.txt"
    printf '%s\n' "$report" >"$report_file"
    curl_command=(curl --silent --show-error --output "$response_file" --write-out '%{http_code}' --request POST
        --header 'Content-Type: application/json' --header "Authorization: Bearer ${token}"
        --connect-timeout "$FEDERATION_AGENT_TIMEOUT" --max-time "$FEDERATION_AGENT_TIMEOUT")
    http_status="$("${curl_command[@]}" --data-binary "@${report_file}" "$FEDERATION_AGENT_HUB_URL" 2>"$error_file")"
    curl_status=$?
    duration_end="$(date '+%s%3N')"
    if (( curl_status == 0 )) && [[ "$http_status" =~ ^2[0-9][0-9]$ ]]; then
        federation_agent_record_report "$overall" || log WARN "federation=agent node=${FEDERATION_NODE_ID} result=marker-write-failed"
        log INFO "federation=agent node=${FEDERATION_NODE_ID} transport=http result=sent bytes=${bytes} duration_ms=$((duration_end - duration_start)) status=${http_status}"
    else
        result=""
        [[ -s "$error_file" ]] && result="$(sanitize_detail "$(<"$error_file")")"
        [[ -n "$result" || ! -s "$response_file" ]] || result="$(sanitize_detail "$(<"$response_file")")"
        log ERROR "federation=agent node=${FEDERATION_NODE_ID} transport=http result=failed status=${http_status:-000} curl_exit=${curl_status} error=${result:-unknown}"
    fi
}

federation_hub_state_value() {
    local node_id="$1" field="$2" fallback="$3" value=""
    [[ -r "$FEDERATION_HUB_STATE_FILE" ]] || { printf '%s' "$fallback"; return 0; }
    value="$(yq eval -r ".agents.\"${node_id}\".${field} // \"\"" "$FEDERATION_HUB_STATE_FILE" 2>/dev/null)" || value=""
    [[ -n "$value" && "$value" != null ]] || value="$fallback"
    printf '%s' "$value"
}

federation_hub_render_template() {
    local template="$1" overall="$2" previous="$3" timestamp="$4" node_id="$5" age="$6"
    template="${template//\{\{overall_status\}\}/$overall}"
    template="${template//\{\{previous_status\}\}/$previous}"
    template="${template//\{\{timestamp\}\}/$timestamp}"
    template="${template//\{\{node_id\}\}/$node_id}"
    template="${template//\{\{age_seconds\}\}/$age}"
    template="${template//\{\{unhealthy_services\}\}/$FEDERATION_HUB_UNHEALTHY_SERVICES}"
    template="${template//\{\{offline_nodes\}\}/$FEDERATION_HUB_OFFLINE_NODES}"
    template="${template//\{\{#unhealthy_services\}\}/}"
    template="${template//\{\{/unhealthy_services\}\}/}"
    template="${template//\{\{#offline_nodes\}\}/}"
    template="${template//\{\{/offline_nodes\}\}/}"
    printf '%s' "$template"
}

federation_hub_notify() {
    local event="$1" overall="$2" previous="$3" node_id="${4:-}" age="${5:-0}"
    local subject_template body_template subject body timestamp webhook_event
    case "$event" in
        overall_failure)
            subject_template='[FEDERATION] Infrastructure status: {{overall_status}}'
            body_template=$'Overall status changed to {{overall_status}}.\n\nUnhealthy services:\n{{unhealthy_services}}\nOffline agents:\n{{offline_nodes}}'
            webhook_event=failure
            ;;
        overall_recovery)
            subject_template='[FEDERATION] Infrastructure recovered: {{overall_status}}'
            body_template='All services are operational. Previously: {{previous_status}}'
            webhook_event=recovery
            ;;
        agent_offline)
            subject_template='[FEDERATION] Agent {{node_id}} is offline'
            body_template='Agent {{node_id}} has not reported for {{age_seconds}} seconds.'
            webhook_event=failure
            ;;
        agent_online)
            subject_template='[FEDERATION] Agent {{node_id}} is online'
            body_template='Agent {{node_id}} is reporting again.'
            webhook_event=recovery
            ;;
        service_change)
            subject_template='[FEDERATION] Service state change on {{node_id}}'
            body_template=$'A service state changed on {{node_id}}.\n\nUnhealthy services:\n{{unhealthy_services}}'
            webhook_event=failure
            ;;
        *) return 1 ;;
    esac
    [[ "$(yaml_read ".federation.hub.templates.${event}.subject // \"\"")" == "" ]] || subject_template="$(yaml_read ".federation.hub.templates.${event}.subject")"
    [[ "$(yaml_read ".federation.hub.templates.${event}.body // \"\"")" == "" ]] || body_template="$(yaml_read ".federation.hub.templates.${event}.body")"
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    subject="$(federation_hub_render_template "$subject_template" "$overall" "$previous" "$timestamp" "$node_id" "$age")"
    body="$(federation_hub_render_template "$body_template" "$overall" "$previous" "$timestamp" "$node_id" "$age")"
    CURRENT_SERVICE="federation"; CURRENT_CHECK_TYPE="federation"; CURRENT_ACTION_STATUS="not-applicable"; CHECK_DETAIL="$body"
    send_email_message "$event" "$subject" "$body" || log ERROR "federation=hub result=email-failed event=${event}"
    send_webhook_notification "$webhook_event" || log ERROR "federation=hub result=webhook-failed event=${event}"
}

federation_hub_write_state() {
    local overall="$1" status_name="$2" seen_name="$3" fingerprint_name="$4"
    local -n status_ref="$status_name" seen_ref="$seen_name" fingerprint_ref="$fingerprint_name"
    local temporary node_id comma=""
    temporary="${FEDERATION_HUB_STATE_FILE}.tmp.$$"
    {
        printf '{\n  "last_run": "%s",\n  "last_overall_status": "%s",\n  "agents": {' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$overall"
        for node_id in "${!status_ref[@]}"; do
            printf '%s\n    "%s": {"last_seen":"%s","last_status":"%s","service_fingerprint":"%s"}' \
                "$comma" "$(escape_json "$node_id")" "$(escape_json "${seen_ref[$node_id]:-}")" \
                "$(escape_json "${status_ref[$node_id]}")" "$(escape_json "${fingerprint_ref[$node_id]:-}")"
            comma=,
        done
        printf '\n  }\n}\n'
    } >"$temporary" || { rm -f -- "$temporary"; return 1; }
    chmod 0640 "$temporary" 2>/dev/null || true
    mv -f -- "$temporary" "$FEDERATION_HUB_STATE_FILE"
}

federation_hub_generate_summary() {
    if [[ -z "$FEDERATION_HUB_UNHEALTHY_SERVICES" ]]; then
        FEDERATION_HUB_UNHEALTHY_SERVICES='- none'
    fi
    if [[ -z "$FEDERATION_HUB_OFFLINE_NODES" ]]; then
        FEDERATION_HUB_OFFLINE_NODES='- none'
    fi
}

# shellcheck disable=SC2034 # The maps below are consumed through namerefs by federation_hub_write_state.
federation_hub_process_reports() {
    local report_file node_id json_node timestamp timestamp_epoch now age service_count service_index service_name service_state last_transition
    local reports_processed=0 valid_reports=0 invalid_reports=0 fresh_reports=0 moved=0 deleted=0 previous_overall overall
    local expected_count expected_index expected_node previous_agent_status previous_fingerprint fingerprint stale_seen stale_epoch
    local has_degraded=0 has_unavailable=0 archive_target
    local -a valid_files=() expected_nodes=()
    local -A selected_file=() selected_epoch=() selected_timestamp=() file_node=() fresh_status=() fresh_fingerprint=()
    local -A agent_status=() agent_seen=() agent_fingerprint=()

    if ! mkdir -p -- "$FEDERATION_HUB_INCOMING_DIRECTORY" "$FEDERATION_HUB_ARCHIVE_DIRECTORY" 2>/dev/null; then
        log ERROR "federation=hub result=failed reason=directory"
        FEDERATION_HUB_OVERALL_STATUS=unknown
        return 0
    fi
    now="$(date '+%s')"
    for report_file in "$FEDERATION_HUB_INCOMING_DIRECTORY"/*.json; do
        [[ -f "$report_file" ]] || continue
        ((reports_processed++))
        node_id="${report_file##*/}"; node_id="${node_id%.json}"
        if ! [[ "$node_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || ! yq eval -e '.' "$report_file" >/dev/null 2>&1; then
            ((invalid_reports++)); log WARN "federation=hub file=${report_file} result=invalid"; continue
        fi
        json_node="$(yq eval -r '.node_id // ""' "$report_file" 2>/dev/null)"
        timestamp="$(yq eval -r '.timestamp // ""' "$report_file" 2>/dev/null)"
        if [[ "$json_node" != "$node_id" ]] || ! timestamp_epoch="$(date -u -d "$timestamp" '+%s' 2>/dev/null)" || ! [[ "$timestamp_epoch" =~ ^[0-9]+$ ]] || [[ "$(yq eval '.services | type' "$report_file" 2>/dev/null)" != '!!seq' ]]; then
            ((invalid_reports++)); log WARN "federation=hub node=${node_id} result=invalid"; continue
        fi
        ((valid_reports++)); valid_files+=("$report_file"); file_node["$report_file"]="$node_id"
        if [[ -z "${selected_epoch[$node_id]:-}" ]] || (( 10#$timestamp_epoch > 10#${selected_epoch[$node_id]} )); then
            selected_file["$node_id"]="$report_file"; selected_epoch["$node_id"]="$timestamp_epoch"; selected_timestamp["$node_id"]="$timestamp"
        fi
    done

    FEDERATION_HUB_UNHEALTHY_SERVICES=""; FEDERATION_HUB_OFFLINE_NODES=""
    for node_id in "${!selected_file[@]}"; do
        report_file="${selected_file[$node_id]}"; timestamp_epoch="${selected_epoch[$node_id]}"; timestamp="${selected_timestamp[$node_id]}"
        age=$((now - 10#$timestamp_epoch)); (( age < 0 )) && age=0
        if (( age > FEDERATION_HUB_MAX_REPORT_AGE )); then
            log WARN "federation=hub node=${node_id} result=offline age=${age}s max_age=${FEDERATION_HUB_MAX_REPORT_AGE}s"
            continue
        fi
        ((fresh_reports++)); service_count="$(yq eval '.services | length' "$report_file")"; fingerprint=""
        fresh_status["$node_id"]=operational
        for ((service_index = 0; service_index < service_count; service_index++)); do
            service_name="$(yq eval -r ".services[$service_index].name // \"unnamed-${service_index}\"" "$report_file")"
            service_state="$(yq eval -r ".services[$service_index].state // \"unknown\"" "$report_file")"
            last_transition="$(yq eval -r ".services[$service_index].last_transition // \"unknown\"" "$report_file")"
            case "$service_state" in healthy|unavailable|dependency_failed|unknown) ;; *) service_state=unknown ;; esac
            fingerprint+="${service_name}:${service_state};"
            if [[ "$service_state" == unavailable ]]; then
                fresh_status["$node_id"]=major_outage; has_unavailable=1
            elif [[ "$service_state" != healthy && "${fresh_status[$node_id]}" != major_outage ]]; then
                fresh_status["$node_id"]=degraded; has_degraded=1
            fi
            [[ "$service_state" == healthy ]] || FEDERATION_HUB_UNHEALTHY_SERVICES+="- [${node_id}] ${service_name}: ${service_state} (since ${last_transition})"$'\n'
        done
        fresh_fingerprint["$node_id"]="$fingerprint"; agent_status["$node_id"]="${fresh_status[$node_id]}"; agent_seen["$node_id"]="$timestamp"; agent_fingerprint["$node_id"]="$fingerprint"
        log INFO "federation=hub node=${node_id} result=online status=${fresh_status[$node_id]}"
    done

    expected_count="$(yaml_read '.federation.hub.expected_nodes // [] | length')"
    for ((expected_index = 0; expected_index < expected_count; expected_index++)); do expected_nodes+=("$(yaml_read ".federation.hub.expected_nodes[$expected_index]")"); done
    previous_overall=unknown
    [[ -r "$FEDERATION_HUB_STATE_FILE" ]] && previous_overall="$(yq eval -r '.last_overall_status // "unknown"' "$FEDERATION_HUB_STATE_FILE" 2>/dev/null || printf unknown)"
    for expected_node in "${expected_nodes[@]}"; do
        previous_agent_status="$(federation_hub_state_value "$expected_node" last_status unknown)"
        if [[ -n "${fresh_status[$expected_node]:-}" ]]; then
            if [[ "$previous_agent_status" == offline ]]; then
                log INFO "federation=hub node=${expected_node} result=online action=recovered"
                if [[ "$(yaml_read '.federation.hub.notify_on.agent_offline // true')" == true && "$DRY_RUN" == 0 ]]; then
                    federation_hub_notify agent_online "${fresh_status[$expected_node]}" "$previous_overall" "$expected_node" 0
                fi
            fi
            continue
        fi
        stale_seen="${selected_timestamp[$expected_node]:-$(federation_hub_state_value "$expected_node" last_seen unknown)}"
        stale_epoch="${selected_epoch[$expected_node]:-0}"
        if [[ "$stale_epoch" =~ ^[0-9]+$ ]] && (( 10#$stale_epoch > 0 )); then age=$((now - 10#$stale_epoch)); (( age < 0 )) && age=0; else age=$((FEDERATION_HUB_MAX_REPORT_AGE + 1)); fi
        agent_status["$expected_node"]=offline; agent_seen["$expected_node"]="$stale_seen"; agent_fingerprint["$expected_node"]=""
        FEDERATION_HUB_OFFLINE_NODES+="- ${expected_node} (last seen ${stale_seen})"$'\n'
        if [[ "$previous_agent_status" != offline ]]; then
            log WARN "federation=hub notify=agent_offline node=${expected_node} age=${age}s"
            if [[ "$(yaml_read '.federation.hub.notify_on.agent_offline // true')" == true && "$DRY_RUN" == 0 ]]; then
                federation_hub_notify agent_offline degraded "$previous_overall" "$expected_node" "$age"
            fi
        fi
    done

    if (( fresh_reports == 0 )); then overall=unknown
    elif (( has_unavailable == 1 )); then overall=major_outage
    elif (( has_degraded == 1 )); then overall=degraded
    else overall=operational; fi
    # Offline expected agents also make the infrastructure degraded, even when
    # every fresh report is healthy.
    [[ -z "$FEDERATION_HUB_OFFLINE_NODES" || "$overall" != operational ]] || overall=degraded
    FEDERATION_HUB_OVERALL_STATUS="$overall"
    federation_hub_generate_summary
    if [[ "$previous_overall" != "$overall" ]]; then
        if [[ "$(yaml_read '.federation.hub.notify_on.overall_change // true')" == true && "$DRY_RUN" == 0 && ! ( "$previous_overall" == unknown && "$overall" == operational ) ]]; then
            if [[ "$overall" == operational ]]; then federation_hub_notify overall_recovery "$overall" "$previous_overall"; else federation_hub_notify overall_failure "$overall" "$previous_overall"; fi
            log INFO "federation=hub overall_status=${overall} previous=${previous_overall} action=notify"
        else
            log INFO "federation=hub overall_status=${overall} previous=${previous_overall} action=record"
        fi
    fi
    if [[ "$(yaml_read '.federation.hub.notify_on.any_service_change // false')" == true && "$DRY_RUN" == 0 ]]; then
        for node_id in "${!fresh_fingerprint[@]}"; do
            previous_fingerprint="$(federation_hub_state_value "$node_id" service_fingerprint "")"
            if [[ -n "$previous_fingerprint" && "$previous_fingerprint" != "${fresh_fingerprint[$node_id]}" && "$previous_overall" == "$overall" ]]; then
                log INFO "federation=hub notify=service_change node=${node_id}"
                federation_hub_notify service_change "$overall" "$previous_overall" "$node_id"
            fi
        done
    fi
    if (( DRY_RUN == 0 )); then
        federation_hub_write_state "$overall" agent_status agent_seen agent_fingerprint || log ERROR "federation=hub result=state-write-failed"
        for report_file in "${valid_files[@]}"; do
            node_id="${file_node[$report_file]}"; timestamp="$(yq eval -r '.timestamp' "$report_file")"
            archive_target="${FEDERATION_HUB_ARCHIVE_DIRECTORY}/${node_id}_${timestamp}.json"
            [[ ! -e "$archive_target" ]] || archive_target="${FEDERATION_HUB_ARCHIVE_DIRECTORY}/${node_id}_${timestamp}.$$.json"
            if mv -f -- "$report_file" "$archive_target"; then ((moved++)); else log ERROR "federation=hub archive=failed file=${report_file}"; fi
        done
        if (( FEDERATION_HUB_ARCHIVE_RETENTION_DAYS > 0 )); then
            deleted="$(find "$FEDERATION_HUB_ARCHIVE_DIRECTORY" -type f -name '*.json' -mtime "+${FEDERATION_HUB_ARCHIVE_RETENTION_DAYS}" -print 2>/dev/null | awk 'END { print NR }')"
            find "$FEDERATION_HUB_ARCHIVE_DIRECTORY" -type f -name '*.json' -mtime "+${FEDERATION_HUB_ARCHIVE_RETENTION_DAYS}" -delete 2>/dev/null || log ERROR "federation=hub archive=retention-failed"
        fi
    fi
    log INFO "federation=hub reports_processed=${reports_processed} valid=${valid_reports} invalid=${invalid_reports}"
    log INFO "federation=hub archive=done moved=${moved} deleted_old=${deleted}"
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
    increment_service_marker_number "$service_name" remediations-total
}

maintenance_marker_file() {
    local service_name="$1" marker="$2"
    printf '%s/%s.%s' "$STATE_DIRECTORY" "$service_name" "$marker"
}

read_service_marker_number() {
    local service_name="$1" marker="$2" default_value="$3" file value=""
    file="$(maintenance_marker_file "$service_name" "$marker")"
    if [[ -r "$file" ]]; then
        IFS= read -r value <"$file" || true
    fi
    [[ "$value" =~ ^[0-9]+$ ]] || value="$default_value"
    printf '%s' "$value"
}

write_service_marker_number() {
    local service_name="$1" marker="$2" value="$3" file temporary
    file="$(maintenance_marker_file "$service_name" "$marker")"
    temporary="${file}.tmp.$$"
    printf '%s\n' "$value" >"$temporary" || die "Cannot write service state: ${temporary}"
    chmod 0640 "$temporary" 2>/dev/null || true
    mv -f -- "$temporary" "$file" || die "Cannot update service state: ${file}"
}

read_service_marker_string() {
    local service_name="$1" marker="$2" default_value="$3" file value=""
    file="$(maintenance_marker_file "$service_name" "$marker")"
    if [[ -r "$file" ]]; then
        IFS= read -r value <"$file" || true
    fi
    [[ -n "$value" ]] || value="$default_value"
    printf '%s' "$value"
}

write_service_marker_string() {
    local service_name="$1" marker="$2" value="$3" file temporary
    file="$(maintenance_marker_file "$service_name" "$marker")"
    temporary="${file}.tmp.$$"
    printf '%s\n' "$value" >"$temporary" || die "Cannot write service state: ${temporary}"
    chmod 0640 "$temporary" 2>/dev/null || true
    mv -f -- "$temporary" "$file" || die "Cannot update service state: ${file}"
}

send_circuit_breaker_notification() {
    local index="$1" service_name="$2" event="$3" notify hook_expression
    notify="$(yaml_read ".services[$index].circuit_breaker.notify // true")"
    if [[ "$notify" == true ]]; then
        send_email_notification "circuit_${event}" || log ERROR "service=${service_name} result=circuit-email-failed event=${event}"
        send_webhook_notification "circuit_${event}" || log ERROR "service=${service_name} result=circuit-webhook-failed event=${event}"
    fi
    hook_expression=".services[$index].circuit_breaker.hooks.on_${event}"
    run_configured_sequence "$hook_expression" "circuit-${event}" "$service_name" ||
        log ERROR "service=${service_name} result=circuit-hook-failed event=${event}"
    log WARN "service=${service_name} event=circuit_breaker_${event} notify=${notify}"
}

should_run_actions_with_circuit_breaker() {
    local index="$1" service_name="$2" circuit_state last_open open_duration now remaining
    [[ "$(yaml_read ".services[$index].circuit_breaker.enabled // false")" == true ]] || return 0
    circuit_state="$(read_service_marker_string "$service_name" circuit-state closed)"
    case "$circuit_state" in
        closed) return 0 ;;
        open)
            last_open="$(read_service_marker_number "$service_name" last-circuit-open 0)"
            open_duration="$(yaml_read ".services[$index].circuit_breaker.open_duration")"
            now="$(date '+%s')"
            if (( 10#$last_open > 0 && now - 10#$last_open >= 10#$open_duration )); then
                write_service_marker_string "$service_name" circuit-state half_open
                write_service_marker_number "$service_name" last-half-open-attempt "$now"
                log WARN "service=${service_name} circuit_state=open action=half_open reason=open_duration_expired"
                return 0
            fi
            remaining=$((10#$open_duration - (now - 10#$last_open)))
            log INFO "service=${service_name} circuit_state=open last_open=${last_open} remaining=${remaining} action=skipped reason=circuit_breaker"
            return 1
            ;;
        half_open) return 0 ;;
        *) write_service_marker_string "$service_name" circuit-state closed; return 0 ;;
    esac
}

record_circuit_action_result() {
    local index="$1" service_name="$2" success="$3" circuit_state failures threshold now
    [[ "$(yaml_read ".services[$index].circuit_breaker.enabled // false")" == true ]] || return 0
    circuit_state="$(read_service_marker_string "$service_name" circuit-state closed)"
    if [[ "$success" == true ]]; then
        write_service_marker_string "$service_name" circuit-state closed
        write_service_marker_number "$service_name" circuit-failure-count 0
        rm -f -- "$(maintenance_marker_file "$service_name" last-circuit-open)"
        if [[ "$circuit_state" == open || "$circuit_state" == half_open ]]; then
            log INFO "service=${service_name} circuit_state=${circuit_state} action=verify result=success next_state=closed"
            send_circuit_breaker_notification "$index" "$service_name" close
        fi
        return 0
    fi
    now="$(date '+%s')"
    if [[ "$circuit_state" == half_open ]]; then
        write_service_marker_string "$service_name" circuit-state open
        write_service_marker_number "$service_name" last-circuit-open "$now"
        log WARN "service=${service_name} circuit_state=half_open action=verify result=failed next_state=open"
        send_circuit_breaker_notification "$index" "$service_name" open
        return 0
    fi
    failures="$(read_service_marker_number "$service_name" circuit-failure-count 0)"
    failures=$((10#$failures + 1))
    write_service_marker_number "$service_name" circuit-failure-count "$failures"
    threshold="$(yaml_read ".services[$index].circuit_breaker.failure_threshold")"
    log WARN "service=${service_name} circuit_state=closed circuit_failure_count=${failures} action=remediation result=failed"
    if (( failures >= 10#$threshold )); then
        write_service_marker_string "$service_name" circuit-state open
        write_service_marker_number "$service_name" last-circuit-open "$now"
        log WARN "service=${service_name} circuit_state=closed circuit_failure_count=${failures} threshold=${threshold} action=trip reason=failure_threshold_reached"
        send_circuit_breaker_notification "$index" "$service_name" open
    fi
}

increment_service_marker_number() {
    local service_name="$1" marker="$2" current
    (( DRY_RUN == 0 )) || return 0
    current="$(read_service_marker_number "$service_name" "$marker" 0)"
    write_service_marker_number "$service_name" "$marker" "$((10#$current + 1))"
}

record_check_attempt() {
    local service_name="$1"
    (( DRY_RUN == 0 )) || return 0
    increment_service_marker_number "$service_name" checks-total
    write_service_marker_number "$service_name" last-check "$(date '+%s')"
}

record_state_transition_timestamp() {
    local service_name="$1"
    (( DRY_RUN == 0 )) || return 0
    write_service_marker_number "$service_name" last-transition "$(date '+%s')"
}

escape_prometheus_label_value() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    printf '%s' "$value"
}

sanitize_prometheus_metric_name() {
    local value="$1"
    value="${value//[^A-Za-z0-9_:]/_}"
    [[ "$value" =~ ^[A-Za-z_:] ]] || value="_${value}"
    printf '%s' "$value"
}

prometheus_labels() {
    local service_name="$1" check_type="$2" count index key value
    printf 'service="%s",check_type="%s"' "$(escape_prometheus_label_value "$service_name")" "$(escape_prometheus_label_value "$check_type")"
    count="$(yaml_read '.metrics.static_labels // {} | length')"
    for ((index = 0; index < count; index++)); do
        key="$(yaml_read ".metrics.static_labels | to_entries[$index].key")"
        value="$(yaml_read ".metrics.static_labels | to_entries[$index].value")"
        printf ',%s="%s"' "$key" "$(escape_prometheus_label_value "$value")"
    done
}

write_prometheus_metrics() {
    local target temporary service_count index service_name check_type state state_value now
    local last_check last_transition failures checks remediations outage labels metric_prefix
    (( METRICS_ENABLED == 1 )) || return 0
    target="${METRICS_DIRECTORY}/${METRICS_FILENAME}"
    if [[ ! -d "$METRICS_DIRECTORY" ]]; then
        if ! mkdir -p -- "$METRICS_DIRECTORY" 2>/dev/null || ! chmod 0755 "$METRICS_DIRECTORY" 2>/dev/null; then
            log ERROR "result=metrics-failed file=${target} reason=directory-not-writable"
            return 0
        fi
    fi
    if [[ ! -w "$METRICS_DIRECTORY" ]]; then
        log ERROR "result=metrics-failed file=${target} reason=directory-not-writable"
        return 0
    fi
    temporary="$(mktemp "${METRICS_DIRECTORY}/.${METRICS_FILENAME}.XXXXXX" 2>/dev/null)" || {
        log ERROR "result=metrics-failed file=${target} reason=temporary-file"
        return 0
    }
    metric_prefix="$(sanitize_prometheus_metric_name "$METRICS_PREFIX")"
    now="$(date '+%s')"
    service_count="$(yaml_read '.services | length')"
    {
        printf '# HELP %s_service_state Service availability state (0=healthy, 1=unavailable, 2=unknown)\n' "$metric_prefix"
        printf '# TYPE %s_service_state gauge\n' "$metric_prefix"
        printf '# HELP %s_service_last_check_timestamp Unix timestamp of the last check attempt\n' "$metric_prefix"
        printf '# TYPE %s_service_last_check_timestamp gauge\n' "$metric_prefix"
        printf '# HELP %s_service_last_transition_timestamp Unix timestamp of the last state transition\n' "$metric_prefix"
        printf '# TYPE %s_service_last_transition_timestamp gauge\n' "$metric_prefix"
        printf '# HELP %s_service_consecutive_failures Total consecutive unavailable checks since last healthy state\n' "$metric_prefix"
        printf '# TYPE %s_service_consecutive_failures gauge\n' "$metric_prefix"
        printf '# HELP %s_service_checks_total Total number of check attempts performed\n' "$metric_prefix"
        printf '# TYPE %s_service_checks_total counter\n' "$metric_prefix"
        printf '# HELP %s_service_remediations_total Total number of remediation attempts performed\n' "$metric_prefix"
        printf '# TYPE %s_service_remediations_total counter\n' "$metric_prefix"
        printf '# HELP %s_service_current_outage_duration_seconds Duration of the current outage in seconds\n' "$metric_prefix"
        printf '# TYPE %s_service_current_outage_duration_seconds gauge\n' "$metric_prefix"
        for ((index = 0; index < service_count; index++)); do
            service_name="$(yaml_read ".services[$index].name")"
            check_type="$(yaml_read ".services[$index].check.type")"
            labels="$(prometheus_labels "$service_name" "$check_type")"
            state="$(read_state "$service_name")"
            case "$state" in healthy) state_value=0 ;; unavailable|dependency_failed) state_value=1 ;; *) state_value=2 ;; esac
            last_check="$(read_service_marker_number "$service_name" last-check 0)"
            last_transition="$(read_service_marker_number "$service_name" last-transition 0)"
            failures="$(read_service_marker_number "$service_name" unavailable-count 0)"
            checks="$(read_service_marker_number "$service_name" checks-total 0)"
            remediations="$(read_service_marker_number "$service_name" remediations-total 0)"
            outage=0
            if [[ "$state" == unavailable && "$last_transition" != 0 ]]; then
                outage=$((now - 10#$last_transition))
            fi
            printf '%s_service_state{%s} %s\n' "$metric_prefix" "$labels" "$state_value"
            printf '%s_service_last_check_timestamp{%s} %s\n' "$metric_prefix" "$labels" "$last_check"
            printf '%s_service_last_transition_timestamp{%s} %s\n' "$metric_prefix" "$labels" "$last_transition"
            printf '%s_service_consecutive_failures{%s} %s\n' "$metric_prefix" "$labels" "$failures"
            printf '%s_service_checks_total{%s} %s\n' "$metric_prefix" "$labels" "$checks"
            printf '%s_service_remediations_total{%s} %s\n' "$metric_prefix" "$labels" "$remediations"
            printf '%s_service_current_outage_duration_seconds{%s} %s\n' "$metric_prefix" "$labels" "$outage"
        done
    } >"$temporary" || { rm -f -- "$temporary"; log ERROR "result=metrics-failed file=${target} reason=write"; return 0; }
    chmod 0644 "$temporary" 2>/dev/null || true
    if mv -f -- "$temporary" "$target"; then
        log INFO "result=metrics-written file=${target} services=${service_count} metrics=7"
    else
        rm -f -- "$temporary"
        log ERROR "result=metrics-failed file=${target} reason=rename"
    fi
}

escape_status_html() {
    local value="$1"
    value="${value//&/\&amp;}"; value="${value//</\&lt;}"; value="${value//>/\&gt;}"; value="${value//\"/\&quot;}"
    printf '%s' "$value"
}

format_status_timestamp() {
    local timestamp="$1"
    [[ "$timestamp" =~ ^[0-9]+$ && "$timestamp" != 0 ]] || { printf '%s' 'Never'; return; }
    date -d "@${timestamp}" '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || printf '%s' 'Unknown'
}

status_page_overall_status() {
    local service_count index state degraded=0
    service_count="$(yaml_read '.services | length')"
    for ((index = 0; index < service_count; index++)); do
        state="$(read_state "$(yaml_read ".services[$index].name")")"
        [[ "$state" == unavailable ]] && { printf '%s' major_outage; return; }
        [[ "$state" == dependency_failed || "$state" == unknown ]] && degraded=1
    done
    (( degraded == 1 )) && printf '%s' degraded || printf '%s' operational
}

status_page_service_card() {
    local service_name="$1" check_type="$2" state="$3" last_check="$4" last_transition="$5" label class
    case "$state" in
        healthy) label='Operational'; class='healthy' ;;
        unavailable) label='Down'; class='down' ;;
        dependency_failed) label='Dependency Failed'; class='warning' ;;
        *) label='Unknown'; class='warning' ;;
    esac
    printf '<article class="service"><div><strong>%s</strong><small>%s · last check: %s · changed: %s</small></div><span class="status %s">● %s</span></article>\n' \
        "$(escape_status_html "$service_name")" "$(escape_status_html "$check_type")" \
        "$(escape_status_html "$(format_status_timestamp "$last_check")")" \
        "$(escape_status_html "$(format_status_timestamp "$last_transition")")" "$class" "$label"
}

generate_status_page() {
    local target html_tmp json_tmp service_count index service_name check_type state last_check last_transition
    local title description logo footer refresh primary danger warning bg card text_color muted overall overall_label overall_class generated
    (( STATUS_PAGE_ENABLED == 1 )) || return 0
    target="${STATUS_PAGE_DIRECTORY}/${STATUS_PAGE_HTML_FILENAME}"
    if [[ ! -d "$STATUS_PAGE_DIRECTORY" ]] && ! mkdir -p -- "$STATUS_PAGE_DIRECTORY" 2>/dev/null; then
        log ERROR "result=status-page-failed file=${target} reason=directory-not-writable"; return 0
    fi
    [[ -w "$STATUS_PAGE_DIRECTORY" ]] || { log ERROR "result=status-page-failed file=${target} reason=directory-not-writable"; return 0; }
    html_tmp="$(mktemp "${STATUS_PAGE_DIRECTORY}/.${STATUS_PAGE_HTML_FILENAME}.XXXXXX" 2>/dev/null)" || { log ERROR "result=status-page-failed file=${target} reason=temporary-file"; return 0; }
    title="$(yaml_read '.status_page.title // "Service Status"')"; description="$(yaml_read '.status_page.description // "Current availability of monitored services"')"
    logo="$(yaml_read '.status_page.logo_url // ""')"; footer="$(yaml_read '.status_page.footer // "Powered by Watchdog"')"; refresh="$(yaml_read '.status_page.auto_refresh // 0')"
    primary="$(yaml_read '.status_page.theme.primary // "2563eb"')"; danger="$(yaml_read '.status_page.theme.danger // "dc2626"')"; warning="$(yaml_read '.status_page.theme.warning // "f59e0b"')"; bg="$(yaml_read '.status_page.theme.bg // "f8fafc"')"; card="$(yaml_read '.status_page.theme.card // "ffffff"')"; text_color="$(yaml_read '.status_page.theme.text // "1e293b"')"; muted="$(yaml_read '.status_page.theme.muted // "64748b"')"
    overall="$(status_page_overall_status)"; generated="$(date '+%Y-%m-%d %H:%M:%S %z')"; service_count="$(yaml_read '.services | length')"
    case "$overall" in operational) overall_label='All Systems Operational'; overall_class='healthy' ;; major_outage) overall_label='Major Outage'; overall_class='down' ;; *) overall_label='Partial Outage'; overall_class='warning' ;; esac
    {
        printf '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">\n'
        (( refresh > 0 )) && printf '<meta http-equiv="refresh" content="%s">\n' "$refresh"
        printf '<title>%s</title><style>:root{--p:#%s;--d:#%s;--w:#%s;--bg:#%s;--card:#%s;--text:#%s;--muted:#%s}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:16px -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}.wrap{max-width:850px;margin:auto;padding:32px 18px}header{text-align:center;margin-bottom:26px}h1{margin:8px 0}p,small,footer{color:var(--muted)}.overall,.service{background:var(--card);border-radius:12px;padding:16px;margin:12px 0;box-shadow:0 1px 3px #0001}.overall{text-align:center;font-weight:700}.service{display:flex;align-items:center;justify-content:space-between;gap:16px}.service small{display:block;margin-top:5px}.status{white-space:nowrap}.healthy{color:var(--p)}.down{color:var(--d)}.warning{color:var(--w)}footer{text-align:center;margin-top:28px;font-size:13px}@media(max-width:550px){.service{align-items:flex-start;flex-direction:column;gap:7px}}</style></head><body><main class="wrap"><header>' "$(escape_status_html "$title")" "$primary" "$danger" "$warning" "$bg" "$card" "$text_color" "$muted"
        [[ -z "$logo" ]] || printf '<img src="%s" alt="" style="max-height:56px">' "$(escape_status_html "$logo")"
        printf '<h1>%s</h1><p>%s</p></header><div class="overall %s">%s</div><section><h2>Services</h2>\n' "$(escape_status_html "$title")" "$(escape_status_html "$description")" "$overall_class" "$overall_label"
        for ((index = 0; index < service_count; index++)); do
            service_name="$(yaml_read ".services[$index].name")"; check_type="$(yaml_read ".services[$index].check.type")"; state="$(read_state "$service_name")"
            last_check="$(read_service_marker_number "$service_name" last-check 0)"; last_transition="$(read_service_marker_number "$service_name" last-transition 0)"
            status_page_service_card "$service_name" "$check_type" "$state" "$last_check" "$last_transition"
        done
        printf '</section><footer>%s<br>Generated by Watchdog at %s</footer></main></body></html>\n' "$(escape_status_html "$footer")" "$generated"
    } >"$html_tmp" || { rm -f -- "$html_tmp"; log ERROR "result=status-page-failed file=${target} reason=write"; return 0; }
    chmod 0644 "$html_tmp" 2>/dev/null || true; mv -f -- "$html_tmp" "$target" || { rm -f -- "$html_tmp"; log ERROR "result=status-page-failed file=${target} reason=rename"; return 0; }
    if [[ -n "$STATUS_PAGE_JSON_FILENAME" ]]; then
        json_tmp="$(mktemp "${STATUS_PAGE_DIRECTORY}/.${STATUS_PAGE_JSON_FILENAME}.XXXXXX" 2>/dev/null)" || return 0
        { printf '{\n  "generated_at": "%s",\n  "overall_status": "%s",\n  "services": [\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$overall"
          for ((index = 0; index < service_count; index++)); do service_name="$(yaml_read ".services[$index].name")"; check_type="$(yaml_read ".services[$index].check.type")"; state="$(read_state "$service_name")"; last_check="$(read_service_marker_number "$service_name" last-check 0)"; last_transition="$(read_service_marker_number "$service_name" last-transition 0)"; printf '    {"name":"%s","status":"%s","check_type":"%s","last_check":"%s","last_transition":"%s"}%s\n' "$(escape_json "$service_name")" "$state" "$check_type" "$(format_status_timestamp "$last_check")" "$(format_status_timestamp "$last_transition")" "$([[ $index -lt $((service_count - 1)) ]] && printf ',' )"; done
          printf '  ]\n}\n'; } >"$json_tmp" && { chmod 0644 "$json_tmp" 2>/dev/null || true; mv -f -- "$json_tmp" "${STATUS_PAGE_DIRECTORY}/${STATUS_PAGE_JSON_FILENAME}"; }
    fi
    log INFO "result=status-page-written file=${target} services=${service_count} overall=${overall}"
}

increment_unavailable_counter() {
    local service_name="$1" current
    (( DRY_RUN == 0 )) || return 0
    current="$(read_service_marker_number "$service_name" unavailable-count 0)"
    ESCALATION_CONSECUTIVE_UNAVAILABLE=$((10#$current + 1))
    write_service_marker_number "$service_name" unavailable-count "$ESCALATION_CONSECUTIVE_UNAVAILABLE"
    ESCALATION_COUNT="$(read_service_marker_number "$service_name" escalation-count 0)"
    log WARN "service=${service_name} state=unavailable consecutive_unavailable=${ESCALATION_CONSECUTIVE_UNAVAILABLE}"
}

reset_unavailable_counter() {
    local service_name="$1" current last_file
    (( DRY_RUN == 0 )) || return 0
    current="$(read_service_marker_number "$service_name" unavailable-count 0)"
    ESCALATION_CONSECUTIVE_UNAVAILABLE=0
    ESCALATION_COUNT=0
    write_service_marker_number "$service_name" unavailable-count 0
    write_service_marker_number "$service_name" escalation-count 0
    last_file="$(maintenance_marker_file "$service_name" last-escalation)"
    rm -f -- "$last_file"
    if (( 10#$current > 0 )); then
        log INFO "service=${service_name} state=healthy consecutive_unavailable=0 action=reset"
    fi
}

should_escalate() {
    local index="$1" service_name="$2" threshold cooldown cooldown_value last_escalation now remaining
    [[ "$(yaml_read ".services[$index].escalation.enabled // false")" == true ]] || return 1
    threshold="$(yaml_read ".services[$index].escalation.after_consecutive_unavailable")"
    (( ESCALATION_CONSECUTIVE_UNAVAILABLE >= 10#$threshold )) || return 1
    cooldown="$(yaml_read ".services[$index].escalation.cooldown // 0")"
    cooldown_value=$((10#$cooldown))
    last_escalation="$(read_service_marker_number "$service_name" last-escalation 0)"
    (( cooldown_value == 0 || 10#$last_escalation == 0 )) && return 0
    now="$(date '+%s')"
    if (( now - 10#$last_escalation >= cooldown_value )); then
        return 0
    fi
    remaining=$((cooldown_value - (now - 10#$last_escalation)))
    log INFO "service=${service_name} event=escalation action=skipped reason=cooldown active=true remaining=${remaining}"
    return 1
}

run_escalation() {
    local index="$1" service_name="$2" cooldown notify last_escalation current_count
    (( DRY_RUN == 0 )) || return 0
    if (( MAINTENANCE_ACTIVE == 1 )); then
        log INFO "service=${service_name} event=escalation action=skipped reason=maintenance-window"
        return 0
    fi
    should_escalate "$index" "$service_name" || return 0
    cooldown="$(yaml_read ".services[$index].escalation.cooldown // 0")"
    current_count="$(read_service_marker_number "$service_name" escalation-count 0)"
    ESCALATION_COUNT=$((10#$current_count + 1))
    log WARN "service=${service_name} event=escalation consecutive_unavailable=${ESCALATION_CONSECUTIVE_UNAVAILABLE} cooldown=${cooldown} action=triggered"
    if ! run_configured_sequence ".services[$index].escalation.actions.commands" escalation "$service_name"; then
        log ERROR "service=${service_name} event=escalation action=commands-failed"
    fi
    notify="$(yaml_read ".services[$index].escalation.notify // true")"
    if [[ "$notify" == true ]]; then
        send_email_notification escalation || log ERROR "service=${service_name} result=escalation-email-failed"
        send_webhook_notification escalation || log ERROR "service=${service_name} result=escalation-webhook-failed"
    fi
    if ! run_configured_sequence ".services[$index].escalation.hooks.on_escalation" escalation "$service_name"; then
        log ERROR "service=${service_name} event=escalation action=hook-failed"
    fi
    last_escalation="$(date '+%s')"
    write_service_marker_number "$service_name" escalation-count "$ESCALATION_COUNT"
    write_service_marker_number "$service_name" last-escalation "$last_escalation"
    log WARN "service=${service_name} event=escalation consecutive_unavailable=${ESCALATION_CONSECUTIVE_UNAVAILABLE} action=executed"
}

is_maintenance_window() {
    local service_name="$1" service_count index name timezone day now days time start end window_count window
    local matched_day normalized_day

    MAINTENANCE_WINDOW_NAME=""
    service_count="$(yaml_read '.services | length')"
    for ((index = 0; index < service_count; index++)); do
        name="$(yaml_read ".services[$index].name")"
        [[ "$name" == "$service_name" ]] && break
    done
    (( index < service_count )) || return 1
    window_count="$(yaml_read ".services[$index].maintenance.windows // [] | length")"
    (( window_count > 0 )) || return 1
    timezone="$(yaml_read ".services[$index].maintenance.timezone // \"\"")"
    if [[ -n "$timezone" ]]; then
        day="$(TZ="$timezone" LC_ALL=C date '+%a')"
        now="$(TZ="$timezone" date '+%H:%M')"
    else
        day="$(LC_ALL=C date '+%a')"
        now="$(date '+%H:%M')"
    fi
    day="${day,,}"
    for ((window = 0; window < window_count; window++)); do
        days="$(yaml_read ".services[$index].maintenance.windows[$window].days")"
        time="$(yaml_read ".services[$index].maintenance.windows[$window].time")"
        matched_day=0
        if [[ "$days" == "*" ]]; then
            matched_day=1
        else
            IFS=',' read -r -a maintenance_days <<<"$days"
            for normalized_day in "${maintenance_days[@]}"; do
                [[ "${normalized_day,,}" == "$day" ]] && matched_day=1
            done
        fi
        start="${time%-*}"; end="${time#*-}"
        if (( matched_day == 1 )) && [[ "$now" > "$start" || "$now" == "$start" ]] && [[ "$now" < "$end" ]]; then
            MAINTENANCE_WINDOW_NAME="$(yaml_read ".services[$index].maintenance.windows[$window].name // \"window-${window}\"")"
            return 0
        fi
    done
    return 1
}

update_maintenance_status() {
    local service_name="$1" active_file
    MAINTENANCE_ACTIVE=0
    if ! is_maintenance_window "$service_name"; then
        record_maintenance_exit "$service_name"
        return 0
    fi
    MAINTENANCE_ACTIVE=1
    (( DRY_RUN == 0 )) || return 0
    active_file="$(maintenance_marker_file "$service_name" maintenance-active)"
    if [[ ! -e "$active_file" ]]; then
        printf '%s\n' "$MAINTENANCE_WINDOW_NAME" >"$active_file" || die "Cannot write maintenance state: ${active_file}"
        log INFO "service=${service_name} maintenance_window=${MAINTENANCE_WINDOW_NAME} active=true"
    fi
}

record_maintenance_exit() {
    local service_name="$1" active_file previous_window="previous"
    (( DRY_RUN == 0 )) || return 0
    active_file="$(maintenance_marker_file "$service_name" maintenance-active)"
    if [[ -e "$active_file" ]]; then
        if [[ -s "$active_file" ]]; then
            IFS= read -r previous_window <"$active_file" || true
        fi
        rm -f -- "$active_file"
        log INFO "service=${service_name} maintenance_window=${previous_window} active=false"
    fi
}

send_deferred_failure_alert() {
    local service_name="$1" deferred_file
    (( DRY_RUN == 0 && MAINTENANCE_ACTIVE == 0 )) || return 0
    deferred_file="$(maintenance_marker_file "$service_name" maintenance-deferred-failure)"
    [[ -e "$deferred_file" ]] || return 0
    [[ "$(read_state "$service_name")" == unavailable ]] || { rm -f -- "$deferred_file"; return 0; }
    log WARN "service=${service_name} state=unavailable maintenance=deferred_alert action=send"
    send_email_notification failure || log ERROR "service=${service_name} result=state-email-failed state=unavailable"
    send_webhook_notification failure || log ERROR "service=${service_name} result=state-webhook-failed state=unavailable"
    run_configured_sequence '.hooks.on_failure' unavailable "$service_name" ||
        log ERROR "service=${service_name} result=state-hook-failed state=unavailable"
    rm -f -- "$deferred_file"
}

handle_state_transition() {
    local service_name="$1" new_state="$2"
    local previous hook_expression notification_event deferred_file
    (( DRY_RUN == 0 )) || return 0
    previous="$(read_state "$service_name")"
    if [[ "$previous" == "$new_state" ]]; then
        [[ "$new_state" == unavailable ]] && send_deferred_failure_alert "$service_name"
        return 0
    fi
    if (( MAINTENANCE_ACTIVE == 1 )); then
        deferred_file="$(maintenance_marker_file "$service_name" maintenance-deferred-failure)"
        if [[ "$new_state" == unavailable ]]; then
            : >"$deferred_file" || die "Cannot write maintenance state: ${deferred_file}"
        else
            rm -f -- "$deferred_file"
        fi
        write_state "$service_name" "$new_state"
        record_state_transition_timestamp "$service_name"
        log INFO "service=${service_name} event=state-change state=${new_state} maintenance_window=${MAINTENANCE_WINDOW_NAME} action=suppressed"
        return 0
    fi
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
    record_state_transition_timestamp "$service_name"
    log INFO "service=${service_name} action=state previous=${previous} current=${new_state}"
}

handle_dependency_failure() {
    local service_name="$1" dependency_name="$2" previous
    previous="$(read_state "$service_name")"
    if [[ "$previous" == unavailable ]]; then
        PROCESS_RESULT=unavailable
        log WARN "service=${service_name} state=unavailable dependency=${dependency_name} note=already_unavailable_before_dependency"
        return 0
    fi
    (( DRY_RUN == 0 )) || { PROCESS_RESULT=dependency_failed; return 0; }
    write_state "$service_name" dependency_failed
    record_state_transition_timestamp "$service_name"
    PROCESS_RESULT=dependency_failed
    log WARN "service=${service_name} state=dependency_failed dependency=${dependency_name} reason=required_dependency_unavailable"
}

required_dependency_is_unavailable() {
    local service_name="$1" dependency_name dependency_state required
    for dependency_name in ${DEPENDENCY_NAMES[$service_name]:-}; do
        dependency_state="${RESOLVED_STATE[$dependency_name]:-unknown}"
        required="${DEPENDENCY_REQUIRED[${service_name}:${dependency_name}]:-true}"
        if [[ "$dependency_state" == unavailable || "$dependency_state" == dependency_failed ]]; then
            if [[ "$required" == true ]]; then
                log WARN "service=${service_name} dependency=${dependency_name} required=true dependency_state=${dependency_state} action=skip reason=dependency_failed"
                printf '%s' "$dependency_name"
                return 0
            fi
            log WARN "service=${service_name} dependency=${dependency_name} required=false dependency_state=${dependency_state} action=proceed reason=optional_dependency_down"
        fi
    done
    return 1
}

service_is_required_for() {
    local target_service="$1" candidate_service="$2" dependency_name
    for dependency_name in ${DEPENDENCY_NAMES[$target_service]:-}; do
        [[ "$dependency_name" == "$candidate_service" ]] && return 0
        service_is_required_for "$dependency_name" "$candidate_service" && return 0
    done
    return 1
}

process_service() {
    local index="$1"
    local enabled actions_count verify_after circuit_state action_due=0 half_open_attempt=0 initial_check_healthy=0
    CURRENT_SERVICE="$(yaml_read ".services[$index].name")"
    CURRENT_CHECK_TYPE="$(yaml_read ".services[$index].check.type")"
    CURRENT_ACTION_STATUS="not-attempted"
    PROCESS_RESULT="unknown"
    ESCALATION_CONSECUTIVE_UNAVAILABLE=0
    ESCALATION_COUNT=0
    CHECK_DETAIL=""
    CHECK_HTTP_STATUS=""
    CHECK_EXIT_CODE=""
    enabled="$(yaml_read ".services[$index].enabled // true")"

    if [[ "$enabled" != true ]]; then
        log INFO "service=${CURRENT_SERVICE} result=skipped reason=disabled"
        PROCESS_RESULT="$(read_state "$CURRENT_SERVICE")"
        return 0
    fi

    local failed_dependency=""
    failed_dependency="$(required_dependency_is_unavailable "$CURRENT_SERVICE")" || true
    if [[ -n "$failed_dependency" ]]; then
        handle_dependency_failure "$CURRENT_SERVICE" "$failed_dependency"
        return 0
    fi

    if [[ -n "${CONDITION_SKIPPED[$CURRENT_SERVICE]+present}" ]]; then
        PROCESS_RESULT="$(read_state "$CURRENT_SERVICE")"
        return 0
    fi
    if [[ -z "${CONDITION_EVALUATED[$CURRENT_SERVICE]+present}" ]] && ! evaluate_conditions "$index" "$CURRENT_SERVICE"; then
        PROCESS_RESULT="$(read_state "$CURRENT_SERVICE")"
        return 0
    fi

    log INFO "service=${CURRENT_SERVICE} action=service-start type=${CURRENT_CHECK_TYPE}"
    if [[ -n "${PRELOADED_CHECK_STATE[$CURRENT_SERVICE]+present}" ]]; then
        use_preloaded_check_result "$CURRENT_SERVICE" && initial_check_healthy=1
    elif check_with_retries "$index"; then
        initial_check_healthy=1
    fi
    if (( initial_check_healthy == 1 )); then
        CURRENT_ACTION_STATUS="not-required"
        update_maintenance_status "$CURRENT_SERVICE"
        record_circuit_action_result "$index" "$CURRENT_SERVICE" true
        reset_unavailable_counter "$CURRENT_SERVICE"
        handle_state_transition "$CURRENT_SERVICE" healthy
        PROCESS_RESULT=healthy
        log INFO "service=${CURRENT_SERVICE} result=healthy"
        return 0
    fi

    update_maintenance_status "$CURRENT_SERVICE"
    actions_count="$(yaml_read ".services[$index].actions.commands // [] | length")"
    if (( actions_count == 0 )); then
        CURRENT_ACTION_STATUS="not-configured"
    elif (( DRY_RUN == 1 )); then
        CURRENT_ACTION_STATUS="skipped-dry-run"
    elif (( MAINTENANCE_ACTIVE == 1 )); then
        CURRENT_ACTION_STATUS="skipped-maintenance"
    elif ! should_run_actions_with_circuit_breaker "$index" "$CURRENT_SERVICE"; then
        CURRENT_ACTION_STATUS="skipped-circuit-breaker"
    elif [[ "$(read_service_marker_string "$CURRENT_SERVICE" circuit-state closed)" == half_open ]]; then
        CURRENT_ACTION_STATUS="pending-half-open"
        action_due=1
        half_open_attempt=1
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
        elif (( MAINTENANCE_ACTIVE == 1 )); then
            log WARN "service=${CURRENT_SERVICE} action=remediation result=skipped reason=maintenance-window maintenance_window=${MAINTENANCE_WINDOW_NAME}"
        elif (( action_due == 1 )); then
            ACTION_ATTEMPTED=1
            record_action_attempt "$CURRENT_SERVICE"
            log WARN "service=${CURRENT_SERVICE} action=remediation-start commands=${actions_count}"
            if run_configured_sequence ".services[$index].actions.commands" remediation "$CURRENT_SERVICE"; then
                CURRENT_ACTION_STATUS="commands-succeeded"
            else
                CURRENT_ACTION_STATUS="command-failed"
            fi

            if (( half_open_attempt == 1 )); then
                verify_after="$(yaml_read ".services[$index].circuit_breaker.half_open_verify_after // 0")"
            else
                verify_after="$(yaml_read ".services[$index].actions.verify_after // 0")"
            fi
            (( verify_after > 0 )) && sleep "$verify_after"
            if check_with_retries "$index"; then
                CURRENT_ACTION_STATUS="successful"
                update_maintenance_status "$CURRENT_SERVICE"
                record_circuit_action_result "$index" "$CURRENT_SERVICE" true
                reset_unavailable_counter "$CURRENT_SERVICE"
                handle_state_transition "$CURRENT_SERVICE" healthy
                PROCESS_RESULT=healthy
                log WARN "service=${CURRENT_SERVICE} result=recovered-after-remediation"
                return 0
            fi
            if [[ "$CURRENT_ACTION_STATUS" == commands-succeeded ]]; then
                CURRENT_ACTION_STATUS="verification-failed"
            fi
            record_circuit_action_result "$index" "$CURRENT_SERVICE" false
        else
            if [[ "$CURRENT_ACTION_STATUS" == skipped-circuit-breaker ]]; then
                log WARN "service=${CURRENT_SERVICE} action=remediation result=skipped reason=circuit-breaker"
            else
                log WARN "service=${CURRENT_SERVICE} action=remediation result=skipped reason=cooldown"
            fi
        fi
    fi

    increment_unavailable_counter "$CURRENT_SERVICE"
    run_escalation "$index" "$CURRENT_SERVICE"
    PROCESS_RESULT=unavailable
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
    for name in bash base64 curl yq flock timeout date dirname mktemp tail tr mv env awk df hostname find; do
        require_command "$name"
    done
    yq_version="$(yq --version 2>/dev/null)" || die "Cannot determine yq version."
    [[ "$yq_version" =~ version[[:space:]]+v?4\. ]] || die "Mike Farah yq v4 is required: ${yq_version}"

    yq eval '.' "$CONFIG_FILE" >/dev/null 2>&1 || die "YAML is syntactically invalid: ${CONFIG_FILE}"
    validate_templates
    expand_templates
    validate_configuration
    configure_runtime
    configure_parallel
    configure_email
    configure_metrics
    configure_status_page
    configure_federation
    if (( PARALLEL_ENABLED == 1 )); then
        TEMP_DIRECTORY="$(mktemp -d "${PARALLEL_TEMP_BASE%/}/watchdog.XXXXXX")" || die "Cannot create parallel temporary directory."
    else
        TEMP_DIRECTORY="$(mktemp -d)" || die "Cannot create temporary directory."
    fi
    exec 9>"$LOCK_FILE" || die "Cannot open lock file: ${LOCK_FILE}"
    if ! flock --nonblock 9; then
        log WARN "action=lock result=already-running"
        exit 0
    fi

    log_template_expansions
    log INFO "action=watchdog-start config=${CONFIG_FILE} dry_run=${DRY_RUN}"
    if (( FEDERATION_HUB_ENABLED == 1 )); then
        federation_hub_process_reports
        if [[ "$FEDERATION_HUB_OVERALL_STATUS" == operational ]]; then
            log INFO "action=watchdog-finish mode=federation-hub exit=0 overall=operational"
            exit 0
        fi
        log WARN "action=watchdog-finish mode=federation-hub exit=1 overall=${FEDERATION_HUB_OVERALL_STATUS}"
        exit 1
    fi
    service_count="$(yaml_read '.services | length')"
    if [[ -n "$ONLY_SERVICE" ]]; then
        for ((index = 0; index < service_count; index++)); do
            name="$(yaml_read ".services[$index].name")"
            [[ "$name" == "$ONLY_SERVICE" ]] && matched=1
        done
        (( matched == 1 )) || die "Service not found: ${ONLY_SERVICE}"
    fi

    RESOLVED_STATE=()
    CONDITION_SKIPPED=()
    CONDITION_EVALUATED=()
    FEDERATION_STATE_CHANGED=0
    if (( PARALLEL_ENABLED == 1 )); then
        local max_level=0 level
        for name in "${SERVICE_ORDER[@]}"; do
            (( max_level < SERVICE_LEVEL[$name] )) && max_level="${SERVICE_LEVEL[$name]}"
        done
        for ((level = 0; level <= max_level; level++)); do
            process_parallel_level "$level"
        done
    else
        for name in "${SERVICE_ORDER[@]}"; do
            if [[ -n "$ONLY_SERVICE" && "$name" != "$ONLY_SERVICE" ]] && ! service_is_required_for "$ONLY_SERVICE" "$name"; then
                continue
            fi
            index="${SERVICE_INDEX[$name]}"
            process_service "$index"
            RESOLVED_STATE["$name"]="$PROCESS_RESULT"
        done
    fi

    write_prometheus_metrics
    generate_status_page
    federation_agent_send_report

    if (( UNHEALTHY_FOUND == 1 || ACTION_ATTEMPTED == 1 )); then
        log WARN "action=watchdog-finish exit=1 unhealthy=${UNHEALTHY_FOUND} remediation=${ACTION_ATTEMPTED}"
        exit 1
    fi
    log INFO "action=watchdog-finish exit=0 unhealthy=0 remediation=0"
    exit 0
}

main "$@"
