#!/usr/bin/env bash
# Replace one task's agent with a fresh agent in the same recorded endpoint and
# worktree while preserving every commit and uncommitted file.
# Usage: fm-relaunch.sh <task-id>
#
# Firstmate must write data/<task-id>/relaunch-note.md before invoking this
# command.
# The note must account for the branch, unpushed commits, PR if any, active
# no-mistakes run and step, and decisions already made for pending gates.
# The replacement receives the original instructions plus an absolute pointer
# requiring it to read that note and treat all existing work as unverified.
# This script never authors the note and never runs stash, reset, checkout, or
# any other command that changes worktree files.
#
# The recorded harness, model, effort, backend, endpoint, and worktree come only
# from state/<task-id>.meta.
# The transactional stop and same-worktree launch are delegated to
# bin/fm-control.sh, whose exit path sends the recorded adapter's command through
# bin/fm-send.sh and whose launch path calls bin/fm-spawn.sh --relaunch.
# That path waits a bounded time for a positively agent-free endpoint with a
# visible shell prompt before it uses fm-spawn's exact recorded-adapter launch
# template in the existing worktree.
#
# A relaunch is refused while fm-crew-state reports an active no-mistakes
# run-step, because the outgoing agent may be in the synchronous response flow
# and replacing it would duplicate pipeline ownership.
# Let that response reach its next stable gate or terminal outcome first.
# If the outgoing agent cannot finish the response, abort the run with the
# supported no-mistakes command, confirm it stopped, follow branch_sync.next_action
# (including recover_custody only when requested), then refresh the relaunch note
# and invoke this command again.
#
# FM_HOME must name the active firstmate home explicitly.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

[ "$#" -eq 1 ] || { usage >&2; exit 2; }

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-relaunch refuses to resolve a task without an explicit firstmate home" >&2
  exit 1
fi
[ -d "$FM_HOME" ] || {
  echo "error: FM_HOME '$FM_HOME' is not a directory" >&2
  exit 1
}

STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
ID=$1

# shellcheck source=bin/fm-backend.sh disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-control-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"

fm_task_id_creation_valid "$ID" || {
  echo "error: invalid task id '$ID'" >&2
  exit 2
}

META="$STATE/$ID.meta"
NOTE="$DATA/$ID/relaunch-note.md"
[ -f "$META" ] && [ ! -L "$META" ] || {
  echo "error: task $ID has no regular metadata at $META" >&2
  exit 1
}
[ -f "$NOTE" ] && [ ! -L "$NOTE" ] || {
  echo "error: write the relaunch note at $NOTE before replacing task $ID's agent" >&2
  exit 1
}

fm_backend_validate_task_endpoint "$META" "$ID" || exit 1
HARNESS=$(fm_meta_get "$META" harness)
MODEL=$(fm_meta_get "$META" model)
EFFORT=$(fm_meta_get "$META" effort)
BACKEND=$FM_BACKEND_VALIDATED_BACKEND
WORKTREE=$(fm_meta_get "$META" worktree)

[ -n "$HARNESS" ] || {
  echo "error: task $ID has no recorded harness" >&2
  exit 1
}
[ -n "$WORKTREE" ] && [ -d "$WORKTREE" ] || {
  echo "error: task $ID's recorded worktree '${WORKTREE:-none}' is missing" >&2
  exit 1
}
case "$EFFORT" in
  ''|default|low|medium|high|xhigh|max) ;;
  *) echo "error: task $ID records invalid effort '$EFFORT'" >&2; exit 1 ;;
esac
fm_control_harness_family "$HARNESS" >/dev/null || {
  echo "error: task $ID records harness '$HARNESS', which has no verified relaunch mechanics" >&2
  exit 1
}
fm_control_backend_state_verified "$BACKEND" || {
  echo "error: task $ID uses backend '$BACKEND', which cannot prove the old agent exited" >&2
  exit 1
}

CREW_STATE=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-crew-state.sh" "$ID")
case "$CREW_STATE" in
  'state: working · source: run-step'*)
    echo "error: task $ID has an active no-mistakes run-step; relaunch is refused while a gate response may own the branch. Let the response reach a stable gate or outcome, or abort and recover custody as documented in this script header." >&2
    exit 1
    ;;
esac

NOTE_DIR=$(cd "$(dirname "$NOTE")" && pwd -P)
NOTE_REAL="$NOTE_DIR/$(basename "$NOTE")"
RECOVERY_POINTER="Before doing anything else, read $NOTE_REAL and follow it. Treat every commit and uncommitted file already present in the recorded worktree as unverified until you have reconciled that note."

FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-control.sh" "$ID" relaunch --note "$RECOVERY_POINTER"

echo "fm-relaunch: replaced $ID in the same worktree=$WORKTREE harness=$HARNESS model=${MODEL:-default} effort=${EFFORT:-default} backend=$BACKEND note=$NOTE_REAL"
