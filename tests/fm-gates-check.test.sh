#!/usr/bin/env bash
# Behavior tests for bin/fm-gates-check.sh on a disposable repo: a true gate,
# a false gate, an abandoned gate, the three hand-ticked shapes (pending, oddly
# cased pending, no EVIDENCE line at all), a task with no gates.md, a gates.md
# that declares nothing parseable, a timed-out CHECK through both the timeout(1)
# and the perl paths, the deciding excerpt, output carrying NUL bytes, the parse
# errors a hand-edited file can carry, the prose it may carry safely, and the
# no-write guarantees.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-gates-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-gates-check)
HOME_DIR="$TMP_ROOT/home"
REPO="$TMP_ROOT/repo"
mkdir -p "$HOME_DIR/data/t1" "$HOME_DIR/state" "$REPO"
git -C "$REPO" init -q
echo hello > "$REPO/README.md"
git -C "$REPO" -c user.name=t -c user.email=t@t add -A
git -C "$REPO" -c user.name=t -c user.email=t@t commit -qm init
HEAD=$(git -C "$REPO" rev-parse HEAD)
echo "worktree=$REPO" > "$HOME_DIR/state/t1.meta"

GATES="$HOME_DIR/data/t1/gates.md"
RESULT="$HOME_DIR/data/t1/gates-result.md"
cat > "$GATES" <<'GATES_EOF'
# Example gates
- [ ] G1: README mentions hello
  CHECK: cat README.md
  EXPECT: hello
  EVIDENCE: pending
- [ ] G2: README mentions goodbye
  CHECK: cat README.md
  EXPECT: goodbye
  EVIDENCE: pending
- [ ] G3: feature we gave up on
  CHECK: echo should-not-run > ran-g3.txt
  EXPECT: never
  EVIDENCE: pending
- [x] G4: ticked by hand without evidence
  CHECK: cat README.md
  EXPECT: hello
  EVIDENCE: pending
- [x] G5: ticked by hand with no evidence line at all
  CHECK: cat README.md
  EXPECT: hello
ABANDON: G3 upstream removed the feature
GATES_EOF
# Appended rather than written in the heredoc so the padding an editor would
# strip stays part of the fixture.
printf -- '- [x] G6: ticked by hand with an oddly written pending\n  CHECK: cat README.md\n  EXPECT: hello\n  EVIDENCE:   Pending  \n' >> "$GATES"
BEFORE=$(cat "$GATES")

run() { FM_HOME="$HOME_DIR" "$CHECK" "$@"; }

# 1. Mixed file: true, false, abandoned, hand-ticked -> exit 1 with each verdict.
out=$(run t1 2>&1); rc=$?
[ "$rc" -eq 1 ] || fail "mixed gates should exit 1, got $rc: $out"
grep -q '^G1: satisfied' <<<"$out" || fail "G1 should be satisfied: $out"
grep -q '^G2: unsatisfied' <<<"$out" || fail "G2 should be unsatisfied: $out"
grep -q '^G3: abandoned' <<<"$out" || fail "G3 should be abandoned: $out"
grep -q '^G4: unsatisfied.*ticked by hand' <<<"$out" || fail "G4 hand tick should be unsatisfied explicitly: $out"
grep -q '^G5: unsatisfied.*ticked by hand' <<<"$out" || fail "G5 tick without an EVIDENCE line should be unsatisfied: $out"
grep -q '^G6: unsatisfied.*ticked by hand' <<<"$out" || fail "G6 padded, capitalised pending should be unsatisfied: $out"
pass "true gate satisfied, false gate refused, abandoned reported, every hand-tick shape refused"

# 2. gates-result.md records head, timestamp, per-gate output, and summary.
[ -f "$RESULT" ] || fail "gates-result.md missing"
grep -q "^head: $HEAD\$" "$RESULT" || fail "result lacks copy HEAD"
grep -Eq '^checked: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$RESULT" || fail "result lacks timestamp"
grep -q "^copy: $REPO\$" "$RESULT" || fail "result lacks copy path"
grep -q '^## G1: satisfied' "$RESULT" || fail "result lacks G1 section"
grep -q '^## G2: unsatisfied' "$RESULT" || fail "result lacks G2 section"
grep -q '^## G3: abandoned' "$RESULT" || fail "result lacks G3 section"
grep -q '^## G4: unsatisfied' "$RESULT" || fail "result lacks G4 section"
grep -q 'upstream removed the feature' "$RESULT" || fail "abandon reason not recorded"
grep -q '^satisfied=1 unsatisfied=4 abandoned=1 accepted=0 abandon_unknown=0 unparseable=0 parse_errors=0 exit=1$' "$RESULT" \
  || fail "summary wrong: $(tail -1 "$RESULT")"
