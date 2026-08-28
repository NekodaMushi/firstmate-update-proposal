#!/usr/bin/env bash
# Behavior tests for the decisive acceptance-run anchor in fm-gates-check.sh.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-gates-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-gates-check-decisive)
HOME_DIR="$TMP_ROOT/home"
REPO="$TMP_ROOT/repo"
GATES="$HOME_DIR/data/t1/gates.md"
RESULT="$HOME_DIR/data/t1/gates-result.md"
mkdir -p "$HOME_DIR/data/t1" "$HOME_DIR/state" "$REPO"
git -C "$REPO" init -q
echo hello > "$REPO/README.md"
git -C "$REPO" -c user.name=t -c user.email=t@t add -A
git -C "$REPO" -c user.name=t -c user.email=t@t commit -qm initial
OLD_HEAD=$(git -C "$REPO" rev-parse HEAD)
echo world >> "$REPO/README.md"
git -C "$REPO" -c user.name=t -c user.email=t@t add -A
git -C "$REPO" -c user.name=t -c user.email=t@t commit -qm delivered
DELIVERED_HEAD=$(git -C "$REPO" rev-parse HEAD)
printf 'worktree=%s\n' "$REPO" > "$HOME_DIR/state/t1.meta"
cat > "$GATES" <<'GATES_EOF'
- [ ] G1: README carries the delivered text
  CHECK: cat README.md
  EXPECT: world
  EVIDENCE: pending
GATES_EOF

run() { FM_HOME="$HOME_DIR" "$CHECK" "$@"; }

out=$(run t1 --for-acceptance --head "$DELIVERED_HEAD" 2> "$TMP_ROOT/pass.err"); rc=$?
expect_code 0 "$rc" "clean delivered HEAD should pass the decisive run ($out)"
assert_contains "$out" "acceptance summary: head=$DELIVERED_HEAD satisfied=1 unsatisfied=0 abandoned=0 accepted=0 abandon_unknown=0 unparseable=0 parse_errors=0 exit=0" \
  "decisive run did not print its anchored final verdict on stdout"
[ ! -s "$TMP_ROOT/pass.err" ] || fail "passing decisive run wrote to stderr: $(cat "$TMP_ROOT/pass.err")"
[ -f "$RESULT" ] || fail "passing decisive run did not write gates-result.md"
pass "fm-gates-check.sh: a clean copy at the delivered HEAD passes with an inline verdict"

echo dirty >> "$REPO/README.md"
out=$(run t1 2>&1); rc=$?
expect_code 0 "$rc" "ordinary gauge run should still allow a dirty copy ($out)"
assert_contains "$out" "summary: satisfied=1 unsatisfied=0 abandoned=0 accepted=0 abandon_unknown=0 unparseable=0 parse_errors=0" \
  "ordinary gauge run changed its summary output"
pass "fm-gates-check.sh: ordinary gauge runs still allow an in-progress dirty copy"

printf 'prior result must survive\n' > "$RESULT"
out=$(run t1 --for-acceptance --head "$DELIVERED_HEAD" 2>&1); rc=$?
expect_code 3 "$rc" "dirty copy should get the decisive-run refusal code ($out)"
assert_contains "$out" "acceptance run refused: task copy $REPO is dirty before checks: [ M README.md]" \
  "dirty-copy refusal did not name the paths that made the copy dirty"
[ "$(cat "$RESULT")" = "prior result must survive" ] \
  || fail "dirty-copy refusal replaced the prior result file"
git -C "$REPO" restore README.md
pass "fm-gates-check.sh: a dirty copy is refused before any decisive check"

out=$(run t1 --for-acceptance --head "$OLD_HEAD" 2>&1); rc=$?
expect_code 3 "$rc" "mismatched delivered HEAD should get the decisive-run refusal code ($out)"
assert_contains "$out" "acceptance run refused: task copy HEAD $DELIVERED_HEAD does not match delivered head $OLD_HEAD before checks" \
  "HEAD-mismatch refusal did not name the actual and delivered commits"
