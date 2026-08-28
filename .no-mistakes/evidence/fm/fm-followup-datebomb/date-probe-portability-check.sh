#!/usr/bin/env bash
# Exercises the SHIPPED future_rfc3339 helper (extracted verbatim from each test
# file) on both date dialects, and asserts the produced fixture is genuinely in
# the future -- the property `tasks-axi public-followup add --expires-at` needs.
set -u
ROOT=${1:?worktree root}
fail=0

extract() {  # <file>
  awk '/^future_rfc3339\(\)/{p=1} p{print} p&&/^}$/{exit}' "$1"
}

check() {  # <label> <path-prefix> <file>
  local label=$1 pathpre=$2 file=$3 out now delta
  out=$(PATH="$pathpre$PATH" bash -c "$(extract "$file"); future_rfc3339 7" 2>&1)
  now=$(date -u +%s)
  delta=$(( $(date -u -d "$out" +%s) - now ))
  printf '%-46s -> %s  (now + %d days)\n' "$label" "$out" "$((delta/86400))"
  if [ "$delta" -lt 518400 ]; then    # < 6 days = collapsed to now / wrong branch
    printf '   FAIL: fixture is not ~7 days in the future\n'; fail=1
  fi
}

for f in tests/fm-public-followup.test.sh tests/fm-backlog-handoff.test.sh; do
  echo "== $f =="
  extract "$ROOT/$f" | sed 's/^/   | /'
  check "GNU date (this Linux host, real date)"   ""                        "$ROOT/$f"
  check "BSD/macOS date (emulated: -d means DST)" "/tmp/dateprobe/bsd-shim:" "$ROOT/$f"
  echo
done

echo "== counter-proof: the GNU-first probe order the review rejected =="
gnu_first() { date -u -d "+$1 days" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v+"$1"d '+%Y-%m-%dT%H:%M:%SZ'; }
out=$(PATH="/tmp/dateprobe/bsd-shim:$PATH" bash -c "$(declare -f gnu_first); gnu_first 7")
printf '%-46s -> %s  (now + %d days)\n' "GNU-first order on BSD/macOS" "$out" \
  "$(( ( $(date -u -d "$out" +%s) - $(date -u +%s) ) / 86400 ))"
echo "   ^ collapses to NOW on macOS; --expires-at <now> is then rejected as past."
echo
[ "$fail" -eq 0 ] && echo "RESULT: shipped BSD-first probe yields a real future fixture on both dialects." \
                  || echo "RESULT: FAILED"
exit "$fail"