awk '/^## G2/,/^## G3/' "$RESULT" | grep -q '^hello$' || fail "deciding output excerpt missing for G2"
pass "gates-result.md carries head, timestamp, excerpts, and summary"

# 3. The checker writes nothing but gates-result.md: gates.md unchanged, copy clean,
#    abandoned CHECK never ran.
[ "$(cat "$GATES")" = "$BEFORE" ] || fail "gates.md was modified"
[ -z "$(git -C "$REPO" status --porcelain)" ] || fail "copy was modified: $(git -C "$REPO" status --porcelain)"
[ ! -e "$REPO/ran-g3.txt" ] || fail "abandoned gate's CHECK was executed"
extra=$(find "$HOME_DIR/data/t1" -mindepth 1 ! -name gates.md ! -name gates-result.md)
[ -z "$extra" ] || fail "unexpected files written: $extra"
pass "only gates-result.md is written"

# 4. Accepting the abandon removes it from the failure set but G2/G4 still fail.
out=$(run t1 --accept-abandon G3 2>&1); rc=$?
[ "$rc" -eq 1 ] || fail "accepted abandon with other failures should still exit 1, got $rc"
grep -q '^G3: abandoned - accepted' <<<"$out" || fail "accepted abandon not reported: $out"
pass "accepted abandon is reported apart and does not mask other failures"

# 5. A file with one true gate and one accepted abandon exits 0; unaccepted exits 1.
cat > "$GATES" <<'GATES_EOF'
- [ ] G1: README mentions hello
  CHECK: cat README.md
  EXPECT: hello
  EVIDENCE: pending
- [ ] G2: gone
  CHECK: true
  EXPECT: x
  EVIDENCE: pending
ABANDON: G2 dropped from scope
GATES_EOF
run t1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] || fail "unaccepted abandon should keep exit non-zero, got $rc"
run t1 --accept-abandon G2 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] || fail "all satisfied plus accepted abandon should exit 0, got $rc"
grep -q '^satisfied=1 unsatisfied=0 abandoned=1 accepted=1 abandon_unknown=0 unparseable=0 parse_errors=0 exit=0$' "$RESULT" \
  || fail "summary wrong after accept"
pass "exit code is zero only once every abandon is accepted"

# 6. A hand-ticked box with non-pending evidence is not refused by the tick alone.
cat > "$GATES" <<'GATES_EOF'
- [x] G1: README mentions hello
  CHECK: cat README.md
  EXPECT: hello
  EVIDENCE: verified by firstmate on a prior run
GATES_EOF
run t1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] || fail "ticked box with recorded evidence and passing CHECK should exit 0, got $rc"
pass "hand tick is refused only while evidence is pending"

# 7. A CHECK that exceeds the timeout is unsatisfied, not a hang.
cat > "$GATES" <<'GATES_EOF'
- [ ] G1: slow
  CHECK: sleep 5; echo done
  EXPECT: done
  EVIDENCE: pending
GATES_EOF
start=$(date +%s)
out=$(run t1 --timeout 1 2>&1); rc=$?
elapsed=$(( $(date +%s) - start ))
[ "$rc" -eq 1 ] || fail "timed-out CHECK should exit 1, got $rc"
grep -q 'timed out' <<<"$out" || fail "timeout not reported: $out"
[ "$elapsed" -lt 4 ] || fail "timeout did not cut the CHECK short (${elapsed}s)"

# Shadow both preferred timers with stubs that exit 0 at once, so only the perl
# branch can still produce a timeout verdict. Without the knob the stub answers
# instead and the gate reads "output lacked EXPECT", which is what makes this
# case discriminating rather than a second copy of the one above.
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
fm_fake_exit0 "$FAKEBIN" timeout gtimeout
out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" "$CHECK" t1 --timeout 1 2>&1); rc=$?
[ "$rc" -eq 1 ] || fail "stubbed timer should leave the gate unsatisfied, got $rc"
grep -q 'output lacked EXPECT' <<<"$out" \
  || fail "the timeout stub is not on PATH, so the fallback case proves nothing: $out"

start=$(date +%s)
out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_CHECK_FORCE_FALLBACK=1 \
  "$CHECK" t1 --timeout 1 2>&1); rc=$?
elapsed=$(( $(date +%s) - start ))
[ "$rc" -eq 1 ] || fail "timed-out CHECK on the perl fallback should exit 1, got $rc"
grep -q 'timed out' <<<"$out" || fail "perl fallback did not report the timeout: $out"
[ "$elapsed" -lt 4 ] || fail "perl fallback did not cut the CHECK short (${elapsed}s)"
pass "per-CHECK timeout is enforced on both the timeout(1) and the perl paths"

