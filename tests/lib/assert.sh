#!/usr/bin/env bash
# tests/lib/assert.sh — tiny assertion library for Helmsman platform tests.
# NOTE: counters use $((x+1)), not ((x++)): `((x++))` returns exit status 1 when x is 0,
# which kills any script running under `set -e` (a bug in the first scaffold in doc 24).
PASS_COUNT="${PASS_COUNT:-0}"
FAIL_COUNT="${FAIL_COUNT:-0}"
FAILURES=()

_pass() { echo "  ✅ PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
_fail() { echo "  ❌ FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); FAILURES+=("$1"); }

assert_eq() {            # description expected actual
  if [[ "$3" == "$2" ]]; then _pass "$1"
  else _fail "$1"; echo "     expected: $2"; echo "     actual:   $3"; fi
}
assert_contains() {      # description needle haystack
  if [[ "$3" == *"$2"* ]]; then _pass "$1"
  else _fail "$1"; echo "     expected to contain: $2"; echo "     actual: $3"; fi
}
assert_not_empty() {     # description value
  if [[ -n "$2" ]]; then _pass "$1"; else _fail "$1 (empty)"; fi
}
wait_for_condition() {   # description command expected [timeout=120] [interval=5]
  local desc="$1" cmd="$2" expected="$3" timeout="${4:-120}" interval="${5:-5}" elapsed=0 actual=""
  echo "  ⏳ waiting: $desc (timeout ${timeout}s)"
  while [[ $elapsed -lt $timeout ]]; do
    actual="$(eval "$cmd" 2>/dev/null || true)"
    if [[ "$actual" == "$expected" ]]; then _pass "$desc (after ${elapsed}s)"; return 0; fi
    sleep "$interval"; elapsed=$((elapsed + interval))
  done
  _fail "$desc (timeout after ${timeout}s; last value: '${actual}')"
  return 1
}
print_summary() {
  echo; echo "──────────────── summary ────────────────"
  echo "  passed: $PASS_COUNT   failed: $FAIL_COUNT"
  if [[ ${#FAILURES[@]} -gt 0 ]]; then
    printf '  failed: %s\n' "${FAILURES[@]}"; return 1
  fi
  echo "  all tests passed ✅"; return 0
}