[ "$(cat "$RESULT")" = "prior result must survive" ] \
  || fail "HEAD-mismatch refusal replaced the prior result file"
pass "fm-gates-check.sh: a copy at a different HEAD than the delivered commit is refused"

out=$(run t1 --for-acceptance --head HEAD 2>&1); rc=$?
expect_code 2 "$rc" "a symbolic --head should be a usage error ($out)"
assert_contains "$out" "--head must be a commit object name taken from the delivery record" \
  "symbolic --head refusal did not say where the delivered commit comes from"
out=$(run t1 --for-acceptance --head @ 2>&1); rc=$?
expect_code 2 "$rc" "--head @ should be a usage error ($out)"
pass "fm-gates-check.sh: a revision the copy resolves for itself is refused as --head"

out=$(run no-such-task --for-acceptance --head "$DELIVERED_HEAD" 2>&1); rc=$?
expect_code 3 "$rc" "a decisive run with no gates.md should refuse ($out)"
assert_contains "$out" "acceptance run refused: task no-such-task declares no gates" \
  "no-gates decisive refusal did not name the missing contract"
out=$(run no-such-task 2>&1); rc=$?
expect_code 0 "$rc" "an ordinary run with no gates.md should stay a no-op ($out)"
assert_contains "$out" "no gates for no-such-task" "ordinary no-gates run changed its output"
pass "fm-gates-check.sh: a decisive run refuses a task that declares no gates"

mkdir -p "$HOME_DIR/data/t-scout"
cp "$GATES" "$HOME_DIR/data/t-scout/gates.md"
{ printf 'worktree=%s\n' "$REPO"; echo kind=scout; } > "$HOME_DIR/state/t-scout.meta"
out=$(run t-scout --for-acceptance --head "$DELIVERED_HEAD" 2>&1); rc=$?
expect_code 3 "$rc" "a scout should be exempt from the decisive run ($out)"
assert_contains "$out" "acceptance run refused: task t-scout is a scout" \
  "scout refusal did not say why a scout has no commit to anchor to"
out=$(run t-scout 2>&1); rc=$?
expect_code 0 "$rc" "a scout should keep the ordinary checker path ($out)"
assert_contains "$out" "summary: satisfied=1 unsatisfied=0" "scout ordinary run lost its summary"
pass "fm-gates-check.sh: a scout is refused a decisive run and keeps the ordinary one"

REPO2="$TMP_ROOT/repo2"
mkdir -p "$HOME_DIR/data/t2" "$REPO2"
git -C "$REPO2" init -q
echo hello > "$REPO2/README.md"
git -C "$REPO2" -c user.name=t -c user.email=t@t add -A
git -C "$REPO2" -c user.name=t -c user.email=t@t commit -qm delivered
DELIVERED_HEAD2=$(git -C "$REPO2" rev-parse HEAD)
printf 'worktree=%s\n' "$REPO2" > "$HOME_DIR/state/t2.meta"
cat > "$HOME_DIR/data/t2/gates.md" <<'GATES_EOF'
- [ ] G1: the check leaves an artifact behind
  CHECK: touch leftover-artifact.txt && echo ok
  EXPECT: ok
  EVIDENCE: pending
GATES_EOF
printf 'prior result must survive\n' > "$HOME_DIR/data/t2/gates-result.md"
out=$(run t2 --for-acceptance --head "$DELIVERED_HEAD2" 2>&1); rc=$?
expect_code 3 "$rc" "a check that dirties the copy should be caught after the checks ($out)"
assert_contains "$out" "acceptance run refused: task copy $REPO2 is dirty after checks: [?? leftover-artifact.txt]" \
  "post-check refusal did not name the phase and the leftover path"
[ "$(cat "$HOME_DIR/data/t2/gates-result.md")" = "prior result must survive" ] \
  || fail "post-check refusal replaced the prior result file"
pass "fm-gates-check.sh: a check that dirties the copy is refused after the checks"

echo "all fm-gates-check decisive tests passed"
