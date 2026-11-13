#!/bin/sh
# Verifies the send-authorization model (Verification/Send) and its conformance with the
# production SignalCore, in one go:
#   1. no `sorry`, `admit`, axioms or other escape hatches in the Lean sources;
#   2. `lake build`: the kernel checks every proof;
#   3. the audit: property definitions, a hash of every definition the theorem statements depend
#      on (transitively), and the theorem statements must equal audit-expected.txt, and every
#      theorem may depend only on propext, Classical.choice and Quot.sound;
#   4. the explorer's verdict per property (fixed seed) must equal explore-expected.txt, and no
#      regression trace may falsify a property;
#   5. Swift: production SignalCore's decisions (MessageSender.authorization,
#      OutgoingPayload.onlyRetracts, GroupSender's recipients) against the Lean oracle on random
#      database states and random payloads (SEREIN_SEND_CASES, default 5000), and the transport's
#      check at the submission boundary;
#   6. mutants: each check weakened in production must make step 5 fail. Each is applied to the
#      working tree and the file restored afterwards (also on interrupt).
#
#   Tools/verify-send.sh                    everything
#   SKIP_SWIFT=1 Tools/verify-send.sh       only the Lean side
#   SKIP_MUTANTS=1 Tools/verify-send.sh     without step 6
#   UPDATE_EXPECTED=1 Tools/verify-send.sh  rewrite the expected files (review the diff!)
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
dir="$root/Verification/Send"
cd "$dir"

if ! command -v lake >/dev/null 2>&1 && [ -f "$HOME/.elan/env" ]; then . "$HOME/.elan/env"; fi
command -v lake >/dev/null 2>&1 || { echo "error: Lean is not installed (brew install elan-init)" >&2; exit 1; }
echo "toolchain: $(cat lean-toolchain)"

echo "== 1. escape hatches"
if grep -rnE '\b(sorry|admit|native_decide|implemented_by|extern|unsafe|axiom)\b|skipKernelTC|ofReduceBool|debug\.' \
     --include='*.lean' Send Main.lean Send.lean Audit.lean; then
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

echo "== 4. explorer verdicts (40000 random traces of 50 events, seed 2026), regression traces"
./.lake/build/bin/oracle check < traces/regressions.txt > "$tmp/regressions"
if grep -v 'fails=\[\]' "$tmp/regressions"; then
  echo "error: a regression trace falsifies a property (above)" >&2; exit 1
fi
./.lake/build/bin/oracle explore 2026 40000 50 > "$tmp/explore-raw"
grep -E '^(OK|FAIL)' "$tmp/explore-raw" | sed -E 's/^(OK|FAIL) ([A-Za-z0-9-]+).*/\2 \1/' > "$tmp/explore"
if [ "${UPDATE_EXPECTED:-}" = 1 ]; then cp "$tmp/explore" explore-expected.txt; fi
if ! diff -u explore-expected.txt "$tmp/explore"; then
  echo "error: a property's verdict changed (review, then UPDATE_EXPECTED=1)" >&2; exit 1
fi
echo "$(grep -c ' OK$' explore-expected.txt) hold, $(grep -c ' FAIL$' explore-expected.txt) falsified"

if [ "${SKIP_SWIFT:-}" = 1 ]; then echo "== 5. Swift: skipped"; exit 0; fi
oracle="$dir/.lake/build/bin/oracle"
cd "$root/Packages/SignalCore"

