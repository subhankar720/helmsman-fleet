#!/usr/bin/env bash
#
# ==============================================================================
# Helmsman Sanity Framework
#
# File      : discovery.sh
# Purpose   : Discovers the current state of the Helmsman environment.
#
# NOTE:
#   This module MUST NOT perform repairs.
#   It only collects facts for repair.sh.
#
# ==============================================================================

################################################################################
# Discovery State
################################################################################

################################################################################
# Discovery State
################################################################################

declare -Ag DISCOVERY

################################################################################
# Repair Plan
################################################################################

declare -Ag REPAIR

################################################################################
# Discovery Helpers
################################################################################

discovery::set() {

    local key="$1"
    local value="$2"

    DISCOVERY["${key}"]="${value}"
}

################################################################################

discovery::get() {

    local key="$1"

    printf "%s" "${DISCOVERY[${key}]:-}"
}

################################################################################

discovery::is_true() {

    local key="$1"

    [[ "$(discovery::get "${key}")" == "true" ]]
}

################################################################################

repair::set() {

    local key="$1"
    local value="${2:-true}"

    REPAIR["${key}"]="${value}"
}

################################################################################

repair::get() {

    local key="$1"

    printf "%s" "${REPAIR[${key}]:-}"
}

################################################################################

repair::required() {

    local key="$1"

    [[ "$(repair::get "${key}")" == "true" ]]
}

################################################################################
# Discovery Report
################################################################################

discovery::print_section() {

    local title="$1"

    echo
    echo "=================================================="
    echo "${title}"
    echo "=================================================="
}

################################################################################

discovery::print_item() {

    local label="$1"
    local key="$2"

    if discovery::is_true "${key}"; then
        printf "  [PASS] %-35s\n" "${label}"
    else
        printf "  [FAIL] %-35s\n" "${label}"
    fi
}

################################################################################

discovery::print_repair() {

    local label="$1"
    local key="$2"

    if repair::required "${key}"; then
        printf "  [TODO] %s\n" "${label}"
    fi
}

################################################################################

discovery::section() {

    local title="$1"

    summary::section "${title}"
}

################################################################################
# Kubernetes Workload Discovery
################################################################################

discovery::deployment() {

    local context="$1"
    local namespace="$2"
    local deployment="$3"
    local key="$4"

    if k8s::deployment_exists \
        "${context}" \
        "${namespace}" \
        "${deployment}"; then

        discovery::set "${key}_EXISTS" true

        summary::pass

        log::success "Deployment '${deployment}' exists."

    else

        discovery::set "${key}_EXISTS" false

        summary::fail

        log::error "Deployment '${deployment}' missing."

        return
    fi

    #
    # Ready Replicas
    #

    local ready

    ready="$(
        k8s::get_jsonpath \
            "${context}" \
            deployment \
            "${deployment}" \
            "{.status.readyReplicas}" \
            "${namespace}"
    )"

    ready="${ready:-0}"

    if [[ "${ready}" -gt 0 ]]; then

        discovery::set "${key}_READY" true

        summary::pass

        log::success "Deployment '${deployment}' is ready."

    else

        discovery::set "${key}_READY" false

        summary::warn

        log::warn "Deployment '${deployment}' has no ready replicas."
    fi
}

################################################################################

discovery::component() {

    local component="$1"
    local context="$2"
    local namespace="$3"
    local deployment="$4"
    local service="$5"

    #
    # Deployment
    #

    discovery::deployment \
        "${context}" \
        "${namespace}" \
        "${deployment}" \
        "${component}"

    #
    # Service
    #

    if k8s::service_exists \
        "${context}" \
        "${namespace}" \
        "${service}"; then

        discovery::set "${component}_SERVICE_EXISTS" true

        summary::pass

        log::success "Service '${service}' exists."

    else

        discovery::set "${component}_SERVICE_EXISTS" false

        repair::set "VERIFY_${component}_SERVICE"

        summary::warn

        log::warn "Service '${service}' missing."
    fi

    #
    # Ready?
    #

    if ! discovery::is_true "${component}_READY"; then

        repair::set "RESTART_${component}"
    fi
}

################################################################################
# Runtime Discovery
################################################################################

discovery::docker() {

    discovery::section "Docker"

    if docker info >/dev/null 2>&1; then

        discovery::set DOCKER_RUNNING true

        summary::pass

        log::success "Docker daemon is running."

    else

        discovery::set DOCKER_RUNNING false

        summary::fail

        log::error "Docker daemon is unavailable."

    fi
}

################################################################################
# Kind Discovery
################################################################################

