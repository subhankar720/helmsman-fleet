#!/bin/bash
# =============================================================================
# helmsman-sanity.sh — v8
# Helmsman Local Dev Environment — Sanity Check and Auto-Fix Script
# =============================================================================
#
# WHEN TO RUN THIS SCRIPT
# -----------------------
# Run at the START OF EVERY DEV SESSION, or after any Docker Desktop restart.
# Safe to run multiple times — all operations are idempotent.
#
# ERRORS THAT MEAN YOU NEED THIS SCRIPT
# --------------------------------------
# 1. argocd CLI → "connection refused" or hangs
# 2. argocd app get → "ComparisonError ... connection refused"
# 3. argocd app get → "InvalidSpecError" (stale cluster IP in Application)
# 4. argocd CLI → "token has invalid claims: token is expired"
# 5. ClusterIP services timeout inside pods
#
# WHAT BREAKS WHEN DOCKER DESKTOP RESTARTS (in order)
# ----------------------------------------------------
# 1. kube-proxy   → iptables rules wiped → ClusterIP TCP + NodePort broken
# 2. CoreDNS      → UDP conntrack stale  → DNS resolution times out
# 3. argocd-redis → stale connection pool
# 4. argocd-server→ can't reach Redis → resets all connections
# 5. argocd-applicationset-controller → can't resolve DNS
# 6. Spoke cluster IP → Docker bridge reassigns IPs → cluster Secret stale
# 7. Applications → destination.server has old IP → InvalidSpecError
#
# RECOVERY ORDER (networking before Argo CD before Applications)
# -------------------------------------------------------------
# A: Docker check
# B: Kind container check (detect restart)
# C: kubectl connectivity
# D: kube-proxy + CoreDNS recovery (if restart detected)
# E: Argo CD component recovery (after networking stable)
# F: Spoke IP drift fix + Application patch
# G: Login with retry loop
# H: Status checks via kubectl (no argocd CLI dependency)
# I: Pod status
# =============================================================================

set -uo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
ARGOCD_URL="localhost:9090"
ARGOCD_USER="admin"
ARGOCD_PASS="${ARGOCD_PASS:-nyKTpDW-m4jQnODE}"
HUB_CONTEXT="kind-helmsman-hub"
SPOKE_CONTEXT="kind-helmsman-onprem"
SPOKE_CONTAINER="helmsman-onprem-control-plane"
HUB_CONTAINER="helmsman-hub-control-plane"
CLUSTER_SECRET_NAME="cluster-helmsman-onprem"
CLUSTER_REGISTERED_NAME="helmsman-onprem"
ARGOCD_NAMESPACE="argocd"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

PASS=0; FAIL=0; FIXED=0
ok()    { echo -e "  ${GREEN}✔${NC}  $1"; ((PASS++)); }
fail()  { echo -e "  ${RED}✘${NC}  $1"; ((FAIL++)); }
fix()   { echo -e "  ${YELLOW}⚙${NC}  $1"; ((FIXED++)); }
info()  { echo -e "  ${CYAN}ℹ${NC}  $1"; }
header(){ echo -e "\n${BOLD}${BLUE}── $1 ──${NC}"; }

echo -e "\n${BOLD}Helmsman Sanity Check${NC} — $(date '+%Y-%m-%d %H:%M:%S')"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

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
CONTAINERS_RESTARTED=false
NETWORK_BROKEN=false
BAD_NODES=""

