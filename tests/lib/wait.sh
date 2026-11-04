#!/usr/bin/env bash
# tests/lib/wait.sh — context defaults and Kubernetes helpers.
# Converged environments (single cluster): export HUB_CTX="$SPOKE_CTX".
HUB_CTX="${HUB_CTX:-kind-helmsman-hub}"
SPOKE_CTX="${SPOKE_CTX:-kind-helmsman-onprem}"

k() { kubectl --context "$SPOKE_CTX" "$@"; }

get_accessgrant_state() {   # name [namespace]
  k -n "${2:-sample-app}" get accessgrant "$1" -o jsonpath='{.status.state}' 2>/dev/null
}
get_appdeployment_phase() { # name [namespace]
  k -n "${2:-sample-app}" get appdeployment "$1" -o jsonpath='{.status.phase}' 2>/dev/null
}
