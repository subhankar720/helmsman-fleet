#!/bin/bash
# =============================================================================
# helmsman-sanity.sh
# Helmsman Local Dev Environment — Sanity Check and Auto-Fix Script
# =============================================================================
#
# WHEN TO RUN THIS SCRIPT
# -----------------------
# Run this script at the START OF EVERY DEV SESSION, or whenever you see
# any of the errors listed below. It is safe to run multiple times.
#
# ERRORS THAT MEAN YOU NEED THIS SCRIPT
# --------------------------------------
#
# 1. In `argocd app list` or `argocd app get`:
#    "Failed to load live state: ... dial tcp 172.18.x.x:6443: connect: connection refused"
#    "ComparisonError ... failed to get server version"
#    → Docker Desktop restarted and the spoke cluster got a new Docker bridge IP.
#      The cluster Secret in Argo CD still has the old IP.
#
# 2. In any `argocd` CLI command:
#    "rpc error: code = Unauthenticated desc = invalid session: token has invalid claims: token is expired"
#    → Your Argo CD CLI session token expired (default TTL is 24 hours).
#
# 3. Running `docker --version` in WSL2 gives:
#    "The command 'docker' could not be found in this WSL 2 distro."
#    → Docker Desktop restarted and lost its WSL2 integration for Ubuntu.
#      Fix: Docker Desktop → Settings → Resources → WSL Integration → Enable Ubuntu.
#      Then re-run this script.
#
# 4. `kubectl get nodes --context kind-helmsman-hub` gives:
#    "Unable to connect to the server: dial tcp ... connection refused"
#    → The kind cluster containers stopped (Docker Desktop restart).
#      The containers auto-restart but take ~30 seconds. Wait and re-run this script.
#
# WHAT THIS SCRIPT DOES
# ---------------------
# 1. Verifies Docker is accessible from WSL2
# 2. Verifies both kind clusters (hub + spoke) are running
# 3. Detects the spoke cluster's current Docker bridge IP
# 4. Compares it to what Argo CD has stored — updates if different
# 5. Re-logs into the Argo CD CLI (safe even if session is still valid)
# 6. Verifies Argo CD can connect to the spoke cluster (STATUS = Successful)
# 7. Lists all Argo CD Applications and their sync/health status
# 8. Checks pod status on the spoke cluster
# 9. Prints a summary of pass/fail for each check
#
# =============================================================================

set -uo pipefail

# ── Configuration — update these if you change passwords or cluster names ─────
ARGOCD_URL="localhost:8080"
ARGOCD_USER="admin"
ARGOCD_PASS="${ARGOCD_PASS:-nyKTpDW-m4jQnODE}"   # override via env var if needed
HUB_CONTEXT="kind-helmsman-hub"
SPOKE_CONTEXT="kind-helmsman-onprem"
SPOKE_CONTAINER="helmsman-onprem-control-plane"
CLUSTER_SECRET_NAME="cluster-helmsman-onprem"
CLUSTER_REGISTERED_NAME="helmsman-onprem"
ARGOCD_NAMESPACE="argocd"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Tracking ──────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
FIXED=0

# ── Helpers ───────────────────────────────────────────────────────────────────
ok()    { echo -e "  ${GREEN}✔${NC}  $1"; ((PASS++)); }
fail()  { echo -e "  ${RED}✘${NC}  $1"; ((FAIL++)); }
fix()   { echo -e "  ${YELLOW}⚙${NC}  $1"; ((FIXED++)); }
info()  { echo -e "  ${CYAN}ℹ${NC}  $1"; }
header(){ echo -e "\n${BOLD}${BLUE}── $1 ──${NC}"; }

# =============================================================================
echo -e "\n${BOLD}Helmsman Sanity Check${NC} — $(date '+%Y-%m-%d %H:%M:%S')"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# =============================================================================
header "1. Docker"
# =============================================================================

if docker info > /dev/null 2>&1; then
    DOCKER_OS=$(docker info 2>/dev/null | grep -i "operating system" | awk -F': ' '{print $2}' || echo "unknown")
    ok "Docker accessible — $DOCKER_OS"
else
    fail "Docker not accessible from WSL2"
    echo ""
    echo -e "  ${YELLOW}FIX:${NC} Open Docker Desktop on Windows."
    echo -e "       Settings → Resources → WSL Integration → Enable Ubuntu → Apply & Restart."
    echo -e "       Wait ~30 seconds then re-run this script."
    echo ""
    exit 1
fi

# =============================================================================
header "2. Kind Cluster Containers"
# =============================================================================

HUB_CONTAINER="helmsman-hub-control-plane"

