#!/usr/bin/env bash
# Behavior tests for bin/fm-gates-check.sh on a disposable repo: a true gate,
# a false gate, an abandoned gate, the hand-ticked shapes (pending however it is
# written, no EVIDENCE line at all), a task with no gates.md, a gates.md
# that declares nothing parseable, a timed-out CHECK through both the timeout(1)
# and the perl paths, the deciding excerpt, output carrying NUL bytes, the parse
# errors a hand-edited file can carry, the prose it may carry safely, the format
# lines a comment marker cannot hide, the refusal to decide anything in a file that
# carries a parse error, the padding it may carry around a value, the exit code of a
# CHECK killed by a signal, the task ids and timeout values that are refused
# outright, and the no-write guarantees.
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

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

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
mode=$(file_mode "$RESULT")
[ "$mode" = 600 ] || fail "gates-result.md landed with mode $mode, not 600"
pass "only gates-result.md is written, and it stays private"

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

# 6. A hand tick is judged by its EVIDENCE line: still pending however the word is
#    elaborated, and the CHECK alone once the line records what was verified.
rows=0
while IFS='|' read -r desc evidence want_rc; do
  case "$desc" in ''|'#'*) continue ;; esac
  rows=$((rows + 1))
  printf -- '- [x] G1: README mentions hello\n  CHECK: cat README.md\n  EXPECT: hello\n  EVIDENCE: %s\n' \
    "$evidence" > "$GATES"
  out=$(run t1 2>&1); rc=$?
  [ "$rc" -eq "$want_rc" ] || fail "$desc: expected exit $want_rc, got $rc: $out"
  if [ "$want_rc" -eq 1 ]; then
    grep -q '^G1: unsatisfied.*ticked by hand' <<<"$out" || fail "$desc: the tick was inherited: $out"
  else
    grep -q '^G1: satisfied' <<<"$out" || fail "$desc: recorded evidence was read as pending: $out"
  fi
