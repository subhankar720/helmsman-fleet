#!/bin/bash
# =============================================================================
# helmsman-sanity.sh — v9
# Helmsman Local Dev Environment — Read-Only Sanity / Status Report
# =============================================================================
#
# PURPOSE
# -------
# This script ONLY inspects and reports. It never restarts containers,
# patches secrets, syncs Argo CD apps, or deletes pods. If something is
# broken, this script tells you what and why — then you run
# ./dev-up-gemini.sh (recovery mode, or --reset if needed) from
# helmsman-operator/ to actually fix it.
#
# WHEN TO RUN THIS SCRIPT
# -----------------------
# Run at the START OF EVERY DEV SESSION, or after any Docker Desktop restart,
# to see what state the environment is in before deciding whether to run
# dev-up-gemini.sh.
#
# WHAT BREAKS WHEN DOCKER DESKTOP RESTARTS (in order) — this script detects
# each of these, dev-up-gemini.sh fixes them
# ----------------------------------------------------
# 1. kube-proxy   → iptables rules wiped → ClusterIP TCP + NodePort broken
# 2. CoreDNS      → UDP conntrack stale  → DNS resolution times out
# 3. argocd-redis → stale connection pool
# 4. argocd-server→ can't reach Redis → resets all connections
# 5. argocd-applicationset-controller → can't resolve DNS
# 6. Spoke cluster IP → Docker bridge reassigns IPs → cluster Secret stale
# 7. Applications → destination.server has old IP → InvalidSpecError
# 8. platform-spoke-promtail → applied directly (no app-of-apps), so its
#    hardcoded clients.url/destination.server go stale on IP drift too
#
# REPORT ORDER
# ------------
# A: Docker check
# B: Kind container status
# C: Hub node IP consistency
# D: Network health (kube-proxy + CoreDNS + connectivity)
# E: Argo CD component health
# F: Spoke IP drift check
# F.1: Hub HTTP endpoint secret / OIDC / Vault reachability for spoke apps
# F.2: Promtail (Spoke) Loki IP drift check
# D.1: Spoke cluster internal connectivity
# G: Argo CD CLI login (read-only diagnostic session)
# H: Argo CD cluster and app status
# I: Spoke workload status
# =============================================================================

set -uo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
ARGOCD_URL="localhost:9090"
ARGOCD_USER="admin"

# Password resolution order: explicit env var > durable password file written
# by dev-up-gemini.sh > argocd-initial-admin-secret (only exists right after a
# fresh --reset, before dev-up-gemini.sh deletes it).
ARGOCD_PASS_FILE="${ARGOCD_PASS_FILE:-$HOME/.helmsman-dev/argocd-admin-password}"
ARGOCD_PASS="${ARGOCD_PASS:-}"
if [ -z "$ARGOCD_PASS" ] && [ -f "$ARGOCD_PASS_FILE" ]; then
    ARGOCD_PASS=$(cat "$ARGOCD_PASS_FILE" 2>/dev/null || echo "")
fi
if [ -z "$ARGOCD_PASS" ]; then
    ARGOCD_PASS=$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
fi

HUB_CONTEXT="kind-helmsman-hub"
SPOKE_CONTEXT="kind-helmsman-onprem"
SPOKE_CONTAINER="helmsman-onprem-control-plane"
HUB_CONTAINER="helmsman-hub-control-plane"
HUB_WORKER_CONTAINER="helmsman-hub-worker"
CLUSTER_SECRET_NAME="cluster-helmsman-onprem"
CLUSTER_REGISTERED_NAME="helmsman-onprem"
ARGOCD_NAMESPACE="argocd"
SAMPLE_APP_APP_NAME="sample-app-helmsman-onprem"
SAMPLE_APP_NAMESPACE="sample-app"
SAMPLE_APP_EXTERNAL_SECRET="sample-app-oidc"
SAMPLE_APP_SERVICE_NAME="sample-app"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

PASS=0; FAIL=0; WARN=0
ok()    { echo -e "  ${GREEN}✔${NC}  $1"; ((PASS++)); }
fail()  { echo -e "  ${RED}✘${NC}  $1"; ((FAIL++)); }
warn()  { echo -e "  ${YELLOW}⚠${NC}  $1"; ((WARN++)); }
info()  { echo -e "  ${CYAN}ℹ${NC}  $1"; }
header(){ echo -e "\n${BOLD}${BLUE}── $1 ──${NC}"; }

echo -e "\n${BOLD}Helmsman Sanity Report${NC} — $(date '+%Y-%m-%d %H:%M:%S')"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

RECOVER_HINT="  ${YELLOW}→ Fix with:${NC} cd ~/projects/helmsman/helmsman-operator && ./dev-up-gemini.sh"

# =============================================================================
header "A. Docker"
# =============================================================================
if ! docker info > /dev/null 2>&1; then
    fail "Docker not accessible from WSL2"
    echo -e "  ${YELLOW}FIX:${NC} Docker Desktop → Settings → Resources → WSL Integration → Enable Ubuntu"
    exit 1
