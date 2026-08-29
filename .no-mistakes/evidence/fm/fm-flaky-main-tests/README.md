# Evidence: repaired flaky main-branch tests + EPIPE plugin fix

Host: Linux, `kernel.pid_max = 4194304` (the state that made PID 999999 occupiable).
Tests run with Node v24.18.0 from nvm, which also carries the `tasks-axi` the
remote-handoff test gates on. Node v20 on the default non-interactive PATH cannot
import the `.pi` TypeScript extensions and is not a usable runtime for this suite.

## 1. Root cause (1): PID 999999 is not a dead pid on this host

`pid999999-repro-driver.sh` runs a tree inside an unprivileged PID namespace with
PID 999999 held by a live process (steered via `ns_last_pid`), reproducing the
failing host state deterministically instead of waiting for it.

| tree | tests/fm-pi-watch-extension.test.sh | tests/fm-remote-backlog-handoff.test.sh |
| --- | --- | --- |
| base c3052ba | `not ok - Pi watcher arm must distinguish owned, live-other, and missing or dead session locks` | `not ok - host-local stale lock recovery did not retry receipt` |
| delivered cc886f2 | `ok - Pi watcher arm distinguishes all session lock ownership states` | `ok - receiver removes one proven dead stale lock and retries once` |

Full transcripts: `pid999999-repro-base.txt`, `pid999999-repro-fixed.txt`.
Both failures match the ones the change set out to repair.

## 2. `fm_dead_pid` contract

`fm-dead-pid-contract.txt`: returns 4194305 here and `kill -0` answers
"No such process" (ESRCH, not EPERM); with `/proc/sys/kernel/pid_max` made
unreadable it falls back to 999999.

## 3. Root cause (2): stdin EPIPE killed the plugin host

`epipe-regression-before-after.txt`: the new regression case run against the
base adapter dies with `Error: write EPIPE` / "Unhandled 'error' event" and the
host process exits; against the delivered adapter it rejects through the
encoder's exit code and passes.

## 4. Stability on the host

`repeat-runs-host.txt`: three consecutive runs of the two repaired tests plus
the operational-input test, 0 failures, 0 gate skips.
