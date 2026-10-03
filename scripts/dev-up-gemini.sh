#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# dev-up.sh — Helmsman Local Platform Bootstrap & Recovery Script
# =============================================================================
#
# MODES:
#   ./scripts/dev-up.sh            Non-reset: recover after Docker Desktop restart
#   ./scripts/dev-up.sh --reset    Full rebuild: destroy clusters, recreate everything
#
# WHEN TO USE EACH MODE:
#   Non-reset: Docker Desktop restarted, clusters still exist, IPs changed
#   Reset:     Kind clusters destroyed/corrupted, need a completely fresh start
#
# STATE OUTSIDE GIT (backed up to ~/.helmsman-dev/ on every run, restored by
# Stage 10.5): Vault secret/agentforge/*, Keycloak agentforge-gateway client +
# groups + user, agentforge ghcr-pull-secret. See helmsman-sanity.sh section K.
#
# LOCATION:
#   Identical copies live at helmsman-fleet/scripts/dev-up-gemini.sh and
#   helmsman-operator/dev-up-gemini.sh — keep them in sync. Repo paths are
#   resolved below so either copy works; override with FLEET_DIR / OPERATOR_DIR.

# =============================================================================
# Configuration — update if you change cluster names or passwords
# =============================================================================
HUB_CLUSTER_NAME="helmsman-hub"
SPOKE_CLUSTER_NAME="helmsman-onprem"
HUB_CTX="kind-${HUB_CLUSTER_NAME}"
SPOKE_CTX="kind-${SPOKE_CLUSTER_NAME}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -z "${FLEET_DIR:-}" ]; then
  if [ -d "$SCRIPT_DIR/../clusters" ]; then
    FLEET_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"                  # helmsman-fleet/scripts/
  else
    FLEET_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/helmsman-fleet"    # helmsman-operator/
  fi
fi
if [ -z "${OPERATOR_DIR:-}" ]; then
  if [ -f "$SCRIPT_DIR/Dockerfile" ] && [ -d "$SCRIPT_DIR/config/default" ]; then
    OPERATOR_DIR="$SCRIPT_DIR"
  else
    OPERATOR_DIR="$(dirname "$FLEET_DIR")/helmsman-operator"
  fi
fi
CLUSTERS_DIR="$FLEET_DIR/clusters"

# Persisted outside /tmp so it survives reboots. Falls back to the legacy
# /tmp location written by older versions of this script.
ARGOCD_PASS_FILE="${ARGOCD_PASS_FILE:-$HOME/.helmsman-dev/argocd-admin-password}"
if [ ! -f "$ARGOCD_PASS_FILE" ] && [ -f /tmp/helmsman-argocd-pass ]; then
  mkdir -p "$(dirname "$ARGOCD_PASS_FILE")"
  tr -d '\n' < /tmp/helmsman-argocd-pass > "$ARGOCD_PASS_FILE"
  chmod 600 "$ARGOCD_PASS_FILE"
fi
if [ -z "${ARGOCD_PASS:-}" ] && [ -f "$ARGOCD_PASS_FILE" ]; then
  ARGOCD_PASS="$(cat "$ARGOCD_PASS_FILE")"
fi
ARGOCD_PASS="${ARGOCD_PASS:-nyKTpDW-m4jQnODE}"  # override via env var after password change
ARGOCD_USER="admin"
ARGOCD_NAMESPACE="argocd"
ARGOCD_PF_PORT="9090"               # port-forward port for argocd CLI
ARGOCD_PF_PID=""

KEYCLOAK_ADMIN_USER="${KEYCLOAK_ADMIN_USER:-admin}"
KEYCLOAK_ADMIN_PASS="${KEYCLOAK_ADMIN_PASS:-admin}"   # matches keycloak-admin-credentials Secret
VAULT_TOKEN="${VAULT_TOKEN:-root}"                    # dev mode root token

FLEET_REPO="https://github.com/subhankar720/helmsman-fleet.git"
CLUSTER_SECRET_NAME="cluster-helmsman-onprem"
ARGOCD_MANAGER_SA="argocd-manager"

OPERATOR_DEPLOY="helmsman-operator-controller-manager"
OPERATOR_NS="helmsman-operator-system"

# Durable state that must outlive the clusters. Vault runs in -dev mode
# (in-memory) and Keycloak has no PVC, so anything written to them at runtime
# is gone after a Docker restart — Stage 10.5 restores it from here.
HELMSMAN_STATE_DIR="${HELMSMAN_STATE_DIR:-$HOME/.helmsman-dev}"
AF_VAULT_BACKUP="$HELMSMAN_STATE_DIR/vault-agentforge.json"
AF_GHCR_BACKUP="$HELMSMAN_STATE_DIR/ghcr-pull-secret.json"
AF_USER_PASS_FILE="$HELMSMAN_STATE_DIR/keycloak-agentforge-user-password"
AF_VAULT_PATHS="auth llm db cache confluence"
AF_KC_CLIENT="agentforge-gateway"
AF_KC_GROUPS="dev-team platform-team readonly"
AF_KC_USER="subhankar"
AF_KC_USER_EMAIL="subhankar@helmsman.dev"
AF_KC_USER_FIRST="Subhankar"
AF_KC_USER_LAST="Padhy"
AF_KC_USER_GROUP="dev-team"
AF_KC_PF_PORT="18081"

RESET_MODE=false

# =============================================================================
# Color helpers
# =============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "\n${BOLD}${CYAN}── $1 ──${NC}"; }

kill_port_process() {
    local port="$1"
    if command -v fuser >/dev/null 2>&1; then
        fuser -k "${port}/tcp" 2>/dev/null || true
    elif command -v lsof >/dev/null 2>&1; then
        lsof -ti:"${port}" | xargs kill -9 2>/dev/null || true
    fi
    pkill -f "port-forward.*${port}" 2>/dev/null || true
}

cleanup() {
    if [ -n "$ARGOCD_PF_PID" ]; then
        kill "$ARGOCD_PF_PID" 2>/dev/null || true
    fi
    kill_port_process "${ARGOCD_PF_PORT}"
}
trap cleanup EXIT

# =============================================================================
# Argument parsing
# =============================================================================
for arg in "$@"; do
  case $arg in
    --reset|--clean|-c) RESET_MODE=true ;;
    --help|-h)
      echo "Usage: ./scripts/dev-up.sh [OPTIONS]"
      echo "  --reset, --clean, -c    Full rebuild from scratch"
      echo "  --help, -h              Show this help"
      exit 0 ;;
  esac
done

echo -e "\n${BOLD}${BLUE}========================================${NC}"
echo -e "${BOLD}${BLUE}  Helmsman Platform Bootstrap           ${NC}"
if $RESET_MODE; then
  echo -e "${BOLD}${RED}  Mode: FULL RESET                      ${NC}"
else
  echo -e "${BOLD}${GREEN}  Mode: RECOVERY (Docker restart)       ${NC}"
fi
echo -e "${BOLD}${BLUE}========================================${NC}\n"

