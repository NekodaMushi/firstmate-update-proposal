#!/usr/bin/env bash
# The "PR must be raised via no-mistakes" gate in
# .github/workflows/no-mistakes-required.yml, run the way the GitHub runner runs
# it: its `run:` block executed under bash with PR_BODY/PR_AUTHOR/PR_NUMBER set.
#
# The block is the workflow's executable surface, so the test extracts it and
# drives it with PR bodies of the shape no-mistakes actually writes; the
# assertions are on exit codes and operator-visible messages, never on workflow
# text. Regression origin: the check demanded a structured attestation HTML
# comment that the installed pipeline does not write when it updates an existing
# PR body, so every contributor PR failed even with review, test, and document
# all completed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKFLOW="$ROOT/.github/workflows/no-mistakes-required.yml"
TMP="$(fm_test_tmproot no-mistakes-required)"
STEP="$TMP/step.sh"

# Dedent the single `run: |` block of the workflow's only step.
awk '
  /^        run: \|$/ { collecting = 1; next }
  collecting {
    if ($0 != "" && $0 !~ /^          /) { collecting = 0; next }
    sub(/^          /, "")
    print
  }
' "$WORKFLOW" > "$STEP"
[ -s "$STEP" ] || fail "could not extract the check step from $WORKFLOW"

SIGNATURE='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
ATTESTATION_PREFIX='<!-- no-mistakes-pipeline-attestation:v1 '

# A body as no-mistakes renders it: prose written by the pipeline's agent, then
# the deterministic "## Pipeline" section with one details block per step.
pipeline_body() {
  local review=${1:-'⚠️ **Review** - 1 info'}
  local test_step=${2:-'✅ **Test** - passed'}
  local document=${3:-'⚠️ **Document** - 1 info'}
  cat <<BODY
## Intent

Add a thing.

## Testing

Ran the suite.

## Pipeline

$SIGNATURE

<details>
<summary>✅ **intent** - passed</summary>

✅ No issues found.

</details>

<details>
<summary>$review</summary>

- ℹ️ \`bin/thing.sh:1\` - a note.

</details>

<details>
<summary>$test_step</summary>

✅ No issues found.

</details>

<details>
<summary>$document</summary>

- ℹ️ \`docs/thing.md\` - a note.

</details>

<details>
<summary>✅ **Push** - passed</summary>

✅ No issues found.

</details>
BODY
}

# run_check <body> -> prints combined output, returns the step's exit code.
run_check() {
  PR_BODY="$1" PR_AUTHOR=contributor PR_NUMBER=6 bash "$STEP" 2>&1
}

test_rendered_summaries_accepted() {
  local out rc
  out="$(run_check "$(pipeline_body)")" && rc=0 || rc=$?
  expect_code 0 "$rc" "a body whose pipeline section reports review, test, and document complete"
  assert_contains "$out" "review, test, and document completed" \
    "the check did not report the three required steps as verified"
}

test_skipped_step_rejected() {
  local out rc
  out="$(run_check "$(pipeline_body '⚠️ **Review** - 1 info' '⏭️ **Test** - skipped')")" && rc=0 || rc=$?
  expect_code 1 "$rc" "a body whose Test step was skipped"
  assert_contains "$out" "test=skipped" "the failure did not name the skipped step"
}

test_missing_step_rejected() {
  local body out rc
  body="$(pipeline_body | grep -v '\*\*Document\*\*')"
  out="$(run_check "$body")" && rc=0 || rc=$?
  expect_code 1 "$rc" "a body with no Document step summary"
  assert_contains "$out" "document=missing" "the failure did not name the absent step"
}

test_signature_only_body_rejected() {
  local out rc
  out="$(run_check "## Pipeline"$'\n\n'"$SIGNATURE")" && rc=0 || rc=$?
  expect_code 1 "$rc" "a body carrying the signature and no step outcomes at all"
  assert_contains "$out" "review=missing" "the failure did not name review as unverified"
}

test_unsigned_body_rejected() {
  local out rc
  out="$(run_check "A hand-written PR body.")" && rc=0 || rc=$?
  expect_code 1 "$rc" "a body without the no-mistakes signature"
  assert_contains "$out" "was not raised through no-mistakes" \
    "the failure did not say the PR bypassed no-mistakes"
}

test_attestation_is_authoritative_when_present() {
  local out rc json
  json='{"head_sha":"deadbeef","steps":[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]}'
  # The rendered summaries say the steps skipped; the attestation is trusted over
  # them, so the verdict must come from the structured record.
  out="$(run_check "$(pipeline_body '**Review** - skipped' '**Test** - skipped' '**Document** - skipped')"$'\n'"${ATTESTATION_PREFIX}${json} -->")" && rc=0 || rc=$?
  expect_code 0 "$rc" "a body whose attestation reports all three steps completed"
  assert_contains "$out" "structured pipeline step attestation" \
    "the check did not report the attestation as the deciding evidence"
}

test_attestation_skip_rejected() {
  local out rc json
  json='{"head_sha":"deadbeef","steps":[{"step":"review","status":"skipped"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]}'
  out="$(run_check "$(pipeline_body)"$'\n'"${ATTESTATION_PREFIX}${json} -->")" && rc=0 || rc=$?
  expect_code 1 "$rc" "an attestation reporting review skipped"
  assert_contains "$out" "review=skipped" "the failure did not name the skipped step"
}

test_unparseable_attestation_rejected() {
  local out rc
  out="$(run_check "$(pipeline_body)"$'\n'"${ATTESTATION_PREFIX}{not json} -->")" && rc=0 || rc=$?
  expect_code 1 "$rc" "an attestation marker wrapping invalid JSON"
  assert_contains "$out" "unparseable" "the failure did not name the attestation as unparseable"
}

test_rendered_summaries_accepted
pass "a pipeline section reporting review, test, and document complete passes the gate"
test_skipped_step_rejected
pass "a skipped required step fails the gate and is named"
test_missing_step_rejected
pass "a required step with no outcome in the pipeline section fails the gate"
test_signature_only_body_rejected
pass "a signature-only body fails the gate"
test_unsigned_body_rejected
pass "a body without the no-mistakes signature fails the gate"

if command -v jq >/dev/null 2>&1; then
  test_attestation_is_authoritative_when_present
  pass "a structured attestation decides the verdict when the body carries one"
  test_attestation_skip_rejected
  pass "an attestation reporting a skipped required step fails the gate"
  test_unparseable_attestation_rejected
  pass "an attestation marker wrapping invalid JSON fails the gate"
else
  pass "SKIP attestation cases: jq is not installed (the GitHub runner has it)"
fi
