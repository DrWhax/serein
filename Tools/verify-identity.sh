#!/bin/sh
# Verifies the identity-approval model (Verification/Identity) and its conformance with the
# production SignalCore, in one go:
#   1. no `sorry`, `admit`, axioms or other escape hatches in the Lean sources;
#   2. `lake build`: the kernel checks every proof;
#   3. the audit: property definitions, a hash of every definition the theorem statements depend
#      on (transitively), and the theorem statements must equal audit-expected.txt, and every
#      theorem may depend only on propext, Classical.choice and Quot.sound;
#   4. the explorer's verdict per property (fixed seed) must equal explore-expected.txt;
#   5. Swift: production SignalCore (approveIdentities, setVerified, safetyNumber, saveIdentity,
#      mergeContact, the VerifiedSync job) against the Lean oracle on a real database, step by
#      step, on the regression traces and random traces (SEREIN_IDENTITY_TRACES, default 2000);
#   6. mutants: each key check removed, the transaction split, the sync looking its key up again,
#      the storage merge without its key match, and a key change keeping its approval must make
#      step 5 report a disagreement. Each is applied to the working tree and the file restored
#      afterwards (also on interrupt).
#
#   Tools/verify-identity.sh                    everything
#   SKIP_SWIFT=1 Tools/verify-identity.sh       only the Lean side
#   SKIP_MUTANTS=1 Tools/verify-identity.sh     without step 6
#   UPDATE_EXPECTED=1 Tools/verify-identity.sh  rewrite the expected files (review the diff!)
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
dir="$root/Verification/Identity"
cd "$dir"

if ! command -v lake >/dev/null 2>&1 && [ -f "$HOME/.elan/env" ]; then . "$HOME/.elan/env"; fi
command -v lake >/dev/null 2>&1 || { echo "error: Lean is not installed (brew install elan-init)" >&2; exit 1; }
echo "toolchain: $(cat lean-toolchain)"

echo "== 1. escape hatches"
if grep -rnE '\b(sorry|admit|native_decide|implemented_by|extern|unsafe|axiom)\b|skipKernelTC|ofReduceBool|debug\.' \
     --include='*.lean' Identity Main.lean Identity.lean Audit.lean; then
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

echo "== 4. explorer verdicts (40000 random traces of 60 events, seed 2026)"
./.lake/build/bin/oracle explore 2026 40000 60 | grep -E '^(OK|FAIL)' | sed -E 's/^(OK|FAIL) ([A-Za-z0-9-]+).*/\2 \1/' > "$tmp/explore"
if [ "${UPDATE_EXPECTED:-}" = 1 ]; then cp "$tmp/explore" explore-expected.txt; fi
if ! diff -u explore-expected.txt "$tmp/explore"; then
  echo "error: a property's verdict changed (review, then UPDATE_EXPECTED=1)" >&2; exit 1
fi
echo "$(grep -c ' OK$' explore-expected.txt) hold, $(grep -c ' FAIL$' explore-expected.txt) falsified"

if [ "${SKIP_SWIFT:-}" = 1 ]; then echo "== 5. Swift: skipped"; exit 0; fi
oracle="$dir/.lake/build/bin/oracle"
cd "$root/Packages/SignalCore"

echo "== 5. Swift: conformance with the oracle"
status=0
SEREIN_IDENTITY_ORACLE="$oracle" SEREIN_IDENTITY_TRACES="${SEREIN_IDENTITY_TRACES:-2000}" \
  swift test --filter 'IdentityConformanceTests' > "$tmp/swift" 2>&1 || status=$?
grep -E 'Test run|passed after|failed after|disagree|model |trace:' "$tmp/swift" | tail -40
[ "$status" -eq 0 ] || exit "$status"

if [ "${SKIP_MUTANTS:-}" = 1 ]; then echo "== 6. mutants: skipped"; exit 0; fi
echo "== 6. mutants: each planted bug must make production and the model disagree"
# mutant <name> <file> <perl substitution>
mutant() {
  name="$1"; file="$root/$2"; expr="$3"
  cp "$file" "$backup"
  mutated="$file"
  perl -0pi -e "$expr" "$file"
  if cmp -s "$file" "$backup"; then echo "error: mutant '$name' did not apply" >&2; exit 1; fi
  SEREIN_IDENTITY_ORACLE="$oracle" SEREIN_IDENTITY_TRACES=300 \
    swift test --filter 'IdentityConformanceTests' > "$tmp/mutant" 2>&1 && survived=1 || survived=0
  restore
  if [ "$survived" = 1 ]; then echo "error: mutant '$name' survived the conformance tests" >&2; exit 1; fi
  if ! grep -qE 'disagree.* at step' "$tmp/mutant"; then
    echo "error: mutant '$name' failed without a disagreement (did it build?)" >&2; tail -20 "$tmp/mutant" >&2; exit 1
  fi
  echo "killed: $name — $(grep -m1 -oE 'disagree.* at step [0-9]+ \([^)]*\)' "$tmp/mutant")"
}
approval=Packages/SignalCore/Sources/SignalCore/Messaging/Messenger+IdentityApproval.swift
identity=Packages/SignalCore/Sources/SignalCore/Identity/Identity.swift
mutant "the review's peer key is not checked" "$approval" \
  's/SignalCrypto\.constantTimeEqual\(current, key\)/!current.isEmpty/'
mutant "our account's identity key is not checked" "$approval" \
  's/SignalCrypto\.constantTimeEqual\(ourKey, account\.aciIdentity\.publicKey\.serialize\(\)\)/!ourKey.isEmpty/'
mutant "our ACI is not checked" "$approval" \
  's/guard ourServiceId == account\.aci,/guard !ourServiceId.isEmpty,/'
mutant "approval validates outside its transaction" "$approval" \
  's/try await database\.pool\.write \{ db in\n\s*\/\/ Validate the entire review before changing any trust state\.\n\s*for identity in identities \{ try identity\.validate\(db, account: account\) \}\n/try await database.pool.read { db in for identity in identities { try identity.validate(db, account: account) } }\n        try await database.pool.write { db in\n/'
mutant "verification is not validated" "$identity" \
  's/            try identity\.validate\(db, account: account\)\n            try Self\.applyVerified/            _ = account\n            try Self.applyVerified/'
mutant "the sync job looks its key up again" "$identity" \
  's/        v\.identityKey = key\n/        v.identityKey = (try? await theirIdentityKey(aci).serialize()) ?? key\n/'
mutant "the storage merge ignores the key match" Packages/SignalCore/Sources/SignalCore/StorageService/StorageRecords+Conversations.swift \
  's/if haveRemoteKey, ctx\.isFirstSync \|\| localIdentity == nil \|\| keysMatch,/if haveRemoteKey,/'
mutant "a new key keeps the old key's approval" Packages/SignalCore/Sources/SignalCore/Protocol/ProtocolStore.swift \
  's/verified: \(wasMarked \? VerifiedStatus\.unverified : \.default\)\.rawValue, nonblockingApproval: nonblockingApproval\)/verified: (wasMarked ? VerifiedStatus.unverified : .default).rawValue, nonblockingApproval: row.nonblockingApproval)/'
echo "8 mutants killed"