fi
DOCKER_OS=$(docker info 2>/dev/null | grep -i "operating system" | awk -F': ' '{print $2}')
ok "Docker accessible — ${DOCKER_OS}"

# =============================================================================
header "B. Kind Cluster Containers"
# =============================================================================
RECENT_RESTART_DETECTED=false
CONTAINERS_DOWN=false

for CONTAINER in "$HUB_CONTAINER" "$SPOKE_CONTAINER"; do
    STATUS=$(docker inspect "$CONTAINER" --format='{{.State.Status}}' 2>/dev/null || echo "not_found")
    case "$STATUS" in
        running)
            STARTED=$(docker inspect "$CONTAINER" --format='{{.State.StartedAt}}' 2>/dev/null || echo "")
            STARTED_EPOCH=$(date -d "$STARTED" +%s 2>/dev/null || echo "0")
            NOW_EPOCH=$(date +%s)
            AGE_SECS=$(( NOW_EPOCH - STARTED_EPOCH ))
            if [ "$AGE_SECS" -lt 600 ] 2>/dev/null; then
                warn "Container $CONTAINER started recently (${AGE_SECS}s ago) — Docker/Kind likely restarted, network state may be stale"
                RECENT_RESTART_DETECTED=true
            else
                ok "Container $CONTAINER running (up ${AGE_SECS}s)"
            fi
            ;;
        exited|stopped|created)
            fail "Container $CONTAINER is $STATUS (not running)"
            CONTAINERS_DOWN=true
            ;;
        not_found)
            fail "Container $CONTAINER not found"
            echo -e "  ${YELLOW}FIX:${NC} cd ~/projects/helmsman/helmsman-operator && ./dev-up-gemini.sh --reset"
            CONTAINERS_DOWN=true
            ;;
        *) fail "Container $CONTAINER: unexpected state '$STATUS'" ;;
    esac
done

if [ "$CONTAINERS_DOWN" = true ]; then
    echo ""
    echo -e "$RECOVER_HINT"
    echo ""
    echo -e "  ${RED}${BOLD}Cannot continue — Kind containers are not all running.${NC}"
    exit 1
fi

# =============================================================================
header "C. Hub Node IP Consistency (kubelet registration check)"
# =============================================================================
# kubectl exec and port-forward fail with "Unauthorized" when the API server
# cannot reach the kubelet. This happens when node InternalIPs in etcd don't
# match the actual Docker bridge IPs (common after multiple Docker restarts).

NODE_IP_DRIFT=false
while IFS= read -r node_line; do
    NODE_NAME=$(echo "$node_line" | awk '{print $1}')
    NODE_IP=$(echo "$node_line"   | awk '{print $6}')
    CONTAINER_NAME="helmsman-hub-${NODE_NAME##helmsman-hub-}"
    CONTAINER_IP=$(docker inspect "$CONTAINER_NAME" \
        --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null || echo "")
    if [ -z "$CONTAINER_IP" ]; then
        continue
    fi
    if [ "$NODE_IP" != "$CONTAINER_IP" ]; then
        warn "Node $NODE_NAME IP mismatch: etcd=$NODE_IP actual=$CONTAINER_IP — kubelet needs re-registration (restart worker containers)"
        NODE_IP_DRIFT=true
    else
        ok "Node $NODE_NAME IP consistent: $NODE_IP"
    fi
done < <(kubectl get nodes -o wide --context "$HUB_CONTEXT" \
    --no-headers 2>/dev/null | grep -v "control-plane")