discovery::kind() {

    discovery::section "Kind Clusters"

    #
    # Hub Context
    #

    if k8s::context_exists "${HUB_CONTEXT}"; then

        discovery::set HUB_CLUSTER_EXISTS true

        summary::pass

        log::success "Hub cluster context found."

    else

        discovery::set HUB_CLUSTER_EXISTS false

        summary::fail

        log::error "Hub cluster context missing."
    fi

    #
    # Spoke Context
    #

    if k8s::context_exists "${SPOKE_CONTEXT}"; then

        discovery::set SPOKE_CLUSTER_EXISTS true

        summary::pass

        log::success "Spoke cluster context found."

    else

        discovery::set SPOKE_CLUSTER_EXISTS false

        summary::fail

        log::error "Spoke cluster context missing."
    fi

    #
    # Hub API
    #

    if discovery::is_true HUB_CLUSTER_EXISTS; then

        if k8s::api_reachable "${HUB_CONTEXT}"; then

            discovery::set HUB_API_AVAILABLE true

            summary::pass

            log::success "Hub Kubernetes API reachable."

        else

            discovery::set HUB_API_AVAILABLE false

            summary::fail

            log::error "Hub Kubernetes API unreachable."
        fi
    fi

    #
    # Spoke API
    #

    if discovery::is_true SPOKE_CLUSTER_EXISTS; then

        if k8s::api_reachable "${SPOKE_CONTEXT}"; then

            discovery::set SPOKE_API_AVAILABLE true

            summary::pass

            log::success "Spoke Kubernetes API reachable."

        else

            discovery::set SPOKE_API_AVAILABLE false

            summary::fail

            log::error "Spoke Kubernetes API unreachable."
        fi
    fi
}

################################################################################
# Network Discovery
################################################################################

discovery::network() {

    discovery::section "Network"

    #
    # Hub Network
    #

    if discovery::is_true HUB_CLUSTER_EXISTS; then

        local hub_network
        local hub_ip

        hub_network="$(docker::container_network "${HUB_CONTEXT}")"
        hub_ip="$(docker::container_ip "${HUB_CONTEXT}")"

        discovery::set HUB_NETWORK "${hub_network}"
        discovery::set HUB_IP "${hub_ip}"

        report::kv "Hub Network" "${hub_network}"
        report::kv "Hub IP" "${hub_ip}"
    fi

    #
    # Spoke Network
    #

    if discovery::is_true SPOKE_CLUSTER_EXISTS; then

        local spoke_network
        local spoke_ip

        spoke_network="$(docker::container_network "${SPOKE_CONTEXT}")"
        spoke_ip="$(docker::container_ip "${SPOKE_CONTEXT}")"

        discovery::set SPOKE_NETWORK "${spoke_network}"
        discovery::set SPOKE_IP "${spoke_ip}"

        report::kv "Spoke Network" "${spoke_network}"
        report::kv "Spoke IP" "${spoke_ip}"
    fi

    #
    # Docker Gateway/Subnet
    #

    if [[ -n "$(discovery::get HUB_NETWORK)" ]]; then

        discovery::set \
            DOCKER_GATEWAY \
            "$(docker::network_gateway "$(discovery::get HUB_NETWORK)")"

        discovery::set \
            DOCKER_SUBNET \
            "$(docker::network_subnet "$(discovery::get HUB_NETWORK)")"

        report::kv \
            "Gateway" \
            "$(discovery::get DOCKER_GATEWAY)"

        report::kv \
            "Subnet" \
            "$(discovery::get DOCKER_SUBNET)"
    fi

    ################################################################################
    # Runtime Comparison
    ################################################################################

    local previous_hub_ip
    local previous_spoke_ip

    previous_hub_ip="$(state::get LAST_HUB_IP)"
    previous_spoke_ip="$(state::get LAST_SPOKE_IP)"

    if [[ -n "${previous_hub_ip}" ]] &&
       [[ "${previous_hub_ip}" != "$(discovery::get HUB_IP)" ]]; then

        repair::set UPDATE_ENDPOINTS
        repair::set REFRESH_ARGOCD

        discovery::set HUB_IP_CHANGED true
    fi

    if [[ -n "${previous_spoke_ip}" ]] &&
       [[ "${previous_spoke_ip}" != "$(discovery::get SPOKE_IP)" ]]; then

        repair::set UPDATE_ENDPOINTS

        discovery::set SPOKE_IP_CHANGED true
    fi

    #
    # Save current values
    #

    state::set LAST_HUB_IP \
        "$(discovery::get HUB_IP)"

    state::set LAST_SPOKE_IP \
        "$(discovery::get SPOKE_IP)"

    state::set LAST_DOCKER_GATEWAY \
        "$(discovery::get DOCKER_GATEWAY)"

    state::set LAST_DOCKER_SUBNET \
        "$(discovery::get DOCKER_SUBNET)"
    
    state::set LAST_HUB_NETWORK \
    "$(discovery::get HUB_NETWORK)"
    
    state::set LAST_SPOKE_NETWORK \
    "$(discovery::get SPOKE_NETWORK)"
}


################################################################################
# Kubernetes Workloads
################################################################################