# =============================================================================
# RESET MODE — destroy and recreate clusters
# =============================================================================
if $RESET_MODE; then
  log_step "Stage R1: Destroying existing Kind clusters"
  kind delete cluster --name "$HUB_CLUSTER_NAME" 2>/dev/null && log_ok "Hub cluster deleted" || log_warn "Hub cluster not found"
  kind delete cluster --name "$SPOKE_CLUSTER_NAME" 2>/dev/null && log_ok "Spoke cluster deleted" || log_warn "Spoke cluster not found"

  log_step "Stage R2: Creating fresh Kind clusters"
  if [ -f "$CLUSTERS_DIR/hub-cluster.yaml" ]; then
    kind create cluster --config "$CLUSTERS_DIR/hub-cluster.yaml"
  else
    log_error "hub-cluster.yaml not found in $CLUSTERS_DIR"
    exit 1
  fi
  log_ok "Hub cluster created"

  if [ -f "$CLUSTERS_DIR/onprem-spoke-cluster.yaml" ]; then
    kind create cluster --config "$CLUSTERS_DIR/onprem-spoke-cluster.yaml"
  else
    log_error "onprem-spoke-cluster.yaml not found in $CLUSTERS_DIR"
    exit 1
  fi
  log_ok "Spoke cluster created"

  log_step "Stage R3: Installing Argo CD on Hub"
  kubectl --context "$HUB_CTX" create namespace argocd --dry-run=client -o yaml | \
    kubectl --context "$HUB_CTX" apply -f -

  # Fix: Use --server-side --force-conflicts to prevent "annotation too long (>256KB)" on CRDs
  kubectl --context "$HUB_CTX" apply --server-side --force-conflicts -n argocd \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

  # Fix: Increase git clone timeout for initial large repository fetches
  kubectl --context "$HUB_CTX" patch configmap argocd-cmd-params-cm \
    -n argocd --type merge \
    -p '{"data":{"reposerver.git.request.timeout":"300"}}'

  # Wait sequentially for backend dependencies before checking argocd-server
  log_info "Waiting for Argo CD backend dependencies (redis, repo-server)..."
  kubectl --context "$HUB_CTX" rollout status deployment/argocd-redis -n argocd --timeout=300s
  kubectl --context "$HUB_CTX" rollout status deployment/argocd-repo-server -n argocd --timeout=300s

  log_info "Waiting for argocd-server to be ready..."
  kubectl --context "$HUB_CTX" rollout status deployment/argocd-server -n argocd --timeout=300s

  # Ensure pods have the Ready condition set
  kubectl --context "$HUB_CTX" wait --for=condition=ready pod \
    -l app.kubernetes.io/name=argocd-server -n argocd --timeout=60s

  # Patch argocd-server to NodePort 30080 for browser/CLI access
  kubectl --context "$HUB_CTX" patch svc argocd-server -n argocd \
    -p '{"spec":{"type":"NodePort","ports":[{"port":443,"targetPort":8080,"nodePort":30080}]}}'

  # Get and save admin password
  ARGOCD_PASS=$(kubectl --context "$HUB_CTX" \
    get secret argocd-initial-admin-secret -n argocd \
    -o jsonpath="{.data.password}" | base64 -d)
  mkdir -p "$(dirname "$ARGOCD_PASS_FILE")"
  echo -n "$ARGOCD_PASS" > "$ARGOCD_PASS_FILE"
  chmod 600 "$ARGOCD_PASS_FILE"
  log_ok "Argo CD installed. Admin password saved to $ARGOCD_PASS_FILE"
  kubectl --context "$HUB_CTX" delete secret argocd-initial-admin-secret -n argocd

  # Restart repo-server to pick up timeout config
  kubectl --context "$HUB_CTX" rollout restart deployment/argocd-repo-server -n argocd
  kubectl --context "$HUB_CTX" rollout status deployment/argocd-repo-server \
    -n argocd --timeout=120s

  log_step "Stage R3.5: Pre-seeding Hub Platform Bootstrap Secrets"
  # Create Keycloak namespace and secret to prevent CreateContainerConfigError
  kubectl --context "$HUB_CTX" create namespace keycloak --dry-run=client -o yaml | \
    kubectl --context "$HUB_CTX" apply -f -
  
  kubectl --context "$HUB_CTX" create secret generic keycloak-admin-credentials \
    -n keycloak \
    --from-literal=admin-user="$KEYCLOAK_ADMIN_USER" \
    --from-literal=admin-password="$KEYCLOAK_ADMIN_PASS" \
    --from-literal=username="$KEYCLOAK_ADMIN_USER" \
    --from-literal=password="$KEYCLOAK_ADMIN_PASS" \
    --dry-run=client -o yaml | kubectl --context "$HUB_CTX" apply -f -
  log_ok "Keycloak admin credentials pre-seeded on Hub"

  log_step "Stage R4: Setting up Argo CD port-forward and login"
  kill_port_process "${ARGOCD_PF_PORT}"
  sleep 2
  kubectl --context "$HUB_CTX" port-forward svc/argocd-server \
    -n argocd "${ARGOCD_PF_PORT}":80 > /tmp/argocd-pf.log 2>&1 &
  ARGOCD_PF_PID=$!
  sleep 8

  if [ -f "$ARGOCD_PASS_FILE" ]; then
    ARGOCD_PASS=$(cat "$ARGOCD_PASS_FILE")
  fi
  
  for attempt in 1 2 3; do
    if argocd login "localhost:${ARGOCD_PF_PORT}" \
        --username "$ARGOCD_USER" \
        --password "$ARGOCD_PASS" \
        --insecure > /dev/null 2>&1; then
      log_ok "Argo CD CLI logged in"
      break
    fi
    log_warn "Login attempt $attempt failed, retrying..."
    sleep 10
  done

  log_step "Stage R5: Registering fleet repository"
  argocd repo add "$FLEET_REPO" --server "localhost:${ARGOCD_PF_PORT}" --insecure 2>/dev/null || true
  log_ok "Fleet repo registered: $FLEET_REPO"

  log_step "Stage R6: Registering spoke cluster"
  kubectl --context "$SPOKE_CTX" apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-manager
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: argocd-manager-role
rules:
- apiGroups: ['*']
  resources: ['*']
  verbs: ['*']
- nonResourceURLs: ['*']
  verbs: ['*']
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-manager-role-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: argocd-manager-role
subjects:
- kind: ServiceAccount
  name: argocd-manager
  namespace: kube-system
---
apiVersion: v1
kind: Secret
metadata:
  name: argocd-manager-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: argocd-manager
type: kubernetes.io/service-account-token
EOF

  sleep 5
  SPOKE_TOKEN=$(kubectl --context "$SPOKE_CTX" \
    get secret argocd-manager-token -n kube-system \
    -o jsonpath='{.data.token}' | base64 -d)

  SPOKE_IP=$(docker inspect "${SPOKE_CLUSTER_NAME}-control-plane" \
    --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')

  kubectl --context "$HUB_CTX" apply -f - <<EOF
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
  name: helmsman-onprem
  server: https://${SPOKE_IP}:6443
  config: |
    {"bearerToken":"${SPOKE_TOKEN}","tlsClientConfig":{"insecure":true}}
EOF
  log_ok "Spoke cluster registered at https://${SPOKE_IP}:6443"

  log_step "Stage R6.5: Pre-seeding Spoke Platform Bootstrap Secrets"
  kubectl --context "$SPOKE_CTX" create namespace external-secrets --dry-run=client -o yaml | \
    kubectl --context "$SPOKE_CTX" apply -f -
  
  kubectl --context "$SPOKE_CTX" create secret generic vault-token \
    -n external-secrets \
    --from-literal=token="$VAULT_TOKEN" \
    --dry-run=client -o yaml | kubectl --context "$SPOKE_CTX" apply -f -
  log_ok "Vault token secret pre-seeded on Spoke for ESO"

  log_step "Stage R7: Applying platform Argo CD Applications from fleet repo"
  TMP_FLEET=$(mktemp -d)
  git clone --depth=1 "$FLEET_REPO" "$TMP_FLEET" 2>/dev/null
  
  for app_file in "$TMP_FLEET"/platform/*/argocd-application.yaml \
                  "$TMP_FLEET"/platform/kyverno/policies/argocd-application.yaml \
                  "$TMP_FLEET"/platform/envoy-gateway/spoke-application.yaml \
                  "$TMP_FLEET"/apps/*/argocd-application.yaml; do
    if [ -f "$app_file" ]; then
      kubectl --context "$HUB_CTX" apply -f "$app_file"
      log_ok "Applied: $app_file"
    fi
  done

  # platform/observability/ doesn't follow the argocd-application.yaml naming
  # convention (loki-application.yaml, loki-nodeport.yaml, kube-prometheus-
  # stack-application.yaml, and spoke/promtail-application.yaml nested a level
  # deeper) — the glob above misses it entirely, so apply it explicitly.
  if [ -d "$TMP_FLEET/platform/observability" ]; then
    find "$TMP_FLEET/platform/observability" -name "*.yaml" -print0 | \
      while IFS= read -r -d '' obs_file; do
        kubectl --context "$HUB_CTX" apply -f "$obs_file"
        log_ok "Applied: $obs_file"
      done
  fi

  if [ -f "$TMP_FLEET/applicationsets/apps-appset.yaml" ]; then
    kubectl --context "$HUB_CTX" apply -f "$TMP_FLEET/applicationsets/apps-appset.yaml"
    log_ok "Applied: helmsman-apps ApplicationSet"
  fi

  rm -rf "$TMP_FLEET"
  log_info "Waiting 30s for platform apps to begin syncing..."
  sleep 30

fi
# =============================================================================
# END RESET MODE
# =============================================================================

# =============================================================================
# Stage 1: Container health — start any stopped containers
# =============================================================================
log_step "Stage 1: Kind Container Health"

ALL_CONTAINERS=(
  "${HUB_CLUSTER_NAME}-control-plane"
  "${HUB_CLUSTER_NAME}-worker"
  "${HUB_CLUSTER_NAME}-worker2"
  "${SPOKE_CLUSTER_NAME}-control-plane"
  "${SPOKE_CLUSTER_NAME}-worker"
)

CONTAINERS_STARTED=false
for CONTAINER in "${ALL_CONTAINERS[@]}"; do
  STATUS=$(docker inspect "$CONTAINER" --format='{{.State.Status}}' 2>/dev/null || echo "not_found")
  CONTAINER_IP=$(docker inspect "$CONTAINER" \
    --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null || echo "")
  case "$STATUS" in
    running)
      if [ -z "$CONTAINER_IP" ] || [ "$CONTAINER_IP" = "invalid IP" ]; then
        log_warn "$CONTAINER has no IP — restarting..."
        docker restart "$CONTAINER" > /dev/null 2>&1 || true
        CONTAINERS_STARTED=true
      else
        log_ok "$CONTAINER running ($CONTAINER_IP)"
      fi
      ;;
    exited|stopped|created)
      log_warn "$CONTAINER is stopped — starting..."
      docker start "$CONTAINER" > /dev/null 2>&1 || true
      CONTAINERS_STARTED=true
      ;;
    not_found)
      log_error "$CONTAINER not found. Run with --reset to recreate clusters."
      exit 1
      ;;
  esac
done

if $CONTAINERS_STARTED; then
  log_info "Containers started — waiting 25s for API servers..."
  sleep 25
fi

# =============================================================================
# Stage 2: Discover IPs
# =============================================================================
log_step "Stage 2: IP Discovery"

