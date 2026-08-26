# fm-brief.sh --gates: generated scaffolds, end to end

Every block is a real run of `bin/fm-brief.sh` at target commit abe95ef against a
throwaway FM_HOME. Absolute paths are rewritten to `<FM_HOME_ROOT>` and `<FM_ROOT>`.

## 1. Without --gates the scaffold is byte-identical to the pre-feature executable

The pre-feature `bin/fm-brief.sh` (base commit de3ea32) and the shipped one were run
in turn against the same FM_HOME with the same arguments, then compared with `cmp`.
Ship and scout, the two heredocs the option interpolates into:

```
$ FM_HOME=<FM_HOME_ROOT> bin/fm-brief.sh demo-task demo-repo --mode no-mistakes   # pre-feature de3ea32
scaffolded: <FM_HOME_ROOT>/home2/data/demo-task/brief.md (ship, mode=no-mistakes; replace {TASK})
$ FM_HOME=<FM_HOME_ROOT> bin/fm-brief.sh demo-task demo-repo --mode no-mistakes   # target abe95ef
scaffolded: <FM_HOME_ROOT>/home2/data/demo-task/brief.md (ship, mode=no-mistakes; replace {TASK})
$ cmp pre-feature/demo-task/brief.md target/demo-task/brief.md
(no output: identical, 6476 bytes, sha256 58d1e67725fad96ec62e6bd0e79642592c39837163cf26dbb405ef5f9b401634)
$ grep -c '^# Acceptance gates' target/demo-task/brief.md
0

$ FM_HOME=<FM_HOME_ROOT> bin/fm-brief.sh demo-scout demo-repo --scout   # pre-feature de3ea32
scaffolded: <FM_HOME_ROOT>/home2/data/demo-scout/brief.md (scout; replace {TASK})
$ FM_HOME=<FM_HOME_ROOT> bin/fm-brief.sh demo-scout demo-repo --scout   # target abe95ef
scaffolded: <FM_HOME_ROOT>/home2/data/demo-scout/brief.md (scout; replace {TASK})
$ cmp pre-feature/demo-scout/brief.md target/demo-scout/brief.md
(no output: identical, 3981 bytes, sha256 c0d199f2c507b5e02546d9f14b8d90901496e88b5c02081ca943b5322d9d2d0e)
$ grep -c '^# Acceptance gates' target/demo-scout/brief.md
0

```

## 2. With --gates the same task gains the section, and only that

`diff -u` between the un-gated and the gated ship brief for one task. Full files:
`ship-brief-without-gates.md`, `ship-brief-with-gates.md`.

```diff
--- /home/fabien/.no-mistakes/evidence/01M0YS6P3BGYRHBW700ZZRHMPF/ship-brief-without-gates.md	2026-08-26 13:17:33.512838703 +0200
+++ /home/fabien/.no-mistakes/evidence/01M0YS6P3BGYRHBW700ZZRHMPF/ship-brief-with-gates.md	2026-08-26 13:17:33.511838696 +0200
@@ -3,6 +3,16 @@
 # Task
 {TASK}
 
+# Acceptance gates
+`<FM_HOME_ROOT>/home/data/demo-task/gates.md` is authoritative for this task.
+Read it, but do not edit it.
+Do not create or modify `<FM_HOME_ROOT>/home/data/demo-task/gates-result.md` yourself; if you run the checker below, the checker alone owns that result-file write.
+Turn every gate that can be expressed as an automated test into a test committed in the eventual PR, so validation and CI run it.
+You may run `FM_HOME='<FM_HOME_ROOT>/home' FM_DATA_OVERRIDE='<FM_HOME_ROOT>/home/data' FM_STATE_OVERRIDE='<FM_HOME_ROOT>/home/state' '<FM_ROOT>/bin/fm-gates-check.sh' 'demo-task'` to gauge progress, but only firstmate's run counts.
+A `done:` status means only "I believe the gates pass", not "the task is finished"; firstmate runs the checker before starting validation.
+If you believe a gate is impossible, append `blocked: gate <gate-id> impossible - <reason>` to the status file.
+Never abandon a gate silently, and never write an abandonment into `<FM_HOME_ROOT>/home/data/demo-task/gates.md`.
+
 # Herdr lifecycle declaration - NOT ENABLED
 **HARD SAFETY GATE:** this scaffold cannot inspect the task text that replaces `{TASK}` later.
 If the task will start, stop, delete, restart, profile, or otherwise drive Herdr lifecycle behavior, stop and regenerate the brief with `--herdr-lab` before dispatch.
@@ -20,7 +30,7 @@
 
 # Rules
 1. Never push to the default branch. Never merge a PR.
-2. Stay inside this worktree; modify nothing outside it.
+2. Stay inside this worktree; the only files written outside it are the status file below and `<FM_HOME_ROOT>/home/data/demo-task/gates-result.md`, which the acceptance-gates checker writes when you run it - that file is the checker's to write and firstmate's to judge, never yours to edit.
 3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
 4. Report status by appending one line:
    `echo "{state}: {one short line}" >> '<FM_HOME_ROOT>/home/state/demo-task.status'`
```

## 3. The orientation checker, copied out of the brief and run as the worker would