# 8. An ABANDON naming an unknown gate is reported and fails.
cat > "$GATES" <<'GATES_EOF'
- [ ] G1: ok
  CHECK: cat README.md
  EXPECT: hello
  EVIDENCE: pending
ABANDON: G9 typo
GATES_EOF
out=$(run t1 --accept-abandon G9 2>&1); rc=$?
[ "$rc" -eq 1 ] || fail "unknown abandon id should exit 1, got $rc"
grep -q '^G9: abandon-unknown' <<<"$out" || fail "unknown abandon not reported: $out"
grep -q 'abandon_unknown=1' "$RESULT" || fail "summary does not explain the verdict: $(tail -1 "$RESULT")"
pass "abandon of an unknown gate is refused, and the summary says so"

# 8b. A gates.md that exists but declares no parseable gate fails; it is not a pass.
printf 'gates to be written later\nnothing declared yet\n' > "$GATES"
out=$(run t1 2>&1); rc=$?
[ "$rc" -eq 1 ] || fail "unparseable gates.md should exit 1, got $rc: $out"
grep -q '^gates.md: unparseable' <<<"$out" || fail "unparseable file not reported: $out"
grep -q 'unparseable=1' "$RESULT" || fail "summary does not explain the verdict: $(tail -1 "$RESULT")"
pass "a gates.md declaring nothing parseable is a failure, not a clean pass"

# 8c. The recorded excerpt carries the line that decided the verdict, and output
#     that is itself fenced does not break the block.
cat > "$GATES" <<'GATES_EOF'
- [ ] G1: the match is buried far below the head of the output
  CHECK: seq 1 40; printf 'intro\n```\nfenced body\n```\nDECIDER\n'
  EXPECT: DECIDER
  EVIDENCE: pending
GATES_EOF
run t1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] || fail "buried match should still satisfy the gate, got $rc"
body=$(awk '/^output:$/ { getline fence; while ((getline l) > 0) { if (l == fence) exit; print l } }' "$RESULT")
grep -q '^DECIDER$' <<<"$body" || fail "excerpt lacks the deciding line: $body"
grep -q '^fenced body$' <<<"$body" || fail "excerpt lost context around the match: $body"
grep -qx '```' <<<"$body" || fail "excerpt dropped the CHECK's own fence: $body"
grep -q '^1$' <<<"$body" && fail "excerpt is still the head of the output rather than the match"
pass "the excerpt shows the deciding line in context, whatever the output contains"

# 8d. A CRLF gates.md is read like any other: the pending tick is still refused.
printf -- '- [x] G1: ticked\r\n  CHECK: cat README.md\r\n  EXPECT: hello\r\n  EVIDENCE: pending\r\n' > "$GATES"
out=$(run t1 2>&1); rc=$?
[ "$rc" -eq 1 ] || fail "CRLF gates.md should still refuse the pending hand tick, got $rc: $out"
grep -q '^G1: unsatisfied.*ticked by hand' <<<"$out" || fail "CRLF hand tick was not refused: $out"
pass "line endings do not decide a gate"

# 8e. NUL bytes in a CHECK's output do not hide the match nor lose the result file.
cat > "$GATES" <<'GATES_EOF'
- [ ] G1: the deciding line sits next to a NUL byte
  CHECK: printf 'noise\000more noise\nDECIDER\n'
  EXPECT: DECIDER
  EVIDENCE: pending
GATES_EOF
out=$(run t1 2> "$TMP_ROOT/nul.err"); rc=$?
[ "$rc" -eq 0 ] || fail "binary-looking output should still satisfy the gate, got $rc: $out"
[ -f "$RESULT" ] || fail "binary-looking output cost the run its result file"
grep -q '^## G1: satisfied' "$RESULT" || fail "result lacks the satisfied verdict: $(cat "$RESULT")"
[ ! -s "$TMP_ROOT/nul.err" ] || fail "NUL output left noise on stderr: $(cat "$TMP_ROOT/nul.err")"
pass "a NUL byte in the output decides nothing and says nothing"

