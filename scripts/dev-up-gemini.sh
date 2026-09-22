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

# =============================================================================
# Configuration — update if you change cluster names or passwords
# =============================================================================
HUB_CLUSTER_NAME="helmsman-hub"
SPOKE_CLUSTER_NAME="helmsman-onprem"
HUB_CTX="kind-${HUB_CLUSTER_NAME}"
SPOKE_CTX="kind-${SPOKE_CLUSTER_NAME}"

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
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  CLUSTERS_DIR="$(dirname "$SCRIPT_DIR")/clusters"

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
  echo "$ARGOCD_PASS" > /tmp/helmsman-argocd-pass
  log_ok "Argo CD installed. Admin password saved to /tmp/helmsman-argocd-pass"
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
  
  if [ -f /tmp/helmsman-argocd-pass ]; then
    ARGOCD_PASS=$(cat /tmp/helmsman-argocd-pass)
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
                  "$TMP_FLEET"/platform/kyverno/policies/argocd-application.yaml; do
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
# Stage 3: Network Recovery (kube-proxy + CoreDNS)
# =============================================================================
log_step "Stage 3: Network Recovery"

COREDNS_READY=$(kubectl --context "$HUB_CTX" get pods -n kube-system \
  -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -c "Running" || echo "0")
COREDNS_READY=$(echo "$COREDNS_READY" | tr -d '[:space:]')

if $CONTAINERS_STARTED || [ "${COREDNS_READY:-0}" -lt 1 ]; then
  log_info "Running network recovery (kube-proxy + CoreDNS)..."

  kubectl --context "$HUB_CTX" rollout restart daemonset/kube-proxy \
    -n kube-system > /dev/null 2>&1
  kubectl --context "$HUB_CTX" rollout status daemonset/kube-proxy \
    -n kube-system --timeout=90s > /dev/null 2>&1
  log_ok "kube-proxy restarted on Hub"

  kubectl --context "$HUB_CTX" rollout restart deployment/coredns \
    -n kube-system > /dev/null 2>&1
  kubectl --context "$HUB_CTX" rollout status deployment/coredns \
    -n kube-system --timeout=90s > /dev/null 2>&1
  log_ok "CoreDNS restarted on Hub"

  log_info "Waiting 15s for DNS to stabilise..."
  sleep 15
else
  log_ok "Network healthy — skipping recovery"
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

# Ensure resource is applied on Spoke immediately with current HUB_IP
kubectl --context "$SPOKE_CTX" apply -f - <<EOF > /dev/null 2>&1 || true
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

if [ -f /tmp/helmsman-argocd-pass ]; then
  ARGOCD_PASS=$(cat /tmp/helmsman-argocd-pass)
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
for attempt in 1 2 3 4 5; do
  if argocd login "localhost:${ARGOCD_PF_PORT}" \
      --username "$ARGOCD_USER" \
      --password "$ARGOCD_PASS" \
      --insecure > /dev/null 2>&1; then
    log_ok "Argo CD CLI logged in via port-forward :${ARGOCD_PF_PORT}"
    LOGIN_OK=true
    break
  fi
  log_warn "Login attempt $attempt/5 failed — waiting 3s..."
  sleep 3
done

if ! $LOGIN_OK; then
  log_warn "Failed to login to Argo CD after 5 attempts"
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

  sleep 5

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
# Stage 11: Health Verification
# =============================================================================
log_step "Stage 11: Health Verification"

log_info "Waiting up to 60s for spoke workloads..."
kubectl --context "$SPOKE_CTX" rollout status statefulset/sample-app \
  -n sample-app --timeout=60s 2>/dev/null && \
  log_ok "sample-app StatefulSet rollout complete" || \
  log_warn "sample-app still reconciling"

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
fi

GRAFANA_READY=$(kubectl --context "$HUB_CTX" get pods -n monitoring \
  -l app.kubernetes.io/name=grafana \
  -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="grafana")].ready}' 2>/dev/null || echo "")
if [ "$GRAFANA_READY" = "true" ]; then
  log_ok "Grafana is Ready"
else
  log_warn "Grafana is not Ready (got: ${GRAFANA_READY:-<not found>})"
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
fi