for CONTAINER in "$HUB_CONTAINER" "$SPOKE_CONTAINER"; do
    STATUS=$(docker inspect "$CONTAINER" --format='{{.State.Status}}' 2>/dev/null || echo "not_found")
    case "$STATUS" in
        running) ok "Container $CONTAINER is running" ;;
        exited|stopped)
            fix "Container $CONTAINER is stopped — starting..."
            docker start "$CONTAINER" > /dev/null 2>&1 || true
            sleep 5
            NEW_STATUS=$(docker inspect "$CONTAINER" --format='{{.State.Status}}' 2>/dev/null || echo "unknown")
            if [ "$NEW_STATUS" = "running" ]; then
                ok "Container $CONTAINER started successfully"
            else
                fail "Container $CONTAINER failed to start (status: $NEW_STATUS)"
            fi
            ;;
        not_found)
            fail "Container $CONTAINER not found — kind cluster may not exist"
            echo -e "  ${YELLOW}FIX:${NC} cd ~/projects/helmsman/clusters && kind create cluster --config hub-cluster.yaml"
            ;;
        *) fail "Container $CONTAINER in unexpected state: $STATUS" ;;
    esac
done

# Give clusters a moment to be fully ready after potential restart
sleep 3

# =============================================================================
header "3. kubectl Connectivity"
# =============================================================================

