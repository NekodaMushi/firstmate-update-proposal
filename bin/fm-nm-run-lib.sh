#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the branch+code-identity matching rule that decides whether a
# no-mistakes run belongs to a given worktree, used by fm-crew-state.sh
# (read-only current-state reporting) and fm-teardown.sh (pre-teardown run
# abort, see its "Fix 1" header comment). Getting this wrong in either
# direction is unsafe: a false negative hides a genuinely parked run, and a
# false positive lets teardown act on a run it does not own.
#
# Bounded call to `no-mistakes "$@"` in dir $1, timeout $2 seconds. The bounded
# form preserves stdout, stderr, and exit status; the checked form discards
# stderr, while fm_nm_run keeps the fail-open query contract for read-only callers.
fm_nm_run_bounded() {  # <dir> <timeout_secs> <args...>
  local dir=$1 timeout_secs=$2 have_timeout=none
  shift 2
  if command -v timeout >/dev/null 2>&1; then have_timeout=timeout
  elif command -v gtimeout >/dev/null 2>&1; then have_timeout=gtimeout
  elif command -v perl >/dev/null 2>&1; then have_timeout=perl
  fi
  case "$have_timeout" in
    timeout)  ( cd "$dir" && timeout "$timeout_secs" no-mistakes "$@" ) ;;
    gtimeout) ( cd "$dir" && gtimeout "$timeout_secs" no-mistakes "$@" ) ;;
    perl)     ( cd "$dir" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$timeout_secs" no-mistakes "$@" ) ;;
    *)        return 1 ;;
  esac
}

fm_nm_run_checked() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_bounded "$@" 2>/dev/null
}

fm_nm_run() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_checked "$@" || true
}

fm_nm_trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

fm_nm_strip_quotes() {
  local s
  s=$(fm_nm_trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  fm_nm_trim "$s"
}

# Scalar value of a TOON key in captured `axi status` output $1.
fm_nm_field() {  # <toon-output> <key>
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\(.*\)/\1/p" | head -1
}

# 0 if run head $2 matches worktree $1's code identity, per the same rule
# everywhere this attribution is needed:
#   - missing/empty head: cannot bind; reject
#   - equal commits (short or full SHA): match
#   - worktree HEAD is an ancestor of run head: match (pipeline fix commits on
#     the same history advanced the run tip past local HEAD)
#   - run head is a strict ancestor of worktree HEAD, or diverged: no match
#     (local work advanced outside the run, or the branch tip was rewritten)
fm_nm_head_matches_worktree() {  # <worktree> <run_head>
  local wt=$1 run_head=$2 local_full run_full
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(git -C "$wt" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) || return 1
  [ "$run_full" = "$local_full" ] && return 0
  git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null
}

# The ONE terminal-outcome vocabulary for a no-mistakes run: the four `outcome:`
# values that mean the run is over and owns nothing any more. Every caller that
# needs "has this run finished" reaches this, so a run that ended with a green PR
# awaiting review (checks-passed) is never mistaken for one still holding a gate.
fm_nm_outcome_is_terminal() {  # <outcome>
  case "$1" in
    cancelled|failed|passed|checks-passed) return 0 ;;
  esac
  return 1
}

# Coarse cross-branch attribution over the top-level `no-mistakes runs` listing,
# used when a bare `axi status` answered for some OTHER branch. The listing is
# plain human-oriented text, newest first, with columns
# "<status> <branch> <short-sha> <date> [<pr-url>]" separated by runs of spaces
# (verified: no quoting, so splitting on the first two whitespace runs is exact).
# Echoes the first matching row's status word (running/completed/cancelled/
# failed), or empty when <branch> has no row within <limit> whose code identity
# also matches <worktree> under fm_nm_head_matches_worktree.
fm_nm_runs_status_for_branch() {  # <worktree> <timeout_secs> <branch> <limit>
  local wt=$1 timeout_secs=$2 branch=$3 limit=$4 out row st rest br sha
  out=$(fm_nm_run "$wt" "$timeout_secs" runs --limit "$limit")
  [ -n "$out" ] || return 0
  while IFS= read -r row; do
    row=$(fm_nm_trim "$row")
    [ -n "$row" ] || continue
    st=${row%% *}
    rest=${row#* }
    rest=$(fm_nm_trim "$rest")
    br=${rest%% *}
    rest=${rest#* }
    rest=$(fm_nm_trim "$rest")
    sha=${rest%% *}
    if [ "$br" = "$branch" ]; then
      # Same code-identity rule as axi status: skip a same-branch row whose
      # short-sha does not match this worktree (rewritten or advanced tip).
      fm_nm_head_matches_worktree "$wt" "$sha" || continue
      printf '%s' "$st"
      return 0
    fi
  done <<< "$out"
  return 0
}

# fm_nm_run_active_for_worktree: 0 when a no-mistakes run attributed to
# <worktree> exists and has NOT reached a terminal outcome - the state in which
# that run may still owe, or be owed, a synchronous gate response, so nothing may
# replace the agent that owns it. Prints a short reason token either way.
#
# The verdict is taken from the RUN, never from any presentation of it: a
# reporting layer may legitimately summarise a live run as `done` for a human
# (bin/fm-crew-state.sh does exactly that once the worker posts "PR open, checks
# green" while the run keeps monitoring), and a caller that keys on such a
# summary would act on a run that is still going.
#
# Attribution walks the same ladder as bin/fm-crew-state.sh: the bare `axi
# status` answer when it is this branch's own run, else the coarse runs listing.
# An unanswerable CLI is fail-open (`unanswered`), matching bin/fm-teardown.sh's
# accepted best-effort residual: making a healthy no-mistakes CLI a prerequisite
# would block recovery precisely when the toolchain is the thing that is wedged.
fm_nm_run_active_for_worktree() {  # <worktree> <timeout_secs> <runs-limit>
  local wt=$1 timeout_secs=$2 limit=$3 branch out run_branch outcome status coarse
  command -v no-mistakes >/dev/null 2>&1 || { printf 'no-cli'; return 1; }
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null) || branch=
  [ -n "$branch" ] || { printf 'detached-head'; return 1; }
  out=$(fm_nm_run "$wt" "$timeout_secs" axi status)
  [ -n "$out" ] || { printf 'unanswered'; return 1; }
  run_branch=$(fm_nm_strip_quotes "$(fm_nm_field "$out" branch)")
  if [ -n "$run_branch" ] && [ "$run_branch" = "$branch" ] \
     && fm_nm_head_matches_worktree "$wt" "$(fm_nm_strip_quotes "$(fm_nm_field "$out" head)")"; then
    outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$out" outcome)")
    if [ -n "$outcome" ] && fm_nm_outcome_is_terminal "$outcome"; then
      printf 'terminal:%s' "$outcome"
      return 1
    fi
    status=$(fm_nm_strip_quotes "$(fm_nm_field "$out" status)")
    printf 'active:%s' "${status:-unknown}"
    return 0
  fi
  coarse=$(fm_nm_runs_status_for_branch "$wt" "$timeout_secs" "$branch" "$limit")
  case "$coarse" in
    running) printf 'active:running'; return 0 ;;
    '') printf 'no-run'; return 1 ;;
    *) printf 'ended:%s' "$coarse"; return 1 ;;
  esac
}
