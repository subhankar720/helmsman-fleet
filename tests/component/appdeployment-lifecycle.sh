#!/usr/bin/env bash
# tests/component/appdeployment-lifecycle.sh — AppDeployment lifecycle, end to end (WO-1.1c, Appendix A).
#
# Creates a temporary namespace (managed-namespace label) and an AppDeployment whose spec is copied from the
# live sample-app one with a different name, then checks that the operator:
#   - gets its StatefulSet admitted by the platform's Kyverno policies and the pod to Ready,
#   - creates the <app>-oidc ExternalSecret and Secret, the Keycloak client and the Vault credentials,
#   - removes all of it again when the AppDeployment is deleted (variant A) or when its namespace is
#     deleted first (variant B: proves the operator-namespace configuration fallback).
# sample-app is the control: its AppDeployment and StatefulSet must be unchanged before and after.
#
# Usage:  tests/component/appdeployment-lifecycle.sh [--variant A|B] [--no-config-copy]
#   --variant A        (default) delete the AppDeployment, then check everything is gone
#   --variant B        delete the NAMESPACE first, then check Keycloak and Vault are cleaned up
#   --no-config-copy   do not copy helmsman-platform-config into the test namespace
#                      (variant B never copies it: the operator must use its own namespace's copy)
# Env: LIFECYCLE_PREFIX (default lc-test) names the namespace/app: <prefix>-<variant>-<random>.
#      READY_TIMEOUT (default 240 s), GONE_TIMEOUT (default 120 s).
#
# Secrets are never printed: Keycloak and Vault are checked from a throwaway pod in the operator's namespace
# that reads helmsman-platform-config through secretKeyRef and prints only "yes"/"no".
set -uo pipefail
cd "$(dirname "$0")/.."
source lib/assert.sh
source lib/wait.sh

VARIANT=A; COPY_CONFIG=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --variant) VARIANT="${2:-A}"; shift 2 ;;
    --no-config-copy) COPY_CONFIG=false; shift ;;
    *) echo "unknown argument: $1"; exit 2 ;;
  esac
done
[[ "$VARIANT" == A || "$VARIANT" == B ]] || { echo "--variant must be A or B"; exit 2; }
[[ "$VARIANT" == B ]] && COPY_CONFIG=false

PREFIX="${LIFECYCLE_PREFIX:-lc-test}"
ID="$(tr -dc 'a-z0-9' </dev/urandom | head -c 5)"
APP="${PREFIX}-$(echo "$VARIANT" | tr 'AB' 'ab')-${ID}"
NS="$APP"
OPNS="helmsman-operator-system"
CHECKER="${PREFIX}-check-${ID}"
READY_TIMEOUT="${READY_TIMEOUT:-240}"
GONE_TIMEOUT="${GONE_TIMEOUT:-120}"
CONFIG_SECRET="helmsman-platform-config"

echo "▶ AppDeployment lifecycle — variant $VARIANT, app/namespace $APP, config copy in namespace: $COPY_CONFIG ($(date -u +%FT%TZ))"

# ── helpers ────────────────────────────────────────────────────────────────────
# Keycloak client and Vault credentials for one app, existence only: prints "kc=yes|no|err vault=yes|no|err".
external_state() {   # app
  local ov
  ov=$(python3 - "$CHECKER" "$CONFIG_SECRET" <<'PY'
import json,sys
name,sec=sys.argv[1:]
env=[{"name":n,"valueFrom":{"secretKeyRef":{"name":sec,"key":k}}} for n,k in
     (("KC_URL","keycloak-url"),("KC_USER","keycloak-admin-user"),("KC_PASS","keycloak-admin-password"),
      ("KC_REALM","keycloak-realm"),("V_URL","vault-url"),("V_TOKEN","vault-token"))]
print(json.dumps({"spec":{"securityContext":{"runAsNonRoot":True,"runAsUser":1000},
  "containers":[{"name":name,"image":"python:3.12-alpine","stdin":True,"stdinOnce":True,"tty":False,"env":env,
  "resources":{"limits":{"cpu":"100m","memory":"64Mi"}},"securityContext":{"allowPrivilegeEscalation":False}}]}}))
PY
)
  k -n "$OPNS" delete pod "$CHECKER" --ignore-not-found >/dev/null 2>&1
  echo "$1" | k -n "$OPNS" run "$CHECKER" --quiet --rm -i --restart=Never --image=python:3.12-alpine \
    --override-type=strategic --overrides="$ov" -- python3 -c '
import json,os,sys,urllib.request,urllib.parse,urllib.error
app=sys.stdin.readline().strip(); e=os.environ
def kc():
    try:
        d=urllib.parse.urlencode({"grant_type":"password","client_id":"admin-cli","username":e["KC_USER"],"password":e["KC_PASS"]}).encode()
        t=json.load(urllib.request.urlopen(e["KC_URL"]+"/realms/master/protocol/openid-connect/token",d,timeout=10))["access_token"]
        r=urllib.request.Request(e["KC_URL"]+"/admin/realms/"+e["KC_REALM"]+"/clients?clientId="+urllib.parse.quote(app),headers={"Authorization":"Bearer "+t})
        return "yes" if json.load(urllib.request.urlopen(r,timeout=10)) else "no"
    except Exception as x: return "err("+type(x).__name__+")"
def vault():
    try:
        r=urllib.request.Request(e["V_URL"]+"/v1/secret/metadata/apps/"+app+"/oidc",headers={"X-Vault-Token":e["V_TOKEN"]})
        urllib.request.urlopen(r,timeout=10); return "yes"
    except urllib.error.HTTPError as x: return "no" if x.code==404 else "err(HTTP %d)"%x.code
    except Exception as x: return "err("+type(x).__name__+")"
print("kc=%s vault=%s" % (kc(), vault()))' 2>/dev/null | tail -1
}

