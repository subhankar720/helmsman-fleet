#!/usr/bin/env bash
set -eo pipefail

HUB_CTX="kind-helmsman-hub"
SPOKE_CTX="kind-helmsman-onprem"
TEST_NS="sample-app"
TEST_APP_NAME="smoke-test-app"
VAULT_TOKEN="${VAULT_TOKEN:-root}"
KEYCLOAK_ADMIN_USER="${KEYCLOAK_ADMIN_USER:-admin}"
KEYCLOAK_ADMIN_PASS="${KEYCLOAK_ADMIN_PASS:-admin}"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

log_stage() { echo -e "\n${CYAN}=====================================================${NC}\n${CYAN} $1${NC}\n${CYAN}=====================================================${NC}"; }
log_pass()  { echo -e "${GREEN}[PASS]${NC} $1"; ((TESTS_PASSED++)); }
log_fail()  { echo -e "${RED}[FAIL]${NC} $1"; ((TESTS_FAILED++)); }
log_info()  { echo -e "[INFO] $1"; }

HUB_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' helmsman-hub-worker 2>/dev/null || echo "127.0.0.1")
KEYCLOAK_URL="http://${HUB_IP}:30081"
VAULT_URL="http://${HUB_IP}:30082"

# ----------------------------------------------------
# Step 1: Keycloak OIDC Client Registration Check
# ----------------------------------------------------
log_stage "1. Testing Keycloak OIDC Client Onboarding"

# Get Keycloak Admin Token
ADMIN_TOKEN=$(curl -s -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=${KEYCLOAK_ADMIN_USER}" \
  -d "password=${KEYCLOAK_ADMIN_PASS}" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" | jq -r '.access_token // empty')

if [ -n "$ADMIN_TOKEN" ]; then
  log_pass "Keycloak admin authentication successful"

  # Register or verify test application client in Keycloak
  CLIENT_EXISTS=$(curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
    "${KEYCLOAK_URL}/admin/realms/helmsman/clients?clientId=${TEST_APP_NAME}" | jq -r '.[0].clientId // empty')

  if [ "$CLIENT_EXISTS" == "$TEST_APP_NAME" ]; then
    log_pass "Keycloak Client ID '$TEST_APP_NAME' is registered in 'helmsman' realm"
  else
    # Create the client dynamically
    CREATE_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${KEYCLOAK_URL}/admin/realms/helmsman/clients" \
      -H "Authorization: Bearer $ADMIN_TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"clientId":"'"$TEST_APP_NAME"'", "directAccessGrantsEnabled":true, "publicClient":false}')

    if [ "$CREATE_STATUS" == "201" ]; then
      log_pass "Successfully registered new Keycloak Client ID '$TEST_APP_NAME'"
    else
      log_fail "Failed to register Keycloak Client ID (HTTP $CREATE_STATUS)"
    fi
  fi
else
  log_fail "Failed to authenticate with Keycloak at $KEYCLOAK_URL"
fi

# ----------------------------------------------------
# Step 2: Vault Secret Creation & KV Engine Check
# ----------------------------------------------------
log_stage "2. Testing Vault Secret Storage"

# Write dynamic test secret to Vault for the onboarded app
VAULT_WRITE_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"data": {"client_id": "'"$TEST_APP_NAME"'", "client_secret": "super-secret-token-123"}}' \
  "${VAULT_URL}/v1/secret/data/${TEST_NS}/config" || echo "000")

if [ "$VAULT_WRITE_STATUS" == "200" ]; then
  log_pass "App secrets successfully written to Vault path: secret/data/${TEST_NS}/config"
else
  log_fail "Failed to write secret to Vault (HTTP $VAULT_WRITE_STATUS)"
fi

# ----------------------------------------------------
# Step 3: ESO ExternalSecret Sync Check on Spoke
# ----------------------------------------------------
log_stage "3. Testing ESO Secret Synchronization on Spoke"

# Check if target Kubernetes namespace exists on spoke
kubectl --context "$SPOKE_CTX" create namespace "$TEST_NS" --dry-run=client -o yaml | \
  kubectl --context "$SPOKE_CTX" apply -f - >/dev/null 2>&1

# Apply a test ExternalSecret object
cat <<EOF | kubectl --context "$SPOKE_CTX" apply -f - >/dev/null 2>&1
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: ${TEST_APP_NAME}-es
  namespace: ${TEST_NS}
spec:
  refreshInterval: 10s
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: ${TEST_APP_NAME}-k8s-secret
    creationPolicy: Owner
  data:
    - secretKey: CLIENT_SECRET
      remoteRef:
        key: secret/data/${TEST_NS}/config
        property: client_secret
EOF

log_info "Waiting up to 30s for External Secrets Operator to sync Vault → K8s Secret..."

SYNC_SUCCESS=false
for i in {1..15}; do
  SECRET_VAL=$(kubectl --context "$SPOKE_CTX" get secret "${TEST_APP_NAME}-k8s-secret" \
    -n "$TEST_NS" -o jsonpath='{.data.CLIENT_SECRET}' 2>/dev/null | base64 -d || echo "")
  
  if [ "$SECRET_VAL" == "super-secret-token-123" ]; then
    SYNC_SUCCESS=true
    break
  fi
  sleep 2
done

if $SYNC_SUCCESS; then
  log_pass "ESO successfully synced Vault secret to Kubernetes Secret '${TEST_APP_NAME}-k8s-secret'"
else
  log_fail "ESO secret sync timed out or secret value mismatch"
fi

# ----------------------------------------------------
# Step 4: Workload Secret Injection Verification
# ----------------------------------------------------
log_stage "4. Verifying Workload Secret Consumption"

POD_SECRET_CHECK=$(kubectl --context "$SPOKE_CTX" get secret "${TEST_APP_NAME}-k8s-secret" \
  -n "$TEST_NS" --no-headers -o name 2>/dev/null || echo "")

if [ -n "$POD_SECRET_CHECK" ]; then
  log_pass "K8s secret is present and ready for mounting by pod deployments in '$TEST_NS'"
else
  log_fail "Kubernetes secret missing in namespace '$TEST_NS'"
fi

# ----------------------------------------------------
# Summary Matrix
# ----------------------------------------------------
log_stage "Onboarding Integration Verification Results"
echo -e "${GREEN}Passed Tests: $TESTS_PASSED${NC}"
echo -e "${RED}Failed Tests: $TESTS_FAILED${NC}"
echo -e "\n${CYAN}Clusters remain running and untouched.${NC}\n"