#!/usr/bin/env bash
# Replace one task's agent with a fresh agent in the same recorded endpoint and
# worktree while preserving every commit and uncommitted file.
# Usage: fm-relaunch.sh <task-id>
#
# Firstmate must write a non-empty data/<task-id>/relaunch-note.md before
# invoking this command.
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
# That path waits a bounded time for the endpoint to prove, from process state
# read through the recorded backend, that no agent remains and the pane is back
# at its own shell with no child of its own, before it uses fm-spawn's exact
# recorded-adapter launch template in the existing worktree.
# The proof never reads the rendered prompt: what a ready shell looks like is
# whatever the operator's PS1 draws.
#
# Only a ship or scout is relaunched here, because only their instructions are
# rewritten to carry the note pointer.
# A secondmate keeps a standing charter that a relaunch never rewrites, so it is
# refused by name and recovered through the secondmate-provisioning skill.
#
# A relaunch is refused while a no-mistakes run attributed to the recorded
# worktree has not reached a terminal outcome - mid-step, parked at a gate, or
# still monitoring green checks - because the outgoing agent may be in the
# synchronous response flow and replacing it would duplicate pipeline ownership.
# fm-crew-state's verdict is reported with that refusal for context.
# Let that response reach a terminal outcome first.
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

FM_RELAUNCH_NM_TIMEOUT=${FM_RELAUNCH_NM_TIMEOUT:-10}
case "$FM_RELAUNCH_NM_TIMEOUT" in ''|*[!0-9]*) FM_RELAUNCH_NM_TIMEOUT=10 ;; esac
FM_RELAUNCH_RUNS_LIMIT=${FM_RELAUNCH_RUNS_LIMIT:-200}
case "$FM_RELAUNCH_RUNS_LIMIT" in ''|*[!0-9]*) FM_RELAUNCH_RUNS_LIMIT=200 ;; esac

# shellcheck source=bin/fm-backend.sh disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-control-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

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
[ -f "$NOTE" ] && [ ! -L "$NOTE" ] && [ -s "$NOTE" ] || {
  echo "error: write the relaunch note at $NOTE before replacing task $ID's agent; an empty note tells the replacement nothing" >&2
  exit 1
}

fm_backend_validate_task_endpoint "$META" "$ID" || exit 1
HARNESS=$(fm_meta_get "$META" harness)
EFFORT=$(fm_meta_get "$META" effort)
KIND=$(fm_meta_get "$META" kind)
BACKEND=$FM_BACKEND_VALIDATED_BACKEND
WORKTREE=$(fm_meta_get "$META" worktree)

# A secondmate's instruction source is the standing charter in its OWN home,
# which a relaunch deliberately never rewrites, so the note pointer this command
# exists to deliver has no channel the replacement reads. Refuse by name rather
# than stopping an agent and silently skipping the required handover.
case "$KIND" in
  secondmate)
    echo "error: task $ID is a secondmate, whose standing charter is never rewritten, so a relaunch note pointer cannot reach its replacement; recover it through the secondmate-provisioning skill and bin/fm-control.sh $ID relaunch instead" >&2
    exit 1
    ;;
  ship|scout) ;;
  '')
    echo "error: task $ID records no kind, so fm-relaunch cannot prove the replacement reads the relaunch note" >&2
    exit 1
    ;;
  *)
    echo "error: task $ID records kind '$KIND', which has no verified same-copy relaunch shape" >&2
    exit 1
    ;;
esac

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

# Only a ship drives a no-mistakes validation of its own worktree (the same rule
# bin/fm-crew-state.sh and bin/fm-teardown.sh apply), and only a run that has not
# reached a terminal outcome can still owe or be owed a synchronous gate
# response. The verdict comes from the run itself through the shared attribution
# owner, never from a reporting layer's summary of it: fm-crew-state
# legitimately presents a live run as `done` to a human once the worker has
# posted "PR open, checks green", so a refusal keyed on that presentation would
# stop an agent whose run is still going.
if [ "$KIND" = ship ]; then
  RUN_ACTIVITY=$(fm_nm_run_active_for_worktree \
    "$WORKTREE" "$FM_RELAUNCH_NM_TIMEOUT" "$FM_RELAUNCH_RUNS_LIMIT") && {
    CREW_STATE=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-crew-state.sh" "$ID" 2>/dev/null || true)
    echo "error: task $ID has a no-mistakes run that has not reached a terminal outcome ($RUN_ACTIVITY); relaunch is refused while a gate response may own the branch. Let the run reach a terminal outcome, or abort and recover custody as documented in this script header. Crew state: ${CREW_STATE:-unavailable}" >&2
    exit 1
  }
fi

NOTE_DIR=$(cd "$(dirname "$NOTE")" && pwd -P)
NOTE_REAL="$NOTE_DIR/$(basename "$NOTE")"
RECOVERY_POINTER="Before doing anything else, read $NOTE_REAL and follow it. Treat every commit and uncommitted file already present in the recorded worktree as unverified until you have reconciled that note."

# fm-control prints the authoritative `relaunched <id> harness=... model=...
# effort=... worktree=...` line for the profile it ACTUALLY launched; this
# wrapper never restates a profile it read before the relaunch.
exec env FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-control.sh" "$ID" relaunch --note "$RECOVERY_POINTER"