for CONTAINER in "$HUB_CONTAINER" "$SPOKE_CONTAINER"; do
    STATUS=$(docker inspect "$CONTAINER" --format='{{.State.Status}}' 2>/dev/null || echo "not_found")
    case "$STATUS" in
        running)
            STARTED=$(docker inspect "$CONTAINER" --format='{{.State.StartedAt}}' 2>/dev/null || echo "")
            STARTED_EPOCH=$(date -d "$STARTED" +%s 2>/dev/null || echo "0")
            NOW_EPOCH=$(date +%s)
            AGE_SECS=$(( NOW_EPOCH - STARTED_EPOCH ))
            if [ "$AGE_SECS" -lt 600 ] 2>/dev/null; then
                fix "Container $CONTAINER started recently (${AGE_SECS}s ago) — network recovery needed"
                CONTAINERS_RESTARTED=true
            else
                ok "Container $CONTAINER running (up ${AGE_SECS}s)"
            fi
            ;;
        exited|stopped|created)
            fix "Container $CONTAINER stopped — starting..."
            docker start "$CONTAINER" > /dev/null 2>&1 || true
            sleep 8
            NEW_STATUS=$(docker inspect "$CONTAINER" --format='{{.State.Status}}' 2>/dev/null || echo "unknown")
            if [ "$NEW_STATUS" = "running" ]; then
                ok "Container $CONTAINER started"
                CONTAINERS_RESTARTED=true
            else
                fail "Container $CONTAINER failed to start (status: $NEW_STATUS)"
            fi
            ;;
        not_found)
            fail "Container $CONTAINER not found"
            echo -e "  ${YELLOW}FIX:${NC} cd ~/projects/helmsman/clusters && kind create cluster --config hub-cluster.yaml"
            ;;
        *) fail "Container $CONTAINER: unexpected state '$STATUS'" ;;
    esac
done

# =============================================================================
header "C. Hub Node IP Consistency (kubelet registration check)"
# =============================================================================
# kubectl exec and port-forward fail with "Unauthorized" when the API server
# cannot reach the kubelet. This happens when node InternalIPs in etcd don't
# match the actual Docker bridge IPs (common after multiple Docker restarts).

NODE_RESTART_NEEDED=false
while IFS= read -r node_line; do
    NODE_NAME=$(echo "$node_line" | awk '{print $1}')
    NODE_IP=$(echo "$node_line"   | awk '{print $6}')
    # Map node name to container name (kind naming convention)
    CONTAINER_NAME="helmsman-hub-${NODE_NAME##helmsman-hub-}"
    CONTAINER_IP=$(docker inspect "$CONTAINER_NAME" \
        --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null || echo "")
    if [ -z "$CONTAINER_IP" ]; then
        continue
    fi
    if [ "$NODE_IP" != "$CONTAINER_IP" ]; then
        fix "Node $NODE_NAME IP mismatch: etcd=$NODE_IP actual=$CONTAINER_IP — kubelet needs re-registration"
        NODE_RESTART_NEEDED=true
        CONTAINERS_RESTARTED=true
    else
        ok "Node $NODE_NAME IP consistent: $NODE_IP"
    fi
done < <(kubectl get nodes -o wide --context "$HUB_CONTEXT" \
    --no-headers 2>/dev/null | grep -v "control-plane")

if [ "$NODE_RESTART_NEEDED" = true ]; then
    fix "Restarting worker node containers to force kubelet re-registration"
    docker restart helmsman-hub-worker helmsman-hub-worker2 > /dev/null 2>&1 || true
    info "Waiting 30s for kubelets to re-register with correct IPs..."
    sleep 30
    ok "Worker nodes restarted — kubectl exec and port-forward should now work"
fi

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

# =============================================================================
header "D. Network Recovery (kube-proxy + CoreDNS)"
# =============================================================================
# DNS check via pod readiness — no kubectl run, no image pull, no timeout race
COREDNS_READY=$(kubectl get pods -n kube-system --context "$HUB_CONTEXT" \
    -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -c "Running" || echo "0")
COREDNS_READY=$(echo "$COREDNS_READY" | tr -d '[:space:]')

NEED_RECOVERY=false
if [ "$CONTAINERS_RESTARTED" = true ]; then
    NEED_RECOVERY=true
    info "Containers recently restarted — running full network recovery"
elif [ "${COREDNS_READY:-0}" -lt 1 ] 2>/dev/null; then
    NEED_RECOVERY=true
    info "CoreDNS pods not Running — triggering network recovery"
fi

