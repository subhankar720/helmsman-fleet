#!/usr/bin/env bash
# tests/component/operator-rbac.sh — the operator may bind exactly the predefined ClusterRoles, nothing broader.
# Regression guard for the Phase 7 failure "attempting to grant RBAC permissions not currently held".
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/assert.sh"; source "$HERE/../lib/wait.sh"

SA="system:serviceaccount:helmsman-operator-system:helmsman-operator-controller-manager"
echo "=== operator RBAC (context: $SPOKE_CTX)"

for role in reader operator admin; do
  out="$(k auth can-i bind "clusterrole/helmsman-namespace-$role" --as="$SA" 2>/dev/null || true)"
  assert_eq "operator may bind helmsman-namespace-$role" "yes" "$out"
done

# Negative: the bind permission must stay restricted by resourceNames.
for role in cluster-admin admin edit; do
  out="$(k auth can-i bind "clusterrole/$role" --as="$SA" 2>/dev/null || true)"
  assert_eq "operator may NOT bind $role" "no" "$out"
done

print_summary
