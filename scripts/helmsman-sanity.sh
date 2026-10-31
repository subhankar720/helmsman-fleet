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
# 9. Vault (-dev, in-memory) and Keycloak (no PVC) lose everything written at
#    runtime: secret/agentforge/* and the agentforge-gateway client, groups and
#    users. oauth2-proxy then keeps a stale issuer/secret until restarted
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
# J: Observability — Loki, Grafana, and live log-shipping check
# K: AgentForge platform — Envoy Gateway, oauth2-proxy, Keycloak client/groups/
#    user, Vault secret/agentforge/*, Kyverno policy, namespace + pull secret
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

# Throwaway curl pods used by the checks below. Namespaces labelled
# helmsman.dev/managed=true (e.g. sample-app) are guarded by the Kyverno
# policies on the spoke, which reject a bare `kubectl run` — so give the probe
# the label, non-root user, limits and no-privilege-escalation they require.
probe_overrides() {
    printf '{"metadata":{"labels":{"app.kubernetes.io/managed-by":"helmsman"}},"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":100},"containers":[{"name":"%s","resources":{"limits":{"cpu":"100m","memory":"64Mi"}},"securityContext":{"allowPrivilegeEscalation":false}}]}}' "$1"
}

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

# Two Docker Desktop failure modes after a host reboot that keep a node down:
# a lost endpoint on the kind network, and a host port taken by another
# container that started first. dev-up-gemini.sh Stage 1 fixes the first and
# names the culprit for the second.
for CONTAINER in helmsman-hub-control-plane helmsman-hub-worker helmsman-hub-worker2 \
                 helmsman-onprem-control-plane helmsman-onprem-worker; do
    docker inspect "$CONTAINER" > /dev/null 2>&1 || continue
    if [ "$(docker inspect "$CONTAINER" --format '{{len .NetworkSettings.Networks}}')" = "0" ]; then
        fail "$CONTAINER has no endpoint on the kind network (boot fails: 'old IPv4 address but no current IPv4 address')"
        CONTAINERS_DOWN=true
    fi
    for HOST_PORT in $(docker inspect "$CONTAINER" --format '{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{.HostPort}} {{end}}{{end}}'); do
        OWNER=$(docker ps --format '{{.Names}}|{{.Ports}}' | grep -E ":${HOST_PORT}->" | cut -d'|' -f1 | grep -vx "$CONTAINER" | head -1)
        if [ -n "$OWNER" ]; then
            fail "Host port $HOST_PORT needed by $CONTAINER is published by $OWNER"
            CONTAINERS_DOWN=true
        fi
    done
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
        if kubectl --context "$SPOKE_CONTEXT" -n "$SAMPLE_APP_NAMESPACE" run --quiet --rm -i --restart=Never sample-app-probe --image=curlimages/curl:latest --override-type=strategic --overrides="$(probe_overrides sample-app-probe)" -- sh -c "curl -fsS --max-time 5 http://$SAMPLE_APP_SERVICE_NAME:80/ping" > /dev/null 2>&1; then
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
        if kubectl --context "$SPOKE_CONTEXT" -n sample-app run --quiet --rm -i --restart=Never vault-check --image=curlimages/curl:latest --override-type=strategic --overrides="$(probe_overrides vault-check)" -- sh -c "curl -fsS --max-time 5 ${CSS_SERVER}/v1/sys/health" > /dev/null 2>&1; then
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

# kindnet enforces NetworkPolicy. If it loses its API watch it keeps stale
# rules and silently drops traffic into namespaces with policies (sample-app)
# while everything else looks healthy.
for NET_CTX in "$HUB_CONTEXT" "$SPOKE_CONTEXT"; do
    # kind's default 100m CPU limit starves kindnet's NetworkPolicy dataplane
    KINDNET_CPU_LIMIT=$(kubectl --context "$NET_CTX" -n kube-system get ds kindnet \
        -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}' 2>/dev/null || echo "")
    if [ "$KINDNET_CPU_LIMIT" = "1" ]; then
        ok "kindnet CPU limit 1 on $NET_CTX"
    else
        fail "kindnet CPU limit on $NET_CTX is '${KINDNET_CPU_LIMIT:-<none>}' (kind default 100m throttles NetworkPolicy enforcement) — dev-up-gemini.sh Stage 3 raises it"
    fi

    KINDNET_ERRS=$(kubectl --context "$NET_CTX" logs -n kube-system -l app=kindnet \
        --since=10m --tail=-1 2>/dev/null | grep -c "Failed to watch" || true)
    if [ "${KINDNET_ERRS:-0}" -eq 0 ] 2>/dev/null; then
        ok "kindnet API watch healthy on $NET_CTX"
    else
        fail "kindnet on $NET_CTX logged $KINDNET_ERRS 'Failed to watch' errors in 10m — NetworkPolicy enforcement is stale (dev-up-gemini.sh Stage 3 restarts kindnet)"
    fi
