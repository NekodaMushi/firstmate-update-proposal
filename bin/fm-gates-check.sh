#!/usr/bin/env bash
# fm-gates-check.sh - run a task's acceptance gates in its isolated copy and
# decide, without a human, whether every gate is satisfied.
#
# Usage: fm-gates-check.sh <task-id> [--accept-abandon <gate-id>]... [--timeout <seconds>]
#
# Reads data/<id>/gates.md (written by firstmate at intake), resolves the task's
# isolated copy from worktree= in state/<id>.meta, executes each CHECK: inside
# that copy, compares its output to EXPECT:, and writes data/<id>/gates-result.md.
# Nothing else is written: gates.md and every file under the copy stay untouched,
# so the checker can be re-run as often as needed and a CHECK that edits the copy
# is the CHECK's problem, never the checker's.
#
# gates.md, by example (this header is the single owner of the grammar below, and
# docs/configuration.md points here):
#   - [ ] G1: <expected outcome, one sentence>
#     CHECK: <shell command run in the task's copy>
#     EXPECT: <substring the combined stdout+stderr must contain>
#     EVIDENCE: pending
#   ABANDON: G3 <reason>
#
# The grammar is deny-by-default, because a human edits this file and one slipped
# character must not decide a gate quietly. A line either matches one of the three
# shapes below, is context, or is a parse-error naming its line number; nothing is
# dropped in silence and nothing lands on a gate that did not declare it.
# A gates.md carrying any parse error decides nothing. Every error is reported, no
# CHECK is run, no gate is given a verdict, and the run exits 1. A file the checker
# cannot read whole must not be allowed to half-decide it, and a gate that merely
# looks intact beside a broken line has not been shown to be intact. Fix the file and
# run again; the cost is that the sound gates in a broken file wait for that fix.
#   gate     at column 0, "- [ ] <id>: <outcome>" or "- [x] <id>: <outcome>" ("X"
#            counts as ticked). <id> is non-empty, carries no whitespace, and is
#            declared once in the file.
#   field    indented by at least one space or tab, following its gate line with
#            nothing but blank lines and accepted sibling fields in between, one of
#            "CHECK: <value>", "EXPECT: <value>", "EVIDENCE: <value>". Each value is
#            non-empty and each key appears at most once per gate, and whitespace is
#            stripped from both ends of it, so neither a doubled space after the
#            colon nor the two spaces a Markdown hard line break leaves behind ever
#            become part of the substring a gate is matched against. EXPECT is
#            matched as text, so a CHECK that emits NUL bytes still decides its gate.
#   abandon  at column 0, "ABANDON: <id> <reason>", both parts non-empty, anywhere in
#            the file, and at most one per id: a second ABANDON naming an id an
#            earlier line already abandoned is a parse error on that second line,
#            like a gate id declared twice, so the newer reason is never dropped
#            behind the older one. An id naming no gate is reported as
#            abandon-unknown.
#   context  ignored as content, but not free-floating. A gate stays open only while
#            what follows it is blank lines and accepted field lines; every other
#            non-blank line closes it, whether that is a heading, prose, a link
#            bullet, a table row, an abandon, a rejected gate line or a rejected
#            field line. A field after such a line belongs to no gate and is
#            reported with its line number instead of being adopted by a gate that
#            never declared it. The checker cannot recognise every shape a human
#            might write, so that one rule, rather than a list of shapes, is what
#            keeps every verdict tied to the gate that earned it.
# A line is held to the gate shape when its trimmed form opens a box within its first
# four characters, meaning a "[" whose content up to the "]" is only spaces, tabs, x,
# or X. So "* [ ] G2", "-[ ] G2", "- [ x] G2" and "- [ ]G2:" are errors, while the
# Markdown link bullet "- [issue#2](url)" and ordinary prose stay context.
# A gate line the detector does not see usually orphans the field lines beneath it,
# and those are reported, which is what keeps a slipped gate from passing unnoticed.
# A gate line it does not see that carries no fields at all has nothing to orphan, so
# it is lost in silence: "> - [ ] G2: not done yet" written on its own leaves G2 out
# of the run entirely rather than unsatisfied for having no CHECK. Declare a gate with
# its fields, and the slip is caught.
# A line whose trimmed form starts with ABANDON, CHECK:, EXPECT:, or EVIDENCE: is held
# to that shape for the same reason, and so is what is left of it once any leading list
# markers ("- ", "* ", "+ ", "1. ") are stripped, again while that keeps changing the
# line. The format takes exactly one spelling of an abandon, "ABANDON: <id> <reason>"
# at column 0, so "- ABANDON: G3 dropped" and "1. ABANDON: G3 dropped" are errors
# naming their line rather than a second accepted spelling. A bulleted abandon is the
# natural thing to write under a list of bulleted gates and carries no fields of its
# own, so nothing downstream would notice it going missing.
# Those strips are a courtesy, not the boundary: no list of markers can cover every
# way a human writes one, so the last word belongs to the line that was about to be
# discarded as context. If it carries "ABANDON:" anywhere in it, it is an error naming
# its line instead, whether the marker was glued to the word ("-ABANDON: G3 dropped"),
# spelled some other way ("1) ABANDON: G3 dropped", "> ABANDON: G3 dropped"), or
# composed ("- # ABANDON: G3 dropped"). An accepted CHECK, EXPECT or EVIDENCE line is
# recognised before that test is reached, so a gate can still name the word inside its
# own value; the cost is that prose that literally writes "ABANDON:" is an error, the
# same collateral already accepted for "<!--".
# A leading "#" buys no exemption from any of this. Strip the run of hashes and the
# whitespace behind it, again while that keeps changing the line, and what is left is
# held to the same shapes, list markers stripped too: "# Gates for t1" and "## G2
# notes" are prose and stay context, while "#- [ ] G2", "## [x] done",
# "#ABANDON: G3 dropped", the doubled "# #ABANDON: G3 dropped", the composed
# "# - ABANDON: G3 dropped" and "# CHECK: cat README.md" are errors naming their line.
# gates.md has no comment syntax of its own, so a line carrying "<!--" or "-->"
# anywhere in it is an error: at the head of the line, behind a hash, indented, after
# a gate, or as either delimiter of a block comment. That is what closes the block
# form, where the delimiters are errors and the rule above then stops the run before
# anything written between them can be declared or executed.
# Commenting a line out is how a human deletes it, and a deleted ABANDON turns a gate
# the author gave up on back into one the checker runs and can pass, so no marker gets
# to hide a line the format recognises. Withdraw a gate with ABANDON and annotate it
# with prose that matches no shape. The cost is that a heading opening with one of
# those four words, "# ABANDON notes", a genuine "<!-- note to self -->", and prose
# that merely quotes "<!--" are errors too. So is a CHECK or an EXPECT that needs the
# markers in its own value: the test runs on the whole line before any shape is
# recognised, so "CHECK: grep -c -- '-->' index.html" and "EXPECT: <!-- generated -->"
# are refused with no escape, and a gate cannot assert on HTML comments in its output.
# EVIDENCE: pending is the literal the intake writes, compared ignoring case and
# surrounding whitespace, and a value whose first word is pending reads the same
# way, so "pending CI" and "pending (see #4)" refuse a hand tick exactly as the
# bare literal does; a human who says why evidence is still missing has not
# thereby supplied it. The word must end there: "pendings" is a different word
# and carries no such meaning. A gate with no EVIDENCE line at all counts as
# pending too, since a missing line backs a tick even less than a pending one.
# Any other value is treated as evidence already recorded elsewhere and does not
# change the verdict here.
# A CR at the end of a line is stripped, so a CRLF gates.md parses like any other.
#
# Verdicts, one per gate:
#   satisfied   the CHECK ran, exited, and its output contained EXPECT.
#   unsatisfied the CHECK ran and EXPECT was absent, the CHECK timed out, or the
#               gate has no CHECK or no EXPECT line (an unrunnable gate is unmet).
#               A box checked by hand ([x]) whose EVIDENCE is still pending is
#               reported unsatisfied explicitly, whatever the CHECK says: the
#               ticked box is a claim, and a pending evidence line means nobody
#               backed it, so the checker refuses to inherit it.
#   abandoned   an ABANDON: line names the gate; the CHECK is not run. The gate is
#               neither satisfied nor failed, and it keeps the exit code non-zero
#               until the caller passes --accept-abandon <id> for that exact id.
#               An ABANDON naming a gate that does not exist is reported and also
#               keeps the exit code non-zero.
#   unparseable a gates.md that exists but declares no gate line at all. Reported
#               once against the file rather than a gate: nothing could be
#               checked, and a malformed intake file must not read as a pass.
#   parse-error a line that is trying to be part of the format and does not match
#               the grammar above. Reported against gates.md:<line>, never against
#               a gate, and discarded rather than applied to the nearest gate.
#   not-checked reported once against the file when it carries any parse error, in
#               place of every gate verdict: no CHECK ran, so no gate earned one.
#
# gates-result.md layout (this header is its single owner):
#   # Gates result for <id>
#   copy: <path>
#   head: <git HEAD of the copy, or "unknown">
#   checked: <UTC ISO-8601 timestamp>
#   timeout: <seconds per CHECK>
#   ## <gate-id>: satisfied|unsatisfied|abandoned|abandon-unknown
#   ## gates.md: unparseable
#   ## gates.md: not-checked
#   ## gates.md:<line>: parse-error
#   reason: <one line: why the verdict was reached>
#   output: <the excerpt that decided the verdict, fenced, when the CHECK ran:
#            the first line containing EXPECT with 3 lines of context each side,
#            or the last 20 lines when no line matched. The fence is grown past
#            the longest backtick run in the excerpt, so a CHECK that prints
#            Markdown cannot close the block early.>
#   ## Summary
#   satisfied=<n> unsatisfied=<n> abandoned=<n> accepted=<n> abandon_unknown=<n> unparseable=<n> parse_errors=<n> exit=<code>
# The file is replaced atomically on each run at mode 0600, like the other private
# records under the operational home; the previous run is not kept.
#
# Exit codes:
#   0 every gate satisfied, and every abandoned gate accepted on this command line.
#   1 at least one gate unsatisfied, or an abandoned gate not accepted, or an
#     ABANDON naming an unknown gate, a gates.md that declares no gate at all, or
#     a line that does not match the format, in which case no CHECK ran at all.
#   2 usage error, a task id that is not a plain name, an unreadable meta or
#     copy, or no worktree= in the meta.
# A task with no data/<id>/gates.md prints "no gates for <id>" and exits 0 without
# writing gates-result.md: nothing was declared, so nothing is owed.
#
# The task id names data/<id>/ and state/<id>.meta, so it is held to a plain name:
# non-empty, letters, digits, dot, underscore and dash only, never a bare "." and
# never carrying "..". This script both executes what an id-derived file says and
# writes back into an id-derived directory, so an id that walks out of the
# operational home is a usage error rather than a path.
#
# Options:
#   --accept-abandon <id>  accept this abandoned gate's reason (repeatable).
#   --timeout <seconds>    per-CHECK wall clock; default FM_GATES_TIMEOUT or 120.
#                          A whole number of seconds greater than zero; leading
#                          zeros are stripped first, so "0", "00" and "000" are
#                          all refused rather than reaching timeout(1) as its
#                          "no timeout" spelling.
#                          Uses timeout(1) or gtimeout(1) when present, else a
#                          perl fallback that runs the CHECK in its own process
#                          group and tears that group down on ALRM, HUP, INT, or
#                          TERM; a timed-out CHECK is unsatisfied. Both paths
#                          escalate: TERM at the deadline, KILL a short grace
#                          later, so a CHECK that ignores TERM cannot outlive its
#                          own wall clock.
#
# Environment:
#   FM_HOME, FM_DATA_OVERRIDE, FM_STATE_OVERRIDE  the usual home overrides.
#   FM_GATES_TIMEOUT  default per-CHECK timeout in seconds.
#   FM_CHECK_FORCE_FALLBACK=1  skip timeout(1)/gtimeout(1) and use the perl
#                     fallback, so the fallback path is reachable in tests.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

