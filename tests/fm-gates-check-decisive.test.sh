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
assert_contains "$out" "acceptance run refused: task copy $REPO is dirty before checks" \
  "dirty-copy refusal did not give one clear reason"
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

echo "all fm-gates-check decisive tests passed"