done

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
header "J. Observability: Loki, Grafana, and Log Shipping"
# =============================================================================
# Loki pod itself
LOKI_READY=$(kubectl get pod platform-loki-0 -n monitoring --context "$HUB_CONTEXT" \
    -o jsonpath='{.status.containerStatuses[?(@.name=="loki")].ready}' 2>/dev/null || echo "")
if [ "$LOKI_READY" = "true" ]; then
    ok "platform-loki-0 'loki' container is Ready"
else
    fail "platform-loki-0 'loki' container is not Ready (got: ${LOKI_READY:-<not found>})"
fi

# Loki /ready reachable in-cluster (in-cluster DNS, no IP drift involved)
# Retried with a fresh pod name: `run --rm -i` can lose the output when the
# attach races the container, and Loki answers "not ready" for a while after a
# restart — neither means Loki is down.
LOKI_READY_OK=false
for attempt in 1 2 3; do
    LH_POD="loki-health-check-$attempt-$$"
    if kubectl --context "$HUB_CONTEXT" -n monitoring run --quiet --rm -i --restart=Never "$LH_POD" \
        --image=curlimages/curl:latest -- sh -c "curl -fsS --max-time 5 http://platform-loki.monitoring.svc.cluster.local:3100/ready" \
        2>/dev/null | grep -q "ready"; then
        LOKI_READY_OK=true
        break
    fi
    kubectl --context "$HUB_CONTEXT" -n monitoring delete pod "$LH_POD" --ignore-not-found > /dev/null 2>&1 || true
    sleep 5
done
kubectl --context "$HUB_CONTEXT" -n monitoring delete pod loki-health-check --ignore-not-found > /dev/null 2>&1 || true
if $LOKI_READY_OK; then
    ok "Loki /ready reachable at platform-loki.monitoring.svc.cluster.local:3100"
else
    fail "Loki /ready NOT reachable at platform-loki.monitoring.svc.cluster.local:3100"
fi

# Grafana pod + its Loki datasource points at the right service name
GRAFANA_READY=$(kubectl get pods -n monitoring --context "$HUB_CONTEXT" \
    -l app.kubernetes.io/name=grafana \
    -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="grafana")].ready}' 2>/dev/null || echo "")
if [ "$GRAFANA_READY" = "true" ]; then
    ok "Grafana pod is Ready"
else
    fail "Grafana pod is not Ready (got: ${GRAFANA_READY:-<not found>})"
fi

GRAFANA_LOKI_DS_URL=$(kubectl get configmap platform-prometheus-stack-grafana-datasource \
    -n monitoring --context "$HUB_CONTEXT" \
    -o jsonpath='{.data.datasource\.yaml}' 2>/dev/null | grep -A2 "name: Loki" | grep "url:" | awk '{print $2}')
EXPECTED_GRAFANA_LOKI_DS_URL="http://platform-loki.monitoring.svc.cluster.local:3100"
if [ "$GRAFANA_LOKI_DS_URL" = "$EXPECTED_GRAFANA_LOKI_DS_URL" ]; then
    ok "Grafana Loki datasource URL correct ($GRAFANA_LOKI_DS_URL)"
else
    fail "Grafana Loki datasource URL wrong: got '${GRAFANA_LOKI_DS_URL:-<none>}', expected '$EXPECTED_GRAFANA_LOKI_DS_URL' — re-apply platform/observability/kube-prometheus-stack-application.yaml (Applications here are kubectl-applied directly, git alone won't fix this)"
fi

# End-to-end: are logs from sample-app actually arriving in Loki, recently?
# This is the only check that proves Promtail is shipping right now, not just
# that everything is configured correctly.
kubectl --context "$HUB_CONTEXT" -n monitoring delete pod loki-shipping-check --ignore-not-found > /dev/null 2>&1 || true
NOW_NS=$(date +%s%N)
FROM_NS=$((NOW_NS - 5*60*1000000000))
SHIPPING_QUERY_URL="http://platform-loki.monitoring.svc.cluster.local:3100/loki/api/v1/query_range?query=%7Bnamespace%3D%22sample-app%22%7D&start=${FROM_NS}&end=${NOW_NS}&limit=1"
SHIPPING_RESULT=$(kubectl --context "$HUB_CONTEXT" -n monitoring run --quiet --rm -i --restart=Never loki-shipping-check \
    --image=curlimages/curl:latest -- sh -c "curl -fsS --max-time 5 '${SHIPPING_QUERY_URL}'" 2>/dev/null || echo "")
if echo "$SHIPPING_RESULT" | grep -q '"resultType":"streams"' && echo "$SHIPPING_RESULT" | grep -q '"values":\[\['; then
    ok "Loki has sample-app log entries from the last 5 minutes — Promtail is shipping live"
else
    fail "No sample-app log entries in Loki from the last 5 minutes — check the platform-spoke-promtail DaemonSet (hostNetwork, clients.url) and the F.2 section above"
fi