OUTPUT_LINES=20
OUTPUT_CONTEXT=3
KILL_GRACE=2

usage() {
  sed -n '2,/^set -eu/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

die() {
  echo "error: $*" >&2
  exit 2
}

ID=
TIMEOUT=${FM_GATES_TIMEOUT:-120}
ACCEPTED=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --accept-abandon)
      [ $# -gt 1 ] || die "--accept-abandon needs a gate id"
      ACCEPTED+=("$2"); shift 2 ;;
    --accept-abandon=*) ACCEPTED+=("${1#--accept-abandon=}"); shift ;;
    --timeout)
      [ $# -gt 1 ] || die "--timeout needs a value in seconds"
      TIMEOUT=$2; shift 2 ;;
    --timeout=*) TIMEOUT=${1#--timeout=}; shift ;;
    -*) die "unknown option $1 (see --help)" ;;
    *)
      [ -z "$ID" ] || die "only one task id is accepted"
      ID=$1; shift ;;
  esac
done
[ -n "$ID" ] || die "usage: fm-gates-check.sh <task-id> [--accept-abandon <gate-id>]... [--timeout <seconds>]"
case "$ID" in
  ''|.|*..*|*[!A-Za-z0-9._-]*)
    die "task id must be a plain name of letters, digits, '.', '_' or '-', got '$ID'" ;;
