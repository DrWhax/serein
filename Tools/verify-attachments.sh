#!/bin/sh
# Verifies the attachment-authentication model (Verification/Attachments) and its conformance with the production
# SignalCore, in one go:
#   1. no `sorry`, `admit`, axioms or other escape hatches in the Lean sources;
#   2. `lake build`: the kernel checks every proof;
#   3. the audit: property definitions, a hash of every definition the theorem statements depend
#      on (transitively), and the theorem statements must equal audit-expected.txt, and every
#      theorem may depend only on propext, Classical.choice and Quot.sound;
#   4. the explorer's verdict per property (fixed seed) must equal explore-expected.txt;
#   5. Swift: MessageModifiers' decisions on a real database, whole runs of messages and modifiers
#      (the stored messages, what they show, the waiting list), and the waiting list's evictions,
#      against the Lean oracle (SEREIN_ATTACHMENTS_CASES, default 3000);
#   6. mutants: each check weakened in production must make step 5 fail. Each is applied to the
#      working tree and the file restored afterwards (also on interrupt).
#
#   Tools/verify-attachments.sh                    everything
#   SKIP_SWIFT=1 Tools/verify-attachments.sh       only the Lean side
#   SKIP_MUTANTS=1 Tools/verify-attachments.sh     without step 6
#   UPDATE_EXPECTED=1 Tools/verify-attachments.sh  rewrite the expected files (review the diff!)
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
dir="$root/Verification/Attachments"
cd "$dir"

if ! command -v lake >/dev/null 2>&1 && [ -f "$HOME/.elan/env" ]; then . "$HOME/.elan/env"; fi
command -v lake >/dev/null 2>&1 || { echo "error: Lean is not installed (brew install elan-init)" >&2; exit 1; }
echo "toolchain: $(cat lean-toolchain)"

echo "== 1. escape hatches"
if grep -rnE '\b(sorry|admit|native_decide|implemented_by|extern|unsafe|axiom)\b|skipKernelTC|ofReduceBool|debug\.' \
     --include='*.lean' Attachments Main.lean Attachments.lean Audit.lean; then
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
./.lake/build/bin/oracle explore 2026 40000 60 | grep -E '^(OK|FAIL)' | sed -E 's/^(OK|FAIL) ([A-Za-z0-9-]+).*/\2 \1/' > "$tmp/explore"
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
SEREIN_ATTACHMENTS_ORACLE="$oracle" SEREIN_ATTACHMENTS_CASES="${SEREIN_ATTACHMENTS_CASES:-3000}" \
  swift test --filter 'AttachmentConformanceTests' > "$tmp/swift" 2>&1 || status=$?
grep -E 'Test run|passed after|failed after|disagree|model |content:' "$tmp/swift" | tail -40
[ "$status" -eq 0 ] || exit "$status"

if [ "${SKIP_MUTANTS:-}" = 1 ]; then echo "== 6. mutants: skipped"; exit 0; fi
echo "== 6. mutants: each planted bug must make production and the model disagree"
# mutant <name> <file> <perl substitution> [what must fail]
killed=0
mutant() {
  name="$1"; file="$root/$2"; expr="$3"; expect="${4:-disagree.* at step|content: |Test (boundedTransfer|pinningRefusesOtherRoots)\(\) (recorded an issue|failed)}"
  cp "$file" "$backup"
  mutated="$file"
  perl -0pi -e "$expr" "$file"
  if cmp -s "$file" "$backup"; then echo "error: mutant '$name' did not apply" >&2; exit 1; fi
  if [ "${DRY_RUN:-}" = 1 ]; then restore; echo "applies: $name"; return; fi
  SEREIN_ATTACHMENTS_ORACLE="$oracle" SEREIN_ATTACHMENTS_CASES=2000 \
    swift test --filter 'AttachmentConformanceTests' > "$tmp/mutant" 2>&1 && survived=1 || survived=0
  restore
  if [ "$survived" = 1 ]; then echo "error: mutant '$name' survived the conformance tests" >&2; exit 1; fi
  if ! grep -qE "$expect" "$tmp/mutant"; then
    echo "error: mutant '$name' failed, but not as expected (did it build?)" >&2; tail -20 "$tmp/mutant" >&2; exit 1
  fi
  killed=$((killed + 1))
  echo "killed: $name — $(grep -m1 -E "$expect" "$tmp/mutant" | sed 's/^[^a-zA-Z]*//' | cut -c1-100)"
}
cipher=Packages/SignalCore/Sources/SignalCore/Attachments/AttachmentCipher.swift
dl=Packages/SignalCore/Sources/SignalCore/Attachments/AttachmentDownloadManager.swift
http=Packages/SignalCore/Sources/SignalCore/Net/HTTPClient.swift
mutant "the MAC is not checked" "$cipher" \
  's/Data\(blob\.suffix\(macLength\)\)\) else \{ throw AttachmentError\.badMAC \}/Data(blob.suffix(macLength))) || !body.isEmpty else { throw AttachmentError.badMAC }/'