done <<TABLE
evidence recorded on a prior run|verified by firstmate on a prior run|0
the bare pending literal|pending|1
pending with a reason|pending CI|1
pending with a parenthetical|pending (see #4)|1
pending said at length|pending manual verification by the reviewer|1
a longer word that merely starts with those letters|pendings were cleared by hand|0
TABLE
[ "$rows" -eq 6 ] || fail "the evidence table ran $rows rows, not 6"
pass "a hand tick is refused while its evidence line still opens with pending"

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

# 7b. A CHECK that ignores TERM is killed anyway, so the wall clock is binding on
#     the timeout(1) path as much as on the perl one.
cat > "$GATES" <<'GATES_EOF'
- [ ] G1: deaf to TERM
  CHECK: trap '' TERM; sleep 30; echo done
  EXPECT: done
  EVIDENCE: pending
GATES_EOF
start=$(date +%s)
out=$(run t1 --timeout 1 2> "$TMP_ROOT/deaf.err"); rc=$?
elapsed=$(( $(date +%s) - start ))
[ "$rc" -eq 1 ] || fail "a CHECK that ignores TERM should still exit 1, got $rc: $out"
grep -q 'timed out' <<<"$out" || fail "the killed CHECK was not reported as a timeout: $out"
[ "$elapsed" -lt 15 ] || fail "a CHECK that ignores TERM outlived its wall clock (${elapsed}s)"
[ ! -s "$TMP_ROOT/deaf.err" ] || fail "the kill left noise on stderr: $(cat "$TMP_ROOT/deaf.err")"
pass "a CHECK that ignores TERM is killed at the deadline, quietly"

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
  if [ "$n" -eq 0 ]; then
    grep -q '^G1: satisfied' <<<"$out" || fail "$desc: the reference gate lost its own verdict: $out"
  else
    grep -q '^gates.md: not-checked' <<<"$out" || fail "$desc: a broken file was not reported as undecided: $out"
    grep -q '^## G1:' "$RESULT" && fail "$desc: a gate was given a verdict in a file with a parse error"
    grep -q '^satisfied=0 unsatisfied=0 abandoned=0 accepted=0 abandon_unknown=0 unparseable=0 ' "$RESULT" \
      || fail "$desc: a broken file still counted verdicts: $(tail -1 "$RESULT")"
  fi
done <<TABLE
a file of nothing but valid shapes|$REF||0
a link bullet is context|- [firstmate#2](https://example.invalid/issues/2)\n$REF||0
a heading and prose are context|# Gates for t1\ncontext for the reviewer\n$REF||0
blank lines between a gate and its fields|- [ ] G1: the reference gate\n\n  CHECK: cat README.md\n\n  EXPECT: hello\n\n  EVIDENCE: pending||0
an asterisk bullet|$REF\n* [ ] G2: an asterisk bullet|5|1
no space after the dash|$REF\n-[ ] G2: x|5|1
two spaces before the box|$REF\n-  [ ] G2: x|5|1
a space inside the box|$REF\n- [ x] G2: x|5|1
no space after the box|$REF\n- [ ]G2: x|5|1
a box with no bullet|$REF\n[x] G2: x|5|1
a box commented out with a hash|$REF\n#- [ ] G2: x|5|1
a box inside a heading|$REF\n## [x] done|5|1
a box behind a hash and a space|$REF\n# - [ ] G2: x|5|1
a commented-out abandon|$REF\n#ABANDON: G1 dropped|5|1
a commented-out field|$REF\n# CHECK: cat README.md|5|1
a doubled hash marker|$REF\n# #ABANDON: G1 dropped|5|1
an html comment holding an abandon|$REF\n<!-- ABANDON: G1 dropped -->|5|1
an html comment holding only prose|$REF\n<!-- a note to the reviewer -->|5|1
an html comment behind a hash|$REF\n# <!-- ABANDON: G1 dropped -->|5|1
an html comment opened mid-line|$REF\n- [ ] G2: x <!-- dropped -->|5|1
a bare block-comment opener|$REF\n<!--|5|1
a bare block-comment closer|$REF\n-->|5|1
a heading that only names a gate is context|$REF\n## G2 notes||0
a comment that only reads as prose is context|$REF\n# G2 was moved to a follow-up||0
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
an id abandoned twice|$REF\nABANDON: G9 dropped\nABANDON: G9 dropped again|6|1
TABLE
[ "$rows" -eq 40 ] || fail "the grammar table ran $rows rows, not 40"
pass "the grammar takes its three shapes, ignores context, and reports every slip"

# 8g. A line the checker does not recognise closes the gate above it, so a field
#     that follows is reported as belonging to no gate rather than quietly filling
#     that gate's hole. The reference gate declares CHECK and EVIDENCE but no
#     EXPECT, and its output contains the stray EXPECT, so an adopted field would
#     leave line 5 unreported and hand G1 a verdict it never earned.
ADOPT='- [ ] G1: the suite passes with no failures\n  CHECK: echo "3 tests, 2 failures"\n  EVIDENCE: pending'
rows=0
while IFS='|' read -r desc stray errs; do
  case "$desc" in ''|'#'*) continue ;; esac
  rows=$((rows + 1))
  printf '%b\n' "$ADOPT\n$stray\n  EXPECT: 3 tests" > "$GATES"
  out=$(run t1 2>&1 </dev/null); rc=$?
  [ "$rc" -eq 1 ] || fail "$desc: expected exit 1, got $rc: $out"
  grep -q '^gates.md:5: parse-error.*EXPECT line belongs to no gate' <<<"$out" \
    || fail "$desc: the stray EXPECT was adopted by the gate above it: $out"
  grep -q '^## G1:' "$RESULT" && fail "$desc: G1 was decided in a file with a parse error"
  n=0
  for e in $errs; do
    n=$((n + 1))
    grep -q "^gates.md:$e: parse-error" <<<"$out" || fail "$desc: line $e was not reported: $out"
  done
  grep -q " parse_errors=$n exit=1\$" "$RESULT" \
    || fail "$desc: summary does not match the verdict: $(tail -1 "$RESULT")"
done <<TABLE
a bullet with no checkbox|- G2: forgot the checkbox|5
a numbered task bullet|10. [ ] G2: tenth gate|5
a blockquoted gate|> - [ ] G2: a blockquoted gate|5
a plain prose note|note: G2 was moved to a follow-up|5
a heading|## G2 notes|5
an abandon of another gate|ABANDON: G9 dropped elsewhere|5
a rejected gate line|* [ ] G2: an asterisk bullet|4 5
a gate line commented out with a hash|#- [ ] G2: commented out|4 5
an abandon commented out with a hash|#ABANDON: G9 dropped elsewhere|4 5
an abandon inside an html comment|<!-- ABANDON: G9 dropped elsewhere -->|4 5
an unindented field|CHECK: stray at column zero|4 5
an indented field missing its space|  EXPECT:nope|4 5
an indented field with no value|  EXPECT:   |4 5
an abandon behind a hash and an html comment|# <!-- ABANDON: G9 dropped elsewhere -->|4 5
TABLE
[ "$rows" -eq 14 ] || fail "the adoption table ran $rows rows, not 14"
pass "a stray line closes the gate above it instead of feeding it"

# 8h. A second ABANDON of a gate already abandoned is refused on its own line, so
#     the newer reason is never buried behind the older one and neither is applied
#     while the file stays broken. An id can therefore be abandoned at most once,
#     which is what keeps a repeated unknown id from counting twice.
cat > "$GATES" <<'GATES_EOF'
- [ ] G1: ok
  CHECK: cat README.md
  EXPECT: hello
  EVIDENCE: pending
ABANDON: G1 dropped
ABANDON: G1 actually shipped
GATES_EOF
out=$(run t1 --accept-abandon G1 2>&1); rc=$?
[ "$rc" -eq 1 ] || fail "a repeated ABANDON should exit 1, got $rc: $out"
grep -q '^gates.md:6: parse-error' <<<"$out" || fail "the second ABANDON was not reported: $out"
grep -q 'actually shipped' "$RESULT" && fail "the second reason was recorded as if it were accepted"
grep -q '^## G1:' "$RESULT" && fail "a gate was decided while the file carried a parse error"
grep -q '^satisfied=0 unsatisfied=0 abandoned=0 accepted=0 abandon_unknown=0 unparseable=0 parse_errors=1 exit=1$' "$RESULT" \
  || fail "summary wrong: $(tail -1 "$RESULT")"

cat > "$GATES" <<'GATES_EOF'
- [ ] G1: ok
  CHECK: cat README.md
  EXPECT: hello
  EVIDENCE: pending
ABANDON: G9 typo
ABANDON: G9 typo again
GATES_EOF
out=$(run t1 2>&1); rc=$?
[ "$rc" -eq 1 ] || fail "a repeated unknown ABANDON should exit 1, got $rc: $out"
grep -q '^gates.md:6: parse-error' <<<"$out" || fail "the repeated unknown ABANDON was not reported: $out"
[ "$(grep -c '^## G9:' "$RESULT")" -eq 0 ] \
  || fail "an unknown gate was reported while the file carried a parse error: $(cat "$RESULT")"
pass "an id is abandoned once, and a repeat is reported instead of silently applied"

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

# 8j. Whitespace at either end of a value is padding, not part of it: an EXPECT
#     doubly spaced after its colon, or carrying a Markdown hard line break, still
#     matches the output that contains it.
printf -- '- [ ] G1: README mentions hello\n  CHECK:  cat README.md\n  EXPECT:  hello\n  EVIDENCE: pending\n' \
  > "$GATES"
out=$(run t1 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "a doubled space after the colon should not fail the gate, got $rc: $out"
grep -q "^G1: satisfied - output contained EXPECT 'hello' " <<<"$out" \
  || fail "the padding stayed part of the EXPECT value: $out"
printf -- '- [ ] G1: README mentions hello\n  CHECK: cat README.md  \n  EXPECT: hello  \n  EVIDENCE: pending\n' \
  > "$GATES"
out=$(run t1 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "a hard line break after EXPECT should not fail the gate, got $rc: $out"
grep -q "^G1: satisfied - output contained EXPECT 'hello' " <<<"$out" \
  || fail "the padding stayed part of the EXPECT value: $out"
printf -- '- [x] G1: README mentions hello\n  CHECK: cat README.md\n  EXPECT: hello\n  EVIDENCE: pending\t\n' \
  > "$GATES"
out=$(run t1 2>&1); rc=$?
[ "$rc" -eq 1 ] || fail "a tab after pending should not turn it into recorded evidence, got $rc: $out"
grep -q '^G1: unsatisfied.*ticked by hand' <<<"$out" || fail "the padded pending was read as evidence: $out"
pass "whitespace at either end of a value pads it rather than deciding a gate"

# 8k. A CHECK killed by a signal records 128+signal, the same on either timer
#     path, so the result never reads a crash as a clean exit.
cat > "$GATES" <<'GATES_EOF'
- [ ] G1: the CHECK dies before it can print the match
  CHECK: echo partial; kill -SEGV $$
  EXPECT: never printed
  EVIDENCE: pending
GATES_EOF
out=$(run t1 --timeout 10 2>&1); rc=$?
[ "$rc" -eq 1 ] || fail "a CHECK that crashes should leave its gate unsatisfied, got $rc: $out"
grep -q '^G1: unsatisfied.*(exit 139)$' <<<"$out" || fail "timeout(1) path lost the signal exit code: $out"
out=$(FM_CHECK_FORCE_FALLBACK=1 run t1 --timeout 10 2>&1); rc=$?
[ "$rc" -eq 1 ] || fail "a crashing CHECK on the perl fallback should exit 1, got $rc: $out"
grep -q '^G1: unsatisfied.*(exit 139)$' <<<"$out" \
  || fail "the perl fallback recorded the crash as a clean exit: $out"
grep -q 'exit 139' "$RESULT" || fail "the result file lost the signal exit code: $(cat "$RESULT")"
pass "a CHECK killed by a signal is recorded as 128+signal on either timer path"

# 8l. No comment marker deletes an ABANDON. Commenting one out used to hand the gate
#     back to the checker, which ran its CHECK and passed it at exit 0 with nothing
#     reported; the hidden line is now named and the run fails.
ABANDONED='- [ ] G1: README mentions hello\n  CHECK: cat README.md\n  EXPECT: hello\n  EVIDENCE: pending\n- [ ] G3: the feature we gave up on\n  CHECK: cat README.md\n  EXPECT: hello\n  EVIDENCE: pending'
rows=0
while IFS='|' read -r desc marker; do
  case "$desc" in ''|'#'*) continue ;; esac
  rows=$((rows + 1))
  printf '%b\n' "$ABANDONED\n$marker" > "$GATES"
  out=$(run t1 --accept-abandon G3 2>&1); rc=$?
  [ "$rc" -eq 1 ] || fail "$desc: a hidden ABANDON should not pass the run, got $rc: $out"
  grep -q '^gates.md:9: parse-error' <<<"$out" || fail "$desc: the hidden ABANDON was dropped in silence: $out"
  grep -q ' abandoned=0 accepted=0 .* parse_errors=1 exit=1$' "$RESULT" \
    || fail "$desc: the hidden ABANDON left the summary claiming a clean run: $(tail -1 "$RESULT")"
done <<TABLE
a hash|#ABANDON: G3 upstream removed the feature
a doubled hash|# #ABANDON: G3 upstream removed the feature
an html comment|<!-- ABANDON: G3 upstream removed the feature -->
an html comment behind a hash|# <!-- ABANDON: G3 upstream removed the feature -->
TABLE
[ "$rows" -eq 4 ] || fail "the hidden-abandon table ran $rows rows, not 4"
pass "no comment marker quietly turns an abandoned gate back into a passing one"

# 8m. A block comment cannot smuggle a gate past the checker either. Both of its
#     delimiters are reported, and because a file with any parse error decides
#     nothing, the gate written between them is never run and never reaches the
#     result file.
cat > "$GATES" <<'GATES_EOF'
- [ ] G1: README mentions hello
  CHECK: cat README.md
  EXPECT: hello
  EVIDENCE: pending
<!--
- [ ] G2: the gate we commented out
  CHECK: touch ran-g2.txt; cat README.md
  EXPECT: hello
  EVIDENCE: pending
-->
GATES_EOF
rm -f "$REPO/ran-g2.txt"
out=$(run t1 2>&1); rc=$?
[ "$rc" -eq 1 ] || fail "a block comment should not leave the run passing, got $rc: $out"
grep -q '^gates.md:5: parse-error' <<<"$out" || fail "the comment opener was not reported: $out"
grep -q '^gates.md:10: parse-error' <<<"$out" || fail "the comment closer was not reported: $out"
[ ! -e "$REPO/ran-g2.txt" ] || fail "the CHECK inside the comment was executed"
grep -q '^## G2:' "$RESULT" && fail "the commented-out gate reached the result file"
grep -q '^## G1:' "$RESULT" && fail "a gate was decided while the file carried a parse error"
grep -q '^satisfied=0 unsatisfied=0 abandoned=0 accepted=0 abandon_unknown=0 unparseable=0 parse_errors=2 exit=1$' "$RESULT" \
  || fail "summary wrong: $(tail -1 "$RESULT")"
[ -z "$(git -C "$REPO" status --porcelain)" ] || fail "the copy was modified: $(git -C "$REPO" status --porcelain)"
pass "a block comment declares nothing, runs nothing, and is reported at both ends"

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

# 10b. The task id names data/<id>/ and state/<id>.meta, so an id that is not a
#      plain name is refused before any file is read or any CHECK is run.
mkdir -p "$HOME_DIR/escape"
printf -- '- [ ] G1: escapes the operational home\n  CHECK: touch %s/escaped.txt; echo done\n  EXPECT: done\n  EVIDENCE: pending\n' \
  "$TMP_ROOT" > "$HOME_DIR/escape/gates.md"
echo "worktree=$REPO" > "$HOME_DIR/escape.meta"
out=$(run ../escape 2>&1); rc=$?
[ "$rc" -eq 2 ] || fail "a traversing task id should exit 2, got $rc: $out"
[ ! -e "$TMP_ROOT/escaped.txt" ] || fail "a traversing task id ran a CHECK from outside the home"
[ ! -e "$HOME_DIR/escape/gates-result.md" ] || fail "a traversing task id wrote a result outside data/"

rows=0
while IFS='|' read -r desc bad_id; do
  case "$desc" in ''|'#'*) continue ;; esac
  rows=$((rows + 1))
  out=$(run "$bad_id" 2>&1); rc=$?
  [ "$rc" -eq 2 ] || fail "$desc: expected exit 2, got $rc: $out"
done <<TABLE
an absolute path|/etc
a bare dot|.
a bare dot-dot|..
a dot-dot segment that lands back inside|t1/../t1
a nested path|sub/t1
an id carrying whitespace|t 1
TABLE
[ "$rows" -eq 6 ] || fail "the task id table ran $rows rows, not 6"
pass "a task id that is not a plain name is a usage error"

# 10c. The per-CHECK wall clock cannot be switched off through the value: every
#      spelling of zero is refused, from the flag and from the environment, and a
#      value written with leading zeros is read as the number it spells.
cat > "$GATES" <<'GATES_EOF'
- [ ] G1: slow
  CHECK: sleep 5; echo done
  EXPECT: done
  EVIDENCE: pending
GATES_EOF
rm -f "$RESULT"
rows=0
while IFS='|' read -r desc value; do
  case "$desc" in ''|'#'*) continue ;; esac
  rows=$((rows + 1))
  start=$(date +%s)
  out=$(run t1 --timeout "$value" 2>&1); rc=$?
  elapsed=$(( $(date +%s) - start ))
  [ "$rc" -eq 2 ] || fail "$desc: --timeout '$value' should exit 2, got $rc: $out"
  [ "$elapsed" -lt 4 ] || fail "$desc: --timeout '$value' ran the CHECK anyway (${elapsed}s)"
  [ ! -e "$RESULT" ] || fail "$desc: --timeout '$value' wrote a result file"