esac
case "$TIMEOUT" in
  ''|*[!0-9]*) die "--timeout must be a positive integer, got '$TIMEOUT'" ;;
esac
TIMEOUT_SECONDS=${TIMEOUT#"${TIMEOUT%%[!0]*}"}
[ -n "$TIMEOUT_SECONDS" ] || die "--timeout must be a positive integer, got '$TIMEOUT'"
TIMEOUT=$TIMEOUT_SECONDS

GATES="$DATA/$ID/gates.md"
RESULT="$DATA/$ID/gates-result.md"
META="$STATE/$ID.meta"

if [ ! -f "$GATES" ]; then
  echo "no gates for $ID ($GATES absent); nothing to check"
  exit 0
fi
[ -f "$META" ] || die "no meta for task $ID at $META"
COPY=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2-)
[ -n "$COPY" ] || die "meta $META has no worktree= line; cannot locate the task's copy"
[ -d "$COPY" ] || die "task copy $COPY does not exist"

is_accepted() {
  local id=$1 a
  for a in "${ACCEPTED[@]+"${ACCEPTED[@]}"}"; do
    [ "$a" = "$id" ] && return 0
  done
  return 1
}

# A tick is unbacked while its evidence still opens with the word pending, whatever
# the case, the padding, or what the rest of the line says about why; an absent
# EVIDENCE line is weaker still, so it counts as pending too.
evidence_is_pending() {
  local v=$1
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  [ -n "$v" ] || return 0
  v=$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')
  case "$v" in
    pending|pending[![:alnum:]_]*) return 0 ;;
  esac
  return 1
}

