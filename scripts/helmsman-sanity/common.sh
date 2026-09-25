#!/usr/bin/env bash
#
# ==============================================================================
# Helmsman Sanity Framework
#
# File      : common.sh
# Purpose   : Shared framework functions used by all modules.
#
# Modules
#   - Logging
#   - Utilities
#   - Kubernetes Helpers
#   - Docker Helpers
#   - ArgoCD Helpers
#   - HTTP Helpers
#   - Timer
#   - Summary
#
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

################################################################################
# Framework Metadata
################################################################################

readonly FRAMEWORK_NAME="Helmsman Sanity Framework"
readonly FRAMEWORK_VERSION="2.0.0"

################################################################################
# Root Directory
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}"

################################################################################
# Load Configuration
################################################################################

CONFIG_FILE="${ROOT_DIR}/config.env"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: Unable to locate ${CONFIG_FILE}"
    exit 1
fi

# shellcheck disable=SC1090
source "${CONFIG_FILE}"

################################################################################
# Runtime Directories
################################################################################

LOG_DIR="${ROOT_DIR}/logs"
REPORT_DIR="${ROOT_DIR}/reports"
TMP_DIR="${ROOT_DIR}/tmp"

mkdir -p \
    "${LOG_DIR}" \
    "${REPORT_DIR}" \
    "${TMP_DIR}"

################################################################################
# Runtime Variables
################################################################################

START_TIME="$(date +%s)"

LOG_FILE="${LOG_DIR}/helmsman-sanity-$(date +%Y%m%d_%H%M%S).log"

################################################################################
# ANSI Colors
################################################################################

readonly CLR_RESET="\033[0m"

readonly CLR_RED="\033[31m"
readonly CLR_GREEN="\033[32m"
readonly CLR_YELLOW="\033[33m"
readonly CLR_BLUE="\033[34m"
readonly CLR_MAGENTA="\033[35m"

################################################################################
# Summary Counters
################################################################################

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
FIX_COUNT=0

################################################################################
# Timestamp
################################################################################

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

################################################################################
# Generic Logger
################################################################################

log::write() {

    local level="$1"
    local color="$2"

    shift 2

    local message="$*"

    printf "%b[%s] [%-7s] %s%b\n" \
        "${color}" \
        "$(timestamp)" \
        "${level}" \
        "${message}" \
        "${CLR_RESET}"

    printf "[%s] [%-7s] %s\n" \
        "$(timestamp)" \
        "${level}" \
        "${message}" \
        >> "${LOG_FILE}"
}

################################################################################
# Logging API
################################################################################

log::info() {
    log::write "INFO" "${CLR_BLUE}" "$@"
}

log::success() {
    log::write "SUCCESS" "${CLR_GREEN}" "$@"
}

log::warn() {
    log::write "WARNING" "${CLR_YELLOW}" "$@"
}

log::error() {
    log::write "ERROR" "${CLR_RED}" "$@"
}

log::debug() {

    if [[ "${ENABLE_DEBUG}" == "true" ]]; then
        log::write "DEBUG" "${CLR_MAGENTA}" "$@"
    fi
}

log::fatal() {

    log::write "FATAL" "${CLR_RED}" "$@"

    exit 1
}

################################################################################
# Framework Banner
################################################################################

framework::print_banner() {

    echo
    echo "===================================================================="
    echo " ${FRAMEWORK_NAME}"
    echo " Version : ${FRAMEWORK_VERSION}"
    echo " Started : $(timestamp)"
    echo "===================================================================="
    echo
}

################################################################################
# Framework Footer
################################################################################

framework::print_footer() {

    local end_time
    local duration

    end_time=$(date +%s)
    duration=$((end_time - START_TIME))

    echo
    echo "===================================================================="
    echo "Completed in ${duration} seconds"
    echo "Log File : ${LOG_FILE}"
    echo "===================================================================="
    echo
}

################################################################################
# Utility Functions
################################################################################

util::command_exists() {
    command -v "$1" >/dev/null 2>&1
}

################################################################################

