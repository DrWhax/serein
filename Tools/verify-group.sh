#!/bin/sh
# Verifies the group-authorization and sender-key model (Verification/Group) and its conformance
# with the production SignalCore, in one go:
#   1. no `sorry`, `admit`, axioms or other escape hatches in the Lean sources;
#   2. `lake build`: the kernel checks every proof;
#   3. the audit: property definitions, a hash of every definition the theorem statements depend
#      on (transitively), and the theorem statements must equal audit-expected.txt, and every
#      theorem may depend only on propext, Classical.choice and Quot.sound;
#   4. the explorer's verdict per property (fixed seed) must equal explore-expected.txt;
#   5. Swift: GroupSendPlan.make, SenderKeyInfo.rotation / recording, MessageSender.authorization for
#      group payloads (on a real database) and isGroupUpdateOnly against the Lean oracle
#      (SEREIN_GROUP_CASES random cases each, default 5000);
#   6. mutants: each check weakened in production must make step 5 fail. Each is applied to the
#      working tree and the file restored afterwards (also on interrupt).
#
#   Tools/verify-group.sh                    everything
#   SKIP_SWIFT=1 Tools/verify-group.sh       only the Lean side
#   SKIP_MUTANTS=1 Tools/verify-group.sh     without step 6
#   UPDATE_EXPECTED=1 Tools/verify-group.sh  rewrite the expected files (review the diff!)
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
dir="$root/Verification/Group"
cd "$dir"

if ! command -v lake >/dev/null 2>&1 && [ -f "$HOME/.elan/env" ]; then . "$HOME/.elan/env"; fi
command -v lake >/dev/null 2>&1 || { echo "error: Lean is not installed (brew install elan-init)" >&2; exit 1; }
echo "toolchain: $(cat lean-toolchain)"

echo "== 1. escape hatches"
if grep -rnE '\b(sorry|admit|native_decide|implemented_by|extern|unsafe|axiom)\b|skipKernelTC|ofReduceBool|debug\.' \
     --include='*.lean' Group Main.lean Group.lean Audit.lean; then
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

echo "== 5. Swift: decisions against the oracle"
status=0
SEREIN_GROUP_ORACLE="$oracle" SEREIN_GROUP_CASES="${SEREIN_GROUP_CASES:-5000}" \
  swift test --filter 'GroupConformanceTests|GroupReservationTests' > "$tmp/swift" 2>&1 || status=$?
grep -E 'Test run|passed after|failed after|disagree|model |trace:' "$tmp/swift" | tail -40
[ "$status" -eq 0 ] || exit "$status"

if [ "${SKIP_MUTANTS:-}" = 1 ]; then echo "== 6. mutants: skipped"; exit 0; fi
echo "== 6. mutants: each planted bug must make production and the model disagree"
# mutant <name> <file> <perl substitution> [what must fail]
mutant() {
  name="$1"; file="$root/$2"; expr="$3"; expect="${4:-disagree.* at step}"
  cp "$file" "$backup"
  mutated="$file"
  perl -0pi -e "$expr" "$file"
  if cmp -s "$file" "$backup"; then echo "error: mutant '$name' did not apply" >&2; exit 1; fi
  SEREIN_GROUP_ORACLE="$oracle" SEREIN_GROUP_CASES=2000 \
    swift test --filter 'GroupConformanceTests|GroupReservationTests' > "$tmp/mutant" 2>&1 && survived=1 || survived=0
  restore
  if [ "$survived" = 1 ]; then echo "error: mutant '$name' survived the conformance tests" >&2; exit 1; fi
  if ! grep -qE "$expect" "$tmp/mutant"; then
    echo "error: mutant '$name' failed, but not as expected (did it build?)" >&2; tail -20 "$tmp/mutant" >&2; exit 1
  fi
  echo "killed: $name — $(grep -m1 -E "$expect" "$tmp/mutant" | sed 's/^[^a-zA-Z]*//' | cut -c1-100)"
}
group=Packages/SignalCore/Sources/SignalCore/Messaging/GroupSender.swift
sender=Packages/SignalCore/Sources/SignalCore/Messaging/MessageSender.swift
mutant "content plans include non-members" "$group" \
  's/let inGroup = all\.filter \{ members\.contains\(\$0\) \}, outside = all\.filter \{ !members\.contains\(\$0\) \}/let inGroup = all, outside = all.filter { !members.contains(\$0) }/'
mutant "a group update no longer reaches those it removes" "$group" \
  's/return GroupSendPlan\(members: inGroup, outside: update \? outside : \[\],/return GroupSendPlan(members: inGroup, outside: update \&\& outside.isEmpty ? outside : [],/'
mutant "a removed account does not rotate our key" "$group" \
  's/let reset = removed\.contains \{ !targets\.contains\(\$0\.serviceId\) \}/let reset = removed.contains { !targets.contains(\$0.serviceId) \&\& \$0.id == UInt32.max }/'
mutant "the key record is replaced, not added to" "$group" \
  's/Array\(Set\(distributed\)\.union\(devices\)\)\.sorted/Array(Set(devices)).sorted/' 'recording is not the union'
mutant "the submission check skips membership" "$sender" \
  's/                    if !groupUpdate \{\n                        let members = try Self\.currentMembers/                    if groupUpdate {\n                        let members = try Self.currentMembers/'
mutant "a one-recipient group send is not checked" "$sender" \
  's/for r in recipients \+ \[serviceId\]\.compactMap\(\{ \$0 \}\) where/for r in recipients where/'
mutant "a group update with content counts as an update" "$sender" \
  's/        bare\.groupV2 = m\.groupV2\n        return bare == m/        bare.groupV2 = m.groupV2\n        return bare.hasGroupV2/'
mutant "a sender-key message counts as a group update" "$sender" \
  's/guard case \.dataMessage\(let m\)\? = content\.content, m\.hasGroupV2 else \{ return false \}/guard case .dataMessage(let m)? = content.content, m.hasGroupV2 else { return !content.senderKeyDistributionMessage.isEmpty }/'
mutant "reservations count as completed deliveries" "$group" \
  's/info.memberDevices = SenderKeyInfo.recording\(info.memberDevices, adding: current\)/info.memberDevices = SenderKeyInfo.recording(info.memberDevices, adding: current)\n        info.deliveredDevices = info.memberDevices/' 'reservation incorrectly counted as completed delivery'
mutant "delivery completion replaces concurrent deliveries" "$group" \
  's/SenderKeyInfo.recording\(info.deliveredDevices \?\? \[\], adding: devices\)/Array(devices)/' 'delivery completion lost a concurrent send'
mutant "sender key generation is not checked" "$group" \
  's/info.generation == generation, info.needsReset/info.generation != nil, info.needsReset/' 'Test resetRejectsOldGenerationAndRetiresReservations\(\) (recorded an issue|failed)'
mutant "removed holders do not block content submission" "$group" \
  's/for device in info.memberDevices where !members.contains\(device.serviceId\) \{/for device in info.memberDevices where !members.contains(device.serviceId) \&\& device.id == UInt32.max {/' 'Test removalInvalidatesEncryptionAndSubmission\(\) (recorded an issue|failed)'
echo "12 mutants killed"