# Run one CHECK in the copy with the per-gate timeout; echo its combined output.
# Return 124 on timeout (same as timeout(1)); any other code is the CHECK's own,
# and a CHECK killed by a signal reports 128 plus that signal on either path, so
# the result file never records a crash as a clean exit.
# timeout(1) reports 137 when it had to escalate to KILL, which is a timeout on
# the wall clock and is reported as one; a CHECK that dies of 137 before the
# deadline keeps its own code.
run_check() {
  local cmd=$1 rc=0 started
  started=$(date +%s)
  if [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v timeout >/dev/null 2>&1; then
    (cd "$COPY" && timeout -k "$KILL_GRACE" "$TIMEOUT" bash -c "$cmd" 2>&1 </dev/null) 2>/dev/null || rc=$?
  elif [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v gtimeout >/dev/null 2>&1; then
    (cd "$COPY" && gtimeout -k "$KILL_GRACE" "$TIMEOUT" bash -c "$cmd" 2>&1 </dev/null) 2>/dev/null || rc=$?
  else
    (cd "$COPY" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } my $stop = sub { $SIG{HUP} = $SIG{INT} = $SIG{TERM} = "IGNORE"; kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; waitpid $pid, 0; exit 124 }; local $SIG{ALRM} = $stop; local $SIG{HUP} = $stop; local $SIG{INT} = $stop; local $SIG{TERM} = $stop; alarm $t; waitpid $pid, 0; exit($? & 127 ? 128 + ($? & 127) : $? >> 8)' "$TIMEOUT" bash -c "$cmd" 2>&1 </dev/null) || rc=$?
  fi
  if [ "$rc" -eq 137 ] && [ "$(( $(date +%s) - started ))" -ge "$TIMEOUT" ]; then
    rc=124
  fi
  return "$rc"
}

# --- parse gates.md into parallel arrays -----------------------------------
GATE_IDS=()
GATE_BOXES=()
GATE_CHECKS=()
GATE_EXPECTS=()
GATE_EVIDENCES=()
GATE_HAS_CHECK=()
GATE_HAS_EXPECT=()
GATE_HAS_EVIDENCE=()
ABANDON_IDS=()
ABANDON_REASONS=()
PARSE_ERROR_LINES=()
PARSE_ERROR_MSGS=()
cur=-1
lineno=0

parse_error() {
  PARSE_ERROR_LINES+=("$1")
  PARSE_ERROR_MSGS+=("$2")
}

gate_index() {
  local id=$1 i
  for i in "${!GATE_IDS[@]}"; do
    [ "${GATE_IDS[$i]}" = "$id" ] && { echo "$i"; return 0; }
  done
  return 1
}

abandon_index() {
  local id=$1 i
  for i in "${!ABANDON_IDS[@]}"; do
    [ "${ABANDON_IDS[$i]}" = "$id" ] && { echo "$i"; return 0; }
  done
  return 1
}

# True when the line opens a box early enough to be a gate line trying its luck:
# a "[" within the first four characters whose content up to the "]" is only
# spaces, tabs, x, or X. A Markdown link bullet fails on that content and stays
# context, which is the whole difference between a slipped gate and prose.
opens_a_box() {
  local s=$1 rest inside
  case "${s:0:4}" in
    *\[*) ;;
    *) return 1 ;;
  esac
  rest=${s#*\[}
  case "$rest" in
    *\]*) ;;
    *) return 1 ;;
  esac
  inside=${rest%%\]*}
  case "$inside" in
    *[![:space:]xX]*) return 1 ;;
  esac
  return 0
}

