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
# That path waits a bounded time for a positively agent-free endpoint with a
# visible shell prompt before it uses fm-spawn's exact recorded-adapter launch
# template in the existing worktree.
#
# Only a ship or scout is relaunched here, because only their instructions are
# rewritten to carry the note pointer.
# A secondmate keeps a standing charter that a relaunch never rewrites, so it is
# refused by name and recovered through the secondmate-provisioning skill.
#
# A relaunch is refused while fm-crew-state attributes any non-terminal
# no-mistakes run-step to the task - working, parked at a gate, or still
# monitoring green checks - because the outgoing agent may be in the synchronous
# response flow and replacing it would duplicate pipeline ownership.
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

# fm-crew-state emits `state: <state> · source: <source>[ · <detail>]`. Any
# run-step verdict means a no-mistakes run is attributed to this task, and the
# outgoing agent may owe it a synchronous answer. Only a detail that names a
# genuinely finished run clears the refusal: `working` is mid-step, `parked` is
# sitting at a gate waiting for exactly the response this agent owes, `checks
# green` is still monitoring the PR, and `unknown` proves nothing. Deciding on
# the terminal DETAIL rather than on one state token keeps a still-active run
# from slipping through on a state name that also has terminal instances.
CREW_STATE=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-crew-state.sh" "$ID")
CREW_SOURCE=${CREW_STATE#*· source: }
CREW_SOURCE=${CREW_SOURCE%%·*}
CREW_SOURCE=${CREW_SOURCE%"${CREW_SOURCE##*[![:space:]]}"}
if [ "$CREW_SOURCE" = run-step ]; then
  CREW_DETAIL=
  case "$CREW_STATE" in
    *"· source: run-step · "*)
      CREW_DETAIL=${CREW_STATE#*· source: run-step · }
      CREW_DETAIL=${CREW_DETAIL%%·*}
      CREW_DETAIL=${CREW_DETAIL%"${CREW_DETAIL##*[![:space:]]}"}
      ;;
  esac
  case "$CREW_DETAIL" in
    'run passed: PR merged/closed'|'run completed'|'run failed'|'run cancelled') ;;
    *)
      echo "error: task $ID has an active no-mistakes run-step ($CREW_STATE); relaunch is refused while a gate response may own the branch. Let the response reach a terminal outcome, or abort and recover custody as documented in this script header." >&2
      exit 1
      ;;
  esac
fi

NOTE_DIR=$(cd "$(dirname "$NOTE")" && pwd -P)
NOTE_REAL="$NOTE_DIR/$(basename "$NOTE")"
RECOVERY_POINTER="Before doing anything else, read $NOTE_REAL and follow it. Treat every commit and uncommitted file already present in the recorded worktree as unverified until you have reconciled that note."

# fm-control prints the authoritative `relaunched <id> harness=... model=...
# effort=... worktree=...` line for the profile it ACTUALLY launched; this
# wrapper never restates a profile it read before the relaunch.
exec env FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-control.sh" "$ID" relaunch --note "$RECOVERY_POINTER"