if kubectl get nodes --context "$HUB_CONTEXT" > /dev/null 2>&1; then
    N=$(kubectl get nodes --context "$HUB_CONTEXT" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    ok "Hub cluster reachable — $N nodes"
else
    fail "Hub cluster not reachable — wait 30s and re-run"
    exit 1
fi

if kubectl get nodes --context "$SPOKE_CONTEXT" > /dev/null 2>&1; then
    N=$(kubectl get nodes --context "$SPOKE_CONTEXT" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    ok "Spoke cluster reachable — $N nodes"
else
    fail "Spoke cluster not reachable — wait 30s and re-run"
    exit 1
fi

SPOKE_IP=$(docker inspect "$SPOKE_CONTAINER" \
    --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null || echo "")
if [ -z "$SPOKE_IP" ]; then
    fail "Cannot determine spoke Docker bridge IP"
    exit 1
fi
info "Current spoke Docker bridge IP: $SPOKE_IP"

# Consistent Hub IP definition used everywhere below — matches what
# dev-up-gemini.sh actually configures (worker IP, falling back to
# control-plane), so this report checks against the same value the fixer uses.
HUB_IP=$(docker inspect "$HUB_WORKER_CONTAINER" \
    --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null || echo "")
if [ -z "$HUB_IP" ]; then
    HUB_IP=$(docker inspect "$HUB_CONTAINER" \
        --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null || echo "")
fi
info "Current hub IP (worker, fallback control-plane): ${HUB_IP:-unknown}"

# =============================================================================
header "D. Network Health (kube-proxy + CoreDNS)"
# =============================================================================
COREDNS_READY=$(kubectl get pods -n kube-system --context "$HUB_CONTEXT" \
    -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -c "Running" || echo "0")
COREDNS_READY=$(echo "$COREDNS_READY" | tr -d '[:space:]')

NETWORK_SUSPECT=false
if [ "$RECENT_RESTART_DETECTED" = true ]; then
    NETWORK_SUSPECT=true
    info "Containers recently restarted — network state may be stale, running full connectivity checks"
elif [ "${COREDNS_READY:-0}" -lt 1 ] 2>/dev/null; then
    NETWORK_SUSPECT=true
    warn "CoreDNS pods not Running"
else
    ok "CoreDNS pods Running"
fi

for POD_LABEL in "app.kubernetes.io/name=argocd-application-controller" "app.kubernetes.io/name=argocd-server"; do
    SERVICE_TEST_POD=$(kubectl get pod -n argocd --context "$HUB_CONTEXT" \
        -l $POD_LABEL -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -z "$SERVICE_TEST_POD" ]; then
        info "No pod found for $POD_LABEL"
        continue
    fi

    if kubectl exec -n argocd --context "$HUB_CONTEXT" "$SERVICE_TEST_POD" -- \
        bash -lc 'exec 3<>/dev/tcp/argocd-repo-server/8081 >/dev/null 2>&1' \
        > /dev/null 2>&1; then
        ok "argocd-repo-server reachable from $SERVICE_TEST_POD"
    else
        fail "Cannot reach argocd-repo-server:8081 from $SERVICE_TEST_POD — kube-proxy/ClusterIP likely broken"
    fi

    if kubectl exec -n argocd --context "$HUB_CONTEXT" "$SERVICE_TEST_POD" -- \
        bash -lc 'exec 3<>/dev/tcp/10.96.0.1/443 >/dev/null 2>&1' \
        > /dev/null 2>&1; then
        ok "Kubernetes API service reachable from $SERVICE_TEST_POD"
    else
        fail "Kubernetes API service 10.96.0.1:443 unreachable from $SERVICE_TEST_POD"
    fi

    if [ -n "$SPOKE_IP" ]; then
        if kubectl exec -n argocd --context "$HUB_CONTEXT" "$SERVICE_TEST_POD" -- \
            bash -lc "exec 3<>/dev/tcp/${SPOKE_IP}/6443 >/dev/null 2>&1" \
            > /dev/null 2>&1; then
            ok "Spoke cluster $SPOKE_IP:6443 reachable from $SERVICE_TEST_POD"
        else
            NODE_NAME=$(kubectl get pod -n argocd --context "$HUB_CONTEXT" "$SERVICE_TEST_POD" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")
            fail "Spoke cluster $SPOKE_IP:6443 unreachable from $SERVICE_TEST_POD on node $NODE_NAME"
        fi
    fi
done

# =============================================================================
header "E. Argo CD Component Health"
# =============================================================================
for NAME in argocd-redis argocd-repo-server argocd-server argocd-applicationset-controller; do
    READY=$(kubectl get pods -n argocd --context "$HUB_CONTEXT" \
        -l "app.kubernetes.io/name=$NAME" --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    READY=$(echo "$READY" | tr -d '[:space:]')
    if [ "${READY:-0}" -ge 1 ] 2>/dev/null; then
        ok "$NAME Running"
    else
        fail "$NAME not Running"
    fi
done
READY=$(kubectl get pods -n argocd --context "$HUB_CONTEXT" \
    -l "app.kubernetes.io/name=argocd-application-controller" --no-headers 2>/dev/null | grep -c "Running" || echo "0")
READY=$(echo "$READY" | tr -d '[:space:]')
if [ "${READY:-0}" -ge 1 ] 2>/dev/null; then
    ok "argocd-application-controller Running"
else
    fail "argocd-application-controller not Running"
fi

# =============================================================================
header "F. Spoke IP Drift Check"
# =============================================================================
STORED_SERVER=$(kubectl get secret "$CLUSTER_SECRET_NAME" \
    -n "$ARGOCD_NAMESPACE" --context "$HUB_CONTEXT" \
    -o jsonpath='{.data.server}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

EXPECTED_SERVER="https://${SPOKE_IP}:6443"

if [ "$STORED_SERVER" = "$EXPECTED_SERVER" ]; then
    ok "Cluster Secret IP current ($SPOKE_IP)"
else
    warn "Cluster Secret IP drift: $STORED_SERVER → $EXPECTED_SERVER"
fi

OLD_IP=$(echo "$STORED_SERVER" | sed 's|https://||' | cut -d: -f1)
STALE_APPS=$(kubectl get applications -n argocd \
    --context "$HUB_CONTEXT" \
    -o jsonpath="{range .items[?(@.spec.destination.server=='https://${OLD_IP}:6443')]}{.metadata.name}{'\n'}{end}" \
    2>/dev/null || echo "")
if [ -n "$STALE_APPS" ] && [ "$STORED_SERVER" != "$EXPECTED_SERVER" ]; then
    for APP in $STALE_APPS; do
        warn "Application $APP still targets stale destination https://${OLD_IP}:6443"
    done
else
    ok "No Applications targeting a stale spoke IP"
fi

# =============================================================================
header "F.1 Hub HTTP endpoint secret for spoke applications"
# =============================================================================
if [ -n "$HUB_IP" ]; then
    EXPECTED_KEYCLOAK_URL="http://${HUB_IP}:30081"
    EXPECTED_VAULT_URL="http://${HUB_IP}:30082"
    EXPECTED_KEYCLOAK_REALM="helmsman"
    EXPECTED_ISSUER_URL="${EXPECTED_KEYCLOAK_URL}/realms/${EXPECTED_KEYCLOAK_REALM}"

    if kubectl --context "$SPOKE_CONTEXT" -n sample-app get secret helmsman-platform-config > /dev/null 2>&1; then
        ACTUAL_KEYCLOAK_URL=$(kubectl --context "$SPOKE_CONTEXT" -n sample-app get secret helmsman-platform-config -o jsonpath='{.data.keycloak-url}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
        ACTUAL_VAULT_URL=$(kubectl --context "$SPOKE_CONTEXT" -n sample-app get secret helmsman-platform-config -o jsonpath='{.data.vault-url}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
        if [ "$ACTUAL_KEYCLOAK_URL" = "$EXPECTED_KEYCLOAK_URL" ] && [ "$ACTUAL_VAULT_URL" = "$EXPECTED_VAULT_URL" ]; then
            ok "helmsman-platform-config current (keycloak-url=$ACTUAL_KEYCLOAK_URL, vault-url=$ACTUAL_VAULT_URL)"
        else
            warn "helmsman-platform-config stale: got keycloak-url=$ACTUAL_KEYCLOAK_URL vault-url=$ACTUAL_VAULT_URL, expected keycloak-url=$EXPECTED_KEYCLOAK_URL vault-url=$EXPECTED_VAULT_URL"
        fi
    else
        fail "helmsman-platform-config secret missing in sample-app namespace"
    fi

    if kubectl --context "$SPOKE_CONTEXT" -n sample-app get secret sample-app-oidc > /dev/null 2>&1; then
        CURRENT_ISSUER_URL=$(kubectl --context "$SPOKE_CONTEXT" -n sample-app get secret sample-app-oidc -o jsonpath='{.data.issuer-url}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
        if [ "$CURRENT_ISSUER_URL" = "$EXPECTED_ISSUER_URL" ]; then
            ok "sample-app-oidc issuer-url current ($CURRENT_ISSUER_URL)"
        else
            warn "sample-app-oidc issuer-url stale: got $CURRENT_ISSUER_URL, expected $EXPECTED_ISSUER_URL"
        fi
    else
        fail "sample-app-oidc secret missing in sample-app namespace"
    fi

    if kubectl --context "$SPOKE_CONTEXT" -n "$SAMPLE_APP_NAMESPACE" get externalsecret "$SAMPLE_APP_EXTERNAL_SECRET" > /dev/null 2>&1; then
        ES_READY=$(kubectl --context "$SPOKE_CONTEXT" -n "$SAMPLE_APP_NAMESPACE" get externalsecret "$SAMPLE_APP_EXTERNAL_SECRET" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
        if [ "$ES_READY" = "True" ]; then
            ok "ExternalSecret $SAMPLE_APP_EXTERNAL_SECRET is Ready"
        else
            fail "ExternalSecret $SAMPLE_APP_EXTERNAL_SECRET is not Ready"
        fi
    else
        fail "ExternalSecret $SAMPLE_APP_EXTERNAL_SECRET is missing in $SAMPLE_APP_NAMESPACE namespace"
    fi

    if kubectl --context "$SPOKE_CONTEXT" -n "$SAMPLE_APP_NAMESPACE" get secret "$SAMPLE_APP_EXTERNAL_SECRET" > /dev/null 2>&1; then
        SECRET_KEYS=$(kubectl --context "$SPOKE_CONTEXT" -n "$SAMPLE_APP_NAMESPACE" get secret "$SAMPLE_APP_EXTERNAL_SECRET" -o jsonpath='{.data}' 2>/dev/null || echo "")
        if echo "$SECRET_KEYS" | grep -q 'cookie-secret'; then
            ok "Secret $SAMPLE_APP_EXTERNAL_SECRET contains cookie-secret"
        else
            fail "Secret $SAMPLE_APP_EXTERNAL_SECRET exists but cookie-secret is missing"
        fi
    else
        fail "Secret $SAMPLE_APP_EXTERNAL_SECRET is missing in $SAMPLE_APP_NAMESPACE namespace"
    fi

    if kubectl --context "$SPOKE_CONTEXT" -n "$SAMPLE_APP_NAMESPACE" get svc "$SAMPLE_APP_SERVICE_NAME" > /dev/null 2>&1; then
        SERVICE_PORT=$(kubectl --context "$SPOKE_CONTEXT" -n "$SAMPLE_APP_NAMESPACE" get svc "$SAMPLE_APP_SERVICE_NAME" -o jsonpath='{.spec.ports[0].targetPort}' 2>/dev/null || echo "")
        if [ "$SERVICE_PORT" = "4180" ]; then
            ok "sample-app Service targetPort is 4180 for OIDC sidecar"
        else
            fail "sample-app Service targetPort is not 4180 (got: $SERVICE_PORT)"
        fi
        kubectl --context "$SPOKE_CONTEXT" -n "$SAMPLE_APP_NAMESPACE" delete pod sample-app-probe --ignore-not-found > /dev/null 2>&1 || true
        if kubectl --context "$SPOKE_CONTEXT" -n "$SAMPLE_APP_NAMESPACE" run --quiet --rm -i --restart=Never sample-app-probe --image=curlimages/curl:latest -- sh -c "curl -fsS --max-time 5 http://$SAMPLE_APP_SERVICE_NAME:80/ping" > /dev/null 2>&1; then
            ok "OIDC sidecar /ping endpoint reachable through sample-app service"
        else
            fail "OIDC sidecar /ping endpoint not reachable through sample-app service"
        fi
    else
        fail "Service $SAMPLE_APP_SERVICE_NAME is missing in $SAMPLE_APP_NAMESPACE namespace"
    fi

    kubectl --context "$SPOKE_CONTEXT" -n default delete pod vault-keycloak-check --ignore-not-found > /dev/null 2>&1 || true
    if kubectl --context "$SPOKE_CONTEXT" -n default run --quiet --rm -i --restart=Never vault-keycloak-check --image=curlimages/curl:latest -- sh -c "curl -fsS --max-time 5 -o /dev/null -w '%{http_code}' http://${HUB_IP}:30081" 2>/dev/null | grep -Eq '^[23][0-9][0-9]$'; then
        ok "Keycloak HTTP endpoint reachable from spoke at http://${HUB_IP}:30081"
    else
        fail "Keycloak http://${HUB_IP}:30081 not reachable from spoke"
    fi

    # --- Check that the ClusterSecretStore's Vault server is actually reachable ---
    CSS_SERVER=$(kubectl --context "$SPOKE_CONTEXT" get clustersecretstore vault-backend -o jsonpath='{.spec.provider.vault.server}' 2>/dev/null || echo "")
    EXPECTED_VAULT_NODEPORT_URL="http://${HUB_IP}:30082"
    kubectl --context "$SPOKE_CONTEXT" -n sample-app delete pod vault-check --ignore-not-found > /dev/null 2>&1 || true
    if [ -z "$CSS_SERVER" ]; then
        fail "ClusterSecretStore 'vault-backend' not found in spoke cluster"
    else
        if kubectl --context "$SPOKE_CONTEXT" -n sample-app run --quiet --rm -i --restart=Never vault-check --image=curlimages/curl:latest -- sh -c "curl -fsS --max-time 5 ${CSS_SERVER}/v1/sys/health" > /dev/null 2>&1; then
            ok "ClusterSecretStore vault-backend server ($CSS_SERVER) reachable from spoke"
        else
            fail "ClusterSecretStore vault-backend server ($CSS_SERVER) NOT reachable from spoke (expected $EXPECTED_VAULT_NODEPORT_URL)"
        fi
        READY=$(kubectl --context "$SPOKE_CONTEXT" get clustersecretstore vault-backend -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
        if [ "$READY" = "True" ]; then
            ok "ClusterSecretStore 'vault-backend' is Ready"
        else
            fail "ClusterSecretStore 'vault-backend' is not Ready"
        fi
        if [ "$CSS_SERVER" != "$EXPECTED_VAULT_NODEPORT_URL" ]; then
            warn "ClusterSecretStore vault-backend server ($CSS_SERVER) differs from the Hub IP this report uses ($EXPECTED_VAULT_NODEPORT_URL) — may still be valid if that IP is reachable"
        fi
    fi
else
    fail "Could not determine Hub container IP; skipping helmsman-platform-config checks"
fi

# =============================================================================
header "F.2 Promtail (Spoke) Loki IP Drift Check"
# =============================================================================
# platform-spoke-promtail is applied directly with `kubectl apply` (not via an
# app-of-apps), so unlike Applications synced from git, a stale clients.url or
# destination.server here will NOT self-heal from a `git push` alone — it
# needs dev-up-gemini.sh's Stage 7.5 (or a manual re-apply) to pick up a new
# HUB_IP/SPOKE_IP.
if [ -n "$HUB_IP" ]; then
    PROMTAIL_VALUES=$(kubectl --context "$HUB_CONTEXT" -n argocd get application platform-spoke-promtail \
        -o jsonpath='{.spec.source.helm.values}' 2>/dev/null || echo "")
    EXPECTED_LOKI_CLIENT_URL="http://${HUB_IP}:30031/loki/api/v1/push"
    if [ -z "$PROMTAIL_VALUES" ]; then
        fail "Application platform-spoke-promtail not found (or has no helm values) in argocd namespace"
    elif echo "$PROMTAIL_VALUES" | grep -qF "$EXPECTED_LOKI_CLIENT_URL"; then
        ok "platform-spoke-promtail clients.url current ($EXPECTED_LOKI_CLIENT_URL)"
    else
        ACTUAL_LOKI_CLIENT_URL=$(echo "$PROMTAIL_VALUES" | grep -o 'http://[^ ]*/loki/api/v1/push' | head -1)
        warn "platform-spoke-promtail clients.url stale: got ${ACTUAL_LOKI_CLIENT_URL:-<none found>}, expected $EXPECTED_LOKI_CLIENT_URL"
    fi

    PROMTAIL_DEST_SERVER=$(kubectl --context "$HUB_CONTEXT" -n argocd get application platform-spoke-promtail \
        -o jsonpath='{.spec.destination.server}' 2>/dev/null || echo "")
    EXPECTED_PROMTAIL_DEST="https://${SPOKE_IP}:6443"
    if [ "$PROMTAIL_DEST_SERVER" = "$EXPECTED_PROMTAIL_DEST" ]; then
        ok "platform-spoke-promtail destination.server current ($EXPECTED_PROMTAIL_DEST)"
    else
        warn "platform-spoke-promtail destination.server stale: got ${PROMTAIL_DEST_SERVER:-<none>}, expected $EXPECTED_PROMTAIL_DEST"
    fi

    PROMTAIL_DS_HOSTNET=$(kubectl --context "$SPOKE_CONTEXT" -n monitoring get daemonset platform-spoke-promtail \
        -o jsonpath='{.spec.template.spec.hostNetwork}' 2>/dev/null || echo "")
    if [ "$PROMTAIL_DS_HOSTNET" = "true" ]; then
        ok "platform-spoke-promtail DaemonSet has hostNetwork=true"
    else
        fail "platform-spoke-promtail DaemonSet missing hostNetwork=true (got: ${PROMTAIL_DS_HOSTNET:-<not found>}) — pod network cannot reach Hub Docker bridge IPs"
    fi
else
    fail "Could not determine Hub container IP; skipping Promtail Loki IP drift checks"
fi

# =============================================================================
header "D.1 Spoke Cluster Network Recovery"
# =============================================================================
SPOKE_NET_CHECK_POD="spoke-network-check"
SPOKE_NET_CHECK_IP="10.96.0.1"

kubectl --context "$SPOKE_CONTEXT" -n default delete pod "$SPOKE_NET_CHECK_POD" --ignore-not-found > /dev/null 2>&1 || true
STATUS=$(kubectl --context "$SPOKE_CONTEXT" -n default run --quiet --rm -i --restart=Never "$SPOKE_NET_CHECK_POD" \
    --image=curlimages/curl:latest -- sh -c "curl --max-time 5 --insecure -o /dev/null -s -w '%{http_code}' https://${SPOKE_NET_CHECK_IP}:443" 2>/dev/null || echo "000")
if [ -n "$STATUS" ] && [ "$STATUS" != "000" ]; then
    ok "Spoke cluster internal service connectivity OK"
else
    fail "Spoke ClusterIP network broken (kube-proxy/kindnet on spoke may need a restart)"
fi

# =============================================================================
header "G. Argo CD CLI Login"
# =============================================================================
# Uses a plain `kubectl port-forward` to a local port, then `argocd login
# localhost:<port>`. The native `argocd login --port-forward` mode was tried
# first but its --kube-context flag is not honored by ANY argocd subcommand
# in this CLI version (login, app list, cluster list all silently fall back
# to the current kubectl context) — this manual tunnel is what
# dev-up-gemini.sh already uses successfully, so we mirror it here.
# Read-only diagnostic session — nothing is synced or refreshed.

ARGOCD_PF_PORT="9091"
pkill -f "port-forward.*${ARGOCD_PF_PORT}" 2>/dev/null || true
sleep 1

if [ -z "$ARGOCD_PASS" ]; then
    warn "No Argo CD admin password available (checked \$ARGOCD_PASS, $ARGOCD_PASS_FILE, argocd-initial-admin-secret)"
fi

ARGOCD_USER="${ARGOCD_USER:-admin}"
ARGOCD_SERVER="localhost:${ARGOCD_PF_PORT}"

kubectl --context "$HUB_CONTEXT" port-forward svc/argocd-server \
    -n argocd "${ARGOCD_PF_PORT}":80 > /tmp/helmsman-sanity-argocd-pf.log 2>&1 &
ARGOCD_PF_PID=$!
cleanup_pf() { kill "$ARGOCD_PF_PID" 2>/dev/null || true; }
trap cleanup_pf EXIT
sleep 3

LOGIN_OK=false
for i in 1 2 3; do
    if argocd login "$ARGOCD_SERVER" \
        --username "$ARGOCD_USER" \
        --password "$ARGOCD_PASS" \
        --insecure > /dev/null 2>&1; then
        ok "Argo CD CLI session authenticated via port-forward :${ARGOCD_PF_PORT}"
        LOGIN_OK=true
        break
    fi
    info "Login attempt $i/3 — waiting 5s..."
    sleep 5
done

if [ "$LOGIN_OK" = false ]; then
    fail "Argo CD CLI login failed via port-forward :${ARGOCD_PF_PORT}"
    echo -e "  ${YELLOW}DEBUG:${NC} kubectl get pods -n argocd --context $HUB_CONTEXT"
    echo -e "  ${YELLOW}DEBUG:${NC} cat $ARGOCD_PASS_FILE"
fi

# =============================================================================
header "H. Argo CD Cluster and App Status"
# =============================================================================
sleep 3

STORED=$(kubectl get secret "$CLUSTER_SECRET_NAME" \
    -n argocd --context "$HUB_CONTEXT" \
    -o jsonpath='{.data.server}' 2>/dev/null | base64 -d 2>/dev/null || echo "unknown")
info "  $STORED"

if [ "$LOGIN_OK" = true ]; then
    CLUSTER_JSON=$(argocd cluster list --server "$ARGOCD_SERVER" --insecure -o json 2>/dev/null || echo "[]")
    if [ -z "$CLUSTER_JSON" ]; then
        CLUSTER_JSON='[]'
    fi

    CLUSTER_STATUS=$(echo "$CLUSTER_JSON" | python3 -c "
import json,sys
try:
    clusters=json.load(sys.stdin)
except Exception:
    clusters=[]
for c in clusters:
    if c.get('name')=='${CLUSTER_REGISTERED_NAME}':
        print(c.get('connectionState',{}).get('status','Unknown'))
        break
else:
    print('NotFound')
" 2>/dev/null || echo "unknown")
    CLUSTER_VERSION=$(echo "$CLUSTER_JSON" | python3 -c "
import json,sys
try:
    clusters=json.load(sys.stdin)
except Exception:
    clusters=[]
for c in clusters:
    if c.get('name')=='${CLUSTER_REGISTERED_NAME}':
        print(c.get('serverVersion','') or '')
        break
" 2>/dev/null || echo "")

    if [ "$CLUSTER_STATUS" = "Successful" ]; then
        ok "Spoke cluster: Successful (Kubernetes $CLUSTER_VERSION)"
    elif [ "$CLUSTER_STATUS" = "Unknown" ]; then
        info "Spoke cluster: Unknown — still connecting, re-run in 60s"
    else
        fail "Spoke cluster: $CLUSTER_STATUS"
    fi

    APP_JSON=$(argocd app list --server "$ARGOCD_SERVER" --insecure -o json 2>/dev/null || echo "[]")
    APP_COUNT=$(echo "$APP_JSON" | python3 -c 'import json,sys
try:
    apps=json.load(sys.stdin)
    print(len(apps))
except Exception:
    print(0)')

    if [ "$APP_COUNT" -eq 0 ]; then
        info "No Argo CD Applications found"
    else
        APP_NAMES=$(printf '%s' "$APP_JSON" | python3 -c 'import json,sys
try:
    apps=json.load(sys.stdin)
except Exception:
    apps=[]
for app in apps:
    name=app.get("metadata",{}).get("name","")
    if name:
        print(name)
')

        if [ -z "$APP_NAMES" ]; then
            info "No Argo CD Applications found"
        else
            for APP_NAME in $APP_NAMES; do
                APP_DATA=$(argocd app get "$APP_NAME" --server "$ARGOCD_SERVER" --insecure -o json 2>/dev/null || echo "{}")
                APP_SYNC=$(printf '%s' "$APP_DATA" | python3 -c 'import json,sys
try:
    app=json.load(sys.stdin)
    print(app.get("status",{}).get("sync",{}).get("status",""))
except Exception:
    print("")
')
                APP_HEALTH=$(printf '%s' "$APP_DATA" | python3 -c 'import json,sys
try:
    app=json.load(sys.stdin)
    print(app.get("status",{}).get("health",{}).get("status",""))
except Exception:
    print("")
')
                COMP_ERROR=$(printf '%s' "$APP_DATA" | python3 -c 'import json,sys
try:
    app=json.load(sys.stdin)
    for c in app.get("status",{}).get("conditions",[]):
        if c.get("type") == "ComparisonError":
            print(c.get("message",""))
            break
except Exception:
    pass
')

                if [ "$APP_SYNC" = "Synced" ] && [ "$APP_HEALTH" = "Healthy" ]; then
                    ok "App $APP_NAME — Synced / Healthy"
                elif [ "$APP_SYNC" = "Synced" ] && [ "$APP_HEALTH" = "Progressing" ]; then
                    info "App $APP_NAME — Synced / Progressing"
                elif [ "$APP_SYNC" = "OutOfSync" ] && [ "$APP_HEALTH" = "Healthy" ]; then
                    warn "App $APP_NAME — OutOfSync / Healthy"
                elif [ "$APP_SYNC" = "Unknown" ]; then
                    if [ -n "$COMP_ERROR" ]; then
                        fail "App $APP_NAME — Unknown / $APP_HEALTH (ComparisonError: $COMP_ERROR)"
                    else
                        fail "App $APP_NAME — Unknown / $APP_HEALTH"
                    fi
                else
                    fail "App $APP_NAME — $APP_SYNC / $APP_HEALTH"
                fi
            done
        fi
    fi
else
    # Fallback: use kubectl directly when argocd CLI login failed
    APP_COUNT=$(kubectl get applications -n argocd --context "$HUB_CONTEXT" \
        --no-headers 2>/dev/null | wc -l | tr -d ' ')
    info "Argo CD Applications in cluster: $APP_COUNT (login required for sync/health status)"
fi

# =============================================================================
header "I. Spoke Workload Status"
# =============================================================================
NAMESPACES=$(kubectl get namespaces --context "$SPOKE_CONTEXT" \
    --no-headers -o custom-columns=":metadata.name" 2>/dev/null \
    | grep -v "^kube-\|^default\|^local-path" || echo "")

if [ -z "$NAMESPACES" ]; then
    info "No application namespaces on spoke"
else
    for NS in $NAMESPACES; do
        PODS=$(kubectl get pods -n "$NS" --context "$SPOKE_CONTEXT" \
            --no-headers 2>/dev/null || echo "")
        [ -z "$PODS" ] && continue
        while IFS= read -r pod_line; do
            [ -z "$pod_line" ] && continue
            POD_NAME=$(echo "$pod_line" | awk '{print $1}')
            READY=$(echo "$pod_line"    | awk '{print $2}')
            STATUS=$(echo "$pod_line"   | awk '{print $3}')
            RESTARTS=$(echo "$pod_line" | awk '{print $4}')
            if [ "$STATUS" = "Running" ]; then
                if [ "${RESTARTS:-0}" -gt 5 ] 2>/dev/null; then
                    warn "Pod $NS/$POD_NAME Running $READY — high restarts ($RESTARTS)"
                else
                    ok "Pod $NS/$POD_NAME — Running $READY (restarts: $RESTARTS)"
                fi
            elif [ "$STATUS" = "Completed" ] || [ "$STATUS" = "Succeeded" ]; then
                ok "Pod $NS/$POD_NAME — $STATUS (one-shot pod)"
            elif [ "$STATUS" = "Terminating" ]; then
                warn "Pod $NS/$POD_NAME stuck Terminating"
            else
                fail "Pod $NS/$POD_NAME — $STATUS $READY"
            fi
        done <<< "$PODS"
    done
fi

# =============================================================================
header "Summary"
# =============================================================================
echo ""
echo -e "  ${GREEN}✔ Passed:${NC}  $PASS"
[ "$WARN" -gt 0 ] && echo -e "  ${YELLOW}⚠ Warnings:${NC} $WARN"
[ "$FAIL" -gt 0 ] && echo -e "  ${RED}✘ Failed:${NC}  $FAIL"
echo ""

if [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}All checks passed. Helmsman environment is healthy.${NC}"
    echo -e "\n  ${CYAN}Quick commands:${NC}"
    echo -e "    argocd app list"
    echo -e "    kubectl get all -n sample-app --context $SPOKE_CONTEXT"
    echo -e "    kubectl logs -n sample-app sample-app-0 -c fluent-bit --context $SPOKE_CONTEXT"
    echo ""
    exit 0
else
    [ "$WARN" -gt 0 ] && echo -e "  ${YELLOW}${BOLD}$WARN item(s) drifted from expected state.${NC}"
    [ "$FAIL" -gt 0 ] && echo -e "  ${RED}${BOLD}$FAIL check(s) failed.${NC}"
    echo ""
    echo -e "$RECOVER_HINT"
    echo -e "  ${YELLOW}(add --reset if that doesn't clear it)${NC}"
    echo ""
    exit 1
fi