# What is left of a line once its leading list markers are gone, stripped again while
# that keeps changing it, so "- ABANDON:" and "1. - ABANDON:" reach the same test.
demark() {
  local s=$1 next
  while :; do
    next=$s
    case "$s" in
      [-*+][[:space:]]*|[-*+]) next=${s#?} ;;
      [0-9]*)
        next=${s#"${s%%[!0-9]*}"}
        case "$next" in
          .[[:space:]]*|.) next=${next#?} ;;
          *) next=$s ;;
        esac ;;
    esac
    next=${next#"${next%%[![:space:]]*}"}
    [ "$next" != "$s" ] || break
    s=$next
  done
  DEMARKED=$s
}

# The four keyword shapes, named when <line> is one of them and empty when it is not.
keyword_shape() {
  case "$1" in
    ABANDON*) echo ABANDON ;;
    CHECK:*) echo CHECK ;;
    EXPECT:*) echo EXPECT ;;
    EVIDENCE:*) echo EVIDENCE ;;
  esac
}

while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))
  line=${line%$'\r'}
  trimmed=${line#"${line%%[![:space:]]*}"}
  [ -n "$trimmed" ] || continue
  case "$trimmed" in
    *'<!--'*|*'-->'*)
      parse_error "$lineno" \
        "HTML comment marker; gates.md has no comment syntax, so no marker hides a line"
      cur=-1; continue ;;
  esac

  if opens_a_box "$trimmed"; then
    if [ "$trimmed" != "$line" ]; then
      parse_error "$lineno" "gate line is indented; a gate line sits at column 0"
      cur=-1; continue
    fi
    case "$line" in
      -\ \[\ \]\ ?*|-\ \[[xX]\]\ ?*) ;;
      *)
        parse_error "$lineno" "gate line does not match '- [ ] <id>: <outcome>'"
        cur=-1; continue ;;
    esac
    box=${line:3:1}
    rest=${line#- \[?\] }
    rest=${rest#"${rest%%[![:space:]]*}"}
    case "$rest" in
      *:*) ;;
      *)
        parse_error "$lineno" "gate line has no ':' after its id"
        cur=-1; continue ;;
    esac
    gid=${rest%%:*}
    gid=${gid%"${gid##*[![:space:]]}"}
    if [ -z "$gid" ]; then
      parse_error "$lineno" "gate line names no id"
      cur=-1; continue
    fi
    case "$gid" in
      *[[:space:]]*)
        parse_error "$lineno" "gate id '$gid' carries whitespace"
        cur=-1; continue ;;
    esac
    if gate_index "$gid" >/dev/null; then
      parse_error "$lineno" "gate id '$gid' is already declared"
      cur=-1; continue
    fi
    GATE_IDS+=("$gid"); GATE_BOXES+=("$box")
    GATE_CHECKS+=(""); GATE_EXPECTS+=(""); GATE_EVIDENCES+=("")
    GATE_HAS_CHECK+=(0); GATE_HAS_EXPECT+=(0); GATE_HAS_EVIDENCE+=(0)
    cur=$(( ${#GATE_IDS[@]} - 1 ))
    continue
  fi

  case "$trimmed" in
    '#'*)
      uncommented=$trimmed
      while :; do
        stripped=${uncommented#"${uncommented%%[!#]*}"}
        stripped=${stripped#"${stripped%%[![:space:]]*}"}
        [ "$stripped" != "$uncommented" ] || break
        uncommented=$stripped
      done
      if opens_a_box "$uncommented"; then
        hidden=gate
      else
        demark "$uncommented"
        hidden=$(keyword_shape "$DEMARKED")
      fi
      [ -z "$hidden" ] || parse_error "$lineno" \
        "commented-out $hidden line; a '#' does not hide a line the format recognises"
      cur=-1; continue ;;
  esac

  demark "$trimmed"
  if [ "$DEMARKED" != "$trimmed" ]; then
    hidden=$(keyword_shape "$DEMARKED")
    if [ -n "$hidden" ]; then
      parse_error "$lineno" \
        "$hidden line behind a list marker; the format takes it at column 0 with no bullet"
      cur=-1; continue
    fi
  fi

  case "$trimmed" in
    ABANDON*)
      if [ "$trimmed" != "$line" ]; then
        parse_error "$lineno" "ABANDON line is indented; it sits at column 0"
        cur=-1; continue
      fi
      case "$line" in
        ABANDON:\ *) ;;
        *)
          parse_error "$lineno" "ABANDON line does not match 'ABANDON: <gate-id> <reason>'"
          cur=-1; continue ;;
      esac
      rest=${line#ABANDON: }
      rest=${rest#"${rest%%[![:space:]]*}"}
      aid=${rest%%[[:space:]]*}
      if [ -z "$aid" ]; then
        parse_error "$lineno" "ABANDON line names no gate id"
        cur=-1; continue
      fi
      reason=${rest#"$aid"}
      reason=${reason#"${reason%%[![:space:]]*}"}
      reason=${reason%"${reason##*[![:space:]]}"}
      if [ -z "$reason" ]; then
        parse_error "$lineno" "ABANDON of $aid gives no reason"
        cur=-1; continue
      fi
      if abandon_index "$aid" >/dev/null; then
        parse_error "$lineno" "gate '$aid' is already abandoned by an earlier ABANDON"
        cur=-1; continue
      fi
      ABANDON_IDS+=("$aid"); ABANDON_REASONS+=("$reason")
      cur=-1; continue ;;
    CHECK:*|EXPECT:*|EVIDENCE:*) ;;
    *ABANDON:*)
      parse_error "$lineno" \
        "ABANDON: sits in a line the format does not recognise; it takes 'ABANDON: <gate-id> <reason>' at column 0"
      cur=-1; continue ;;
    *) cur=-1; continue ;;
  esac

  key=${trimmed%%:*}
  if [ "$trimmed" = "$line" ]; then
    parse_error "$lineno" "$key line is not indented under a gate"
    cur=-1; continue
  fi
  case "$trimmed" in
    "$key: "?*) ;;
    *)
      parse_error "$lineno" "$key line does not match '$key: <value>'"
      cur=-1; continue ;;
  esac
  value=${trimmed#"$key": }
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  if [ -z "$value" ]; then
    parse_error "$lineno" "$key line carries no value"
    cur=-1; continue
  fi
  if [ "$cur" -lt 0 ]; then
    parse_error "$lineno" "$key line belongs to no gate"
    continue
  fi
  case "$key" in
    CHECK)
      [ "${GATE_HAS_CHECK[cur]}" -eq 0 ] || { parse_error "$lineno" "gate ${GATE_IDS[cur]} already has a CHECK"; cur=-1; continue; }
      GATE_CHECKS[cur]=$value; GATE_HAS_CHECK[cur]=1 ;;
    EXPECT)
      [ "${GATE_HAS_EXPECT[cur]}" -eq 0 ] || { parse_error "$lineno" "gate ${GATE_IDS[cur]} already has an EXPECT"; cur=-1; continue; }
      GATE_EXPECTS[cur]=$value; GATE_HAS_EXPECT[cur]=1 ;;
    EVIDENCE)
      [ "${GATE_HAS_EVIDENCE[cur]}" -eq 0 ] || { parse_error "$lineno" "gate ${GATE_IDS[cur]} already has an EVIDENCE"; cur=-1; continue; }
      GATE_EVIDENCES[cur]=$value; GATE_HAS_EVIDENCE[cur]=1 ;;
  esac