HUB_IP=$(docker inspect "${HUB_CLUSTER_NAME}-worker" \
  --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null || \
  docker inspect "${HUB_CLUSTER_NAME}-control-plane" \
  --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')

SPOKE_IP=$(docker inspect "${SPOKE_CLUSTER_NAME}-control-plane" \
  --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')

if [ -z "$HUB_IP" ] || [ -z "$SPOKE_IP" ]; then
  log_error "Could not determine cluster IPs — are containers running?"
  exit 1
fi
log_ok "Hub worker IP: $HUB_IP"
log_ok "Spoke control-plane IP: $SPOKE_IP"

kubectl --context "$HUB_CTX" get nodes --no-headers > /dev/null 2>&1 && \
  log_ok "Hub API server reachable" || { log_error "Hub API server not responding"; exit 1; }
kubectl --context "$SPOKE_CTX" get nodes --no-headers > /dev/null 2>&1 && \
  log_ok "Spoke API server reachable" || { log_error "Spoke API server not responding"; exit 1; }

# =============================================================================
# Stage 3: Network Recovery (kube-proxy + kindnet + CoreDNS, Hub and Spoke)
# =============================================================================
# After a Docker restart kube-proxy rules and CoreDNS conntrack go stale, and
# kindnet can lose its API watch (log: "Failed to watch … NetworkPolicy … TLS
# handshake timeout"). kindnet then enforces stale NetworkPolicy rules and
# silently drops traffic into namespaces that have policies (sample-app).
log_step "Stage 3: Network Recovery"

# kind ships kindnet with a 100m CPU limit. kindnet also enforces
# NetworkPolicy by judging every new pod connection in userspace (nfqueue),
# and at 100m it was CPU-throttled in >99% of periods: API watches timed out
# and queued connections stalled (Argo CD/CoreDNS on the hub, sample-app on
# the spoke). Give it real headroom; kind re-creates it with the default on
# --reset, so this is enforced on every run.
KINDNET_RESOURCES='{"requests":{"cpu":"100m","memory":"50Mi"},"limits":{"cpu":"1","memory":"256Mi"}}'
for NET_CTX in "$HUB_CTX" "$SPOKE_CTX"; do
  KINDNET_CPU_LIMIT=$(kubectl --context "$NET_CTX" -n kube-system get ds kindnet \
    -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}' 2>/dev/null || echo "")
  if [ "$KINDNET_CPU_LIMIT" = "1" ]; then
    log_ok "kindnet CPU limit OK on $NET_CTX"
  elif kubectl --context "$NET_CTX" -n kube-system patch ds kindnet --type=json \
      -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/resources\",\"value\":${KINDNET_RESOURCES}}]" \
      > /dev/null 2>&1; then
    kubectl --context "$NET_CTX" -n kube-system rollout status ds/kindnet --timeout=120s > /dev/null 2>&1 || true
    log_ok "kindnet CPU limit raised ${KINDNET_CPU_LIMIT:-?} → 1 on $NET_CTX"
  else
    log_warn "Could not patch kindnet resources on $NET_CTX"
  fi
done

for NET_CTX in "$HUB_CTX" "$SPOKE_CTX"; do
  NET_LABEL=$([ "$NET_CTX" = "$HUB_CTX" ] && echo Hub || echo Spoke)
  COREDNS_READY=$(kubectl --context "$NET_CTX" get pods -n kube-system \
    -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -c "Running" || true)
  KINDNET_WATCH_ERRORS=$(kubectl --context "$NET_CTX" logs -n kube-system -l app=kindnet \
    --since=10m --tail=-1 2>/dev/null | grep -c "Failed to watch" || true)

  NET_REASON=""
  $CONTAINERS_STARTED && NET_REASON="containers restarted"
  [ "${COREDNS_READY:-0}" -lt 1 ] && NET_REASON="CoreDNS not Running"
  [ "${KINDNET_WATCH_ERRORS:-0}" -gt 0 ] && NET_REASON="kindnet lost its API watch (${KINDNET_WATCH_ERRORS} errors in 10m)"

  if [ -n "$NET_REASON" ]; then
    log_info "$NET_LABEL network recovery: $NET_REASON"
    for NET_RES in daemonset/kube-proxy daemonset/kindnet deployment/coredns; do
      kubectl --context "$NET_CTX" rollout restart "$NET_RES" -n kube-system > /dev/null 2>&1 || true
      if kubectl --context "$NET_CTX" rollout status "$NET_RES" -n kube-system --timeout=90s > /dev/null 2>&1; then
        log_ok "${NET_RES#*/} restarted on $NET_LABEL"
      else
        log_warn "${NET_RES#*/} restart on $NET_LABEL did not finish within 90s"
      fi
    done
    NETWORK_RECOVERED=true
  else
    log_ok "$NET_LABEL network healthy — skipping recovery"
  fi
done

if ${NETWORK_RECOVERED:-false}; then
  log_info "Waiting 15s for DNS to stabilise..."
  sleep 15
fi

# =============================================================================
# Stage 4: Argo CD Component Recovery
# =============================================================================
log_step "Stage 4: Argo CD Recovery"

if $CONTAINERS_STARTED; then
  for COMPONENT in argocd-redis argocd-server argocd-applicationset-controller; do
    kubectl --context "$HUB_CTX" rollout restart "deployment/$COMPONENT" \
      -n argocd > /dev/null 2>&1
    kubectl --context "$HUB_CTX" rollout status "deployment/$COMPONENT" \
      -n argocd --timeout=90s > /dev/null 2>&1
    log_ok "$COMPONENT restarted"
  done
  log_info "Waiting 15s for Argo CD to initialise..."
  sleep 15
else
  log_ok "Argo CD recovery not needed"
fi

# =============================================================================
# Stage 4.5: Helmsman Operator Deployment (Spoke)
# =============================================================================
# Runs after Stages 1–3 so the spoke API server and node networking are up.
# Builds from OPERATOR_DIR; skipped (with a warning) if that repo isn't present.
log_step "Stage 4.5: Helmsman Operator Deployment"

if [ -f "$OPERATOR_DIR/Dockerfile" ] && [ -d "$OPERATOR_DIR/config/default" ]; then
  log_info "Building operator image from $OPERATOR_DIR..."
  if docker build -t helmsman-operator:dev \
      --build-arg TARGETOS=linux \
      --build-arg TARGETARCH=amd64 \
      -f "$OPERATOR_DIR/Dockerfile" "$OPERATOR_DIR" > /dev/null 2>&1; then
    kind load docker-image helmsman-operator:dev --name "$SPOKE_CLUSTER_NAME" > /dev/null 2>&1 && \
      log_ok "Operator image loaded into Spoke cluster" || \
      log_warn "kind load docker-image failed"
  else
    log_warn "Operator image build failed, will use the image already on the Spoke"
  fi

  OPERATOR_MANIFESTS="$(mktemp /tmp/helmsman-operator-manifests.XXXXXX.yaml)"

  log_info "Generating operator manifests..."
  (cd "$OPERATOR_DIR" && make manifests > /dev/null 2>&1) && \
    log_ok "CRDs and RBAC generated" || log_warn "make manifests failed"

  if [ -x "$OPERATOR_DIR/bin/kustomize" ]; then
    if (cd "$OPERATOR_DIR" && ./bin/kustomize build config/default) > "$OPERATOR_MANIFESTS" 2>/dev/null; then
      log_ok "Manifests built via kustomize ($(wc -l < "$OPERATOR_MANIFESTS") lines)"
    else
      log_warn "kustomize build failed"
    fi
  else
    log_warn "$OPERATOR_DIR/bin/kustomize not found — run 'make kustomize' in the operator repo"
  fi

  if [ -s "$OPERATOR_MANIFESTS" ]; then
    sed -i 's|image: controller:latest|image: helmsman-operator:dev|g' "$OPERATOR_MANIFESTS"
    sed -i 's|image: ghcr.io/subhankar720/helmsman-operator:latest|image: helmsman-operator:dev|g' "$OPERATOR_MANIFESTS"
    kubectl --context "$SPOKE_CTX" apply -f "$OPERATOR_MANIFESTS" > /dev/null 2>&1 && \
      log_ok "Operator manifests applied to Spoke" || log_warn "Operator manifest apply failed"
  fi
  rm -f "$OPERATOR_MANIFESTS"

  if kubectl --context "$SPOKE_CTX" get deployment "$OPERATOR_DEPLOY" -n "$OPERATOR_NS" >/dev/null 2>&1; then
    # helmsman-operator:dev only exists in the kind node's image store
    kubectl --context "$SPOKE_CTX" patch deployment "$OPERATOR_DEPLOY" -n "$OPERATOR_NS" \
      --type='json' \
      -p='[{"op": "add", "path": "/spec/template/spec/containers/0/imagePullPolicy", "value": "Never"}]' > /dev/null 2>&1 || true
    # Pick up a freshly loaded :dev image even if the pod spec didn't change
    kubectl --context "$SPOKE_CTX" rollout restart "deployment/$OPERATOR_DEPLOY" -n "$OPERATOR_NS" > /dev/null 2>&1 || true
    log_info "Waiting for operator deployment to be ready..."
    kubectl --context "$SPOKE_CTX" rollout status "deployment/$OPERATOR_DEPLOY" \
      -n "$OPERATOR_NS" --timeout=180s > /dev/null 2>&1 && \
      log_ok "Helmsman operator is running on Spoke" || \
      log_warn "Operator rollout not complete — check: kubectl --context $SPOKE_CTX -n $OPERATOR_NS get pods"
  fi
else
  log_warn "Operator repo not found at $OPERATOR_DIR — skipping (set OPERATOR_DIR to override)"
fi

# =============================================================================
# Stage 5: Update Spoke Cluster Secret
# =============================================================================
log_step "Stage 5: Spoke Cluster IP Sync"

STORED_SERVER=$(kubectl --context "$HUB_CTX" \
  get secret "$CLUSTER_SECRET_NAME" -n argocd \
  -o jsonpath='{.data.server}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
EXPECTED_SERVER="https://${SPOKE_IP}:6443"

if [ "$STORED_SERVER" != "$EXPECTED_SERVER" ]; then
  log_warn "Spoke IP drift detected: $STORED_SERVER → $EXPECTED_SERVER"
  OLD_SPOKE_IP=$(echo "$STORED_SERVER" | sed 's|https://||' | cut -d: -f1)

  SPOKE_TOKEN=$(kubectl --context "$SPOKE_CTX" \
    get secret argocd-manager-token -n kube-system \
    -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)

  kubectl --context "$HUB_CTX" delete secret "$CLUSTER_SECRET_NAME" \
    -n argocd > /dev/null 2>&1 || true

  kubectl --context "$HUB_CTX" apply -f - <<EOF > /dev/null
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
  name: helmsman-onprem
  server: https://${SPOKE_IP}:6443
  config: |
    {"bearerToken":"${SPOKE_TOKEN}","tlsClientConfig":{"insecure":true}}
EOF
  log_ok "Cluster Secret updated → https://${SPOKE_IP}:6443"

  if [ -n "${OLD_SPOKE_IP:-}" ]; then
    STALE_APPS=$(kubectl --context "$HUB_CTX" get applications -n argocd \
      -o jsonpath="{range .items[?(@.spec.destination.server=='https://${OLD_SPOKE_IP}:6443')]}{.metadata.name}{'\n'}{end}" \
      2>/dev/null || echo "")
    if [ -n "$STALE_APPS" ]; then
      while IFS= read -r APP; do
        [ -z "$APP" ] && continue
        kubectl --context "$HUB_CTX" patch application "$APP" -n argocd \
          --type=merge \
          -p "{\"spec\":{\"destination\":{\"server\":\"https://${SPOKE_IP}:6443\"}}}" \
          > /dev/null 2>&1 && log_ok "Patched Application: $APP" || true
      done <<< "$STALE_APPS"
    fi
  fi

  kubectl --context "$HUB_CTX" annotate applicationset helmsman-apps \
    -n argocd argocd.argoproj.io/refresh=normal \
    --overwrite > /dev/null 2>&1 || true
  sleep 10
else
  log_ok "Spoke cluster IP current ($SPOKE_IP)"
fi

# =============================================================================
# Stage 6: Update helmsman-platform-config & hub secrets
# =============================================================================
log_step "Stage 6: Platform Secrets Sync"

# Ensure Keycloak admin credentials exist on Hub during recovery mode
kubectl --context "$HUB_CTX" create namespace keycloak --dry-run=client -o yaml | \
  kubectl --context "$HUB_CTX" apply -f - > /dev/null 2>&1 || true

kubectl --context "$HUB_CTX" create secret generic keycloak-admin-credentials \
  -n keycloak \
  --from-literal=admin-user="$KEYCLOAK_ADMIN_USER" \
  --from-literal=admin-password="$KEYCLOAK_ADMIN_PASS" \
  --from-literal=username="$KEYCLOAK_ADMIN_USER" \
  --from-literal=password="$KEYCLOAK_ADMIN_PASS" \
  --dry-run=client -o yaml | \
  kubectl --context "$HUB_CTX" apply -f - > /dev/null 2>&1 || true
log_ok "keycloak-admin-credentials verified on Hub"

APP_NAMESPACES=$(kubectl --context "$SPOKE_CTX" get namespaces \
  --no-headers -o custom-columns=":metadata.name" 2>/dev/null \
  | grep -v "^kube-\|^default\|^local-path\|^external-secrets\|^kyverno" || echo "sample-app")

for NS in $APP_NAMESPACES; do
  kubectl --context "$SPOKE_CTX" create namespace "$NS" --dry-run=client -o yaml | \
    kubectl --context "$SPOKE_CTX" apply -f - > /dev/null 2>&1 || true

  kubectl --context "$SPOKE_CTX" create secret generic helmsman-platform-config \
    -n "$NS" \
    --from-literal=keycloak-url="http://${HUB_IP}:30081" \
    --from-literal=keycloak-oidc-url="http://host.docker.internal:8081" \
    --from-literal=keycloak-admin-user="$KEYCLOAK_ADMIN_USER" \
    --from-literal=keycloak-admin-password="$KEYCLOAK_ADMIN_PASS" \
    --from-literal=keycloak-realm="helmsman" \
    --from-literal=vault-url="http://${HUB_IP}:30082" \
    --from-literal=vault-token="$VAULT_TOKEN" \
    --from-literal=cluster-name="$SPOKE_CLUSTER_NAME" \
    --dry-run=client -o yaml | \
    kubectl --context "$SPOKE_CTX" apply -f - > /dev/null 2>&1 || true
  log_ok "helmsman-platform-config updated in namespace: $NS"
done

kubectl --context "$SPOKE_CTX" create namespace external-secrets --dry-run=client -o yaml | \
  kubectl --context "$SPOKE_CTX" apply -f - > /dev/null 2>&1 || true

kubectl --context "$SPOKE_CTX" create secret generic vault-token \
  -n external-secrets \
  --from-literal=token="$VAULT_TOKEN" \
  --dry-run=client -o yaml | \
  kubectl --context "$SPOKE_CTX" apply -f - > /dev/null 2>&1 || true
log_ok "vault-token Secret ensured in external-secrets namespace"

# =============================================================================
# Stage 7: Update ESO ClusterSecretStore Vault URL
# =============================================================================
log_step "Stage 7: ESO ClusterSecretStore Sync"

# ESO CRDs come from platform-eso; on a fresh --reset they may not exist yet
# (Stage 10 re-applies the store after ESO syncs).
log_info "Waiting for External Secrets CRDs on Spoke cluster..."
CRD_READY=false
for i in {1..30}; do
  if kubectl --context "$SPOKE_CTX" get crd clustersecretstores.external-secrets.io >/dev/null 2>&1; then
    CRD_READY=true
    break
  fi
  sleep 3
done

if $CRD_READY; then
# Ensure resource is applied on Spoke immediately with current HUB_IP
kubectl --context "$SPOKE_CTX" apply -f - <<EOF > /dev/null 2>&1 || log_warn "ClusterSecretStore apply failed"
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: "http://${HUB_IP}:30082"
      path: "secret"
      version: "v2"
      auth:
        tokenSecretRef:
          name: vault-token
          namespace: external-secrets
          key: token
EOF

kubectl --context "$SPOKE_CTX" patch clustersecretstore vault-backend \
  --type='json' \
  -p="[{\"op\":\"replace\",\"path\":\"/spec/provider/vault/server\",\"value\":\"http://${HUB_IP}:30082\"}]" \
  > /dev/null 2>&1 || true

log_ok "ClusterSecretStore vault-backend configured → http://${HUB_IP}:30082"
else
  log_warn "External Secrets CRDs not available on Spoke yet — Stage 10 will retry after platform-eso syncs"
fi

# =============================================================================
# Stage 7.5: Update Promtail (Spoke) Loki client + destination IPs
# =============================================================================
log_step "Stage 7.5: Promtail Loki IP Sync"

# platform-spoke-promtail is applied directly (not via an app-of-apps), so a
# plain `git push` never reaches the live Application object — re-apply the
# manifest with the current HUB_IP/SPOKE_IP baked in, then trigger a sync.
kubectl --context "$HUB_CTX" apply -f - <<EOF > /dev/null 2>&1 || true
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform-spoke-promtail
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://grafana.github.io/helm-charts
    chart: promtail
    targetRevision: "6.16.6"
    helm:
      values: |
        config:
          clients:
            - url: http://${HUB_IP}:30031/loki/api/v1/push
          snippets:
            pipelineStages:
              - docker: {}
        # hostNetwork puts Promtail in the node network namespace
        # — the only namespace from which Hub Docker bridge IPs are reachable
        # without a cross-cluster routing setup
        hostNetwork: true
        dnsPolicy: ClusterFirstWithHostNet
        tolerations:
          - operator: Exists
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 128Mi
  destination:
    server: https://${SPOKE_IP}:6443
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

kubectl --context "$HUB_CTX" annotate application platform-spoke-promtail \
  -n argocd argocd.argoproj.io/refresh=hard --overwrite > /dev/null 2>&1 || true

log_ok "Promtail Application synced → clients.url=http://${HUB_IP}:30031, destination=https://${SPOKE_IP}:6443"
log_warn "NOTE: keep this manifest's HUB_IP/SPOKE_IP in sync with platform/observability/spoke/promtail-application.yaml if you edit the chart values there — this stage overwrites the live object from the same source of truth."

# =============================================================================
# Stage 8: Label app namespaces for Kyverno
# =============================================================================
log_step "Stage 8: Kyverno Namespace Labels"

for NS in $APP_NAMESPACES; do
  kubectl --context "$SPOKE_CTX" label namespace "$NS" \
    helmsman.dev/managed=true \
    --overwrite > /dev/null 2>&1 || true
  log_ok "Kyverno label applied: $NS"
done

# =============================================================================
# Stage 9: Argo CD Login
# =============================================================================
log_step "Stage 9: Argo CD CLI Login"

if [ -f "$ARGOCD_PASS_FILE" ]; then
  ARGOCD_PASS=$(cat "$ARGOCD_PASS_FILE")
fi

kill_port_process "${ARGOCD_PF_PORT}"
sleep 1

kubectl --context "$HUB_CTX" port-forward svc/argocd-server \
  -n argocd "${ARGOCD_PF_PORT}":80 > /tmp/argocd-pf.log 2>&1 &
ARGOCD_PF_PID=$!

for i in {1..15}; do
  if nc -z localhost "${ARGOCD_PF_PORT}" 2>/dev/null; then break; fi
  sleep 1
done

LOGIN_OK=false
LOGIN_ERR=""
for attempt in 1 2 3 4 5; do
  if LOGIN_ERR=$(argocd login "localhost:${ARGOCD_PF_PORT}" \
      --username "$ARGOCD_USER" \
      --password "$ARGOCD_PASS" \
      --insecure 2>&1 > /dev/null); then
    log_ok "Argo CD CLI logged in via port-forward :${ARGOCD_PF_PORT}"
    LOGIN_OK=true
    break
  fi
  log_warn "Login attempt $attempt/5 failed: ${LOGIN_ERR} — waiting 3s..."
  sleep 3
done

if ! $LOGIN_OK; then
  log_error "Argo CD CLI login failed after 5 attempts. If the password file is stale, reset it:"
  log_error "  argocd account bcrypt --password '<new-pass>' | xargs -I{} kubectl --context $HUB_CTX -n argocd patch secret argocd-secret -p '{\"stringData\":{\"admin.password\":\"{}\"}}'"
  log_error "  echo -n '<new-pass>' > $ARGOCD_PASS_FILE && kubectl --context $HUB_CTX -n argocd rollout restart deployment/argocd-server"
fi

# =============================================================================
# Stage 10: Sync platform and application ArgoCD apps
# =============================================================================
log_step "Stage 10: ArgoCD App Sync"

if $LOGIN_OK; then
  PLATFORM_APPS=("platform-eso" "platform-vault" "platform-keycloak" "platform-kyverno" "platform-kyverno-policies")

  for app in "${PLATFORM_APPS[@]}"; do
    if argocd app get "$app" --server "localhost:${ARGOCD_PF_PORT}" \
        --insecure > /dev/null 2>&1; then
      argocd app sync "$app" --async \
        --server "localhost:${ARGOCD_PF_PORT}" --insecure > /dev/null 2>&1 || true
      log_ok "Sync triggered: $app"
    else
      log_warn "$app not found in Argo CD (will appear after fleet repo sync)"
    fi
  done

  log_info "Waiting for Keycloak deployment on Hub to be ready..."
  kubectl --context "$HUB_CTX" rollout status deployment/keycloak -n keycloak \
    --timeout=300s > /dev/null 2>&1 && log_ok "Keycloak ready" || \
    log_warn "Keycloak rollout wait timed out"

  log_info "Waiting for platform-eso deployment to settle on Spoke..."
  sleep 15

  # Stage 7 skips the store when ESO CRDs weren't installed yet (fresh --reset)
  if ! kubectl --context "$SPOKE_CTX" get clustersecretstore vault-backend >/dev/null 2>&1; then
    log_info "Re-applying ClusterSecretStore vault-backend post ESO sync..."
    kubectl --context "$SPOKE_CTX" apply -f - <<EOF > /dev/null 2>&1 || log_warn "ClusterSecretStore apply failed"
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: "http://${HUB_IP}:30082"
      path: "secret"
      version: "v2"
      auth:
        tokenSecretRef:
          name: vault-token
          namespace: external-secrets
          key: token
EOF
  fi

  kubectl --context "$SPOKE_CTX" delete job \
    -n sample-app -l argocd.argoproj.io/hook=PreSync \
    --ignore-not-found > /dev/null 2>&1 || true
  log_ok "Stale PreSync hook jobs cleaned up"

  if argocd app get sample-app-helmsman-onprem \
      --server "localhost:${ARGOCD_PF_PORT}" --insecure > /dev/null 2>&1; then
    if argocd app sync sample-app-helmsman-onprem --force --timeout 120 \
        --server "localhost:${ARGOCD_PF_PORT}" --insecure > /dev/null 2>&1; then
      log_ok "Sync triggered: sample-app-helmsman-onprem"
    else
      log_warn "sample-app-helmsman-onprem sync did not complete within 120s — check: argocd app get sample-app-helmsman-onprem --server localhost:${ARGOCD_PF_PORT} --insecure"
    fi
  fi

  # The sample-app-oidc-register PreSync hook writes a fresh issuer-url (with
  # the current HUB_IP) into Vault every sync, but the already-running `adc`
  # (oauth2-proxy) container has the OLD issuer-url baked into its process
  # env from pod start — it will not pick up the new Secret value without an
  # actual restart, and keeps CrashLoopBackOff-ing on stale-IP OIDC discovery
  # until it does. Detect that and force a restart.
  sleep 5
  ADC_READY=$(kubectl --context "$SPOKE_CTX" get pod sample-app-0 -n sample-app \
    -o jsonpath='{.status.containerStatuses[?(@.name=="adc")].ready}' 2>/dev/null || echo "")
  if [ "$ADC_READY" != "true" ]; then
    log_warn "sample-app-0 'adc' container not ready — likely stale OIDC issuer-url, restarting pod"
    kubectl --context "$SPOKE_CTX" delete pod sample-app-0 -n sample-app --ignore-not-found > /dev/null 2>&1 || true
    kubectl --context "$SPOKE_CTX" wait --for=condition=ready pod/sample-app-0 \
      -n sample-app --timeout=60s > /dev/null 2>&1 && \
      log_ok "sample-app-0 restarted and ready" || \
      log_warn "sample-app-0 still not ready after restart — check: kubectl logs sample-app-0 -n sample-app -c adc --context $SPOKE_CTX"
  else
    log_ok "sample-app-0 'adc' container already ready"
  fi
fi

# =============================================================================
# Stage 10.5: AgentForge Platform State
# =============================================================================
# Envoy Gateway, oauth2-proxy and the Kyverno policy live in git, but several
# AgentForge pieces only exist at runtime and do NOT survive a Docker restart:
#   - Vault runs `server -dev` (in-memory)  → secret/agentforge/* is wiped
#   - Keycloak has no PVC                   → realm re-imported bare: the
#     agentforge-gateway client, its groups mapper, the groups and users vanish
#   - auth.keycloak_url and oauth2-proxy's issuer embed HUB_IP → stale on drift
# This stage backs that state up to $HELMSMAN_STATE_DIR on every run and
# restores it from there when it's missing. helmsman-sanity.sh section K
# checks the same items read-only.
log_step "Stage 10.5: AgentForge Platform State"

mkdir -p "$HELMSMAN_STATE_DIR" && chmod 700 "$HELMSMAN_STATE_DIR"

# Python helpers below print "OK: …" / "WARN: …" / "ERR: …" lines
# (streamed, so progress shows while kubectl exec / API calls run)
af_log_lines() {
  while IFS= read -r line; do
    case "$line" in
      "") ;;
      OK:*)   log_ok   "${line#OK: }" ;;
      WARN:*) log_warn "${line#WARN: }" ;;
      *)      log_error "${line#ERR: }" ;;
    esac
  done
}

