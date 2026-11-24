#!/usr/bin/env bash
# bootstrap.sh — build a local kind pair from git, the scripts and the encrypted seed (WO-1.5b).
#
# Needs: a clean checkout of helmsman-fleet and helmsman-operator side by side, and the age
# private key (default ~/.helmsman-dev/age.key, or SOPS_AGE_KEY_FILE). Nothing else.
#
#   CLUSTER_PREFIX=rb- ./scripts/bootstrap.sh          # kind clusters rb-hub / rb-onprem
#   ./scripts/bootstrap.sh --allow-existing            # also run when the clusters already exist
#
# Steps (each logged with start, end and exit code to $HELMSMAN_STATE_DIR/bootstrap.log):
#   1 preflight        tools, age key, refuse existing clusters unless --allow-existing
#   2 materialise      seed -> $HELMSMAN_STATE_DIR (mode 600 files; existing files are kept)
#   3 operator-tools   make kustomize in the operator checkout (bin/kustomize)
#   4 dev-up           dev-up-gemini.sh --bootstrap: create clusters, Argo CD, spoke registration,
#                      platform Applications, operator image build + kind load, platform state
#   5 seed-apply       seed -> Vault (fill missing) and the seed-made cluster Secrets
#   6 argo-wait        every Argo CD Application Synced and Healthy
#   7 seed-verify      every Vault path/property the platform reads, and the seed-made Secrets
#   8 sanity           helmsman-sanity.sh (0 failures required)
# Every step is idempotent: re-running the script repairs or re-checks, it never deletes.
# No credential is ever put on a command line (see docs/credentials.md).
set -euo pipefail

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; }
ALLOW_EXISTING=false
for a in "$@"; do
  case "$a" in
    --allow-existing) ALLOW_EXISTING=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $a (try --help)" >&2; exit 2 ;;
  esac
done

FLEET_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export FLEET_DIR
export OPERATOR_DIR="${OPERATOR_DIR:-$(dirname "$FLEET_DIR")/helmsman-operator}"
export CLUSTER_PREFIX="${CLUSTER_PREFIX:-helmsman-}"
export HUB_CLUSTER_NAME="${HUB_CLUSTER_NAME:-${CLUSTER_PREFIX}hub}"
export SPOKE_CLUSTER_NAME="${SPOKE_CLUSTER_NAME:-${CLUSTER_PREFIX}onprem}"
export HUB_CTX="kind-${HUB_CLUSTER_NAME}" SPOKE_CTX="kind-${SPOKE_CLUSTER_NAME}"
export HELMSMAN_STATE_DIR="${HELMSMAN_STATE_DIR:-$HOME/.helmsman-dev}"
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HELMSMAN_STATE_DIR/age.key}"
ARGO_MIN_APPS="${ARGO_MIN_APPS:-16}"   # Applications on the hub: platform-root, its children and sample-app (16 since WO-1.5b)
ARGO_WAIT_SECONDS="${ARGO_WAIT_SECONDS:-1500}"

mkdir -p "$HELMSMAN_STATE_DIR" && chmod 700 "$HELMSMAN_STATE_DIR"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$HELMSMAN_STATE_DIR/bootstrap.log"
OUT="$HELMSMAN_STATE_DIR/bootstrap-$RUN_ID.out"
( umask 077; : > "$OUT"; touch "$LOG" ); chmod 600 "$LOG" "$OUT"
exec > >(tee -a "$OUT") 2>&1

say()  { printf '\n\033[1;36m== %s ==\033[0m  %s\n' "$1" "$(date -u +%H:%M:%SZ)"; }
die()  { printf '\033[0;31mBOOTSTRAP FAILED:\033[0m %s\n' "$*"; exit 1; }
step() {  # NAME COMMAND...: run one step, record its timing and exit code
  local name="$1" t0 rc; shift
  say "$name"
  t0=$(date +%s)
  set +e; "$@"; rc=$?; set -e
  printf 'run=%s step=%s start=%s seconds=%d exit=%d prefix=%s\n' "$RUN_ID" "$name" \
    "$(date -u -d "@$t0" +%FT%TZ)" "$(( $(date +%s) - t0 ))" "$rc" "$CLUSTER_PREFIX" >> "$LOG"
  [ "$rc" -eq 0 ] || die "step $name exited $rc (full output: $OUT)"
}