if kubectl get nodes --context "$HUB_CONTEXT" > /dev/null 2>&1; then
    NODE_COUNT=$(kubectl get nodes --context "$HUB_CONTEXT" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    ok "Hub cluster reachable — $NODE_COUNT nodes"
else
    fail "Hub cluster not reachable via kubectl"
    echo -e "  ${YELLOW}FIX:${NC} Wait 30 seconds for cluster to finish restarting, then re-run this script."
    exit 1
fi

if kubectl get nodes --context "$SPOKE_CONTEXT" > /dev/null 2>&1; then
    NODE_COUNT=$(kubectl get nodes --context "$SPOKE_CONTEXT" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    ok "Spoke cluster reachable — $NODE_COUNT nodes"
else
    fail "Spoke cluster not reachable via kubectl"
    exit 1
fi

# =============================================================================
header "4. Spoke IP Drift Check and Fix"
# =============================================================================
#
# Why this check exists:
# When Docker Desktop restarts, kind cluster containers restart and the Docker
# bridge network may reassign IPs. The Argo CD cluster Secret stores the spoke's
# IP as its API server URL. If the IP changes, Argo CD loses connectivity.
# This check detects and fixes that mismatch automatically.

SPOKE_IP=$(docker inspect "$SPOKE_CONTAINER" \
    --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)

if [ -z "$SPOKE_IP" ]; then
    fail "Could not determine spoke Docker bridge IP"
    exit 1
fi

info "Current spoke Docker bridge IP: $SPOKE_IP"

# Read what Argo CD currently has stored
STORED_SERVER=$(kubectl get secret "$CLUSTER_SECRET_NAME" \
    -n "$ARGOCD_NAMESPACE" \
    --context "$HUB_CONTEXT" \
    -o jsonpath='{.data.server}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

EXPECTED_SERVER="https://${SPOKE_IP}:6443"

if [ "$STORED_SERVER" = "$EXPECTED_SERVER" ]; then
    ok "Cluster Secret IP is current ($SPOKE_IP) — no update needed"
else
    fix "IP mismatch detected — Stored: $STORED_SERVER | Current: $EXPECTED_SERVER"
    fix "Re-extracting ServiceAccount token and updating cluster Secret..."

    SPOKE_TOKEN=$(kubectl --context "$SPOKE_CONTEXT" \
        get secret argocd-manager-token \
        -n kube-system \
        -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)

    if [ -z "$SPOKE_TOKEN" ]; then
        fail "Could not extract argocd-manager-token from spoke — was Phase 0 step 0.7 completed?"
        exit 1
    fi

    kubectl delete secret "$CLUSTER_SECRET_NAME" \
        -n "$ARGOCD_NAMESPACE" \
        --context "$HUB_CONTEXT" > /dev/null 2>&1 || true

    kubectl apply --context "$HUB_CONTEXT" -f - > /dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${CLUSTER_SECRET_NAME}
  namespace: ${ARGOCD_NAMESPACE}
  labels:
    argocd.argoproj.io/secret-type: cluster
    platform-enabled: "true"
type: Opaque
stringData:
  name: ${CLUSTER_REGISTERED_NAME}
  server: https://${SPOKE_IP}:6443
  config: |
    {
      "bearerToken": "${SPOKE_TOKEN}",
      "tlsClientConfig": {
        "insecure": true
      }
    }
EOF
    ok "Cluster Secret updated — new server: https://${SPOKE_IP}:6443"
    info "Waiting 10s for Argo CD to detect the update..."
    sleep 10
fi

# =============================================================================
header "5. Argo CD CLI Login"
# =============================================================================
#
# Argo CD CLI sessions expire after 24 hours by default.
# Re-logging in is idempotent — safe to do on every run.

if argocd login "$ARGOCD_URL" \
    --username "$ARGOCD_USER" \
    --password "$ARGOCD_PASS" \
    --insecure > /dev/null 2>&1; then
    ok "Argo CD CLI session refreshed"
else
    fail "Argo CD CLI login failed — is the Hub cluster running and NodePort reachable?"
    echo -e "  ${YELLOW}FIX:${NC} kubectl get svc argocd-server -n argocd --context $HUB_CONTEXT"
    echo -e "       Confirm TYPE is NodePort and port 30080 is listed."
fi

# =============================================================================
header "6. Argo CD Cluster Connectivity"
# =============================================================================

sleep 5  # Give Argo CD a moment to reconnect after potential Secret update

CLUSTER_STATUS=$(argocd cluster list 2>/dev/null \
    | grep "$CLUSTER_REGISTERED_NAME" \
    | awk '{print $4}' || echo "unknown")

CLUSTER_VERSION=$(argocd cluster list 2>/dev/null \
    | grep "$CLUSTER_REGISTERED_NAME" \
    | awk '{print $3}' || echo "")

if [ "$CLUSTER_STATUS" = "Successful" ]; then
    ok "Argo CD → spoke connectivity: Successful (Kubernetes $CLUSTER_VERSION)"
elif [ "$CLUSTER_STATUS" = "Unknown" ]; then
    info "Spoke cluster status Unknown — Argo CD may still be reconnecting"
    info "Run 'argocd cluster list' in ~30 seconds to confirm"
    ((PASS++))
else
    fail "Spoke cluster status: $CLUSTER_STATUS — check 'argocd cluster list' for details"
fi

# =============================================================================
header "7. Argo CD Application Status"
# =============================================================================

APP_LIST=$(argocd app list 2>/dev/null || echo "")

if [ -z "$APP_LIST" ]; then
    info "No Argo CD applications found"
else
    echo "$APP_LIST" | tail -n +2 | while IFS= read -r line; do
        APP_NAME=$(echo "$line" | awk '{print $1}' | sed 's|argocd/||')
        SYNC=$(echo "$line"    | awk '{print $5}')
        HEALTH=$(echo "$line"  | awk '{print $6}')
        CONDITIONS=$(echo "$line" | awk '{print $9}')

        if [ "$SYNC" = "Synced" ] && [ "$HEALTH" = "Healthy" ]; then
            ok "App: $APP_NAME — Synced / Healthy"
        elif [ "$SYNC" = "Synced" ] && [ "$HEALTH" = "Progressing" ]; then
            info "App: $APP_NAME — Synced / Progressing (pods still starting)"
        elif echo "$CONDITIONS" | grep -q "ComparisonError"; then
            fail "App: $APP_NAME — $SYNC / $HEALTH (ComparisonError — likely stale cluster IP, re-run this script)"
        else
            fail "App: $APP_NAME — $SYNC / $HEALTH"
        fi
    done
fi

# =============================================================================
header "8. Spoke Workload Status"
# =============================================================================

NAMESPACES=$(kubectl get namespaces --context "$SPOKE_CONTEXT" \
    --no-headers -o custom-columns=":metadata.name" 2>/dev/null \
    | grep -v "^kube-\|^default\|^local-path" || echo "")

if [ -z "$NAMESPACES" ]; then
    info "No application namespaces found on spoke cluster"
else
    for NS in $NAMESPACES; do
        PODS=$(kubectl get pods -n "$NS" --context "$SPOKE_CONTEXT" \
            --no-headers 2>/dev/null || echo "")

        if [ -z "$PODS" ]; then
            info "Namespace $NS — no pods"
            continue
        fi

        while IFS= read -r pod_line; do
            POD_NAME=$(echo "$pod_line"  | awk '{print $1}')
            READY=$(echo "$pod_line"     | awk '{print $2}')
            STATUS=$(echo "$pod_line"    | awk '{print $3}')
            RESTARTS=$(echo "$pod_line"  | awk '{print $4}')

            if [ "$STATUS" = "Running" ]; then
                if [ "$RESTARTS" -gt 5 ] 2>/dev/null; then
                    fail "Pod $NS/$POD_NAME — Running $READY but high restarts ($RESTARTS)"
                else
                    ok "Pod $NS/$POD_NAME — Running $READY (restarts: $RESTARTS)"
                fi
            elif [ "$STATUS" = "Pending" ]; then
                info "Pod $NS/$POD_NAME — Pending (may still be starting)"
            else
                fail "Pod $NS/$POD_NAME — $STATUS $READY (restarts: $RESTARTS)"
            fi
        done <<< "$PODS"
    done
fi

# =============================================================================
header "Summary"
# =============================================================================

TOTAL=$((PASS + FAIL))
echo ""
echo -e "  ${GREEN}✔ Passed:${NC}  $PASS"
[ "$FIXED" -gt 0 ] && echo -e "  ${YELLOW}⚙ Fixed:${NC}   $FIXED"
[ "$FAIL" -gt 0 ]  && echo -e "  ${RED}✘ Failed:${NC}  $FAIL"
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}All checks passed. Helmsman environment is healthy.${NC}"
    echo ""
    echo -e "  ${CYAN}Useful commands:${NC}"
    echo -e "    argocd app list"
    echo -e "    kubectl get all -n sample-app --context $SPOKE_CONTEXT"
    echo -e "    kubectl logs -n sample-app sample-app-0 -c fluent-bit --context $SPOKE_CONTEXT"
    echo ""
    exit 0
else
    echo -e "  ${RED}${BOLD}$FAIL check(s) failed. Review the output above.${NC}"
    echo ""
    exit 1
fi