The demo gate file asserts the brief carries the section. Run from a foreign cwd
under a different ambient FM_HOME, the command emitted in the brief still resolves
the task's own home and writes its result only there
(`gates-result-written-by-checker.md`). The worker never writes that file itself.

```
$ cat <FM_HOME_ROOT>/home/data/demo-task/gates.md   # firstmate-owned, read-only to the worker
- [ ] G1: fm-brief.sh --gates emits the acceptance-gates section
  CHECK: bash -c 'grep -c "^# Acceptance gates" brief.md'
  EXPECT: 1
  EVIDENCE: pending

# the worker's cwd and ambient FM_HOME point at an unrelated home:
$ cd <FM_HOME_ROOT>/decoy && FM_HOME=<FM_HOME_ROOT>/decoy FM_DATA_OVERRIDE= FM_STATE_OVERRIDE= \
    FM_HOME='<FM_HOME_ROOT>/home' FM_DATA_OVERRIDE='<FM_HOME_ROOT>/home/data' FM_STATE_OVERRIDE='<FM_HOME_ROOT>/home/state' '<FM_ROOT>/bin/fm-gates-check.sh' 'demo-task'
G1: satisfied - output contained EXPECT '1' (exit 0)
summary: satisfied=1 unsatisfied=0 abandoned=0 accepted=0 abandon_unknown=0 unparseable=0 parse_errors=0 -> <FM_HOME_ROOT>/home/data/demo-task/gates-result.md
exit=0

$ ls <FM_HOME_ROOT>/decoy/data   # the ambient home was not written to
$ head -6 <FM_HOME_ROOT>/home/data/demo-task/gates-result.md   # the brief's own home was
# Gates result for demo-task
copy: <FM_HOME_ROOT>/worktree
head: unknown
checked: 2026-08-26T11:18:02Z
timeout: 120

```

## 4. Scout and --herdr-lab, secondmate refusal, intake guard, --help

Full scout brief: `scout-brief-with-gates-and-herdr-lab.md`.

```
== scout, --gates + --herdr-lab ==
scaffolded: <TMP>/home/data/demo-scout/brief.md (scout; replace {TASK})
# Acceptance gates
`<TMP>/home/data/demo-scout/gates.md` is authoritative for this task.
Read it, but do not edit it.
Do not create or modify `<TMP>/home/data/demo-scout/gates-result.md` yourself; if you run the checker below, the checker alone owns that result-file write.
Record every gate that can be expressed as an automated test in the report as a proposed test, so it can land if the scout is promoted; write no test and open no PR here.
You may run `FM_HOME='<TMP>/home' FM_DATA_OVERRIDE='<TMP>/home/data' FM_STATE_OVERRIDE='<TMP>/home/state' '<FM_ROOT>/bin/fm-gates-check.sh' 'demo-scout'` to gauge progress, but only firstmate's run counts.
A `done:` status means only "I believe the gates pass", not "the task is finished"; firstmate runs the checker before accepting your report.
If you believe a gate is impossible, append `blocked: gate <gate-id> impossible - <reason>` to the status file.
Never abandon a gate silently, and never write an abandonment into `<TMP>/home/data/demo-scout/gates.md`.


-- scout Rule 2 and Herdr contract survive --
43:2. Stay inside this worktree; the only files you may write outside it are the report and the status file below. Running the acceptance-gates checker also writes `<TMP>/home/data/demo-scout/gates-result.md`, but that write is the checker's and firstmate's to judge, never yours to edit.
16:# Herdr isolation - HARD SAFETY CONTRACT

== secondmate charters refuse --gates ==
error: --gates applies only to crewmate ship or scout briefs; secondmate charters cannot carry task gates
exit=1

== --gates refuses a task whose gates.md does not exist yet ==
error: --gates requires <TMP>/home/data/no-gate-file/gates.md to exist; firstmate writes it at intake (docs/configuration.md "Task gates"). Write the gate file first, then scaffold the brief.
exit=1

== misspellings are refused, never dropped behind a success message ==
$ fm-brief.sh drop-demo demo-repo --mode no-mistakes --gates=1
error: --gates is a bare boolean flag and takes no value; drop the '=1'
exit=1
$ fm-brief.sh drop-demo demo-repo --mode no-mistakes -gates
error: unknown option -gates (see --help)
exit=1
$ fm-brief.sh drop-demo demo-repo gates --mode no-mistakes
error: unexpected extra argument 'gates'; a ship brief takes only <task-id> <repo-name>, and anything beyond them would be read by nothing (see --help)
exit=1

== --help documents the option and its schema owner ==
8:Usage: fm-brief.sh <task-id> <repo-name> --mode <no-mistakes|direct-PR|local-only> [--herdr-lab] [--gates]
9:       fm-brief.sh <task-id> <repo-name> --scout [--herdr-lab] [--gates]
13:  --gates adds the worker contract for the firstmate-owned acceptance gates at
22:  The gate file must already exist: --gates refuses to scaffold without it, so
25:  See docs/configuration.md "Task gates" for the schema-owner reference.
61:never read. So a misspelled --gates or --herdr-lab is refused rather than dropped
```