# --- Argo CD Applications ----------------------------------------------------
# These are kubectl-applied (no app-of-apps), so re-create any that are missing
# from fleet main. Existing ones are left alone.
AF_APP_FILES="platform/envoy-gateway/argocd-application.yaml
platform/envoy-gateway/spoke-application.yaml
platform/oauth2-proxy-agentforge/argocd-application.yaml
platform/kyverno/policies/argocd-application.yaml
apps/agentforge/argocd-application.yaml"
AF_FLEET_TMP=$(mktemp -d)
if git clone -q --depth=1 "$FLEET_REPO" "$AF_FLEET_TMP" 2>/dev/null; then
  while IFS= read -r f; do
    if [ ! -f "$AF_FLEET_TMP/$f" ]; then
      log_warn "$f not found in fleet main"
      continue
    fi
    APP_NAME=$(awk '/^metadata:/{m=1} m && /^  name:/{print $2; exit}' "$AF_FLEET_TMP/$f")
    if kubectl --context "$HUB_CTX" get application "$APP_NAME" -n argocd >/dev/null 2>&1; then
      log_ok "Application $APP_NAME present"
    elif kubectl --context "$HUB_CTX" apply -f "$AF_FLEET_TMP/$f" >/dev/null 2>&1; then
      log_ok "Application $APP_NAME was missing — applied from fleet main"
    else
      log_warn "Application $APP_NAME missing and apply failed ($f)"
    fi
  done <<< "$AF_APP_FILES"