done < "$GATES"

# --- run ---------------------------------------------------------------------
HEAD=$(git -C "$COPY" rev-parse HEAD 2>/dev/null || echo unknown)
STAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
n_sat=0; n_unsat=0; n_aband=0; n_acc=0; n_unknown=0; n_unparseable=0; n_parse=0
out=
TMP=$(mktemp "$DATA/$ID/.gates-result.XXXXXX")
trap 'rm -f "$TMP" ${out:+"$out"}' EXIT

{
  echo "# Gates result for $ID"
  echo "copy: $COPY"
  echo "head: $HEAD"
  echo "checked: $STAMP"
  echo "timeout: $TIMEOUT"
  echo
} > "$TMP"

# The output that decided the verdict: the first line containing EXPECT with
# OUTPUT_CONTEXT lines each side, or the tail when no line matched, so a verbose
# CHECK still records the match rather than its opening banner.
excerpt() {  # <output-file> [expect]
  local file=$1 expect=${2-} n from to
  if [ -n "$expect" ]; then
    n=$(grep -anF -m1 -e "$expect" "$file" | cut -d: -f1) || true
    case "$n" in ''|*[!0-9]*) n= ;; esac
    if [ -n "$n" ]; then
      from=$((n - OUTPUT_CONTEXT))
      [ "$from" -ge 1 ] || from=1
      to=$((n + OUTPUT_CONTEXT))
      sed -n "${from},${to}p" "$file" | tr -d '\0'
      return 0
    fi
  fi
  tail -n "$OUTPUT_LINES" "$file" | tr -d '\0'
}

