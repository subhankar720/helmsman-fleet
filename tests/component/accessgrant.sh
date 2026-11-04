#!/usr/bin/env bash
# tests/component/accessgrant.sh — AccessGrant lifecycle: Pending → Active → Expired, RoleBinding created and
# removed, access actually granted then revoked, and NO oscillation after expiry (the Phase 7 bug).
# Env: GRANT_NS (sample-app), GRANT_TTL (1m), GRANT_TTL_SECONDS (60), SPOKE_CTX.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/assert.sh"; source "$HERE/../lib/wait.sh"

NS="${GRANT_NS:-sample-app}"
TTL="${GRANT_TTL:-1m}"
TTL_S="${GRANT_TTL_SECONDS:-60}"
NAME="test-grant-$$"
SUBJECT="test-$$@helmsman.dev"

cleanup() { k -n "$NS" delete accessgrant "$NAME" --ignore-not-found >/dev/null 2>&1; }
trap cleanup EXIT

echo "=== AccessGrant lifecycle (context: $SPOKE_CTX, ttl: $TTL)"

echo "--- before the grant"
out="$(k auth can-i list pods -n "$NS" --as="$SUBJECT" 2>/dev/null || true)"
assert_eq "subject has no access before the grant" "no" "$out"

echo "--- create (environment: dev, no approval needed)"
k apply -f - >/dev/null <<YAML
apiVersion: access.helmsman.dev/v1alpha1
kind: AccessGrant
metadata: { name: $NAME, namespace: $NS }
spec:
  subject: "user:$SUBJECT"
  cluster: helmsman-onprem
  namespace: $NS
  permission: ro
  ttl: "$TTL"
  environment: dev
  reason: "automated component test"
YAML

wait_for_condition "grant reaches Active" "get_accessgrant_state $NAME $NS" "Active" 60 3 || true

rb="$(k -n "$NS" get rolebinding "helmsman-ag-$NAME" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "RoleBinding exists while Active" "1" "$rb"
role="$(k -n "$NS" get rolebinding "helmsman-ag-$NAME" -o jsonpath='{.roleRef.name}' 2>/dev/null || true)"
assert_eq "RoleBinding references the reader ClusterRole" "helmsman-namespace-reader" "$role"
assert_not_empty "status.expiresAt is set" "$(k -n "$NS" get accessgrant "$NAME" -o jsonpath='{.status.expiresAt}' 2>/dev/null || true)"
assert_not_empty "status.roleBindingRef is set" "$(k -n "$NS" get accessgrant "$NAME" -o jsonpath='{.status.roleBindingRef}' 2>/dev/null || true)"

out="$(k auth can-i list pods -n "$NS" --as="$SUBJECT" 2>/dev/null || true)"
assert_eq "subject CAN list pods while Active" "yes" "$out"
out="$(k auth can-i delete pods -n "$NS" --as="$SUBJECT" 2>/dev/null || true)"
assert_eq "read-only grant does NOT allow delete" "no" "$out"

echo "--- wait for expiry (ttl ${TTL_S}s)"
wait_for_condition "grant reaches Expired" "get_accessgrant_state $NAME $NS" "Expired" $((TTL_S + 90)) 5 || true

rb="$(k -n "$NS" get rolebinding "helmsman-ag-$NAME" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "RoleBinding removed after expiry" "0" "$rb"
out="$(k auth can-i list pods -n "$NS" --as="$SUBJECT" 2>/dev/null || true)"
assert_eq "subject has no access after expiry" "no" "$out"

echo "--- no oscillation (watch 25s)"
sleep 25
assert_eq "state is still Expired" "Expired" "$(get_accessgrant_state "$NAME" "$NS")"
rb="$(k -n "$NS" get rolebinding "helmsman-ag-$NAME" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "RoleBinding not recreated" "0" "$rb"

print_summary
