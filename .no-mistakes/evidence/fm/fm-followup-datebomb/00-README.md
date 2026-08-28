# Time-bomb repair: before/after on the day the bomb went off

Host clock during this run: **2026-08-28 ~19:40 UTC** (`date -u`).
`tasks-axi 0.2.5`, `node v24.18.0`.

## The bomb, reproduced at the base commit

`tests/fm-public-followup.test.sh` at `f191bda` seeds
`followup_expires_at: "2026-08-28T01:12:00Z"`. Run today, ~18 hours after that
instant, `bin/fm-public-followup.sh` rechain refuses the loop:

```
fm-public-followup: followup_expires_at 2026-08-28T01:12:00Z is in the past: the
thread can no longer be reached, so this loop cannot be closed publicly. This is
a captain decision.
not ok - rechain failed:
```

Base: 34 ok, 1 not ok, exit 1 (`01-base-...FAILS.log`).
Target: 52 ok, 0 not ok, exit 0 (`02-head-...PASSES.log`), stable over two runs.

The literal that actually detonates is `followup_expires_at` in the request
context, read by `bin/fm-public-followup.sh:1109`. `tasks-axi public-followup
add --expires-at` accepts a past value without complaint, so the `--expires-at`
literals were never the trigger.

## Portability of the repaired probe (`04-date-probe-gnu-vs-bsd.txt`)

`date-probe-portability-check.sh` extracts the shipped `future_rfc3339` verbatim
from each test file and runs it against real GNU `date` and against a BSD/macOS
`date` emulator where `-d` is the DST-value option: accepted, ignored, exit 0.

- shipped BSD-first order: `now + 7 days` on both dialects
- the GNU-first order the review rejected: `now + 0 days` on the BSD emulator

## Sibling file

`tests/fm-backlog-handoff.test.sh` was also relativized (per the round-1 user
decision). Its fixtures were not in fact live bombs: at the base commit the
suite is green today with `followup_expires_at` already three weeks past, and it
stays green when `--expires-at 2026-10-01T00:00:00Z` is forced to `2020-10-01`.
The edit is hardening, and it is behaviour-neutral: 13/13 before and after.