# A fence longer than the longest backtick run the excerpt opens a line with,
# so a CHECK that prints Markdown cannot close the block early.
fence_for() {
  local longest len
  longest=$(printf '%s\n' "$1" | sed -n 's/^ \{0,3\}\(`\{3,\}\).*/\1/p' |
    awk '{ if (length($0) > n) n = length($0) } END { print n + 0 }')
  len=3
  [ "$longest" -lt 3 ] || len=$((longest + 1))
  printf '%*s' "$len" '' | tr ' ' '`'
}

emit() {  # <id> <verdict> <reason> [output-file] [expect]
  local body fence
  {
    echo "## $1: $2"
    echo "reason: $3"
    if [ $# -ge 4 ] && [ -s "$4" ]; then
      body=$(excerpt "$4" "${5-}")
      if [ -n "$body" ]; then
        fence=$(fence_for "$body")
        echo "output:"
        echo "$fence"
        printf '%s\n' "$body"
        echo "$fence"
      fi
    fi
    echo
  } >> "$TMP"
  echo "$1: $2 - $3"
}

for i in "${!PARSE_ERROR_LINES[@]}"; do
  n_parse=$((n_parse + 1))
  emit "gates.md:${PARSE_ERROR_LINES[$i]}" parse-error "${PARSE_ERROR_MSGS[$i]}"
done

if [ "$n_parse" -gt 0 ]; then
  emit gates.md not-checked \
    "$GATES carries $n_parse parse error(s), so no CHECK was run and no gate was given a verdict; fix the file and run again"
elif [ "${#GATE_IDS[@]}" -eq 0 ]; then
  n_unparseable=1
  emit gates.md unparseable \
    "$GATES exists but declares no gate line; a file that checks nothing is not a clean pass"
fi

for i in "${!GATE_IDS[@]}"; do
  [ "$n_parse" -eq 0 ] || break
  gid=${GATE_IDS[$i]}
  box=${GATE_BOXES[$i]}
  check=${GATE_CHECKS[$i]}
  expect=${GATE_EXPECTS[$i]}
  evidence=${GATE_EVIDENCES[$i]}

  if ai=$(abandon_index "$gid"); then
    n_aband=$((n_aband + 1))
    if is_accepted "$gid"; then
      n_acc=$((n_acc + 1))
      emit "$gid" abandoned "accepted via --accept-abandon; reason given: ${ABANDON_REASONS[$ai]:-(none)}"
    else
      emit "$gid" abandoned "not accepted; reason given: ${ABANDON_REASONS[$ai]:-(none)}; pass --accept-abandon $gid to accept"
    fi
    continue
  fi
  if [ "${GATE_HAS_CHECK[$i]}" -eq 0 ]; then
    n_unsat=$((n_unsat + 1)); emit "$gid" unsatisfied "no CHECK line; an unrunnable gate is unmet"; continue
  fi
  if [ "${GATE_HAS_EXPECT[$i]}" -eq 0 ]; then
    n_unsat=$((n_unsat + 1)); emit "$gid" unsatisfied "no EXPECT line; nothing to compare the output against"; continue
  fi

  out=$(mktemp "$DATA/$ID/.gates-out.XXXXXX")
  rc=0
  run_check "$check" > "$out" || rc=$?
  if [ "$rc" -eq 124 ]; then
    n_unsat=$((n_unsat + 1))
    emit "$gid" unsatisfied "CHECK timed out after ${TIMEOUT}s" "$out"
    rm -f "$out"; out=; continue
  fi
  if grep -qaF -e "$expect" "$out"; then
    if [ "$box" != " " ] && evidence_is_pending "$evidence"; then
      n_unsat=$((n_unsat + 1))
      emit "$gid" unsatisfied "box ticked by hand while EVIDENCE is still pending; the tick is an unbacked claim (CHECK output did contain EXPECT, exit $rc)" "$out" "$expect"
    else
      n_sat=$((n_sat + 1))
      emit "$gid" satisfied "output contained EXPECT '$expect' (exit $rc)" "$out" "$expect"
    fi
  else
    if [ "$box" != " " ] && evidence_is_pending "$evidence"; then
      n_unsat=$((n_unsat + 1))
      emit "$gid" unsatisfied "box ticked by hand while EVIDENCE is still pending, and output lacked EXPECT '$expect' (exit $rc)" "$out"
    else
      n_unsat=$((n_unsat + 1))
      emit "$gid" unsatisfied "output lacked EXPECT '$expect' (exit $rc)" "$out"
    fi
  fi
  rm -f "$out"; out=
done

for i in "${!ABANDON_IDS[@]}"; do
  [ "$n_parse" -eq 0 ] || break
  aid=${ABANDON_IDS[$i]}
  found=0
  for g in "${GATE_IDS[@]+"${GATE_IDS[@]}"}"; do
    [ "$g" = "$aid" ] && { found=1; break; }
  done
  [ "$found" -eq 1 ] && continue
  n_unknown=$((n_unknown + 1))
  emit "$aid" abandon-unknown "ABANDON names a gate that does not exist in $GATES"
done

SUMMARY="satisfied=$n_sat unsatisfied=$n_unsat abandoned=$n_aband accepted=$n_acc"
SUMMARY="$SUMMARY abandon_unknown=$n_unknown unparseable=$n_unparseable parse_errors=$n_parse"
exit_code=0
if [ "$n_unsat" -gt 0 ] || [ "$n_unknown" -gt 0 ] || [ "$n_unparseable" -gt 0 ] ||
  [ "$n_parse" -gt 0 ] || [ "$n_aband" -ne "$n_acc" ]; then
  exit_code=1
fi
{
  echo "## Summary"
  echo "$SUMMARY exit=$exit_code"
} >> "$TMP"
chmod 600 "$TMP"
mv -f "$TMP" "$RESULT"
trap - EXIT
echo "summary: $SUMMARY -> $RESULT"
exit "$exit_code"