preflight() {
  local missing=() t
  for t in docker kind kubectl argocd age sops python3 git make go curl jq nc; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  [ ${#missing[@]} -eq 0 ] || { echo "missing tools: ${missing[*]}"; return 1; }
  [ -f "$SOPS_AGE_KEY_FILE" ] || { echo "age private key not found: $SOPS_AGE_KEY_FILE"; return 1; }
  [ -z "$(find "$SOPS_AGE_KEY_FILE" -perm /077)" ] || { echo "$SOPS_AGE_KEY_FILE must be mode 600"; return 1; }
  [ -f "$FLEET_DIR/secrets.enc.yaml" ] || { echo "seed not found: $FLEET_DIR/secrets.enc.yaml"; return 1; }
  [ -f "$OPERATOR_DIR/Makefile" ] || { echo "operator checkout not found: $OPERATOR_DIR (set OPERATOR_DIR)"; return 1; }
  docker info >/dev/null 2>&1 || { echo "docker is not running"; return 1; }
  local existing
  existing=$(kind get clusters 2>/dev/null | grep -xE "${HUB_CLUSTER_NAME}|${SPOKE_CLUSTER_NAME}" || true)
  if [ -n "$existing" ] && ! $ALLOW_EXISTING; then
    echo "clusters already exist: $(echo "$existing" | tr '\n' ' ')— refusing (use --allow-existing to re-run on them)"
    return 1
  fi
  echo "fleet=$FLEET_DIR ($(git -C "$FLEET_DIR" rev-parse --short HEAD)) operator=$OPERATOR_DIR ($(git -C "$OPERATOR_DIR" rev-parse --short HEAD))"
  echo "clusters=$HUB_CLUSTER_NAME,$SPOKE_CLUSTER_NAME state=$HELMSMAN_STATE_DIR key=$SOPS_AGE_KEY_FILE"
  echo "free memory: $(free -m | awk '/^Mem:/ {print $7}') MiB available"
}

operator_tools() {
  if [ -x "$OPERATOR_DIR/bin/kustomize" ]; then echo "bin/kustomize present"; return 0; fi
  make -C "$OPERATOR_DIR" kustomize
}

argo_wait() {
  local deadline=$(( $(date +%s) + ARGO_WAIT_SECONDS )) total ok last=""
  while :; do
    total=$(kubectl --context "$HUB_CTX" -n argocd get applications --no-headers 2>/dev/null | wc -l)
    ok=$(kubectl --context "$HUB_CTX" -n argocd get applications --no-headers \
         -o custom-columns=S:.status.sync.status,H:.status.health.status 2>/dev/null | grep -c '^Synced *Healthy$' || true)
    [ "$ok/$total" != "$last" ] && echo "$(date -u +%H:%M:%SZ) Synced+Healthy $ok of $total (need all, at least $ARGO_MIN_APPS)"
    last="$ok/$total"
    if [ "$total" -ge "$ARGO_MIN_APPS" ] && [ "$ok" -eq "$total" ]; then return 0; fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      kubectl --context "$HUB_CTX" -n argocd get applications \
        -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
      return 1
    fi
    sleep 15
  done
}

T_START=$(date +%s)
step preflight      preflight
step materialise    python3 -I "$FLEET_DIR/scripts/seed.py" materialise
step operator-tools operator_tools
step dev-up         "$FLEET_DIR/scripts/dev-up-gemini.sh" --bootstrap
step seed-apply     python3 -I "$FLEET_DIR/scripts/seed.py" apply
step argo-wait      argo_wait
step seed-verify    python3 -I "$FLEET_DIR/scripts/seed.py" verify
step sanity         "$FLEET_DIR/scripts/helmsman-sanity.sh"
printf 'run=%s step=TOTAL seconds=%d exit=0 prefix=%s\n' "$RUN_ID" "$(( $(date +%s) - T_START ))" "$CLUSTER_PREFIX" >> "$LOG"
say "BOOTSTRAP COMPLETED in $(( ($(date +%s) - T_START) / 60 )) min — log: $LOG, output: $OUT"