else
  log_warn "Could not clone $FLEET_REPO — skipping Application presence check"
fi
rm -rf "$AF_FLEET_TMP"

# --- agentforge namespace: label + GHCR pull secret --------------------------
kubectl --context "$SPOKE_CTX" create namespace agentforge --dry-run=client -o yaml | \
  kubectl --context "$SPOKE_CTX" apply -f - > /dev/null 2>&1 || true
kubectl --context "$SPOKE_CTX" label namespace agentforge helmsman.dev/managed=true \
  --overwrite > /dev/null 2>&1 && log_ok "agentforge namespace labelled helmsman.dev/managed=true" || \
  log_warn "Could not label agentforge namespace"

# The GHCR token isn't in git, so keep a local copy to survive a --reset.
if kubectl --context "$SPOKE_CTX" get secret ghcr-pull-secret -n agentforge >/dev/null 2>&1; then
  if kubectl --context "$SPOKE_CTX" get secret ghcr-pull-secret -n agentforge \
      -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 -d > "$AF_GHCR_BACKUP.tmp" 2>/dev/null && \
      [ -s "$AF_GHCR_BACKUP.tmp" ]; then
    chmod 600 "$AF_GHCR_BACKUP.tmp" && mv "$AF_GHCR_BACKUP.tmp" "$AF_GHCR_BACKUP"
    log_ok "ghcr-pull-secret present in agentforge (backed up to $AF_GHCR_BACKUP)"
  else
    rm -f "$AF_GHCR_BACKUP.tmp"
    log_warn "ghcr-pull-secret present but could not be backed up"
  fi