# generation + sha256 of the spec, for the sample-app control
fingerprint() {      # kind name ns
  k -n "$3" get "$1" "$2" -o json 2>/dev/null | python3 -c '
import json,sys,hashlib
d=json.load(sys.stdin); print("gen=%s spec=%s" % (d["metadata"]["generation"], hashlib.sha256(json.dumps(d["spec"],sort_keys=True).encode()).hexdigest()[:16]))'
}

exists() { k -n "$NS" get "$1" "$2" >/dev/null 2>&1 && echo yes || echo no; }   # kind name

operator_errors_for_app() {
  k -n "$OPNS" logs deploy/helmsman-operator-controller-manager --since=10m 2>/dev/null \
    | grep -F "\"$NS\"" | grep -E 'Reconciler error|denied|Failed|Warning' | tail -3 | cut -c1-600
}

cleanup() {
  echo; echo "▶ cleanup (always runs)"
  k -n "$OPNS" delete pod "$CHECKER" --ignore-not-found >/dev/null 2>&1
  if k get ns "$NS" >/dev/null 2>&1; then
    k -n "$NS" delete appdeployment "$APP" --ignore-not-found --wait=false >/dev/null 2>&1
    k -n "$NS" wait --for=delete "appdeployment/$APP" --timeout=60s >/dev/null 2>&1 \
      || echo "  ⚠ AppDeployment $NS/$APP still present after 60 s (finalizer kept — see the operator's Warning events)"
    k delete ns "$NS" --wait=false >/dev/null 2>&1 && echo "  namespace $NS deletion requested"
  fi
  local st; st=$(external_state "$APP")
  echo "  leftovers for $APP: ${st:-checker failed}  (anything 'yes' is a leak the operator did not clean up)"
}
trap cleanup EXIT

# ── 1. before ──────────────────────────────────────────────────────────────────
echo; echo "▶ 1. before"
SA_AD_BEFORE=$(fingerprint appdeployment sample-app sample-app)
SA_STS_BEFORE=$(fingerprint statefulset sample-app sample-app)
assert_not_empty "control: sample-app AppDeployment present ($SA_AD_BEFORE)" "$SA_AD_BEFORE"
assert_not_empty "control: sample-app StatefulSet present ($SA_STS_BEFORE)" "$SA_STS_BEFORE"
assert_eq "no namespace $NS yet" "no" "$(k get ns "$NS" >/dev/null 2>&1 && echo yes || echo no)"
assert_eq "no Keycloak client and no Vault credentials for $APP" "kc=no vault=no" "$(external_state "$APP")"

# ── 2. create ──────────────────────────────────────────────────────────────────
echo; echo "▶ 2. create namespace and AppDeployment"
k create ns "$NS" >/dev/null && k label ns "$NS" helmsman.dev/managed=true helmsman.dev/purpose=lifecycle-test >/dev/null
k get ns "$NS" --show-labels --no-headers | sed 's/^/  /'
if $COPY_CONFIG; then
  # copy of the config Secret (values never printed): metadata stripped, data kept
  k -n sample-app get secret "$CONFIG_SECRET" -o json | python3 -c '
import json,sys; d=json.load(sys.stdin)
print(json.dumps({"apiVersion":"v1","kind":"Secret","type":d.get("type","Opaque"),"metadata":{"name":d["metadata"]["name"]},"data":d["data"]}))' \
    | k -n "$NS" apply -f - >/dev/null && echo "  copied $CONFIG_SECRET into $NS (keys only shown): $(k -n "$NS" get secret "$CONFIG_SECRET" -o json | python3 -c 'import json,sys; print(sorted(json.load(sys.stdin)["data"]))')"
else
  echo "  no $CONFIG_SECRET in $NS: the operator must use the copy in $OPNS"
fi
k -n sample-app get appdeployment sample-app -o json | python3 -c '
import json,sys; d=json.load(sys.stdin); s=d["spec"]; s["appName"]=sys.argv[1]
print(json.dumps({"apiVersion":d["apiVersion"],"kind":"AppDeployment","metadata":{"name":sys.argv[1],"namespace":sys.argv[2],"labels":{"helmsman.dev/purpose":"lifecycle-test"}},"spec":s}))' "$APP" "$NS" \
  | k apply -f - | sed 's/^/  /'