mutant "the digest is not checked" "$cipher" \
  's/guard SignalCrypto\.constantTimeEqual\(digest, expected\) else/guard SignalCrypto.constantTimeEqual(digest, expected) || !digest.isEmpty else/'
mutant "an empty digest is accepted" "$cipher" \
  's/guard !expected\.isEmpty else \{ throw AttachmentError\.missingDigest \}/guard !expected.isEmpty || expected.isEmpty else { throw AttachmentError.missingDigest }/'
mutant "the plaintext hash is not checked" "$cipher" \
  's/guard SignalCrypto\.constantTimeEqual\(plaintextHash, expected\) else/guard SignalCrypto.constantTimeEqual(plaintextHash, expected) || !plaintextHash.isEmpty else/'
mutant "the incremental MAC is not checked" "$cipher" \
  's/_ = try validator\.update\(blob\)\n                _ = try validator\.finalize\(\)/_ = try validator.update(Data())/'
mutant "a chunk size beyond any pointer traps" "$cipher" \
  's/guard let chunk = UInt32\(exactly: chunkSize\) else \{ throw AttachmentError\.badIncrementalMAC \}/let chunk = UInt32(chunkSize)/' \
  'disagree.* at step|Fatal error|unexpected signal|exited with|crashed'
mutant "the blob's shape is not checked" "$cipher" \
  's/guard blob\.count >= ivLength \+ 16 \+ macLength, \(blob\.count - ivLength - macLength\) % 16 == 0 else/guard blob.count >= ivLength + macLength else/' \
  'disagree.* at step|Fatal error|unexpected signal|exited with|crashed'
mutant "the padding is not trimmed to the size" "$cipher" \
  's/let plaintext = size\.map \{ Data\(padded\.prefix\(max\(0, \$0\)\)\) \} \?\? padded/let plaintext = padded/'
mutant "the incoming size limit is ignored" "$dl" \
  's/guard a\.size <= maxSize else \{ throw AttachmentDownloadError\.tooBig\(a\.size\) \}/guard a.size <= maxSize || maxSize >= 0 else { throw AttachmentDownloadError.tooBig(a.size) }/'
mutant "the response is not bounded" "$dl" \
  's/client\.maxResponseBytes = job\.ciphertextSize \+ 64 << 10/client.maxResponseBytes = Int(Int32.max)/'
mutant "a pointer with neither digest nor hash is accepted" "$dl" \
  's/else \{ throw AttachmentError\.missingDigest \}\n        let local/else { integrity = .local }\n        let local/'
mutant "an unverified blob is stored as received" "$dl" \
  's/let local = try AttachmentCipher\.reencryptLocally\(/let local = (try? AttachmentCipher.reencryptLocally(/; s/chunkSize: a\.chunkSize\)\n/chunkSize: a.chunkSize)) ?? LocalAttachment(blob: blob, localKey: keys, plaintextHash: "", digest: Data(), size: a.size)\n/'
mutant "the transfer is not stopped at the limit" "$http" \
  's/guard data\.count < limit else \{ throw HTTPError\.tooLarge\(data\.count \+ 1\) \}/guard data.count < limit || limit >= 0 else { throw HTTPError.tooLarge(data.count + 1) }/'
mutant "a streamed response skips certificate pinning" "$http" \
  's/        await urlSession\(session, didReceive: challenge\)\n/        challenge.protectionSpace.serverTrust.map { (.useCredential, URLCredential(trust: \$0)) } ?? (.performDefaultHandling, nil)\n/'
echo "$killed mutants killed"