# =============================================================================
header "K. AgentForge Platform (Envoy Gateway, oauth2-proxy, Keycloak, Vault)"
# =============================================================================
# Vault runs in -dev mode (in-memory) and Keycloak has no PVC, so a Docker
# restart wipes secret/agentforge/* and the agentforge-gateway client, groups
# and users. dev-up-gemini.sh Stage 10.5 restores them from ~/.helmsman-dev/;
# this section only reports.
AF_FIX="dev-up-gemini.sh Stage 10.5 repairs this"
AF_STATE_DIR="${HELMSMAN_STATE_DIR:-$HOME/.helmsman-dev}"
# Must match dev-up-gemini.sh (AF_KC_GROUPS / AF_KC_USERS).
AF_KC_GROUPS="/teams/dev-team /teams/platform-team /readonly"
AF_KC_USERS="subhankar:/teams/dev-team af-platform-user:/teams/platform-team af-readonly-user:/teams/dev-team,/readonly"
AF_KC_USERS_LIST=$(for s in $AF_KC_USERS; do printf '%s ' "${s%%:*}"; done)

# --- Argo CD Applications (kubectl-applied — git alone can't recreate them) ---
for APP in platform-envoy-gateway platform-envoy-gateway-infra platform-agentforge-oauth2proxy \
           platform-kyverno-policies agentforge; do
    if kubectl --context "$HUB_CONTEXT" -n argocd get application "$APP" > /dev/null 2>&1; then
        ok "Application $APP exists"
    else
        fail "Application $APP missing in argocd namespace — $AF_FIX"
    fi
done

# --- Envoy Gateway ------------------------------------------------------------
EG_READY=$(kubectl --context "$SPOKE_CONTEXT" -n envoy-gateway-system get deployment envoy-gateway \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "")
[ "${EG_READY:-0}" -ge 1 ] 2>/dev/null && ok "Envoy Gateway controller Running on spoke" || \
    fail "Envoy Gateway controller not ready in envoy-gateway-system"

GC_ACCEPTED=$(kubectl --context "$SPOKE_CONTEXT" get gatewayclass envoy \
    -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "")
[ "$GC_ACCEPTED" = "True" ] && ok "GatewayClass envoy Accepted" || \
    fail "GatewayClass envoy not Accepted (got: ${GC_ACCEPTED:-<not found>})"

GW_PROGRAMMED=$(kubectl --context "$SPOKE_CONTEXT" -n gateway-infra get gateway helmsman-gateway \
    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "")
GW_ADDR=$(kubectl --context "$SPOKE_CONTEXT" -n gateway-infra get gateway helmsman-gateway \
    -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "")
if [ "$GW_PROGRAMMED" = "True" ]; then
    ok "Gateway gateway-infra/helmsman-gateway Programmed (address ${GW_ADDR:-none})"
else
    fail "Gateway helmsman-gateway not Programmed (got: ${GW_PROGRAMMED:-<not found>}) — $AF_FIX"
fi

