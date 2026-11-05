#!/usr/bin/env bash
# tests/component/agentforge-ingress-probe.sh — the AgentForge gateway pod accepts traffic only from the
# two sources allowed by NetworkPolicy agentforge-allow-ingress (PWP-1 item 1.1):
#   gateway-infra pods        app.kubernetes.io/name=agentforge-oauth2-proxy
#   envoy-gateway-system pods  the four Envoy proxy labels of helmsman-gateway
# For each probe namespace a throwaway pod whose labels match NEITHER source sends forged identity
# headers to the gateway's /health. A probe PASSES when the answer is NOT HTTP 200 (blocked or timed
# out). A separate control pod in gateway-infra carries the allowed oauth2-proxy label and is EXPECTED
# to get 200 — that proves the probe can see reachability at all. The control pod has a readiness probe
# that always fails, so it never becomes an endpoint of the real oauth2-proxy Service.
# Every probe pod is deleted (kubectl run --rm, plus an EXIT trap). Exit non-zero if any probe got 200
# or the control did not.
# Env: SPOKE_CTX, PROBE_NAMESPACES ("default gateway-infra envoy-gateway-system monitoring"),
#      PROBE_IMAGE (curlimages/curl:latest), PROBE_TIMEOUT (5).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/assert.sh"; source "$HERE/../lib/wait.sh"

TARGET="http://agentforge-gateway.agentforge.svc.cluster.local:8000/health"
NAMESPACES="${PROBE_NAMESPACES:-default gateway-infra envoy-gateway-system monitoring}"
IMAGE="${PROBE_IMAGE:-curlimages/curl:latest}"
TIMEOUT="${PROBE_TIMEOUT:-5}"
ID="$$"
CREATED=()

cleanup() {
  for ref in "${CREATED[@]}"; do
    k -n "${ref%%/*}" delete pod "${ref#*/}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

# run_probe <namespace> <pod-name> <labels> → prints "<http_code> <curl_exit>", or nothing if the pod never ran
run_probe() {
  local ns="$1" name="$2" labels="$3"
  CREATED+=("$ns/$name")
  k -n "$ns" run "$name" --quiet --rm -i --restart=Never --image="$IMAGE" \
      --labels="$labels" --override-type=strategic \
      --overrides="{\"spec\":{\"containers\":[{\"name\":\"$name\",\"image\":\"$IMAGE\",\"readinessProbe\":{\"exec\":{\"command\":[\"false\"]},\"periodSeconds\":1}}]}}" \
      -- sh -c "curl -s -o /dev/null --max-time $TIMEOUT -w '%{http_code}' \
         -H 'X-Forwarded-User: mallory' -H 'X-Forwarded-Groups: /teams/mallory' '$TARGET'; echo \" \$?\"" 2>/dev/null \
    | grep -Eo '^[0-9]{3} [0-9]+$' | tail -1
}

# A non-allowed probe is BLOCKED only when curl gave up on the connection (28 timeout, 7 refused,
# 52/56 reset) or got a non-200 answer. No output at all means the probe pod did not run: ERROR.
classify() {  # "<code> <exit>" → REACHABLE | BLOCKED | ERROR
  local code="${1%% *}" rc="${1##* }"
  if [[ -z "$1" ]]; then echo ERROR
  elif [[ "$code" == "200" ]]; then echo REACHABLE
  elif [[ "$code" != "000" ]] || [[ "$rc" =~ ^(7|28|52|56)$ ]]; then echo BLOCKED
  else echo ERROR; fi
}

echo "=== AgentForge gateway ingress probe (context: $SPOKE_CTX, target: $TARGET, timeout ${TIMEOUT}s)"

echo "--- probes from non-allowed pods (expected: NOT 200)"
for ns in $NAMESPACES; do
  res="$(run_probe "$ns" "af-ingress-probe-$ID" "helmsman.dev/probe=agentforge-ingress")"
  detail="HTTP ${res%% *}, curl exit ${res##* }"; [[ -z "$res" ]] && detail="probe pod produced no result"
  case "$(classify "$res")" in
    BLOCKED)   _pass "$(printf '%-22s BLOCKED   (%s)' "$ns" "$detail")" ;;
    REACHABLE) _fail "$(printf '%-22s REACHABLE (%s) — a non-allowed pod reached the gateway' "$ns" "$detail")" ;;
    *)         _fail "$(printf '%-22s ERROR     (%s) — could not run the probe' "$ns" "$detail")" ;;
  esac
done

echo "--- control: gateway-infra pod WITH the allowed oauth2-proxy label (expected: 200)"
res="$(run_probe gateway-infra "af-ingress-control-$ID" "app.kubernetes.io/name=agentforge-oauth2-proxy,helmsman.dev/probe=agentforge-ingress-control")"
detail="HTTP ${res%% *}, curl exit ${res##* }"; [[ -z "$res" ]] && detail="probe pod produced no result"
if [[ "$(classify "$res")" == "REACHABLE" ]]; then
  _pass "$(printf '%-22s CONTROL REACHABLE (%s) — the probe can detect reachability' "gateway-infra" "$detail")"
else
  _fail "$(printf '%-22s CONTROL NOT REACHABLE (%s) — probe results above cannot be trusted' "gateway-infra" "$detail")"
fi

print_summary