util::require_commands() {

    local missing=()

    for cmd in "$@"; do
        if ! util::command_exists "${cmd}"; then
            missing+=("${cmd}")
        fi
    done

    if ((${#missing[@]})); then
        log::fatal "Missing required command(s): ${missing[*]}"
    fi
}

################################################################################

util::is_true() {

    local value="${1:-false}"

    case "${value,,}" in
        true|yes|y|1|on)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

################################################################################

util::run() {

    if util::is_true "${DRY_RUN:-false}"; then
        log::info "[DRY-RUN] $*"
        return 0
    fi

    log::debug "Executing: $*"

    "$@"
}

################################################################################

util::retry() {

    local retries="$1"
    local delay="$2"

    shift 2

    local attempt=1

    until "$@"; do

        if (( attempt >= retries )); then
            log::error "Command failed after ${attempt} attempt(s): $*"
            return 1
        fi

        log::warn \
            "Attempt ${attempt}/${retries} failed. Retrying in ${delay}s..."

        sleep "${delay}"

        ((attempt++))

    done

    return 0
}

################################################################################

util::wait_until() {

    local timeout="$1"
    local interval="$2"

    shift 2

    local elapsed=0

    until "$@"; do

        if (( elapsed >= timeout )); then
            return 1
        fi

        sleep "${interval}"

        elapsed=$((elapsed + interval))

    done

    return 0
}

################################################################################

util::create_workspace() {

    WORK_DIR="${TMP_DIR}/run-$(date +%Y%m%d_%H%M%S)"

    mkdir -p "${WORK_DIR}"

    log::debug "Workspace created: ${WORK_DIR}"
}

################################################################################

util::cleanup() {

    if [[ -n "${WORK_DIR:-}" ]] && [[ -d "${WORK_DIR}" ]]; then
        rm -rf "${WORK_DIR}"
        log::debug "Workspace removed: ${WORK_DIR}"
    fi
}

################################################################################

util::require_context() {

    local context="$1"

    kubectl config get-contexts -o name | grep -Fxq "${context}" \
        || log::fatal "Kubernetes context not found: ${context}"
}

################################################################################

util::require_namespace() {

    local context="$1"
    local namespace="$2"

    kubectl \
        --context "${context}" \
        get namespace "${namespace}" >/dev/null 2>&1 \
        || log::fatal \
            "Namespace '${namespace}' not found in context '${context}'"
}

################################################################################

framework::initialize() {

    framework::print_banner

    util::require_commands \
        kubectl \
        docker \
        curl \
        jq

    util::require_context "${HUB_CONTEXT}"
    util::require_context "${SPOKE_CONTEXT}"

    util::create_workspace

    log::success "Framework initialization completed."
}

################################################################################

framework::shutdown() {

    util::cleanup

    framework::print_footer
}

################################################################################
# Kubernetes Framework
################################################################################

k8s::hub() {
    kubectl --context "${HUB_CONTEXT}" "$@"
}

################################################################################

k8s::spoke() {
    kubectl --context "${SPOKE_CONTEXT}" "$@"
}

################################################################################

k8s::resource_exists() {

    local cluster="$1"
    shift

    if [[ "${cluster}" == "hub" ]]; then
        k8s::hub "$@" >/dev/null 2>&1
    else
        k8s::spoke "$@" >/dev/null 2>&1
    fi
}

################################################################################

k8s::namespace_exists() {

    local cluster="$1"
    local namespace="$2"

    k8s::resource_exists \
        "${cluster}" \
        get namespace "${namespace}"
}

################################################################################

k8s::secret_exists() {

    local cluster="$1"
    local namespace="$2"
    local secret="$3"

    k8s::resource_exists \
        "${cluster}" \
        get secret "${secret}" \
        -n "${namespace}"
}

################################################################################

k8s::deployment_exists() {

    local cluster="$1"
    local namespace="$2"
    local deployment="$3"

    k8s::resource_exists \
        "${cluster}" \
        get deployment "${deployment}" \
        -n "${namespace}"
}

################################################################################

k8s::service_exists() {

    local cluster="$1"
    local namespace="$2"
    local service="$3"

    k8s::resource_exists \
        "${cluster}" \
        get service "${service}" \
        -n "${namespace}"
}

################################################################################

k8s::pod_exists() {

    local cluster="$1"
    local namespace="$2"
    local pod="$3"

    k8s::resource_exists \
        "${cluster}" \
        get pod "${pod}" \
        -n "${namespace}"
}

################################################################################

k8s::rollout_restart() {

    local cluster="$1"
    local namespace="$2"
    local deployment="$3"

    log::info "Restarting deployment '${deployment}' (${cluster})"

    if [[ "${cluster}" == "hub" ]]; then
        util::run \
            k8s::hub rollout restart deployment "${deployment}" \
            -n "${namespace}"
    else
        util::run \
            k8s::spoke rollout restart deployment "${deployment}" \
            -n "${namespace}"
    fi
}

################################################################################

k8s::wait_rollout() {

    local cluster="$1"
    local namespace="$2"
    local deployment="$3"

    log::info "Waiting for rollout: ${deployment}"

    if [[ "${cluster}" == "hub" ]]; then

        util::retry \
            "${RETRY_COUNT}" \
            "${RETRY_INTERVAL}" \
            k8s::hub rollout status deployment "${deployment}" \
            -n "${namespace}"

    else

        util::retry \
            "${RETRY_COUNT}" \
            "${RETRY_INTERVAL}" \
            k8s::spoke rollout status deployment "${deployment}" \
            -n "${namespace}"

    fi
}

################################################################################

k8s::wait_pods() {

    local cluster="$1"
    local namespace="$2"

    log::info "Waiting for pods in namespace '${namespace}'"

    if [[ "${cluster}" == "hub" ]]; then

        util::retry \
            "${RETRY_COUNT}" \
            "${RETRY_INTERVAL}" \
            k8s::hub wait \
                --for=condition=Ready \
                pod \
                --all \
                -n "${namespace}" \
                --timeout=120s

    else

        util::retry \
            "${RETRY_COUNT}" \
            "${RETRY_INTERVAL}" \
            k8s::spoke wait \
                --for=condition=Ready \
                pod \
                --all \
                -n "${namespace}" \
                --timeout=120s

    fi
}

################################################################################

k8s::get_jsonpath() {

    local cluster="$1"
    shift

    if [[ "${cluster}" == "hub" ]]; then
        k8s::hub "$@"
    else
        k8s::spoke "$@"
    fi
}

################################################################################

k8s::delete_pod() {

    local cluster="$1"
    local namespace="$2"
    local pod="$3"

    log::warn "Deleting pod '${pod}'"

    if [[ "${cluster}" == "hub" ]]; then

        util::run \
            k8s::hub delete pod "${pod}" \
            -n "${namespace}"

    else

        util::run \
            k8s::spoke delete pod "${pod}" \
            -n "${namespace}"

    fi
}

################################################################################

k8s::current_context() {

    kubectl config current-context

}

################################################################################

k8s::context_exists() {

    local context="$1"

    kubectl config get-contexts -o name | grep -Fxq "${context}"
}

################################################################################

k8s::api_reachable() {

    local context="$1"

    kubectl \
        --context "${context}" \
        version \
        --request-timeout=5s \
        >/dev/null 2>&1
}

################################################################################
# Docker Framework
################################################################################

docker::exists() {

    local container="$1"

    docker ps -a \
        --format '{{.Names}}' \
        | grep -Fxq "${container}"
}

################################################################################

docker::is_running() {

    local container="$1"

    [[ "$(docker inspect \
        -f '{{.State.Running}}' \
        "${container}" 2>/dev/null)" == "true" ]]
}

################################################################################

docker::exec() {

    local container="$1"
    shift

    util::run docker exec "${container}" "$@"
}

################################################################################

docker::inspect() {

    local container="$1"
    shift

    docker inspect "$@" "${container}"
}

################################################################################

docker::container_ip() {

    local container="$1"

    docker inspect \
        -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
        "${container}"
}

################################################################################

docker::container_network() {

    local container="$1"

    docker inspect \
        --format '{{range $k, $_ := .NetworkSettings.Networks}}{{println $k}}{{end}}' \
        "${container}" \
        2>/dev/null \
        | head -n1
}

################################################################################

docker::container_gateway() {

    local container="$1"

    local network

    network="$(docker::container_network "${container}")" || return 1

    docker::network_gateway "${network}"
}

################################################################################

docker::container_subnet() {

    local container="$1"

    local network

    network="$(docker::container_network "${container}")" || return 1

    docker::network_subnet "${network}"
}

################################################################################

docker::restart() {

    local container="$1"

    log::warn "Restarting Docker container '${container}'"

    util::run docker restart "${container}" >/dev/null

    util::retry \
        "${RETRY_COUNT}" \
        "${RETRY_INTERVAL}" \
        docker::is_running "${container}"

    log::success "Container '${container}' restarted successfully."
}

################################################################################

docker::stop() {

    local container="$1"

    log::warn "Stopping Docker container '${container}'"

    util::run docker stop "${container}" >/dev/null
}

################################################################################

docker::start() {

    local container="$1"

    log::warn "Starting Docker container '${container}'"

    util::run docker start "${container}" >/dev/null

    util::retry \
        "${RETRY_COUNT}" \
        "${RETRY_INTERVAL}" \
        docker::is_running "${container}"
}

################################################################################

docker::network_exists() {

    local network="$1"

    docker network ls \
        --format '{{.Name}}' \
        | grep -Fxq "${network}"
}

################################################################################

docker::network_inspect() {

    local network="$1"

    docker network inspect "${network}"
}

################################################################################

docker::network_gateway() {

    local network="$1"

    docker network inspect \
        -f '{{(index .IPAM.Config 0).Gateway}}' \
        "${network}"
}

################################################################################

docker::network_subnet() {

    local network="$1"

    docker network inspect \
        -f '{{(index .IPAM.Config 0).Subnet}}' \
        "${network}"
}

################################################################################

docker::remove() {

    local container="$1"

    if docker::exists "${container}"; then

        log::warn "Removing container '${container}'"

        util::run docker rm -f "${container}"
    fi
}

################################################################################

docker::wait_running() {

    local container="$1"

    util::retry \
        "${RETRY_COUNT}" \
        "${RETRY_INTERVAL}" \
        docker::is_running "${container}"
}

################################################################################

docker::host_gateway() {

    ip route | awk '/default/ {print $3; exit}'
}

################################################################################
# Runtime State
################################################################################

readonly STATE_DIR="${ROOT_DIR}/state"
readonly STATE_FILE="${STATE_DIR}/runtime.env"

declare -Ag STATE

################################################################################

state::load() {

    mkdir -p "${STATE_DIR}"

    [[ -f "${STATE_FILE}" ]] || touch "${STATE_FILE}"

    while IFS='=' read -r key value; do

        #
        # Skip blank lines
        #

        [[ -z "${key}" ]] && continue

        #
        # Skip comments
        #

        [[ "${key}" =~ ^# ]] && continue

        value="${value%\"}"
        value="${value#\"}"

        STATE["${key}"]="${value}"

    done < "${STATE_FILE}"
}

################################################################################

state::save() {

    mkdir -p "${STATE_DIR}"

    {
        echo "# ----------------------------------------------------------------------"
        echo "# Helmsman Runtime State"
        echo "# Generated automatically."
        echo "# ----------------------------------------------------------------------"
        echo

        printf 'FRAMEWORK_VERSION="%s"\n' "${FRAMEWORK_VERSION}"
        printf 'LAST_RUN="%s"\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

        if (( FAIL_COUNT > 0 )); then
            printf 'LAST_RESULT="FAIL"\n'
        elif (( WARN_COUNT > 0 )); then
            printf 'LAST_RESULT="WARN"\n'
        else
            printf 'LAST_RESULT="PASS"\n'
        fi

        echo

        for key in $(printf "%s\n" "${!STATE[@]}" | sort); do

            printf '%s="%s"\n' \
                "${key}" \
                "${STATE[$key]}"

        done

    } > "${STATE_FILE}"
}

################################################################################

state::set() {

    local key="$1"
    local value="$2"

    STATE["$key"]="$value"
}

################################################################################

state::get() {

    local key="$1"

    printf "%s" "${STATE[$key]:-}"
}

################################################################################

state::exists() {

    local key="$1"

    [[ -n "${STATE[$key]:-}" ]]
}

################################################################################

state::changed() {

    local key="$1"
    local current="$2"

    [[ "$(state::get "${key}")" != "${current}" ]]
}

################################################################################

state::update() {

    local key="$1"
    local value="$2"

    if state::changed "${key}" "${value}"; then
        state::set "${key}" "${value}"
    fi
}

################################################################################

state::clear() {

    STATE=()
}

################################################################################
# HTTP Framework
################################################################################

http::get() {

    local url="$1"
    shift

    curl \
        --fail \
        --silent \
        --show-error \
        "$@" \
        "${url}"
}

################################################################################

http::post() {

    local url="$1"
    shift

    curl \
        --fail \
        --silent \
        --show-error \
        -X POST \
        "$@" \
        "${url}"
}

################################################################################

http::head() {

    local url="$1"

    curl \
        --fail \
        --silent \
        --show-error \
        --head \
        "${url}" >/dev/null
}

################################################################################

http::reachable() {

    local url="$1"

    http::head "${url}"
}

################################################################################

http::wait_until_reachable() {

    local url="$1"

    util::retry \
        "${RETRY_COUNT}" \
        "${RETRY_INTERVAL}" \
        http::reachable "${url}"
}

################################################################################

http::healthcheck() {

    local url="$1"

    http::get "${url}" >/dev/null
}

################################################################################
# ArgoCD Framework
################################################################################

argocd::run() {

    argocd "$@"
}

################################################################################

argocd::login() {

    local server="$1"
    local username="$2"
    local password="$3"

    log::info "Logging into ArgoCD (${server})"

    util::run \
        argocd login "${server}" \
        --username "${username}" \
        --password "${password}" \
        --insecure \
        --grpc-web
}

################################################################################

argocd::logout() {

    local server="$1"

    argocd logout "${server}" >/dev/null 2>&1 || true
}

################################################################################

argocd::app_exists() {

    local app="$1"

    argocd app get "${app}" >/dev/null 2>&1
}

################################################################################

argocd::app_sync() {

    local app="$1"

    log::info "Syncing ArgoCD application '${app}'"

    util::run \
        argocd app sync "${app}" \
        --retry-limit 3
}

################################################################################

argocd::app_wait() {

    local app="$1"

    log::info "Waiting for application '${app}'"

    util::retry \
        "${RETRY_COUNT}" \
        "${RETRY_INTERVAL}" \
        argocd app wait "${app}" \
            --health \
            --sync
}

################################################################################

argocd::app_refresh() {

    local app="$1"

    log::debug "Refreshing application '${app}'"

    util::run \
        argocd app get "${app}" \
        --refresh >/dev/null
}

################################################################################

argocd::app_health() {

    local app="$1"

    argocd app get "${app}" \
        -o json \
        | jq -r '.status.health.status'
}

################################################################################

argocd::app_sync_status() {

    local app="$1"

    argocd app get "${app}" \
        -o json \
        | jq -r '.status.sync.status'
}

################################################################################

argocd::is_healthy() {

    local app="$1"

    [[ "$(argocd::app_health "${app}")" == "Healthy" ]]
}

################################################################################

argocd::is_synced() {

    local app="$1"

    [[ "$(argocd::app_sync_status "${app}")" == "Synced" ]]
}

################################################################################

argocd::wait_healthy() {

    local app="$1"

    util::retry \
        "${RETRY_COUNT}" \
        "${RETRY_INTERVAL}" \
        argocd::is_healthy "${app}"
}

################################################################################

argocd::wait_synced() {

    local app="$1"

    util::retry \
        "${RETRY_COUNT}" \
        "${RETRY_INTERVAL}" \
        argocd::is_synced "${app}"
}

################################################################################

argocd::hard_refresh() {

    local app="$1"

    log::warn "Performing hard refresh for '${app}'"

    util::run \
        argocd app get "${app}" \
        --hard-refresh >/dev/null
}

################################################################################
# Timer Framework
################################################################################

declare -A TIMER_STARTS

################################################################################

timer::start() {

    local name="$1"

    TIMER_STARTS["${name}"]="$(date +%s)"

    log::debug "Started timer: ${name}"
}

################################################################################

timer::stop() {

    local name="$1"

    local end
    local start
    local elapsed

    end=$(date +%s)
    start="${TIMER_STARTS[${name}]:-0}"

    elapsed=$((end - start))

    log::debug "Completed '${name}' in ${elapsed}s"

    printf "%s" "${elapsed}"
}

################################################################################
# Summary Framework
################################################################################

summary::pass() {
    ((PASS_COUNT++))
}

################################################################################

summary::warn() {
    ((WARN_COUNT++))
}

################################################################################

summary::fail() {
    ((FAIL_COUNT++))
}

################################################################################

summary::fix() {
    ((FIX_COUNT++))
}

################################################################################

summary::section() {

    local title="$1"

    echo
    echo "------------------------------------------------------------"
    echo "${title}"
    echo "------------------------------------------------------------"
}

################################################################################

summary::phase() {

    local phase="$1"

    echo
    echo "============================================================"
    echo "${phase}"
    echo "============================================================"
}

################################################################################

summary::print() {

    echo
    echo "============================================================"
    echo "Execution Summary"
    echo "============================================================"

    printf "%-25s : %d\n" "Passed Checks" "${PASS_COUNT}"
    printf "%-25s : %d\n" "Warnings" "${WARN_COUNT}"
    printf "%-25s : %d\n" "Failures" "${FAIL_COUNT}"
    printf "%-25s : %d\n" "Repairs Applied" "${FIX_COUNT}"

    local end_time
    local duration

    end_time=$(date +%s)
    duration=$((end_time - START_TIME))

    printf "%-25s : %ds\n" "Execution Time" "${duration}"

    printf "%-25s : %s\n" "Log File" "${LOG_FILE}"

    echo "============================================================"
}

################################################################################
# Report Helpers
################################################################################

report::header() {

    local title="$1"

    echo
    echo "######################################################################"
    echo "# ${title}"
    echo "######################################################################"
}

################################################################################

report::footer() {

    echo
    echo "######################################################################"
}

################################################################################

report::kv() {

    local key="$1"
    local value="$2"

    printf "%-35s : %s\n" "${key}" "${value}"
}

################################################################################

report::status() {

    local status="$1"
    local message="$2"

    printf "[%-8s] %s\n" "${status}" "${message}"
}

################################################################################

report::blank() {

    echo
}

################################################################################
# Error Handling
################################################################################

framework::on_error() {

    local exit_code="$1"
    local line_number="$2"

    log::error "Framework aborted at line ${line_number} (Exit Code: ${exit_code})"

    summary::fail
}

################################################################################

framework::register_traps() {

    trap 'framework::on_error $? ${LINENO}' ERR
}

################################################################################
# Framework Validation
################################################################################

framework::validate_environment() {

    log::info "Validating runtime environment..."

    util::require_commands \
        kubectl \
        docker \
        curl \
        jq \
        argocd

    util::require_context "${HUB_CONTEXT}"
    util::require_context "${SPOKE_CONTEXT}"

    util::require_namespace "${HUB_CONTEXT}" "${ARGO_NAMESPACE}"
    util::require_namespace "${HUB_CONTEXT}" "${KEYCLOAK_NAMESPACE}"
    util::require_namespace "${HUB_CONTEXT}" "${VAULT_NAMESPACE}"

    util::require_namespace "${SPOKE_CONTEXT}" "${ESO_NAMESPACE}"
    util::require_namespace "${SPOKE_CONTEXT}" "${APP_NAMESPACE}"

    log::success "Environment validation completed."
}

################################################################################
# Signal Handling
################################################################################

framework::signal_handler() {

    local signal="$1"

    log::warn "Received signal ${signal}"

    framework::shutdown

    exit 130
}

################################################################################

framework::register_signals() {

    trap 'framework::signal_handler SIGINT' INT
    trap 'framework::signal_handler SIGTERM' TERM

    framework::register_traps
}

################################################################################
# Framework Initialization
################################################################################

framework::initialize() {

    framework::print_banner

    framework::register_signals

    framework::validate_environment

    util::create_workspace

    state::load

    START_TIME=$(date +%s)

    log::success "Framework initialized successfully."
}

################################################################################
# Framework Shutdown
################################################################################

framework::shutdown() {

    log::info "Cleaning up framework..."

    state::save

    util::cleanup

    summary::print

    framework::print_footer
}

################################################################################
# Version
################################################################################

framework::version() {

    echo "${FRAMEWORK_NAME} ${FRAMEWORK_VERSION}"
}

################################################################################
# Help
################################################################################

framework::help() {

cat <<EOF

${FRAMEWORK_NAME}
Version : ${FRAMEWORK_VERSION}

Usage

    ./helmsman-sanity.sh

EOF

}

################################################################################
# End of common.sh
################################################################################