GW_SVC=$(kubectl --context "$SPOKE_CONTEXT" -n envoy-gateway-system get svc \
    -l gateway.envoyproxy.io/owning-gateway-name=helmsman-gateway,gateway.envoyproxy.io/owning-gateway-namespace=gateway-infra \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
GW_SVC_TYPE=$(kubectl --context "$SPOKE_CONTEXT" -n envoy-gateway-system get svc "$GW_SVC" \
    -o jsonpath='{.spec.type}' 2>/dev/null || echo "")
if [ "$GW_SVC_TYPE" = "NodePort" ]; then
    ok "Gateway proxy Service $GW_SVC is NodePort (kind has no LoadBalancer)"
else
    fail "Gateway proxy Service type is '${GW_SVC_TYPE:-<not found>}', expected NodePort — check EnvoyProxy gateway-infra/helmsman-proxy"
fi

# The route is owned by the AgentForge chart (agentforge namespace); its "/"
# backend is oauth2-proxy in gateway-infra, allowed by a ReferenceGrant there.
if kubectl --context "$SPOKE_CONTEXT" -n gateway-infra get referencegrant agentforge-to-oauth2-proxy > /dev/null 2>&1; then
    ok "ReferenceGrant gateway-infra/agentforge-to-oauth2-proxy present"
else
    fail "ReferenceGrant gateway-infra/agentforge-to-oauth2-proxy missing — the AgentForge route can't reach oauth2-proxy"
fi
ROUTE_STATUS=$(kubectl --context "$SPOKE_CONTEXT" -n agentforge get httproute agentforge \
    -o jsonpath='{range .status.parents[0].conditions[*]}{.type}={.status} {end}' 2>/dev/null || echo "")
if echo "$ROUTE_STATUS" | grep -q "Accepted=True" && echo "$ROUTE_STATUS" | grep -q "ResolvedRefs=True"; then
    ok "HTTPRoute agentforge/agentforge Accepted, backends resolved"
else
    fail "HTTPRoute agentforge/agentforge not healthy (${ROUTE_STATUS:-not found}) — synced by the agentforge Application"
fi

# --- oauth2-proxy -------------------------------------------------------------
GI_KC_URL=$(kubectl --context "$SPOKE_CONTEXT" -n gateway-infra get secret helmsman-platform-config \
    -o jsonpath='{.data.keycloak-url}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
if [ "$GI_KC_URL" = "http://${HUB_IP}:30081" ]; then
    ok "gateway-infra helmsman-platform-config keycloak-url current ($GI_KC_URL)"
else
    fail "gateway-infra helmsman-platform-config keycloak-url is '${GI_KC_URL:-<missing>}', expected http://${HUB_IP}:30081 — $AF_FIX"
fi

ES_READY=$(kubectl --context "$SPOKE_CONTEXT" -n gateway-infra get externalsecret agentforge-oauth2-proxy-secret \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
[ "$ES_READY" = "True" ] && ok "ExternalSecret agentforge-oauth2-proxy-secret Ready" || \
    fail "ExternalSecret agentforge-oauth2-proxy-secret not Ready (got: ${ES_READY:-<not found>})"

OAUTH_AVAILABLE=$(kubectl --context "$SPOKE_CONTEXT" -n gateway-infra get deployment agentforge-oauth2-proxy \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
[ "$OAUTH_AVAILABLE" = "True" ] && ok "oauth2-proxy Deployment Available" || \
    fail "oauth2-proxy Deployment not Available (got: ${OAUTH_AVAILABLE:-<not found>})"

# Same fingerprint dev-up records after restarting oauth2-proxy: if the URL
# or credentials changed since, the running process still has the old ones.
OAUTH_FP=$( {
    kubectl --context "$SPOKE_CONTEXT" -n gateway-infra get secret helmsman-platform-config -o jsonpath='{.data.keycloak-url}' 2>/dev/null
    kubectl --context "$SPOKE_CONTEXT" -n gateway-infra get secret agentforge-oauth2-proxy-secret -o jsonpath='{.data}' 2>/dev/null
  } | sha256sum | cut -c1-16)
RUNNING_FP=$(kubectl --context "$SPOKE_CONTEXT" -n gateway-infra get deployment agentforge-oauth2-proxy \
    -o jsonpath='{.metadata.annotations.helmsman\.dev/config-fingerprint}' 2>/dev/null || echo "")
if [ "$OAUTH_FP" = "$RUNNING_FP" ]; then
    ok "oauth2-proxy started with the current Keycloak URL and credentials"
else
    warn "oauth2-proxy config changed since it last started (or was never recorded) — needs a restart; $AF_FIX"
fi

if [ -n "$GW_SVC" ]; then
    GW_URL="http://${GW_SVC}.envoy-gateway-system.svc.cluster.local"
    # Authenticated API call as subhankar (agentforge-cli password grant →
    # Bearer → oauth2-proxy → gateway). GET /v1/agents is a static list: no
    # agent runs, no LLM call. The password goes in on stdin, not the pod spec.
    AF_PW=$(cat "$AF_STATE_DIR/keycloak-agentforge-user-password" 2>/dev/null || echo "")
    for attempt in 1 2 3; do   # a throwaway probe pod can fail on its own; retry before reporting
        kubectl --context "$SPOKE_CONTEXT" -n default delete pod agentforge-gw-check --ignore-not-found > /dev/null 2>&1 || true
        AF_E2E=$(printf '%s\n' "$AF_PW" | kubectl --context "$SPOKE_CONTEXT" -n default run --quiet --rm -i --restart=Never agentforge-gw-check \
            --image=curlimages/curl:latest -- sh -c "
              read -r P
              curl -s -o /dev/null -w 'ping=%{http_code}\n' --max-time 5 -H 'Host: agentforge.helmsman.local' '${GW_URL}/ping'
              curl -s -o /dev/null -w 'start=%{http_code} %{redirect_url}\n' --max-time 5 -H 'Host: agentforge.helmsman.local' '${GW_URL}/oauth2/start'
              curl -s -o /dev/null -w 'noauth=%{http_code}\n' --max-time 5 -H 'Host: agentforge.helmsman.local' '${GW_URL}/v1/agents'
              T=\$(curl -s --max-time 10 'http://${HUB_IP}:30081/realms/helmsman/protocol/openid-connect/token' \
                  -d grant_type=password -d client_id=agentforge-cli -d username=subhankar --data-urlencode \"password=\$P\" \
                  | sed -n 's/.*\"access_token\":\"\\([^\"]*\\)\".*/\\1/p')
              echo \"token=\${T:+yes}\"
              [ -n \"\$T\" ] && curl -s -o /dev/null -w 'api=%{http_code}\n' --max-time 10 -H 'Host: agentforge.helmsman.local' \
                  -H \"Authorization: Bearer \$T\" '${GW_URL}/v1/agents'
            " 2>/dev/null || echo "")
        echo "$AF_E2E" | grep -q '^ping=200' && echo "$AF_E2E" | grep -q "^start=302 http://${HUB_IP}:30081/" \
            && echo "$AF_E2E" | grep -q '^api=200' && break
        sleep 5
    done
    if echo "$AF_E2E" | grep -q '^ping=200'; then
        ok "agentforge.helmsman.local → Envoy Gateway → oauth2-proxy (/ping 200)"
    else
        fail "Gateway → oauth2-proxy /ping failed (${AF_E2E:-no response})"
    fi
    if echo "$AF_E2E" | grep -q "^start=302 http://${HUB_IP}:30081/realms/helmsman/"; then
        ok "oauth2-proxy login redirects to current Keycloak (http://${HUB_IP}:30081/realms/helmsman)"
    else
        fail "oauth2-proxy login redirect is not the current Keycloak ($(echo "$AF_E2E" | grep '^start=' || echo 'no response')) — stale issuer; $AF_FIX"
    fi
    if echo "$AF_E2E" | grep -q '^noauth=401'; then
        ok "Unauthenticated API call gets 401 (/v1/agents, --api-route)"
    else
        fail "Unauthenticated /v1/agents returned $(echo "$AF_E2E" | sed -n 's/^noauth=//p'), expected 401 — check oauth2-proxy --api-route"
    fi
    if [ -z "$AF_PW" ]; then
        warn "No password in $AF_STATE_DIR/keycloak-agentforge-user-password — skipped the authenticated API check"
    elif echo "$AF_E2E" | grep -q '^api=200'; then
        ok "Authenticated API call as subhankar: Keycloak token → oauth2-proxy → AgentForge GET /v1/agents 200"
    elif ! echo "$AF_E2E" | grep -q '^token=yes'; then
        fail "Could not get a Keycloak token for subhankar via agentforge-cli — $AF_FIX"
    else
        fail "Bearer call to /v1/agents returned $(echo "$AF_E2E" | sed -n 's/^api=//p') — oauth2-proxy or the AgentForge gateway is unhealthy"
    fi
else
    fail "No Envoy proxy Service for helmsman-gateway — cannot test the AgentForge route"
fi

# --- Vault: secret/agentforge/* -----------------------------------------------
VAULT_POD=$(kubectl --context "$HUB_CONTEXT" -n vault get pods --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
AF_VAULT_CS=""
if [ -z "$VAULT_POD" ]; then
    fail "No running Vault pod on hub"
else
    for P in auth llm db cache confluence; do
        DATA=$(kubectl --context "$HUB_CONTEXT" -n vault exec "$VAULT_POD" -- \
            env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="${VAULT_TOKEN:-root}" \
            vault kv get -format=json "secret/agentforge/$P" 2>/dev/null || echo "")
        if [ -z "$DATA" ]; then
            fail "Vault secret/agentforge/$P missing — $AF_FIX"
            continue
        fi
        if [ "$P" = "auth" ]; then
            AUTH_CHECK=$(printf '%s' "$DATA" | HUB_IP="$HUB_IP" python3 -c '
import json, os, sys
d = json.load(sys.stdin)["data"]["data"]
need = ["keycloak_client_id", "keycloak_client_secret", "cookie_secret", "keycloak_realm", "keycloak_url"]
missing = [k for k in need if not d.get(k)]
if missing:
    print("missing keys: " + ",".join(missing))
elif d["keycloak_url"] != "http://%s:30081" % os.environ["HUB_IP"]:
    print("stale keycloak_url " + d["keycloak_url"])
else:
    print("OK " + d["keycloak_client_secret"])
' 2>/dev/null || echo "unreadable")
            if [ "${AUTH_CHECK%% *}" = "OK" ]; then
                AF_VAULT_CS="${AUTH_CHECK#OK }"
                ok "Vault secret/agentforge/auth present with all keys, keycloak_url current"
            else
                fail "Vault secret/agentforge/auth: $AUTH_CHECK — $AF_FIX"
            fi
        else
            ok "Vault secret/agentforge/$P present"
        fi
    done
fi

# --- Keycloak: agentforge-gateway client, groups, user -------------------------
KC_REPORT=$(docker exec "$HUB_CONTAINER" sh -c "
    T=\$(curl -s --max-time 10 -X POST http://${HUB_IP}:30081/realms/master/protocol/openid-connect/token \
        -d grant_type=password -d client_id=admin-cli \
        -d username='${KEYCLOAK_ADMIN_USER:-admin}' -d password='${KEYCLOAK_ADMIN_PASS:-admin}' \
        | sed -n 's/.*\"access_token\":\"\\([^\"]*\\)\".*/\\1/p')
    K=http://${HUB_IP}:30081/admin/realms/helmsman
    echo \"CLIENT \$(curl -s --max-time 10 -H \"Authorization: Bearer \$T\" \"\$K/clients?clientId=agentforge-gateway\")\"
    CID=\$(curl -s --max-time 10 -H \"Authorization: Bearer \$T\" \"\$K/clients?clientId=agentforge-gateway\" | sed -n 's/^\\[{\"id\":\"\\([^\"]*\\)\".*/\\1/p')
    [ -n \"\$CID\" ] && echo \"SECRET \$(curl -s --max-time 10 -H \"Authorization: Bearer \$T\" \"\$K/clients/\$CID/client-secret\")\"
    echo \"CLI \$(curl -s --max-time 10 -H \"Authorization: Bearer \$T\" \"\$K/clients?clientId=agentforge-cli\")\"
    for P in ${AF_KC_GROUPS}; do
        echo \"GP\$P \$(curl -s -o /dev/null -w %{http_code} --max-time 10 -H \"Authorization: Bearer \$T\" \"\$K/group-by-path\$P\")\"
    done
    for U in ${AF_KC_USERS_LIST}; do
        ID=\$(curl -s --max-time 10 -H \"Authorization: Bearer \$T\" \"\$K/users?exact=true&username=\$U\" | sed -n 's/^\\[{\"id\":\"\\([^\"]*\\)\".*/\\1/p')
        [ -n \"\$ID\" ] && echo \"MEMBER:\$U \$(curl -s --max-time 10 -H \"Authorization: Bearer \$T\" \"\$K/users/\$ID/groups\")\"
    done
" 2>/dev/null || echo "")
KC_CS_LIVE=$(kubectl --context "$SPOKE_CONTEXT" -n gateway-infra get secret agentforge-oauth2-proxy-secret \
    -o jsonpath='{.data.client-secret}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
while IFS= read -r line; do
    case "$line" in
        OK*)   ok   "${line#OK }" ;;
        WARN*) warn "${line#WARN } — $AF_FIX" ;;
        *)     fail "${line#FAIL } — $AF_FIX" ;;
    esac
done < <(printf '%s\n' "$KC_REPORT" | VAULT_CS="$AF_VAULT_CS" K8S_CS="$KC_CS_LIVE" \
    AF_KC_GROUPS="$AF_KC_GROUPS" AF_KC_USERS="$AF_KC_USERS" python3 -c '
import json, os, sys
r = {}
for line in sys.stdin:
    k, _, v = line.rstrip("\n").partition(" ")
    r[k] = v
def j(k):
    try:
        return json.loads(r.get(k) or "null")
    except ValueError:
        return None
clients = j("CLIENT")
if not isinstance(clients, list):
    print("FAIL Keycloak admin API not reachable from hub (http://<hub-ip>:30081)"); sys.exit()
if not clients:
    print("FAIL Keycloak client agentforge-gateway missing")
else:
    c = clients[0]
    print("OK Keycloak client agentforge-gateway present (confidential=%s)" % (not c.get("publicClient")))
    gm = [m for m in c.get("protocolMappers", []) if m.get("protocolMapper") == "oidc-group-membership-mapper"]
    if gm and gm[0].get("config", {}).get("full.path") == "true":
        print("OK Keycloak client agentforge-gateway has groups mapper (full.path=true)")
    else:
        print("FAIL Keycloak client agentforge-gateway groups mapper %s" % ("has full.path=false (team paths missing)" if gm else "missing"))
    secret = (j("SECRET") or {}).get("value")
    vcs, kcs = os.environ.get("VAULT_CS"), os.environ.get("K8S_CS")
    if secret and secret == vcs == kcs:
        print("OK client secret identical in Keycloak, Vault and the oauth2-proxy Secret")
    else:
        print("FAIL client secret mismatch (Keycloak=%s, Vault=%s, oauth2-proxy Secret=%s)" %
              tuple("set" if x else "missing" for x in (secret, vcs, kcs)) if not (secret and vcs and kcs)
              else "FAIL client secret differs between Keycloak, Vault and the oauth2-proxy Secret")
cli = j("CLI")
if not cli:
    print("FAIL Keycloak client agentforge-cli missing (CLI/SDK bearer tokens)")
else:
    ms = {m.get("protocolMapper"): m for m in cli[0].get("protocolMappers", [])}
    fp = ms.get("oidc-group-membership-mapper", {}).get("config", {}).get("full.path")
    if "oidc-audience-mapper" in ms and fp == "true" and cli[0].get("directAccessGrantsEnabled"):
        print("OK Keycloak client agentforge-cli present (password grant, groups full.path + audience mappers)")
    else:
        print("FAIL Keycloak client agentforge-cli is missing a mapper, full.path=true or the password grant")
for g in os.environ["AF_KC_GROUPS"].split():
    print(("OK Keycloak group %s present" if r.get("GP" + g) == "200" else "FAIL Keycloak group %s missing") % g)
for spec in os.environ["AF_KC_USERS"].split():
    u, _, want = spec.partition(":")
    m = j("MEMBER:" + u)
    if not isinstance(m, list):
        print("FAIL Keycloak user %s missing" % u)
        continue
    have, need = {g["path"] for g in m}, set(want.split(","))
    if need <= have:
        print("OK Keycloak user %s is in %s" % (u, want))
    else:
        print("FAIL Keycloak user %s is in %s, expected %s" % (u, ",".join(sorted(have)) or "no groups", want))
    if have - need:
        print("WARN Keycloak user %s is also in %s" % (u, ",".join(sorted(have - need))))
')

# --- Platform namespaces must stay out of the Kyverno app policies ------------
for NS in helmsman-operator-system envoy-gateway-system gateway-infra monitoring kyverno external-secrets; do
    if [ "$(kubectl --context "$SPOKE_CONTEXT" get namespace "$NS" \
        -o jsonpath='{.metadata.labels.helmsman\.dev/managed}' 2>/dev/null)" = "true" ]; then
        fail "Platform namespace $NS is labelled helmsman.dev/managed=true — Kyverno app policies will block its next pod (dev-up-gemini.sh Stage 8 removes it)"
    fi
done
# Events linger ~1h, so only report owners that are still short of pods.
BLOCKED=""
while read -r NS KIND NAME; do
    [ -z "$NAME" ] && continue
    case "$KIND" in
        ReplicaSet)  SHORT=$(kubectl --context "$SPOKE_CONTEXT" -n "$NS" get rs "$NAME" \
                       -o jsonpath='{.spec.replicas} {.status.replicas}' 2>/dev/null) ;;
        DaemonSet)   SHORT=$(kubectl --context "$SPOKE_CONTEXT" -n "$NS" get ds "$NAME" \
                       -o jsonpath='{.status.desiredNumberScheduled} {.status.currentNumberScheduled}' 2>/dev/null) ;;
        StatefulSet) SHORT=$(kubectl --context "$SPOKE_CONTEXT" -n "$NS" get sts "$NAME" \
                       -o jsonpath='{.spec.replicas} {.status.replicas}' 2>/dev/null) ;;
        *)           SHORT="" ;;
    esac
    read -r WANT HAVE <<< "$SHORT"
    [ "${WANT:-0}" -gt "${HAVE:-0}" ] 2>/dev/null && BLOCKED="$BLOCKED $NS/$KIND/$NAME"
done < <(kubectl --context "$SPOKE_CONTEXT" get events -A --field-selector reason=FailedCreate \
    -o jsonpath='{range .items[*]}{.involvedObject.namespace} {.involvedObject.kind} {.involvedObject.name} {.message}{"\n"}{end}' 2>/dev/null \
    | grep -i kyverno | awk '{print $1, $2, $3}' | sort -u)
if [ -z "$BLOCKED" ]; then
    ok "No workloads currently blocked by Kyverno admission on spoke"
else
    for B in $BLOCKED; do fail "Kyverno is blocking pod creation for $B"; done
fi

# --- Kyverno, namespace, pull secret -------------------------------------------
POLICY_READY=$(kubectl --context "$SPOKE_CONTEXT" get clusterpolicy verify-agentforge-signatures \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
[ "$POLICY_READY" = "True" ] && ok "Kyverno ClusterPolicy verify-agentforge-signatures Ready on spoke" || \
    fail "Kyverno ClusterPolicy verify-agentforge-signatures not Ready on spoke (got: ${POLICY_READY:-<not found>})"

NS_LABEL=$(kubectl --context "$SPOKE_CONTEXT" get namespace agentforge \
    -o jsonpath='{.metadata.labels.helmsman\.dev/managed}' 2>/dev/null || echo "")
[ "$NS_LABEL" = "true" ] && ok "Namespace agentforge labelled helmsman.dev/managed=true" || \
    fail "Namespace agentforge missing label helmsman.dev/managed=true (got: ${NS_LABEL:-<none>})"

GHCR_TYPE=$(kubectl --context "$SPOKE_CONTEXT" -n agentforge get secret ghcr-pull-secret \
    -o jsonpath='{.type}' 2>/dev/null || echo "")
[ "$GHCR_TYPE" = "kubernetes.io/dockerconfigjson" ] && ok "ghcr-pull-secret present in agentforge" || \
    fail "ghcr-pull-secret missing in agentforge (got type: ${GHCR_TYPE:-<none>}) — $AF_FIX"

# --- Backups that make the above survive a restart -----------------------------
for B in vault-agentforge.json ghcr-pull-secret.json; do
    if [ -s "$AF_STATE_DIR/$B" ]; then
        ok "Backup $AF_STATE_DIR/$B present ($(date -r "$AF_STATE_DIR/$B" '+%Y-%m-%d %H:%M'))"
    else
        warn "Backup $AF_STATE_DIR/$B missing — a Docker restart now would lose this state for good; run dev-up-gemini.sh"
    fi
done

# --- AgentForge workloads (apps/agentforge chart) ------------------------------
KY_GHCR=$(kubectl --context "$SPOKE_CONTEXT" -n kyverno get secret ghcr-pull-secret -o jsonpath='{.type}' 2>/dev/null || echo "")
[ "$KY_GHCR" = "kubernetes.io/dockerconfigjson" ] && ok "ghcr-pull-secret present in kyverno (image signature checks can authenticate)" || \
    fail "ghcr-pull-secret missing in kyverno namespace — verify-agentforge-signatures can't read private images; $AF_FIX"

# GHCR only accepts classic PATs (ghp_) or gh OAuth tokens (gho_) with
# read:packages. A fine-grained PAT (github_pat_) authenticates but every
# manifest read is 403 — Kyverno then rejects gateway/worker. gh OAuth tokens
# are also replaced by `gh auth refresh` / logout, so test actual access.
GHCR_CHECK=$(kubectl --context "$SPOKE_CONTEXT" -n agentforge get secret ghcr-pull-secret \
    -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 -d 2>/dev/null | \
    IMAGE="$(kubectl --context "$SPOKE_CONTEXT" -n agentforge get deploy agentforge-gateway \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)" python3 -c '
import base64, json, os, sys, urllib.request, urllib.error
try:
    a = json.load(sys.stdin)["auths"]["ghcr.io"]
except Exception:
    print("FAIL unreadable"); sys.exit()
user, tok = (a.get("username"), a.get("password")) if a.get("password") else base64.b64decode(a["auth"]).decode().split(":", 1)
kind = "fine-grained PAT" if tok.startswith("github_pat_") else "classic PAT" if tok.startswith("ghp_") else "gh OAuth token" if tok.startswith("gho_") else "token"
img = os.environ.get("IMAGE") or "ghcr.io/subhankar720/agentforge:latest"
# Kyverno pins verified images as repo:tag@sha256:… — prefer the digest
name, _, digest = img.split("ghcr.io/", 1)[1].partition("@")
repo, _, tag = name.partition(":")
ref = digest or tag or "latest"
basic = base64.b64encode(("%s:%s" % (user, tok)).encode()).decode()
try:
    t = json.load(urllib.request.urlopen(urllib.request.Request(
        "https://ghcr.io/token?scope=repository:%s:pull&service=ghcr.io" % repo,
        headers={"Authorization": "Basic " + basic}), timeout=10))["token"]
    urllib.request.urlopen(urllib.request.Request(
        "https://ghcr.io/v2/%s/manifests/%s" % (repo, ref), method="HEAD",
        headers={"Authorization": "Bearer " + t, "Accept": "application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"}), timeout=10)
    print("OK %s can read %s" % (kind, img))
except urllib.error.HTTPError as e:
    print("FAIL %s cannot read %s (HTTP %s)%s" % (kind, img, e.code,
          " — GHCR rejects fine-grained PATs; use a classic PAT or gh OAuth token with read:packages" if tok.startswith("github_pat_") else ""))
except Exception as e:
    print("WARN could not reach ghcr.io (%s)" % e)
' 2>/dev/null || echo "FAIL ghcr-pull-secret missing in agentforge")
case "$GHCR_CHECK" in
    OK*)   ok   "ghcr-pull-secret: ${GHCR_CHECK#OK }" ;;
    WARN*) warn "ghcr-pull-secret: ${GHCR_CHECK#WARN }" ;;
    *)     fail "ghcr-pull-secret: ${GHCR_CHECK#FAIL }" ;;
esac

AF_ES=$(kubectl --context "$SPOKE_CONTEXT" -n agentforge get externalsecret agentforge-secrets \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
[ "$AF_ES" = "True" ] && ok "ExternalSecret agentforge/agentforge-secrets Ready" || \
    fail "ExternalSecret agentforge/agentforge-secrets not Ready (${AF_ES:-not found}) — check its Vault keys; $AF_FIX"

for W in statefulset/agentforge-postgres statefulset/agentforge-redis deployment/agentforge-flower \
         deployment/agentforge-gateway deployment/agentforge-worker; do
    WANT=$(kubectl --context "$SPOKE_CONTEXT" -n agentforge get "$W" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")
    HAVE=$(kubectl --context "$SPOKE_CONTEXT" -n agentforge get "$W" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "")
    if [ -z "$WANT" ]; then
        REASON=$(kubectl --context "$HUB_CONTEXT" -n argocd get application agentforge \
            -o jsonpath='{.status.operationState.syncResult.resources[?(@.name=="'"${W#*/}"'")].message}' 2>/dev/null \
            | grep -o "failed to verify image[^']*" | head -1 | cut -c1-160)
        fail "AgentForge ${W#*/} not deployed${REASON:+ — Kyverno: $REASON}"
    elif [ "${HAVE:-0}" -ge "$WANT" ] 2>/dev/null; then
        ok "AgentForge ${W#*/} ready (${HAVE}/${WANT})"
    else
        fail "AgentForge ${W#*/} not ready (${HAVE:-0}/${WANT})"
    fi
done

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