wait_for_condition "StatefulSet $APP created (admitted by Kyverno)" "k -n $NS get sts $APP -o name" "statefulset.apps/$APP" "$READY_TIMEOUT" 5 \
  || { echo "     operator errors for $NS (last 3):"; operator_errors_for_app | sed 's/^/       /'; }
echo "  StatefulSet labels: $(k -n "$NS" get sts "$APP" -o jsonpath='{.metadata.labels}' 2>/dev/null)"
echo "  pod-template labels: $(k -n "$NS" get sts "$APP" -o jsonpath='{.spec.template.metadata.labels}' 2>/dev/null)"
wait_for_condition "ExternalSecret $APP-oidc present" "k -n $NS get externalsecret $APP-oidc -o name" "externalsecret.external-secrets.io/$APP-oidc" 60 5
wait_for_condition "Secret $APP-oidc synced (keys: client-id, client-secret, cookie-secret, issuer-url)" \
  "k -n $NS get secret $APP-oidc -o json | python3 -c 'import json,sys; print(\",\".join(sorted(json.load(sys.stdin)[\"data\"])))'" \
  "client-id,client-secret,cookie-secret,issuer-url" 90 5
wait_for_condition "pod $APP-0 Ready" "k -n $NS get pod $APP-0 -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'" "True" "$READY_TIMEOUT" 5 \
  || { k -n "$NS" get pod "$APP-0" -o jsonpath='{range .status.containerStatuses[*]}     {.name} ready={.ready} restarts={.restartCount} state={.state}{"\n"}{end}' 2>/dev/null | cut -c1-300; }
wait_for_condition "AppDeployment status Ready=True, phase Ready" \
  "k -n $NS get appdeployment $APP -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}/{.status.phase}'" "True/Ready" 60 5

# ── 3. while alive ─────────────────────────────────────────────────────────────
echo; echo "▶ 3. while alive"
assert_eq "Keycloak client and Vault credentials exist for $APP" "kc=yes vault=yes" "$(external_state "$APP")"

# ── 4. delete ──────────────────────────────────────────────────────────────────
echo; echo "▶ 4. delete ($([[ $VARIANT == A ]] && echo "AppDeployment" || echo "NAMESPACE first"))"
T0=$(date +%s)
if [[ "$VARIANT" == A ]]; then
  k -n "$NS" delete appdeployment "$APP" --wait=false | sed 's/^/  /'
  wait_for_condition "AppDeployment gone (finalizer completed)" "k -n $NS get appdeployment $APP -o name 2>/dev/null || echo gone" "gone" "$GONE_TIMEOUT" 3
else
  k delete ns "$NS" --wait=false | sed 's/^/  /'
  wait_for_condition "namespace $NS gone (AppDeployment finalizer completed)" "k get ns $NS -o name 2>/dev/null || echo gone" "gone" "$GONE_TIMEOUT" 3
fi
echo "  took $(( $(date +%s) - T0 )) s"
k -n "$OPNS" get events --field-selector involvedObject.name="$APP" -o custom-columns=TYPE:.type,REASON:.reason,MSG:.message --no-headers 2>/dev/null | sed 's/^/  operator-ns event: /'
k -n "$NS" get events --field-selector involvedObject.kind=AppDeployment -o custom-columns=TYPE:.type,REASON:.reason,MSG:.message --no-headers 2>/dev/null | tail -5 | cut -c1-250 | sed 's/^/  event: /'

# ── 5. after ───────────────────────────────────────────────────────────────────
echo; echo "▶ 5. after"
assert_eq "Keycloak client and Vault credentials removed for $APP" "kc=no vault=no" "$(external_state "$APP")"
if [[ "$VARIANT" == A ]]; then
  sleep 5   # owned objects are garbage-collected after the owner is gone
  for obj in "externalsecret $APP-oidc" "secret $APP-oidc" "statefulset $APP" "service $APP" "service $APP-headless" \
             "networkpolicy $APP-default-deny" "networkpolicy $APP-allow-ingress" "networkpolicy $APP-allow-dns" \
             "networkpolicy $APP-allow-keycloak-egress" "networkpolicy $APP-allow-vault-egress"; do
    set -- $obj
    wait_for_condition "$1 $2 gone" "k -n $NS get $1 $2 -o name 2>/dev/null || echo gone" "gone" 60 3
  done
else
  assert_eq "namespace $NS gone" "gone" "$(k get ns "$NS" -o name 2>/dev/null || echo gone)"
fi

# ── 6. control ─────────────────────────────────────────────────────────────────
echo; echo "▶ 6. sample-app unchanged"
assert_eq "sample-app AppDeployment unchanged" "$SA_AD_BEFORE" "$(fingerprint appdeployment sample-app sample-app)"
assert_eq "sample-app StatefulSet unchanged" "$SA_STS_BEFORE" "$(fingerprint statefulset sample-app sample-app)"

print_summary
