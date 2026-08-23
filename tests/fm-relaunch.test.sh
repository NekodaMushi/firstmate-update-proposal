#!/usr/bin/env bash
# fm-relaunch.sh behavior tests with a stateful fake tmux endpoint.
# No real agent is spawned: the fake models an agent process, its exit to a bare
# shell, and the replacement launch while real git fixtures prove that commits
# and uncommitted files remain untouched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RELAUNCH="$ROOT/bin/fm-relaunch.sh"
TMP_ROOT=$(fm_test_tmproot fm-relaunch-tests)
mkdir -p "$TMP_ROOT"

make_fakebin() {  # <case-dir>
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit)
          if [ "${FM_FAKE_NEVER_BARE:-0}" != 1 ]; then
            printf 'zsh' > "$D/command"
            rm -f "$D/shell-captured"
          fi
          ;;
        *'encode launch-brief'*) printf 'claude' > "$D/command" ;;
      esac
    fi
    exit 0
    ;;
  display-message)
    for arg in "$@"; do
      case "$arg" in
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
        *pane_tty*) printf '\n'; exit 0 ;;
        *cursor_y*) printf '1\n'; exit 0 ;;
      esac
    done
    printf 'fake-pane\n'
    exit 0
    ;;
  capture-pane)
    if [ "$(cat "$D/command")" = zsh ]; then
      if [ ! -e "$D/shell-captured" ]; then
        : > "$D/shell-captured"
        printf '╭────╮\n│    │\n╰────╯\n'
      else
        printf '$ \n'
      fi
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0
    ;;
  list-windows) cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"

  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${FM_FAKE_RUN_ACTIVE:-0}" = 1 ] && [ "${1:-}" = axi ] && [ "${2:-}" = status ]; then
  branch=$(git symbolic-ref --quiet --short HEAD)
  head=$(git rev-parse HEAD)
  cat <<EOF
run:
  id: "RUN1"
  branch: $branch
  status: running
  head: "$head"
  pr: ""
steps[2]{step,status,findings,duration_ms}:
  review,completed,0,1
  test,running,0,1
EOF
fi
exit 0
SH
  chmod +x "$fb/no-mistakes"

  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
}

new_case() {  # <name> <id>
  local name=$1 id=$2 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state" "$dir/home/data/$id" "$dir/fake"
  fm_git_worktree "$dir/project" "$dir/worktree" "task-$id"
  printf 'first\n' > "$dir/worktree/first.txt"
  git -C "$dir/worktree" add first.txt
  git -C "$dir/worktree" -c user.name=Test -c user.email=test@example.invalid commit -qm first
  printf 'second\n' > "$dir/worktree/second.txt"
  git -C "$dir/worktree" add second.txt
  git -C "$dir/worktree" -c user.name=Test -c user.email=test@example.invalid commit -qm second
  printf 'uncommitted\n' > "$dir/worktree/scratch.txt"
  printf '# Original instructions\n\nContinue the task.\n' > "$dir/home/data/$id/brief.md"
  printf '# Relaunch note\n\nBranch and validation state are recorded here.\n' > "$dir/home/data/$id/relaunch-note.md"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$dir/worktree"
    echo "project=$dir/project"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=sonnet"
    echo "effort=high"
  } > "$dir/home/state/$id.meta"
  printf 'claude' > "$dir/fake/command"
  printf '%s' "$dir/worktree" > "$dir/fake/cwd"
  printf 'fm-%s\n' "$id" > "$dir/fake/windows"
  : > "$dir/fake/literal"
  make_fakebin "$dir"
  printf '%s\n' "$dir"
}

run_relaunch() {  # <case-dir> <id>
  local dir=$1 id=$2
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.03 \
    FM_CONTROL_LAUNCH_WAIT=0.03 FM_SEND_SETTLE=0 \
    FM_FAKE_NEVER_BARE="${FM_FAKE_NEVER_BARE:-0}" \
    FM_FAKE_RUN_ACTIVE="${FM_FAKE_RUN_ACTIVE:-0}" \
    "$RELAUNCH" "$id" 2>&1
}

test_successful_relaunch_preserves_the_same_worktree() {
  local dir out rc before after note
  dir=$(new_case success rr1)
  before=$(git -C "$dir/worktree" rev-parse HEAD)
  out=$(run_relaunch "$dir" rr1); rc=$?
  expect_code 0 "$rc" "successful relaunch should exit zero"$'\n'"$out"
  after=$(git -C "$dir/worktree" rev-parse HEAD)
  [ "$before" = "$after" ] || fail "relaunch changed the worktree HEAD"
  [ -f "$dir/worktree/scratch.txt" ] || fail "relaunch lost the uncommitted file"
  [ "$(git -C "$dir/worktree" rev-list --count HEAD)" -eq 3 ] \
    || fail "the initial commit plus both task commits must survive"
  assert_grep '/exit' "$dir/fake/literal" "the recorded adapter exit command was not sent"
  assert_grep 'encode launch-brief' "$dir/fake/literal" "fm-spawn's launch template was not used"
  note="$dir/home/data/rr1/relaunch-note.md"
  assert_grep "$note" "$dir/home/data/rr1/brief.md" "replacement instructions do not reference the relaunch note"
  [ "$(grep '^model=' "$dir/home/state/rr1.meta")" = model=sonnet ] \
    || fail "the recorded model changed"
  [ "$(grep '^effort=' "$dir/home/state/rr1.meta")" = effort=high ] \
    || fail "the recorded effort changed"
  pass "fm-relaunch: successful replacement preserves commits, dirty files, profile, endpoint, and worktree"
}

test_refuses_when_the_pane_never_becomes_a_bare_shell() {
  local dir out rc
  dir=$(new_case never-bare rr2)
  out=$(FM_FAKE_NEVER_BARE=1 run_relaunch "$dir" rr2); rc=$?
  expect_code 1 "$rc" "a pane that never becomes a bare shell must refuse"
  assert_contains "$out" "did not stop" "the refusal should explain that the old agent never exited"
  assert_no_grep 'encode launch-brief' "$dir/fake/literal" "a replacement must not launch before bare-shell proof"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "the never-bare fixture should retain the old agent"
  pass "fm-relaunch: refuses without launching when the pane never becomes a bare shell"
}

test_refuses_while_a_no_mistakes_run_owns_the_branch() {
  local dir out rc
  dir=$(new_case run-owner rr3)
  out=$(FM_FAKE_RUN_ACTIVE=1 run_relaunch "$dir" rr3); rc=$?
  expect_code 1 "$rc" "an active run-step must refuse relaunch"
  assert_contains "$out" "active no-mistakes run-step" "the refusal should name pipeline ownership"
  [ ! -s "$dir/fake/literal" ] || fail "run ownership refusal must send no lifecycle input"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "run ownership refusal must leave the old agent running"
  pass "fm-relaunch: refuses while an active no-mistakes response may own the branch"
}

test_successful_relaunch_preserves_the_same_worktree
test_refuses_when_the_pane_never_becomes_a_bare_shell
test_refuses_while_a_no_mistakes_run_owns_the_branch