discovery::workloads() {

    discovery::section "Kubernetes Workloads"

    #
    # Hub Components
    #

    discovery::component \
        "ARGOCD" \
        "${HUB_CONTEXT}" \
        "${ARGO_NAMESPACE}" \
        "${ARGOCD_SERVER_DEPLOYMENT}" \
        "${ARGOCD_SERVICE}"

    discovery::component \
        "KEYCLOAK" \
        "${HUB_CONTEXT}" \
        "${KEYCLOAK_NAMESPACE}" \
        "${KEYCLOAK_DEPLOYMENT}" \
        "${KEYCLOAK_SERVICE}"

    discovery::component \
        "VAULT" \
        "${HUB_CONTEXT}" \
        "${VAULT_NAMESPACE}" \
        "${VAULT_DEPLOYMENT}" \
        "${VAULT_SERVICE}"

    #
    # Spoke Components
    #

    discovery::component \
        "OAUTH2" \
        "${SPOKE_CONTEXT}" \
        "${APP_NAMESPACE}" \
        "${OAUTH2_PROXY_DEPLOYMENT}" \
        "${OAUTH2_PROXY_SERVICE}"

    discovery::component \
        "SAMPLE_APP" \
        "${SPOKE_CONTEXT}" \
        "${APP_NAMESPACE}" \
        "${SAMPLE_APP_DEPLOYMENT}" \
        "${SAMPLE_APP_SERVICE}"
}

################################################################################
# Endpoint Discovery
################################################################################

discovery::endpoints() {

    discovery::section "Platform Endpoints"

    #
    # ArgoCD
    #

    if http::reachable "${ARGOCD_URL}"; then

        discovery::set ARGOCD_REACHABLE true

        summary::pass

        log::success "ArgoCD endpoint reachable."

    else

        discovery::set ARGOCD_REACHABLE false
        repair::set REFRESH_ARGOCD

        summary::warn

        log::warn "ArgoCD endpoint unreachable."
    fi

    #
    # Keycloak
    #

    if http::reachable "${KEYCLOAK_URL}"; then

        discovery::set KEYCLOAK_REACHABLE true

        summary::pass

        log::success "Keycloak endpoint reachable."

    else

        discovery::set KEYCLOAK_REACHABLE false

        summary::warn

        log::warn "Keycloak endpoint unreachable."
    fi

    #
    # Vault
    #

    if http::reachable "${VAULT_URL}"; then

        discovery::set VAULT_REACHABLE true

        summary::pass

        log::success "Vault endpoint reachable."

    else

        discovery::set VAULT_REACHABLE false

        summary::warn

        log::warn "Vault endpoint unreachable."
    fi
}

################################################################################
# Summary
################################################################################

discovery::summary() {

    discovery::print_section "Infrastructure"

    discovery::print_item \
        "Docker Running" \
        "DOCKER_RUNNING"

    discovery::print_item \
        "Hub API Reachable" \
        "HUB_API_AVAILABLE"

    discovery::print_item \
        "Spoke API Reachable" \
        "SPOKE_API_AVAILABLE"
    
    if discovery::is_true HUB_IP_CHANGED; then
        report::status "Hub IP changed"
    fi

    if discovery::is_true SPOKE_IP_CHANGED; then
        report::status "Spoke IP changed"
    fi

    discovery::print_section "Applications"

    discovery::print_item \
        "ArgoCD Ready" \
        "ARGOCD_READY"

    discovery::print_item \
        "Keycloak Ready" \
        "KEYCLOAK_READY"

    discovery::print_item \
        "Vault Ready" \
        "VAULT_READY"

    discovery::print_item \
        "oauth2-proxy Ready" \
        "OAUTH2_READY"

    discovery::print_item \
        "Sample App Ready" \
        "SAMPLE_APP_READY"

    discovery::print_section "Repair Plan"

    discovery::print_repair \
        "Restart ArgoCD" \
        "RESTART_ARGOCD"

    discovery::print_repair \
        "Restart Keycloak" \
        "RESTART_KEYCLOAK"

    discovery::print_repair \
        "Restart Vault" \
        "RESTART_VAULT"

    discovery::print_repair \
        "Restart oauth2-proxy" \
        "RESTART_OAUTH2"

    discovery::print_repair \
        "Restart Sample App" \
        "RESTART_SAMPLE_APP"

    discovery::print_repair \
        "Refresh ArgoCD" \
        "REFRESH_ARGOCD"

    discovery::print_repair \
        "Verify ArgoCD Service" \
        "VERIFY_ARGOCD_SERVICE"

    discovery::print_repair \
        "Verify Keycloak Service" \
        "VERIFY_KEYCLOAK_SERVICE"

    discovery::print_repair \
        "Verify Vault Service" \
        "VERIFY_VAULT_SERVICE"

    discovery::print_repair \
        "Verify oauth2-proxy Service" \
        "VERIFY_OAUTH2_SERVICE"

    discovery::print_repair \
        "Verify Sample App Service" \
        "VERIFY_SAMPLE_APP_SERVICE"

    echo

    if [[ ${#REPAIR[@]} -eq 0 ]]; then
        log::success "Discovery completed. No repairs required."
    else
        log::warn "Discovery completed. ${#REPAIR[@]} repair action(s) identified."
    fi
}

################################################################################
# Entry Point
################################################################################

discovery::run() {

    summary::phase "Discovery Phase"

    discovery::docker

    discovery::kind

    discovery::network

    discovery::workloads

    discovery::endpoints

    discovery::summary
}