done <<TABLE
zero|0
zero written twice|00
zero written three times|000
not a number|abc
a fraction|1.5
nothing at all|
TABLE
[ "$rows" -eq 6 ] || fail "the timeout table ran $rows rows, not 6"

start=$(date +%s)
out=$(FM_GATES_TIMEOUT=00 run t1 2>&1); rc=$?
elapsed=$(( $(date +%s) - start ))
[ "$rc" -eq 2 ] || fail "FM_GATES_TIMEOUT=00 should exit 2, got $rc: $out"
[ "$elapsed" -lt 4 ] || fail "FM_GATES_TIMEOUT=00 ran the CHECK anyway (${elapsed}s)"
[ ! -e "$RESULT" ] || fail "FM_GATES_TIMEOUT=00 wrote a result file"

cat > "$GATES" <<'GATES_EOF'
- [ ] G1: README mentions hello
  CHECK: cat README.md
  EXPECT: hello
  EVIDENCE: pending
GATES_EOF
out=$(run t1 --timeout 0060 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "a padded but positive timeout should be accepted, got $rc: $out"
grep -q '^timeout: 60$' "$RESULT" || fail "the padded timeout was not read as 60: $(grep '^timeout:' "$RESULT")"
pass "every spelling of a zero timeout is refused, and leading zeros are just padding"

echo "all fm-gates-check tests passed"
