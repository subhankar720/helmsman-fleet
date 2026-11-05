#!/usr/bin/env bash
# tests/run-all.sh — run the component tests; non-zero exit if any script fails.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
for t in component/operator-rbac.sh component/accessgrant.sh component/agentforge-ingress-probe.sh; do
  echo; echo "################ $t"
  bash "$HERE/$t" || rc=1
done
echo; [ $rc -eq 0 ] && echo "ALL SUITES PASSED" || echo "SOME SUITES FAILED"
exit $rc