echo "== 5. Swift: decisions against the oracle, the submission boundary"
status=0
SEREIN_SEND_ORACLE="$oracle" SEREIN_SEND_CASES="${SEREIN_SEND_CASES:-5000}" \
  swift test --filter 'SendAuthorizationConformanceTests|SubmissionBoundaryTests' > "$tmp/swift" 2>&1 || status=$?
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
  SEREIN_SEND_ORACLE="$oracle" SEREIN_SEND_CASES=2000 \
    swift test --filter 'SendAuthorizationConformanceTests|SubmissionBoundaryTests' > "$tmp/mutant" 2>&1 && survived=1 || survived=0
  restore
  if [ "$survived" = 1 ]; then echo "error: mutant '$name' survived the conformance tests" >&2; exit 1; fi
  if ! grep -qE "$expect" "$tmp/mutant"; then
    echo "error: mutant '$name' failed, but not as expected (did it build?)" >&2; tail -20 "$tmp/mutant" >&2; exit 1
  fi
  echo "killed: $name — $(grep -m1 -E "$expect" "$tmp/mutant" | sed 's/^[^a-zA-Z]*//' | cut -c1-100)"
}
sender=Packages/SignalCore/Sources/SignalCore/Messaging/MessageSender.swift
mutant "a delete with content counts as a retraction (the old check)" "$sender" \
  's/case \.dataMessage\(let m\)\?: return Self\.onlyDeletes\(m\)/case .dataMessage(let m)?: return m.hasDelete || m.hasAdminDelete/'
mutant "a transcript carrying a story or an edit counts as a retraction" "$sender" \
  's/guard case \.sent\(let sent\)\? = sync\.content, !sent\.hasStoryMessage, !sent\.hasEditMessage else/guard case .sent(let sent)? = sync.content else/'
mutant "the named messages are not checked" "$sender" \
  's/for id in messageIds where !retracting \{/for id in messageIds where messageIds.isEmpty {/'
mutant "a retraction is refused once its message is gone" "$sender" \
  's/for id in messageIds where !retracting \{/for id in messageIds where !messageIds.isEmpty {/'
mutant "an erased message counts as present" "$sender" \
  's/try MessageStore\.jsonObject\(json\)\["isErased"\] as\? Bool != true else/!json.isEmpty else/'
mutant "a contact blocked by number is not blocked" "$sender" \
  's/return try number\.map \{ try BlockedList\.numbers\.blockedAt\(db, \$0\)\.blocked \} \?\? false/_ = number\n        return false/'
mutant "a blocked contact is not refused" "$sender" \
  's/if try Self\.isBlocked\(db, serviceId: serviceId\) \{ throw/if try Self.isBlocked(db, serviceId: serviceId) \&\& serviceId.isEmpty { throw/'
mutant "a blocked group is not refused" "$sender" \
  's/if try BlockedList\.groups\.blockedAt\(db, groupId\.base64EncodedString\(\)\)\.blocked \{/if try BlockedList.groups.blockedAt(db, groupId.base64EncodedString()).blocked \&\& groupId.isEmpty {/'
mutant "a group send goes to members we blocked" Packages/SignalCore/Sources/SignalCore/Messaging/GroupSender.swift \
  's/try serviceIds\.filter \{ try !MessageSender\.isBlocked\(db, serviceId: \$0\) \}/_ = db\n        return serviceIds/'
socket=Packages/SignalCore/Sources/SignalCore/Net/SocketManager.swift
mutant "the authenticated transport skips the check" "$socket" \
  's/(let response = try await withAuthenticated \{ chat in\n\s*try Task\.checkCancellation\(\)\n)\s*try authorize\(\)\n/$1            _ = authorize\n/' 'Test transportRefusesAtTheBoundary\(\) (recorded an issue|failed)'
mutant "the unauthenticated transport skips the check" "$socket" \
  's/(let response = try await withUnauthenticated \{ chat in\n\s*try Task\.checkCancellation\(\)\n)\s*try authorize\(\)\n(\s*return try await chat\.send\()/$1            _ = authorize\n$2/' 'Test transportRefusesAtTheBoundary\(\) (recorded an issue|failed)'
mutant "the multi-recipient transport skips the check" "$socket" \
  's/(let response = try await withUnauthenticated \{ chat in\n\s*try Task\.checkCancellation\(\)\n)\s*try authorize\(\)\n(\s*return try await chat\.sendMultiRecipientMessage)/$1            _ = authorize\n$2/' 'Test transportRefusesAtTheBoundary\(\) (recorded an issue|failed)'
echo "12 mutants killed"
