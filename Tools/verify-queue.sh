#!/bin/sh
# Verifies the job-queue model (Verification/Queue) and its conformance with production
# SignalCore's JobQueue, in one go:
#   1. no `sorry`, `admit`, axioms or other escape hatches in the Lean sources;
#   2. `lake build`: the kernel checks every proof;
#   3. the audit: property definitions, a hash of every definition the theorem statements depend
#      on (transitively), and the theorem statements must equal audit-expected.txt, and every
#      theorem may depend only on propext, Classical.choice and Quot.sound;
#   4. the explorer's verdict per property (fixed seed) must equal explore-expected.txt;
#   5. Swift: the real JobQueue with held handlers on a real database, against the Lean oracle,
#      after each event once the actor is quiet (SEREIN_QUEUE_TRACES random traces, default 300,
#      and the regression traces);
#   6. mutants: each check weakened in production must make step 5 fail. Each is applied to the
#      working tree and the file restored afterwards (also on interrupt).
#
#   Tools/verify-queue.sh                    everything
#   SKIP_SWIFT=1 Tools/verify-queue.sh       only the Lean side
#   SKIP_MUTANTS=1 Tools/verify-queue.sh     without step 6
#   UPDATE_EXPECTED=1 Tools/verify-queue.sh  rewrite the expected files (review the diff!)
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
dir="$root/Verification/Queue"
cd "$dir"

if ! command -v lake >/dev/null 2>&1 && [ -f "$HOME/.elan/env" ]; then . "$HOME/.elan/env"; fi
command -v lake >/dev/null 2>&1 || { echo "error: Lean is not installed (brew install elan-init)" >&2; exit 1; }
echo "toolchain: $(cat lean-toolchain)"

echo "== 1. escape hatches"
if grep -rnE '\b(sorry|admit|native_decide|implemented_by|extern|unsafe|axiom)\b|skipKernelTC|ofReduceBool|debug\.' \
     --include='*.lean' Queue Main.lean Queue.lean Audit.lean; then
  echo "error: forbidden construct (above)" >&2; exit 1
fi
echo "none"

echo "== 2. lake build (the kernel checks every proof)"
if ! lake build > /dev/null 2>&1; then lake build; exit 1; fi
echo "ok"

echo "== 3. audit: definitions, statements, axioms"
tmp=$(mktemp -d)
backup="$tmp/backup"
mutated=""
restore() { if [ -n "$mutated" ]; then cp "$backup" "$mutated"; mutated=""; fi; }
trap 'restore; rm -rf "$tmp"' EXIT
trap 'restore; rm -rf "$tmp"; exit 130' INT TERM
if ! lake env lean Audit.lean > "$tmp/audit" 2>&1; then cat "$tmp/audit" >&2; exit 1; fi
if [ "${UPDATE_EXPECTED:-}" = 1 ]; then cp "$tmp/audit" audit-expected.txt; fi
if ! diff -u audit-expected.txt "$tmp/audit"; then
  echo "error: definitions or theorem statements changed (review, then UPDATE_EXPECTED=1)" >&2; exit 1
fi
total=$(grep -c ' depends on axioms: ' "$tmp/audit")
bad=$(grep ' depends on axioms: ' "$tmp/audit" | sed 's/.* depends on axioms: \[\(.*\)\]$/\1/' | tr ',' '\n' | tr -d ' ' \
      | grep -vxE '(propext|Classical\.choice|Quot\.sound)?' || true)
if [ -n "$bad" ] || [ "$total" -eq 0 ]; then
  echo "error: unexpected axioms:" >&2; echo "$bad" >&2; exit 1
fi
echo "$total theorems; axioms used: propext, Classical.choice, Quot.sound; $(grep -m1 ' definitions$' "$tmp/audit") in the audited closure"

echo "== 4. explorer verdicts (40000 random traces of 60 events, any schedule, seed 2026)"
./.lake/build/bin/oracle explore 2026 40000 60 > "$tmp/explore-raw"
grep -E '^(OK|FAIL)' "$tmp/explore-raw" | sed -E 's/^(OK|FAIL) ([A-Za-z0-9-]+).*/\2 \1/' > "$tmp/explore"
if [ "${UPDATE_EXPECTED:-}" = 1 ]; then cp "$tmp/explore" explore-expected.txt; fi
if ! diff -u explore-expected.txt "$tmp/explore"; then
  echo "error: a property's verdict changed (review, then UPDATE_EXPECTED=1)" >&2; exit 1
fi
echo "$(grep -c ' OK$' explore-expected.txt) hold, $(grep -c ' FAIL$' explore-expected.txt) falsified"

if [ "${SKIP_SWIFT:-}" = 1 ]; then echo "== 5. Swift: skipped"; exit 0; fi
oracle="$dir/.lake/build/bin/oracle"
cd "$root/Packages/SignalCore"

echo "== 5. Swift: the real JobQueue against the oracle"
status=0
SEREIN_QUEUE_ORACLE="$oracle" SEREIN_QUEUE_TRACES="${SEREIN_QUEUE_TRACES:-300}" \
  swift test --filter 'QueueConformanceTests' > "$tmp/swift" 2>&1 || status=$?
grep -E 'Test run|passed after|failed after|disagree|model |swift |trace:' "$tmp/swift" | tail -20
[ "$status" -eq 0 ] || exit "$status"

if [ "${SKIP_MUTANTS:-}" = 1 ]; then echo "== 6. mutants: skipped"; exit 0; fi
echo "== 6. mutants: each planted bug must make production and the model disagree"
mutant() {
  name="$1"; file="$root/$2"; expr="$3"
  cp "$file" "$backup"
  mutated="$file"
  perl -0pi -e "$expr" "$file"
  if cmp -s "$file" "$backup"; then echo "error: mutant '$name' did not apply" >&2; exit 1; fi
  SEREIN_QUEUE_ORACLE="$oracle" SEREIN_QUEUE_TRACES=60 swift test --filter 'QueueConformanceTests' > "$tmp/mutant" 2>&1 && survived=1 || survived=0
  restore
  if [ "$survived" = 1 ]; then echo "error: mutant '$name' survived" >&2; exit 1; fi
  if ! grep -qE 'disagree.* at step' "$tmp/mutant"; then
    echo "error: mutant '$name' failed without a disagreement (did it build?)" >&2; tail -20 "$tmp/mutant" >&2; exit 1
  fi
  echo "killed: $name — $(grep -m1 -E 'disagree.* at step' "$tmp/mutant" | sed 's/^[^a-zA-Z]*//' | cut -c1-100)"
}
queue=Packages/SignalCore/Sources/SignalCore/Jobs/JobQueue.swift
mutant "start ignores a pending drain" "$queue" \
  's/        guard draining == 0 else \{ return \}\n        wantsRunning = true/        _ = draining\n        wantsRunning = true/'
mutant "stopAndWait does not wait for the loop" "$queue" \
  's/        await running\?\.value\n        draining -= 1/        _ = running\n        draining -= 1/'
mutant "the loop restarts after a stop" "$queue" \
  's/            if wantsRunning \{ start\(\) \}/            start()/'
mutant "a cancelled handler's job is discarded" "$queue" \
  's/if Task\.isCancelled \{ return \}/if Task.isCancelled { finish(job); return }/'
mutant "a permanent failure is retried" "$queue" \
  's/let permanent = \(error as\? JobError\) != nil/let permanent = (error as? JobError) != nil \&\& job.id.isEmpty/'
echo "5 mutants killed"