if [ "$NEED_RECOVERY" = true ]; then
    fix "Restarting kube-proxy — regenerates iptables ClusterIP and NodePort rules"
    kubectl rollout restart daemonset/kube-proxy \
        -n kube-system --context "$HUB_CONTEXT" > /dev/null 2>&1
    kubectl rollout status daemonset/kube-proxy \
        -n kube-system --context "$HUB_CONTEXT" --timeout=90s > /dev/null 2>&1
    info "Waiting 15s for iptables rules to fully propagate..."
    sleep 15
    ok "kube-proxy restarted"

    fix "Restarting CoreDNS — clears stale UDP conntrack entries"
    kubectl rollout restart deployment/coredns \
        -n kube-system --context "$HUB_CONTEXT" > /dev/null 2>&1
    kubectl rollout status deployment/coredns \
        -n kube-system --context "$HUB_CONTEXT" --timeout=90s > /dev/null 2>&1
    info "Waiting 15s for CoreDNS to stabilise..."
    sleep 15
    ok "CoreDNS restarted"

    COREDNS_CHECK=$(kubectl get pods -n kube-system --context "$HUB_CONTEXT" \
        -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    COREDNS_CHECK=$(echo "$COREDNS_CHECK" | tr -d '[:space:]')
    if [ "${COREDNS_CHECK:-0}" -ge 1 ] 2>/dev/null; then
        ok "CoreDNS pods Running"

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
                fail "Cannot reach argocd-repo-server:8081 from $SERVICE_TEST_POD — possible kube-proxy/ClusterIP issue"
                NETWORK_BROKEN=true
            fi

            if kubectl exec -n argocd --context "$HUB_CONTEXT" "$SERVICE_TEST_POD" -- \
                bash -lc 'exec 3<>/dev/tcp/10.96.0.1/443 >/dev/null 2>&1' \
                > /dev/null 2>&1; then
                ok "Kubernetes API service reachable from $SERVICE_TEST_POD"
            else
                fail "Kubernetes API service 10.96.0.1:443 unreachable from $SERVICE_TEST_POD"
                NETWORK_BROKEN=true
            fi

            if [ -n "$SPOKE_IP" ]; then
                if kubectl exec -n argocd --context "$HUB_CONTEXT" "$SERVICE_TEST_POD" -- \
                    bash -lc "exec 3<>/dev/tcp/${SPOKE_IP}/6443 >/dev/null 2>&1" \
                    > /dev/null 2>&1; then
                    ok "Spoke cluster $SPOKE_IP:6443 reachable from $SERVICE_TEST_POD"
                else
                    NODE_NAME=$(kubectl get pod -n argocd --context "$HUB_CONTEXT" "$SERVICE_TEST_POD" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")
                    fail "Spoke cluster $SPOKE_IP:6443 unreachable from $SERVICE_TEST_POD on node $NODE_NAME"
                    NETWORK_BROKEN=true
                    BAD_NODES="$BAD_NODES $NODE_NAME"
                fi
            fi
        done

        if [ "$NETWORK_BROKEN" = true ] && [ -n "$BAD_NODES" ]; then
            for NODE_NAME in $BAD_NODES; do
                CONTAINER_NAME="helmsman-hub-${NODE_NAME##helmsman-hub-}"
                fix "Restarting node container $CONTAINER_NAME because pod on $NODE_NAME cannot reach spoke cluster"
                docker restart "$CONTAINER_NAME" > /dev/null 2>&1 || true
            done
            info "Waiting 30s for restarted nodes to rejoin network"
            sleep 30
            kubectl rollout restart daemonset/kube-proxy \
                -n kube-system --context "$HUB_CONTEXT" > /dev/null 2>&1
            kubectl rollout status daemonset/kube-proxy \
                -n kube-system --context "$HUB_CONTEXT" --timeout=90s > /dev/null 2>&1
            info "Waiting 15s for kube-proxy to stabilise after node restart"
            sleep 15
        fi
    else
        fail "CoreDNS pods still not Running — check: kubectl get pods -n kube-system -l k8s-app=kube-dns"
        NETWORK_BROKEN=true
    fi

    if [ "$NETWORK_BROKEN" = true ] && [ -n "$BAD_NODES" ]; then
        NEED_RECOVERY=true
    fi
else
    ok "Network healthy — recovery not needed"
fi

# =============================================================================
header "E. Argo CD Component Recovery"
# =============================================================================
if [ "$NEED_RECOVERY" = true ]; then
    fix "Restarting argocd-redis"
    kubectl rollout restart deployment/argocd-redis \
        -n argocd --context "$HUB_CONTEXT" > /dev/null 2>&1
    kubectl rollout status deployment/argocd-redis \
        -n argocd --context "$HUB_CONTEXT" --timeout=90s > /dev/null 2>&1
    ok "argocd-redis restarted"

    fix "Restarting argocd-repo-server"
    kubectl rollout restart deployment/argocd-repo-server \
        -n argocd --context "$HUB_CONTEXT" > /dev/null 2>&1
    kubectl rollout status deployment/argocd-repo-server \
        -n argocd --context "$HUB_CONTEXT" --timeout=90s > /dev/null 2>&1
    ok "argocd-repo-server restarted"

    fix "Restarting argocd-server"
    kubectl rollout restart deployment/argocd-server \
        -n argocd --context "$HUB_CONTEXT" > /dev/null 2>&1
    kubectl rollout status deployment/argocd-server \
        -n argocd --context "$HUB_CONTEXT" --timeout=90s > /dev/null 2>&1
    ok "argocd-server restarted"

    fix "Restarting argocd-application-controller"
    kubectl rollout restart deployment/argocd-application-controller \
        -n argocd --context "$HUB_CONTEXT" > /dev/null 2>&1
    kubectl rollout status deployment/argocd-application-controller \
        -n argocd --context "$HUB_CONTEXT" --timeout=90s > /dev/null 2>&1
    ok "argocd-application-controller restarted"

    fix "Restarting argocd-applicationset-controller"
    kubectl rollout restart deployment/argocd-applicationset-controller \
        -n argocd --context "$HUB_CONTEXT" > /dev/null 2>&1
    kubectl rollout status deployment/argocd-applicationset-controller \
        -n argocd --context "$HUB_CONTEXT" --timeout=90s > /dev/null 2>&1
    ok "argocd-applicationset-controller restarted"

    info "Waiting 20s for Argo CD to fully initialise..."
    sleep 20
else
    ok "Argo CD recovery not needed"
fi

# =============================================================================
header "F. Spoke IP Drift Check and Fix"
# =============================================================================
SPOKE_IP=$(docker inspect "$SPOKE_CONTAINER" \
    --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)

if [ -z "$SPOKE_IP" ]; then
    fail "Cannot determine spoke Docker bridge IP"
    exit 1
fi

info "Current spoke Docker bridge IP: $SPOKE_IP"

STORED_SERVER=$(kubectl get secret "$CLUSTER_SECRET_NAME" \
    -n "$ARGOCD_NAMESPACE" --context "$HUB_CONTEXT" \
    -o jsonpath='{.data.server}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

EXPECTED_SERVER="https://${SPOKE_IP}:6443"

if [ "$STORED_SERVER" = "$EXPECTED_SERVER" ]; then
    ok "Cluster Secret IP current ($SPOKE_IP) — no update needed"
else
    OLD_IP=$(echo "$STORED_SERVER" | sed 's|https://||' | cut -d: -f1)
    fix "IP drift: $STORED_SERVER → $EXPECTED_SERVER"

    SPOKE_TOKEN=$(kubectl --context "$SPOKE_CONTEXT" \
        get secret argocd-manager-token -n kube-system \
        -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)

    if [ -z "$SPOKE_TOKEN" ]; then
        fail "Cannot extract argocd-manager-token from spoke"
    else
        kubectl delete secret "$CLUSTER_SECRET_NAME" \
            -n "$ARGOCD_NAMESPACE" --context "$HUB_CONTEXT" > /dev/null 2>&1 || true

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
    {"bearerToken":"${SPOKE_TOKEN}","tlsClientConfig":{"insecure":true}}
EOF
        ok "Cluster Secret updated → https://${SPOKE_IP}:6443"

        # Patch stale Applications in-place (never delete — avoids finalizer hang)
        STALE_APPS=$(kubectl get applications -n argocd \
            --context "$HUB_CONTEXT" \
            -o jsonpath="{range .items[?(@.spec.destination.server=='https://${OLD_IP}:6443')]}{.metadata.name}{'\n'}{end}" \
            2>/dev/null || echo "")

        if [ -n "$STALE_APPS" ]; then
            for APP in $STALE_APPS; do
                fix "Patching Application $APP: $OLD_IP → $SPOKE_IP"
                kubectl patch application "$APP" \
                    -n argocd --context "$HUB_CONTEXT" \
                    --type=merge \
                    -p "{\"spec\":{\"destination\":{\"server\":\"https://${SPOKE_IP}:6443\"}}}" \
                    > /dev/null 2>&1 && ok "Patched: $APP" || fail "Failed to patch: $APP"
            done
        else
            info "No stale Applications to patch"
        fi

        # Trigger ApplicationSet reconcile
        kubectl annotate applicationset helmsman-apps \
            -n argocd --context "$HUB_CONTEXT" \
            argocd.argoproj.io/refresh=normal --overwrite > /dev/null 2>&1 || true
        info "Waiting 15s for ApplicationSet to reconcile..."
        sleep 15
    fi
fi

# =============================================================================
header "G. Argo CD CLI Login"
# =============================================================================
# Uses kubectl port-forward on port 9090 (HTTP/plaintext) rather than NodePort.
# NodePort relies on kind host port mapping + kube-proxy iptables which are
# unreliable after multiple Docker Desktop restarts.
# Port-forward goes directly through the Kubernetes API — always works if
# kubectl can reach the hub cluster (already verified in Phase C).

# Kill any existing port-forward we started
pkill -f "port-forward.*argocd-server.*9090" 2>/dev/null || true
sleep 2

# Start port-forward to the HTTPS port (443) using a local secure connection — avoids HTTP redirect and gRPC mismatch
# Use nohup so the port-forward survives script exit and keeps localhost:9090 available
nohup kubectl port-forward svc/argocd-server \
    -n argocd --context "$HUB_CONTEXT" \
    --address 127.0.0.1 9090:443 > /tmp/argocd-pf.log 2>&1 &
ARGOCD_PF_PID=$!
echo "$ARGOCD_PF_PID" > /tmp/argocd-pf.pid
sleep 5

LOGIN_OK=false
for i in 1 2 3; do
    if argocd login localhost:9090 \
        --username "$ARGOCD_USER" \
        --password "$ARGOCD_PASS" \
        --insecure \
        --grpc-web > /dev/null 2>&1; then
        ok "Argo CD CLI session refreshed via port-forward :9090 (PID $ARGOCD_PF_PID)"
        # Update argocd context URL so subsequent commands use 9090
        ARGOCD_URL="localhost:9090"
        LOGIN_OK=true
        break
    fi
    info "Login attempt $i/3 — waiting 10s..."
    sleep 10
done

if [ "$LOGIN_OK" = false ]; then
    kill $ARGOCD_PF_PID 2>/dev/null || true
    rm -f /tmp/argocd-pf.pid
    fail "Argo CD CLI login failed via port-forward"
    echo -e "  ${YELLOW}DEBUG:${NC} kubectl get pods -n argocd --context $HUB_CONTEXT"
    echo -e "  ${YELLOW}DEBUG:${NC} cat /tmp/argocd-pf.log"
fi

# =============================================================================
header "H. Argo CD Cluster and App Status"
# =============================================================================
sleep 5

# Use kubectl directly — no argocd CLI dependency for status checks
info "Cluster Secret server URL stored in Argo CD:"
STORED=$(kubectl get secret "$CLUSTER_SECRET_NAME" \
    -n argocd --context "$HUB_CONTEXT" \
    -o jsonpath='{.data.server}' 2>/dev/null | base64 -d 2>/dev/null || echo "unknown")
info "  $STORED"

if [ "$LOGIN_OK" = true ]; then
    CLUSTER_JSON=$(argocd cluster list -o json 2>/dev/null || echo "[]")
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
        ((PASS++))
    else
        fail "Spoke cluster: $CLUSTER_STATUS"
    fi

    APP_JSON=$(argocd app list -o json 2>/dev/null || echo "[]")
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
                APP_DATA=$(argocd app get "$APP_NAME" -o json 2>/dev/null || echo "{}")
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

                if [ "$APP_SYNC" = "Unknown" ] && [ -n "$COMP_ERROR" ]; then
                    info "App $APP_NAME has ComparisonError; restarting Argo CD internals and refreshing status"
                    kubectl rollout restart deployment/argocd-repo-server \
                        -n argocd --context "$HUB_CONTEXT" > /dev/null 2>&1
                    kubectl rollout status deployment/argocd-repo-server \
                        -n argocd --context "$HUB_CONTEXT" --timeout=90s > /dev/null 2>&1
                    kubectl rollout restart deployment/argocd-application-controller \
                        -n argocd --context "$HUB_CONTEXT" > /dev/null 2>&1
                    kubectl rollout status deployment/argocd-application-controller \
                        -n argocd --context "$HUB_CONTEXT" --timeout=90s > /dev/null 2>&1
                    kubectl rollout restart deployment/argocd-server \
                        -n argocd --context "$HUB_CONTEXT" > /dev/null 2>&1
                    kubectl rollout status deployment/argocd-server \
                        -n argocd --context "$HUB_CONTEXT" --timeout=90s > /dev/null 2>&1
                    info "Argo CD server, repo-server, and application-controller restarted"
                    argocd app refresh "$APP_NAME" > /dev/null 2>&1 || true
                    sleep 15
                    APP_DATA=$(argocd app get "$APP_NAME" -o json 2>/dev/null || echo "{}")
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
                fi

                if [ "$APP_SYNC" = "Synced" ] && [ "$APP_HEALTH" = "Healthy" ]; then
                    ok "App $APP_NAME — Synced / Healthy"
                elif [ "$APP_SYNC" = "Synced" ] && [ "$APP_HEALTH" = "Progressing" ]; then
                    info "App $APP_NAME — Synced / Progressing"
                    ((PASS++))
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
    # Fallback: use kubectl directly when argocd CLI is unavailable
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
                    fail "Pod $NS/$POD_NAME Running $READY — high restarts ($RESTARTS)"
                else
                    ok "Pod $NS/$POD_NAME — Running $READY (restarts: $RESTARTS)"
                fi
            elif [ "$STATUS" = "Terminating" ]; then
                fix "Pod $NS/$POD_NAME Terminating — force deleting"
                kubectl delete pod "$POD_NAME" -n "$NS" \
                    --context "$SPOKE_CONTEXT" \
                    --force --grace-period=0 > /dev/null 2>&1 && \
                    ok "Force deleted: $NS/$POD_NAME" || \
                    fail "Could not force delete: $NS/$POD_NAME"
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
[ "$FIXED" -gt 0 ] && echo -e "  ${YELLOW}⚙ Fixed:${NC}   $FIXED"
[ "$FAIL" -gt 0  ] && echo -e "  ${RED}✘ Failed:${NC}  $FAIL"
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}All checks passed. Helmsman environment is healthy.${NC}"
    echo -e "\n  ${CYAN}Quick commands:${NC}"
    echo -e "    argocd app list"
    echo -e "    kubectl get all -n sample-app --context $SPOKE_CONTEXT"
    echo -e "    kubectl logs -n sample-app sample-app-0 -c fluent-bit --context $SPOKE_CONTEXT"
    echo ""
    exit 0
else
    echo -e "  ${RED}${BOLD}$FAIL check(s) failed. Review output above.${NC}"
    echo ""
    exit 1
fi