elif [ -s "$AF_GHCR_BACKUP" ]; then
  kubectl --context "$SPOKE_CTX" create secret generic ghcr-pull-secret -n agentforge \
    --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson="$AF_GHCR_BACKUP" > /dev/null 2>&1 && \
    log_ok "ghcr-pull-secret was missing — restored from $AF_GHCR_BACKUP" || \
    log_warn "ghcr-pull-secret restore failed"
else
  log_warn "ghcr-pull-secret missing in agentforge and no backup at $AF_GHCR_BACKUP — recreate it:"
  log_warn "  kubectl --context $SPOKE_CTX -n agentforge create secret docker-registry ghcr-pull-secret --docker-server=ghcr.io --docker-username=<user> --docker-password=<PAT>"
fi

# --- Vault: secret/agentforge/* ------------------------------------------------
# Live Vault wins (so values the AgentForge team writes are kept and backed
# up); the backup only fills paths Vault lost. auth.keycloak_url always tracks
# the current HUB_IP.
kubectl --context "$HUB_CTX" rollout status deployment/vault -n vault --timeout=120s > /dev/null 2>&1 || true
VAULT_POD=$(kubectl --context "$HUB_CTX" get pods -n vault --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
AF_VAULT_OK=false
if [ -z "$VAULT_POD" ]; then
  log_error "No running Vault pod on Hub — cannot check secret/agentforge/*"
else
  log_info "Checking secret/agentforge/* in Vault..."
  if HUB_CTX="$HUB_CTX" VAULT_POD="$VAULT_POD" VAULT_TOKEN="$VAULT_TOKEN" HUB_IP="$HUB_IP" \
    AF_VAULT_PATHS="$AF_VAULT_PATHS" AF_VAULT_BACKUP="$AF_VAULT_BACKUP" AF_KC_CLIENT="$AF_KC_CLIENT" \
    python3 -u - 2>&1 <<'PY' | af_log_lines
import json, os, secrets, subprocess, sys

ctx, pod, tok = os.environ["HUB_CTX"], os.environ["VAULT_POD"], os.environ["VAULT_TOKEN"]
paths = os.environ["AF_VAULT_PATHS"].split()
backup_file = os.environ["AF_VAULT_BACKUP"]
keycloak_url = "http://%s:30081" % os.environ["HUB_IP"]
PLACEHOLDER = {"placeholder": "AgentForge team must populate this path"}

def vault(*args, stdin=None):
    return subprocess.run(
        ["kubectl", "--context", ctx, "exec", "-i", "-n", "vault", pod, "--",
         "env", "VAULT_ADDR=http://127.0.0.1:8200", "VAULT_TOKEN=" + tok, "vault", *args],
        input=stdin, capture_output=True, text=True)

def get(p):
    r = vault("kv", "get", "-format=json", "secret/agentforge/" + p)
    return json.loads(r.stdout)["data"]["data"] if r.returncode == 0 else None

try:
    with open(backup_file) as f:
        backup = json.load(f)
except (OSError, ValueError):
    backup = {}

desired, failed = {}, False
for p in paths:
    live = get(p)
    data = dict(live or backup.get(p) or ({} if p == "auth" else PLACEHOLDER))
    source = "live" if live else ("backup" if p in backup else "new")
    if p == "auth":
        data["keycloak_client_id"] = os.environ["AF_KC_CLIENT"]
        data["keycloak_realm"] = "helmsman"
        data["keycloak_url"] = keycloak_url
        if not data.get("keycloak_client_secret"):
            data["keycloak_client_secret"] = secrets.token_urlsafe(24)
            print("WARN: auth.keycloak_client_secret generated (no live value or backup)")
        if not data.get("cookie_secret"):
            data["cookie_secret"] = secrets.token_urlsafe(24)   # 32 chars, valid for oauth2-proxy
            print("WARN: auth.cookie_secret generated (no live value or backup)")
    desired[p] = data
    if data == live:
        print("OK: secret/agentforge/%s present" % p)
        continue
    r = vault("kv", "put", "secret/agentforge/" + p, "-", stdin=json.dumps(data))
    if r.returncode != 0:
        failed = True
        print("ERR: writing secret/agentforge/%s failed: %s" % (p, r.stderr.strip()))
    elif source == "live":
        print("OK: secret/agentforge/%s updated (keycloak_url -> %s)" % (p, keycloak_url))
    elif source == "backup":
        print("OK: secret/agentforge/%s was missing — restored from backup" % p)
    else:
        print("WARN: secret/agentforge/%s was missing with no backup — created %s" %
              (p, "with fresh credentials" if p == "auth" else "placeholder"))

if not failed:
    tmp = backup_file + ".tmp"
    with open(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
        json.dump(desired, f, indent=1, sort_keys=True)
    os.replace(tmp, backup_file)
    print("OK: secret/agentforge/* backed up to %s" % backup_file)
sys.exit(1 if failed else 0)
PY
  then
    AF_VAULT_OK=true
  fi
fi

# --- Keycloak: agentforge-gateway client, groups, user ------------------------
# Client secret comes from the Vault backup above so Keycloak, Vault and
# oauth2-proxy always agree. The user's password is only set when the user has
# to be (re)created — from $AF_USER_PASS_FILE, or generated and saved there.
AF_KC_OK=false
if ! $AF_VAULT_OK; then
  log_warn "Skipping Keycloak AgentForge setup — Vault state above is not healthy"
elif ! kubectl --context "$HUB_CTX" rollout status deployment/keycloak -n keycloak --timeout=300s > /dev/null 2>&1; then
  log_error "Keycloak not ready on Hub — cannot check AgentForge client/groups/users"
else
  kill_port_process "$AF_KC_PF_PORT"
  kubectl --context "$HUB_CTX" port-forward svc/keycloak -n keycloak "${AF_KC_PF_PORT}:80" \
    > /tmp/helmsman-keycloak-pf.log 2>&1 &
  AF_KC_PF_PID=$!
  for i in {1..15}; do nc -z localhost "$AF_KC_PF_PORT" 2>/dev/null && break; sleep 1; done

  log_info "Checking Keycloak client, groups and user..."
  if KC_URL="http://localhost:${AF_KC_PF_PORT}" KC_ADMIN_USER="$KEYCLOAK_ADMIN_USER" \
    KC_ADMIN_PASS="$KEYCLOAK_ADMIN_PASS" AF_VAULT_BACKUP="$AF_VAULT_BACKUP" \
    AF_KC_CLIENT="$AF_KC_CLIENT" AF_KC_GROUPS="$AF_KC_GROUPS" AF_KC_USER="$AF_KC_USER" \
    AF_KC_USER_EMAIL="$AF_KC_USER_EMAIL" AF_KC_USER_GROUP="$AF_KC_USER_GROUP" \
    AF_KC_USER_FIRST="$AF_KC_USER_FIRST" AF_KC_USER_LAST="$AF_KC_USER_LAST" \
    AF_USER_PASS_FILE="$AF_USER_PASS_FILE" AF_KC_USER_PASS="${AF_KC_USER_PASS:-}" \
    python3 -u - 2>&1 <<'PY' | af_log_lines
import json, os, secrets, sys, urllib.error, urllib.parse, urllib.request

E = os.environ
base = E["KC_URL"]
realm = base + "/admin/realms/helmsman"

def req(method, url, body=None, form=None, token=None):
    data, headers = None, {}
    if form is not None:
        data = urllib.parse.urlencode(form).encode()
    elif body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = "Bearer " + token
    r = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(r, timeout=20) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")

try:
    st, tok = req("POST", base + "/realms/master/protocol/openid-connect/token",
                  form={"grant_type": "password", "client_id": "admin-cli",
                        "username": E["KC_ADMIN_USER"], "password": E["KC_ADMIN_PASS"]})
    if st != 200:
        print("ERR: Keycloak admin login failed (%s)" % st); sys.exit(1)
    T = tok["access_token"]
    with open(E["AF_VAULT_BACKUP"]) as f:
        client_secret = json.load(f)["auth"]["keycloak_client_secret"]
    failed = False

    # Groups
    groups = {g["name"]: g["id"] for g in req("GET", realm + "/groups?max=1000", token=T)[1]}
    for g in E["AF_KC_GROUPS"].split():
        if g in groups:
            print("OK: Keycloak group %s present" % g)
        else:
            st, _ = req("POST", realm + "/groups", {"name": g}, token=T)
            print(("OK: Keycloak group %s was missing — created" if st in (201, 409) else
                   "ERR: Keycloak group %s create failed (" + str(st) + ")") % g)
            failed |= st not in (201, 409)
    groups = {g["name"]: g["id"] for g in req("GET", realm + "/groups?max=1000", token=T)[1]}

    # Client + groups mapper + secret
    mapper = {"name": "groups", "protocol": "openid-connect",
              "protocolMapper": "oidc-group-membership-mapper", "consentRequired": False,
              "config": {"full.path": "false", "id.token.claim": "true",
                         "access.token.claim": "true", "claim.name": "groups",
                         "userinfo.token.claim": "true"}}
    cid = E["AF_KC_CLIENT"]
    found = req("GET", realm + "/clients?clientId=" + urllib.parse.quote(cid), token=T)[1]
    if not found:
        st, _ = req("POST", realm + "/clients", {
            "clientId": cid, "enabled": True, "protocol": "openid-connect",
            "publicClient": False, "secret": client_secret, "redirectUris": ["*"],
            "standardFlowEnabled": True, "implicitFlowEnabled": False,
            "directAccessGrantsEnabled": True, "serviceAccountsEnabled": False,
            "protocolMappers": [mapper]}, token=T)
        print(("OK: Keycloak client %s was missing — created with the Vault client secret" if st == 201
               else "ERR: Keycloak client %s create failed (" + str(st) + ")") % cid)
        failed |= st != 201
    else:
        c = found[0]
        print("OK: Keycloak client %s present" % cid)
        if not any(m.get("protocolMapper") == mapper["protocolMapper"] for m in c.get("protocolMappers", [])):
            st, _ = req("POST", "%s/clients/%s/protocol-mappers/models" % (realm, c["id"]), mapper, token=T)
            print("OK: groups mapper was missing — added" if st == 201 else "ERR: groups mapper add failed (%s)" % st)
            failed |= st != 201
        else:
            print("OK: Keycloak client %s has groups mapper" % cid)
        cur = req("GET", "%s/clients/%s/client-secret" % (realm, c["id"]), token=T)[1] or {}
        if cur.get("value") != client_secret:
            c["secret"] = client_secret
            st, _ = req("PUT", "%s/clients/%s" % (realm, c["id"]), c, token=T)
            print("OK: client secret re-aligned with Vault auth.keycloak_client_secret" if st == 204
                  else "ERR: client secret update failed (%s)" % st)
            failed |= st != 204
        else:
            print("OK: Keycloak client secret matches Vault")

    # User + group membership
    uname = E["AF_KC_USER"]
    users = req("GET", realm + "/users?exact=true&username=" + urllib.parse.quote(uname), token=T)[1]
    if users:
        uid = users[0]["id"]
        print("OK: Keycloak user %s present" % uname)
    else:
        pw = E.get("AF_KC_USER_PASS") or ""
        pf = E["AF_USER_PASS_FILE"]
        if not pw and os.path.exists(pf):
            pw = open(pf).read().strip()
        generated = not pw
        if generated:
            pw = secrets.token_urlsafe(12)
        # first/last name + verified email: Keycloak's user profile otherwise
        # marks the account "not fully set up" and refuses logins
        st, _ = req("POST", realm + "/users", {
            "username": uname, "email": E["AF_KC_USER_EMAIL"], "emailVerified": True,
            "firstName": E["AF_KC_USER_FIRST"], "lastName": E["AF_KC_USER_LAST"], "enabled": True,
            "credentials": [{"type": "password", "value": pw, "temporary": False}]}, token=T)
        if st != 201:
            print("ERR: Keycloak user %s create failed (%s)" % (uname, st)); sys.exit(1)
        if generated or not os.path.exists(pf):
            with open(os.open(pf, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
                f.write(pw)
        print(("WARN: Keycloak user %s was missing — created with a NEW password saved in %s" if generated else
               "OK: Keycloak user %s was missing — recreated with the password from %s") % (uname, pf))
        uid = req("GET", realm + "/users?exact=true&username=" + urllib.parse.quote(uname), token=T)[1][0]["id"]
    member_of = {g["name"] for g in req("GET", "%s/users/%s/groups" % (realm, uid), token=T)[1]}
    g = E["AF_KC_USER_GROUP"]
    if g in member_of:
        print("OK: %s is in %s" % (uname, g))
    elif g in groups:
        st, _ = req("PUT", "%s/users/%s/groups/%s" % (realm, uid, groups[g]), token=T)
        print(("OK: %s added to %s" if st == 204 else "ERR: adding %s to %s failed (" + str(st) + ")") % (uname, g))
        failed |= st != 204
    sys.exit(1 if failed else 0)
except Exception as e:
    print("ERR: Keycloak AgentForge setup failed: %s" % e)
    sys.exit(1)
PY
  then
    AF_KC_OK=true
  fi
  kill "$AF_KC_PF_PID" 2>/dev/null || true
fi

# --- oauth2-proxy: credentials + issuer must match the above ------------------
# ExternalSecret refreshes hourly; force it now so a restored/realigned Vault
# value lands immediately. oauth2-proxy only reads its env at start-up, so
# restart it whenever the Keycloak URL or credentials it was started with
# change (tracked in a Deployment annotation Argo CD doesn't manage).
if kubectl --context "$SPOKE_CTX" get externalsecret agentforge-oauth2-proxy-secret -n gateway-infra >/dev/null 2>&1; then
  kubectl --context "$SPOKE_CTX" annotate externalsecret agentforge-oauth2-proxy-secret -n gateway-infra \
    force-sync="$(date +%s)" --overwrite > /dev/null 2>&1 || true
  EXPECTED_CS=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["auth"]["keycloak_client_secret"])' \
    "$AF_VAULT_BACKUP" 2>/dev/null || echo "")
  for i in {1..20}; do
    LIVE_CS=$(kubectl --context "$SPOKE_CTX" get secret agentforge-oauth2-proxy-secret -n gateway-infra \
      -o jsonpath='{.data.client-secret}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    [ -n "$EXPECTED_CS" ] && [ "$LIVE_CS" = "$EXPECTED_CS" ] && break
    sleep 3
  done
  if [ -n "$EXPECTED_CS" ] && [ "$LIVE_CS" = "$EXPECTED_CS" ]; then
    log_ok "ExternalSecret agentforge-oauth2-proxy-secret synced from Vault"
  else
    log_warn "agentforge-oauth2-proxy-secret does not match Vault yet — check: kubectl --context $SPOKE_CTX -n gateway-infra describe externalsecret agentforge-oauth2-proxy-secret"
  fi
else
  log_warn "ExternalSecret agentforge-oauth2-proxy-secret not found in gateway-infra (platform-agentforge-oauth2proxy not synced?)"
fi

if kubectl --context "$SPOKE_CTX" get deployment agentforge-oauth2-proxy -n gateway-infra >/dev/null 2>&1; then
  OAUTH_FP=$( {
      kubectl --context "$SPOKE_CTX" get secret helmsman-platform-config -n gateway-infra -o jsonpath='{.data.keycloak-url}' 2>/dev/null
      kubectl --context "$SPOKE_CTX" get secret agentforge-oauth2-proxy-secret -n gateway-infra -o jsonpath='{.data}' 2>/dev/null
    } | sha256sum | cut -c1-16)
  RUNNING_FP=$(kubectl --context "$SPOKE_CTX" get deployment agentforge-oauth2-proxy -n gateway-infra \
    -o jsonpath='{.metadata.annotations.helmsman\.dev/config-fingerprint}' 2>/dev/null || echo "")
  OAUTH_AVAILABLE=$(kubectl --context "$SPOKE_CTX" get deployment agentforge-oauth2-proxy -n gateway-infra \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
  if [ "$OAUTH_FP" != "$RUNNING_FP" ] || [ "$OAUTH_AVAILABLE" != "True" ]; then
    log_info "oauth2-proxy config changed or not available — restarting"
    kubectl --context "$SPOKE_CTX" rollout restart deployment/agentforge-oauth2-proxy -n gateway-infra > /dev/null 2>&1 || true
    if kubectl --context "$SPOKE_CTX" rollout status deployment/agentforge-oauth2-proxy -n gateway-infra \
        --timeout=120s > /dev/null 2>&1; then
      kubectl --context "$SPOKE_CTX" annotate deployment agentforge-oauth2-proxy -n gateway-infra \
        helmsman.dev/config-fingerprint="$OAUTH_FP" --overwrite > /dev/null 2>&1 || true
      log_ok "oauth2-proxy restarted with current Keycloak URL and credentials"
    else
      log_error "oauth2-proxy did not become ready — check: kubectl --context $SPOKE_CTX -n gateway-infra logs deploy/agentforge-oauth2-proxy"
    fi
  else
    log_ok "oauth2-proxy running with current Keycloak URL and credentials"
  fi
else
  log_warn "Deployment agentforge-oauth2-proxy not found in gateway-infra"
fi

# --- Kyverno: verify-agentforge-signatures on Spoke ----------------------------
AF_POLICY_READY=$(kubectl --context "$SPOKE_CTX" get clusterpolicy verify-agentforge-signatures \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
if [ "$AF_POLICY_READY" != "True" ]; then
  log_info "verify-agentforge-signatures not Ready on Spoke — hard-refreshing platform-kyverno-policies"
  kubectl --context "$HUB_CTX" annotate application platform-kyverno-policies -n argocd \
    argocd.argoproj.io/refresh=hard --overwrite > /dev/null 2>&1 || true
  for i in {1..20}; do
    AF_POLICY_READY=$(kubectl --context "$SPOKE_CTX" get clusterpolicy verify-agentforge-signatures \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    [ "$AF_POLICY_READY" = "True" ] && break
    sleep 3
  done
fi
[ "$AF_POLICY_READY" = "True" ] && log_ok "Kyverno policy verify-agentforge-signatures Ready on Spoke" || \
  log_warn "Kyverno policy verify-agentforge-signatures still not Ready on Spoke"

# --- Envoy Gateway: GatewayClass accepted, helmsman-gateway programmed ---------
gw_programmed() {
  kubectl --context "$SPOKE_CTX" get gateway helmsman-gateway -n gateway-infra \
    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo ""
}
if [ "$(gw_programmed)" != "True" ]; then
  log_info "helmsman-gateway not Programmed — refreshing Envoy Gateway apps and restarting the controller"
  for app in platform-envoy-gateway platform-envoy-gateway-infra; do
    kubectl --context "$HUB_CTX" annotate application "$app" -n argocd \
      argocd.argoproj.io/refresh=hard --overwrite > /dev/null 2>&1 || true
  done
  kubectl --context "$SPOKE_CTX" rollout restart deployment/envoy-gateway -n envoy-gateway-system > /dev/null 2>&1 || true
  kubectl --context "$SPOKE_CTX" rollout status deployment/envoy-gateway -n envoy-gateway-system \
    --timeout=120s > /dev/null 2>&1 || true
  for i in {1..20}; do [ "$(gw_programmed)" = "True" ] && break; sleep 3; done
fi
if [ "$(gw_programmed)" = "True" ]; then
  log_ok "helmsman-gateway Programmed ($(kubectl --context "$SPOKE_CTX" get gateway helmsman-gateway -n gateway-infra -o jsonpath='{.status.addresses[0].value}' 2>/dev/null))"
else
  log_error "helmsman-gateway still not Programmed — check: kubectl --context $SPOKE_CTX -n gateway-infra describe gateway helmsman-gateway"
fi

# --- End to end: gateway → oauth2-proxy → Keycloak ----------------------------
# /ping is answered by oauth2-proxy itself; /oauth2/start must redirect to the
# current Keycloak, which proves the issuer oauth2-proxy discovered is fresh.
AF_E2E_OK=false
AF_GW_SVC=$(kubectl --context "$SPOKE_CTX" get svc -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=helmsman-gateway,gateway.envoyproxy.io/owning-gateway-namespace=gateway-infra \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$AF_GW_SVC" ]; then
  AF_GW_URL="http://${AF_GW_SVC}.envoy-gateway-system.svc.cluster.local"
  for attempt in 1 2 3; do   # a throwaway probe pod can fail on its own; don't report that as an outage
    kubectl --context "$SPOKE_CTX" -n default delete pod agentforge-e2e-check --ignore-not-found > /dev/null 2>&1 || true
    AF_E2E=$(kubectl --context "$SPOKE_CTX" -n default run --quiet --rm -i --restart=Never agentforge-e2e-check \
      --image=curlimages/curl:latest -- sh -c "
        curl -s -o /dev/null -w 'ping=%{http_code}\n' --max-time 5 -H 'Host: agentforge.helmsman.local' '${AF_GW_URL}/ping'
        curl -s -o /dev/null -w 'start=%{http_code} %{redirect_url}\n' --max-time 5 -H 'Host: agentforge.helmsman.local' '${AF_GW_URL}/oauth2/start'
      " 2>/dev/null || echo "")
    echo "$AF_E2E" | grep -q '^ping=200' && echo "$AF_E2E" | grep -q "^start=302 http://${HUB_IP}:30081/" && break
    sleep 5
  done
  if echo "$AF_E2E" | grep -q '^ping=200'; then
    log_ok "Gateway routes agentforge.helmsman.local → oauth2-proxy (/ping 200)"
  else
    log_error "Gateway → oauth2-proxy /ping failed (${AF_E2E:-no response})"
  fi
  if echo "$AF_E2E" | grep -q "^start=302 http://${HUB_IP}:30081/realms/helmsman/"; then
    echo "$AF_E2E" | grep -q '^ping=200' && AF_E2E_OK=true
    log_ok "oauth2-proxy redirects to Keycloak at http://${HUB_IP}:30081/realms/helmsman"
  else
    log_error "oauth2-proxy login redirect is not the current Keycloak ($(echo "$AF_E2E" | grep '^start=' || echo 'no response'))"
  fi
else
  log_error "No Envoy proxy Service found for helmsman-gateway"
fi

log_info "Argo CD Application agentforge waits for the AgentForge Helm chart in apps/agentforge/"

# =============================================================================
# Stage 11: Health Verification
# =============================================================================
log_step "Stage 11: Health Verification & Sanity Checks"

SANITY_PASS=true

log_info "Waiting up to 60s for spoke workloads..."
if kubectl --context "$SPOKE_CTX" rollout status statefulset/sample-app \
    -n sample-app --timeout=60s > /dev/null 2>&1; then
  log_ok "sample-app StatefulSet rollout complete"
else
  log_warn "sample-app still reconciling"
  SANITY_PASS=false
fi

if $AF_VAULT_OK && $AF_KC_OK && $AF_E2E_OK; then
  log_ok "AgentForge platform state healthy (Vault, Keycloak, gateway → oauth2-proxy → Keycloak)"
else
  log_warn "AgentForge platform state has problems — see Stage 10.5 above"
  SANITY_PASS=false
fi

OPERATOR_PODS=$(kubectl --context "$SPOKE_CTX" get pods -n "$OPERATOR_NS" \
  -l app.kubernetes.io/name=helmsman-operator --no-headers 2>/dev/null | grep -c "Running" || true)
if [ "${OPERATOR_PODS:-0}" -gt 0 ] 2>/dev/null; then
  log_ok "Helmsman operator: $OPERATOR_PODS pod(s) Running in $OPERATOR_NS"
else
  log_error "Helmsman operator: NOT running in $OPERATOR_NS"
  SANITY_PASS=false
fi

if kubectl --context "$SPOKE_CTX" get clustersecretstore vault-backend >/dev/null 2>&1; then
  log_ok "ClusterSecretStore vault-backend present on Spoke"
else
  log_error "ClusterSecretStore vault-backend missing on Spoke"
  SANITY_PASS=false
fi

echo ""
log_info "Cluster status:"
argocd cluster list --server "localhost:${ARGOCD_PF_PORT}" --insecure 2>/dev/null || true

echo ""
log_info "Application status:"
argocd app list --server "localhost:${ARGOCD_PF_PORT}" --insecure 2>/dev/null || true

echo ""
log_info "Spoke workloads:"
kubectl --context "$SPOKE_CTX" get pods,externalsecret \
  -n sample-app 2>/dev/null || true

echo ""
log_info "Observability: Loki, Grafana, and log shipping..."

LOKI_READY=$(kubectl --context "$HUB_CTX" get pod platform-loki-0 -n monitoring \
  -o jsonpath='{.status.containerStatuses[?(@.name=="loki")].ready}' 2>/dev/null || echo "")
if [ "$LOKI_READY" = "true" ]; then
  log_ok "Loki is Ready"
else
  log_warn "Loki is not Ready (got: ${LOKI_READY:-<not found>})"
  SANITY_PASS=false
fi

GRAFANA_READY=$(kubectl --context "$HUB_CTX" get pods -n monitoring \
  -l app.kubernetes.io/name=grafana \
  -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="grafana")].ready}' 2>/dev/null || echo "")
if [ "$GRAFANA_READY" = "true" ]; then
  log_ok "Grafana is Ready"
else
  log_warn "Grafana is not Ready (got: ${GRAFANA_READY:-<not found>})"
  SANITY_PASS=false
fi

# The only check that proves Promtail is shipping right now, not just that
# everything is configured correctly — query Loki for recent sample-app logs.
kubectl --context "$HUB_CTX" -n monitoring delete pod loki-shipping-check --ignore-not-found > /dev/null 2>&1 || true
NOW_NS=$(date +%s%N)
FROM_NS=$((NOW_NS - 5*60*1000000000))
SHIPPING_QUERY_URL="http://platform-loki.monitoring.svc.cluster.local:3100/loki/api/v1/query_range?query=%7Bnamespace%3D%22sample-app%22%7D&start=${FROM_NS}&end=${NOW_NS}&limit=1"
SHIPPING_RESULT=$(kubectl --context "$HUB_CTX" -n monitoring run --quiet --rm -i --restart=Never loki-shipping-check \
  --image=curlimages/curl:latest -- sh -c "curl -fsS --max-time 5 '${SHIPPING_QUERY_URL}'" 2>/dev/null || echo "")
if echo "$SHIPPING_RESULT" | grep -q '"resultType":"streams"' && echo "$SHIPPING_RESULT" | grep -q '"values":\[\['; then
  log_ok "Loki has sample-app log entries from the last 5 minutes — Promtail is shipping live"
else
  log_warn "No recent sample-app log entries in Loki — check platform-spoke-promtail (hostNetwork, clients.url) with ./scripts/helmsman-sanity.sh"
  SANITY_PASS=false
fi

if $SANITY_PASS; then
  echo -e "\n${BOLD}${GREEN}========================================${NC}"
  echo -e "${BOLD}${GREEN}  BOOTSTRAP COMPLETED SUCCESSFULLY      ${NC}"
  echo -e "${BOLD}${GREEN}========================================${NC}"
else
  echo -e "\n${BOLD}${YELLOW}========================================${NC}"
  echo -e "${BOLD}${YELLOW}  SANITY CHECK COMPLETED WITH WARNINGS  ${NC}"
  echo -e "${BOLD}${YELLOW}========================================${NC}"
fi

log_info "Argo CD login: ${ARGOCD_USER} / password in ${ARGOCD_PASS_FILE}"
log_info "The script's port-forward on :${ARGOCD_PF_PORT} closes on exit; re-open with:"
log_info "  kubectl --context $HUB_CTX port-forward svc/argocd-server -n argocd ${ARGOCD_PF_PORT}:80"