# 8f. The grammar is deny-by-default: a line matches one of the three shapes, is
#     context, or is a parse error naming its own line number. Each row below is
#     description|gates.md body|expected parse-error lines|expected exit code.
#     Every body carries the same reference gate, so each row also proves the slip
#     did not change the verdict of the gate beside it.
REF='- [ ] G1: the reference gate\n  CHECK: cat README.md\n  EXPECT: hello\n  EVIDENCE: pending'
rows=0
while IFS='|' read -r desc body errs want_rc; do
  case "$desc" in ''|'#'*) continue ;; esac
  rows=$((rows + 1))
  printf '%b\n' "$body" > "$GATES"
  out=$(run t1 2>&1 </dev/null); rc=$?
  [ "$rc" -eq "$want_rc" ] || fail "$desc: expected exit $want_rc, got $rc: $out"
  n=0
  for e in $errs; do
    n=$((n + 1))
    grep -q "^gates.md:$e: parse-error" <<<"$out" || fail "$desc: line $e was not reported: $out"
  done
  grep -q " parse_errors=$n exit=$want_rc\$" "$RESULT" \
    || fail "$desc: summary does not match the verdict: $(tail -1 "$RESULT")"
  grep -q '^G1: satisfied' <<<"$out" || fail "$desc: the reference gate lost its own verdict: $out"
done <<TABLE
a file of nothing but valid shapes|$REF||0
a link bullet is context|- [firstmate#2](https://example.invalid/issues/2)\n$REF||0
a heading and prose are context|# Gates for t1\ncontext for the reviewer\n$REF||0
an asterisk bullet|$REF\n* [ ] G2: an asterisk bullet|5|1
no space after the dash|$REF\n-[ ] G2: x|5|1
two spaces before the box|$REF\n-  [ ] G2: x|5|1
a space inside the box|$REF\n- [ x] G2: x|5|1
no space after the box|$REF\n- [ ]G2: x|5|1
a box with no bullet|$REF\n[x] G2: x|5|1
an indented gate line|$REF\n - [ ] G2: x|5|1
a gate with no id|$REF\n- [ ] : an outcome with no id|5|1
a gate id carrying whitespace|$REF\n- [ ] G 2: x|5|1
a gate line with no colon|$REF\n- [ ] G2 no colon here|5|1
a gate id declared twice|$REF\n- [ ] G1: declared a second time|5|1
a field given twice|$REF\n  CHECK: echo twice|5|1
a field with no value|- [ ] G1: the reference gate\n  CHECK: cat README.md\n  EXPECT: hello\n  EVIDENCE:   |4|1
a field with no space after the colon|$REF\n  CHECK:echo x|5|1
an unindented field|$REF\nCHECK: echo x|5|1
a field before any gate|  CHECK: echo x\n$REF|1|1
a field after a rejected gate line|$REF\n* [ ] G2: x\n  CHECK: echo x|5 6|1
an abandon with no space after the colon|$REF\nABANDON:G1 no space|5|1
an indented abandon|$REF\n ABANDON: G1 indented|5|1
an abandon with no reason|$REF\nABANDON: G1|5|1
an abandon with no id|$REF\nABANDON:   |5|1
TABLE
[ "$rows" -eq 24 ] || fail "the grammar table ran $rows rows, not 24"
pass "the grammar takes its three shapes, ignores context, and reports every slip"

# 8i. Padding after the checkbox does not change the gate id an ABANDON must name.
cat > "$GATES" <<'GATES_EOF'
- [ ]  G1: two spaces after the box
  CHECK: cat README.md
  EXPECT: hello
  EVIDENCE: pending
ABANDON: G1 dropped from scope
GATES_EOF
out=$(run t1 --accept-abandon G1 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "the padded gate id should be the one ABANDON names, got $rc: $out"
grep -q '^G1: abandoned - accepted' <<<"$out" || fail "padded gate id was not matched: $out"
pass "the gate id is read the same way wherever it appears"

# 9. No gates.md: explicit no-op, exit 0, no result written.
mkdir -p "$HOME_DIR/data/t2"
echo "worktree=$REPO" > "$HOME_DIR/state/t2.meta"
out=$(run t2 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "task without gates.md should exit 0, got $rc: $out"
grep -q '^no gates for t2' <<<"$out" || fail "no-op message missing: $out"
[ ! -e "$HOME_DIR/data/t2/gates-result.md" ] || fail "no-op wrote a result file"
pass "task without gates.md is an explicit no-op"

# 10. Missing meta or worktree= is a usage error (exit 2).
mkdir -p "$HOME_DIR/data/t3"
printf -- '- [ ] G1: x\n  CHECK: true\n  EXPECT: x\n  EVIDENCE: pending\n' > "$HOME_DIR/data/t3/gates.md"
run t3 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "missing meta should exit 2, got $rc"
echo "project=x" > "$HOME_DIR/state/t3.meta"
run t3 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "meta without worktree= should exit 2, got $rc"
pass "unresolvable copy is a usage error"

echo "all fm-gates-check tests passed"
