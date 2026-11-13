#!/bin/sh
# Verifies the retry/resend model (Verification/Resend) and its conformance with the production
# SignalCore, in one go:
#   1. no `sorry`, `admit`, axioms or other escape hatches in the Lean sources;
#   2. `lake build`: the kernel checks every proof;
#   3. the audit: property definitions, a hash of every definition the theorem statements depend
#      on (transitively), and the theorem statements must equal audit-expected.txt, and every
#      theorem may depend only on propext, Classical.choice and Quot.sound;
#   4. the explorer's verdict per property (fixed seed) must equal explore-expected.txt;
#   5. Swift: whole runs of sends, delivery receipts, time, stories, list changes and retry
#      requests on a real database, every answer of SendLog.answer (with RetryLimiter) against the
#      Lean oracle (SEREIN_RESEND_CASES, default 3000);
#   6. mutants: each check weakened in production must make step 5 fail. Each is applied to the
#      working tree and the file restored afterwards (also on interrupt).
#
#   Tools/verify-resend.sh                    everything
#   SKIP_SWIFT=1 Tools/verify-resend.sh       only the Lean side
#   SKIP_MUTANTS=1 Tools/verify-resend.sh     without step 6
#   UPDATE_EXPECTED=1 Tools/verify-resend.sh  rewrite the expected files (review the diff!)
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
dir="$root/Verification/Resend"
cd "$dir"

if ! command -v lake >/dev/null 2>&1 && [ -f "$HOME/.elan/env" ]; then . "$HOME/.elan/env"; fi
command -v lake >/dev/null 2>&1 || { echo "error: Lean is not installed (brew install elan-init)" >&2; exit 1; }
echo "toolchain: $(cat lean-toolchain)"

echo "== 1. escape hatches"
if grep -rnE '\b(sorry|admit|native_decide|implemented_by|extern|unsafe|axiom)\b|skipKernelTC|ofReduceBool|debug\.' \
     --include='*.lean' Resend Main.lean Resend.lean Audit.lean; then
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

echo "== 4. explorer verdicts (40000 random runs of 60 events, seed 2026)"
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

echo "== 5. Swift: runs against the oracle"
status=0
SEREIN_RESEND_ORACLE="$oracle" SEREIN_RESEND_CASES="${SEREIN_RESEND_CASES:-3000}" \
  swift test --filter 'ResendConformanceTests' > "$tmp/swift" 2>&1 || status=$?
grep -E 'Test run|passed after|failed after|disagree|model ' "$tmp/swift" | tail -40
[ "$status" -eq 0 ] || exit "$status"

if [ "${SKIP_MUTANTS:-}" = 1 ]; then echo "== 6. mutants: skipped"; exit 0; fi
echo "== 6. mutants: each planted bug must make production and the model disagree"
# mutant <name> <file> <perl substitution> [what must fail]
killed=0
mutant() {
  name="$1"; file="$root/$2"; expr="$3"; expect="${4:-disagree.* at step}"
  cp "$file" "$backup"
  mutated="$file"
  perl -0pi -e "$expr" "$file"
  if cmp -s "$file" "$backup"; then echo "error: mutant '$name' did not apply" >&2; exit 1; fi
  if [ "${DRY_RUN:-}" = 1 ]; then restore; echo "applies: $name"; return; fi
  SEREIN_RESEND_ORACLE="$oracle" SEREIN_RESEND_CASES=2000 \
    swift test --filter 'ResendConformanceTests' > "$tmp/mutant" 2>&1 && survived=1 || survived=0
  restore
  if [ "$survived" = 1 ]; then echo "error: mutant '$name' survived the conformance tests" >&2; exit 1; fi
  if ! grep -qE "$expect" "$tmp/mutant"; then
    echo "error: mutant '$name' failed, but not as expected (did it build?)" >&2; tail -20 "$tmp/mutant" >&2; exit 1
  fi
  killed=$((killed + 1))
  echo "killed: $name — $(grep -m1 -E "$expect" "$tmp/mutant" | sed 's/^[^a-zA-Z]*//' | cut -c1-100)"
}
log=Packages/SignalCore/Sources/SignalCore/Messaging/SendLog.swift
mutant "the lookup ignores the device" "$log" \
  's/AND r\.recipientServiceId = \? AND r\.deviceId = \? AND p\.timestamp >= \?/AND r.recipientServiceId = ? AND r.deviceId = r.deviceId + 0 * ? AND p.timestamp >= ?/'
mutant "the lookup takes another recipient's payload" "$log" \
  's/AND r\.recipientServiceId = \? AND r\.deviceId = \? AND p\.timestamp >= \?/AND (r.recipientServiceId = ? OR 1) AND r.deviceId = ? AND p.timestamp >= ?/'
mutant "a payload older than a day is resent" "$log" \
  's/AND r\.deviceId = \? AND p\.timestamp >= \?/AND r.deviceId = ? AND (p.timestamp >= ? OR 1)/'
mutant "the newest payload at that timestamp is chosen" "$log" \
  's/ORDER BY p\.id LIMIT 1/ORDER BY p.id DESC LIMIT 1/'
mutant "there is no retry limit" "$log" \
  's/guard answered < retryLimit else \{ return \.nothing \}/guard answered < retryLimit + 100 else { return .nothing }/'
mutant "the limiter does not count" "$log" \
  's/c\[key\] = n \+ 1/c[key] = n/'
mutant "a story is resent whatever the lists" "$log" \
  's/try !storyListed\(db, requester: requester, timestamp: timestamp, ourAci: ourAci\)/try !storyListed(db, requester: requester, timestamp: timestamp, ourAci: ourAci) \&\& requester.isEmpty/'
mutant "a block list counts as a list" "$log" \
  's/return !list\.isBlockList \&\& list\.deletedAt == nil/return list.deletedAt == nil/'
mutant "a group's story is checked like a list story" "$log" \
  's/, !story\.hasGroup,/, story.hasGroup || !story.hasGroup,/'
mutant "a receipt removes the recipient's other devices" "$log" \
  's/DELETE FROM sendLogRecipients WHERE recipientServiceId = \? AND deviceId = \?/DELETE FROM sendLogRecipients WHERE recipientServiceId = ? AND deviceId = deviceId + 0 * ?/'
mutant "a receipt removes the payload while others wait for it" "$log" \
  's/WHERE timestamp = \? AND id NOT IN \(SELECT payloadId FROM sendLogRecipients\)/WHERE timestamp = ?/'
echo "$killed mutants killed"
