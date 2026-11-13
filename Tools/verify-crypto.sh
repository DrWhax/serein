#!/bin/sh
# Verifies the crypto-formats model (Verification/Crypto) and its conformance with the production
# SignalCore, in one go:
#   1. no `sorry`, `admit`, axioms or other escape hatches in the Lean sources;
#   2. `lake build`: the kernel checks every proof;
#   3. the audit: property definitions, a hash of every definition the theorem statements depend
#      on (transitively), and the theorem statements must equal audit-expected.txt, and every
#      theorem may depend only on propext, Classical.choice and Quot.sound;
#   4. the explorer's verdict per property (fixed seed) must equal explore-expected.txt;
#   5. Swift: transport padding, every key derivation, profile padding, and the six decryptions
#      (storage manifests and records, profile fields, stickers, provisioning, device names) on
#      values sealed under right, near and unrelated keys, against the Lean oracle
#      (SEREIN_CRYPTO_CASES, default 3000);
#   6. mutants: each check weakened in production must make step 5 fail. Each is applied to the
#      working tree and the file restored afterwards (also on interrupt).
#
#   Tools/verify-crypto.sh                    everything
#   SKIP_SWIFT=1 Tools/verify-crypto.sh       only the Lean side
#   SKIP_MUTANTS=1 Tools/verify-crypto.sh     without step 6
#   UPDATE_EXPECTED=1 Tools/verify-crypto.sh  rewrite the expected files (review the diff!)
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
dir="$root/Verification/Crypto"
cd "$dir"

if ! command -v lake >/dev/null 2>&1 && [ -f "$HOME/.elan/env" ]; then . "$HOME/.elan/env"; fi
command -v lake >/dev/null 2>&1 || { echo "error: Lean is not installed (brew install elan-init)" >&2; exit 1; }
echo "toolchain: $(cat lean-toolchain)"

echo "== 1. escape hatches"
if grep -rnE '\b(sorry|admit|native_decide|implemented_by|extern|unsafe|axiom)\b|skipKernelTC|ofReduceBool|debug\.' \
     --include='*.lean' Crypto Main.lean Crypto.lean Audit.lean; then
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

echo "== 4. explorer verdicts (40000 random inputs per property, seed 2026)"
./.lake/build/bin/oracle explore 2026 40000 > "$tmp/explore-raw"
grep -E '^(OK|FAIL)' "$tmp/explore-raw" | sed -E 's/^(OK|FAIL) ([A-Za-z0-9-]+).*/\2 \1/' > "$tmp/explore"
if [ "${UPDATE_EXPECTED:-}" = 1 ]; then cp "$tmp/explore" explore-expected.txt; fi
if ! diff -u explore-expected.txt "$tmp/explore"; then
  echo "error: a property's verdict changed (review, then UPDATE_EXPECTED=1)" >&2; exit 1
fi
echo "$(grep -c ' OK$' explore-expected.txt) hold, $(grep -c ' FAIL$' explore-expected.txt) falsified (the four limits)"

if [ "${SKIP_SWIFT:-}" = 1 ]; then echo "== 5. Swift: skipped"; exit 0; fi
oracle="$dir/.lake/build/bin/oracle"
cd "$root/Packages/SignalCore"

echo "== 5. Swift: production against the oracle"
status=0
SEREIN_CRYPTO_ORACLE="$oracle" SEREIN_CRYPTO_CASES="${SEREIN_CRYPTO_CASES:-3000}" \
  swift test --filter 'CryptoConformanceTests' > "$tmp/swift" 2>&1 || status=$?
grep -E 'Test run|passed after|failed after|disagree|model verdicts' "$tmp/swift" | tail -40
[ "$status" -eq 0 ] || exit "$status"

if [ "${SKIP_MUTANTS:-}" = 1 ]; then echo "== 6. mutants: skipped"; exit 0; fi
echo "== 6. mutants: each planted bug must make production and the model disagree"
# mutant <name> <file> <perl substitution> [what must fail]
killed=0
mutant() {
  name="$1"; file="$root/$2"; expr="$3"; expect="${4:-disagree: |Fatal error|unexpected signal|exited with|crashed|swiftpm-testing-helper}"
  cp "$file" "$backup"
  mutated="$file"
  perl -0pi -e "$expr" "$file"
  if cmp -s "$file" "$backup"; then echo "error: mutant '$name' did not apply" >&2; exit 1; fi
  if [ "${DRY_RUN:-}" = 1 ]; then restore; echo "applies: $name"; return; fi
  SEREIN_CRYPTO_ORACLE="$oracle" SEREIN_CRYPTO_CASES=1500 \
    swift test --filter 'CryptoConformanceTests' > "$tmp/mutant" 2>&1 && survived=1 || survived=0
  restore
  if [ "$survived" = 1 ]; then echo "error: mutant '$name' survived the conformance tests" >&2; exit 1; fi
  if ! grep -qE "$expect" "$tmp/mutant"; then
    echo "error: mutant '$name' failed, but not as expected (did it build?)" >&2; tail -20 "$tmp/mutant" >&2; exit 1
  fi
  killed=$((killed + 1))
  echo "killed: $name — $(grep -m1 -E "$expect" "$tmp/mutant" | sed 's/^[^a-zA-Z]*//' | cut -c1-110)"
}
src=Packages/SignalCore/Sources/SignalCore
send=$src/Messaging/MessageSender.swift
recv=$src/Messaging/MessageReceiver.swift
storage=$src/StorageService/StorageService.swift
prov=$src/Provisioning/ProvisioningCipher.swift
profile=$src/Profiles/ProfileService.swift
sticker=$src/Stickers/StickerService.swift
cipher=$src/Attachments/AttachmentCipher.swift
tables=$src/StorageService/StorageRecords+Tables.swift

# Transport padding.
mutant "the padding block is 64 bytes" "$send" 's/static let paddingBlock = 80/static let paddingBlock = 64/'
mutant "the length leaves no room for the extra byte" "$send" 's/let withTerminator = plaintext\.count \+ 2/let withTerminator = plaintext.count + 1/'
mutant "the terminator is a zero" "$send" 's/out\.append\(0x80\)/out.append(0x00)/'
mutant "unpad takes any non-zero byte as the terminator" "$recv" 's/if b == 0x80 \{ return data\[/if b != 0 { return data[/'
mutant "unpad hands back input with no terminator (upstream's behaviour)" "$recv" \
  's/            end -= 1\n        \}\n        throw ReceiveError\.invalidPadding/            end -= 1\n        }\n        return data/'
mutant "unpad keeps the terminator" "$recv" 's/return data\[data\.startIndex\.\.<\(end - 1\)\]/return data[data.startIndex..<end]/'

# Key separation.
mutant "manifest keys ignore all but the last three digits" "$storage" 's/Data\("Manifest_\\\(version\)"\.utf8\)/Data("Manifest_\\(version % 1000)".utf8)/'
mutant "legacy item keys use the first 8 bytes of the id" "$storage" 's/Data\("Item_\\\(raw\.base64EncodedString\(\)\)"\.utf8\)/Data("Item_\\(raw.prefix(8).base64EncodedString())".utf8)/'
mutant "record-IKM item keys leave out the id" "$storage" 's/info: Data\("20240801_SIGNAL_STORAGE_SERVICE_ITEM_"\.utf8\) \+ raw\)/info: Data("20240801_SIGNAL_STORAGE_SERVICE_ITEM_".utf8))/'
mutant "an empty record IKM is used as one" "$storage" 's/if let recordIkm, !recordIkm\.isEmpty \{/if let recordIkm {/'
mutant "the sticker pack HKDF has another salt" "$sticker" 's/info: Data\("Sticker Pack"\.utf8\), salt: Data\(count: 32\)\)/info: Data("Sticker Pack".utf8), salt: Data(repeating: 1, count: 32))/'
mutant "a call link room id comes from the whole root key" "$tables" 's/ikm: rootKey\.prefix\(16\), info:/ikm: rootKey, info:/'
mutant "the provisioning MAC is keyed by the AES half" "$prov" 's/hmacSHA256\(key: keys\.suffix\(32\), Data\(signed\)\)/hmacSHA256(key: keys.prefix(32), Data(signed))/'
mutant "device names are checked with the cipher key" "$prov" \
  's/(let plaintext = try SignalCrypto\.aes256CTR\(key: cipherKey, iv: Data\(count: 16\), proto\.ciphertext\)\n        let key1 = SignalCrypto\.hmacSHA256\(key: master, Data\(")auth/$1cipher/'

# Profile padding.
mutant "the last length that fits, not the first" "$profile" 's/lengths\.first\(where: \{ item\.count <= \$0 \}\)/lengths.last(where: { item.count <= \$0 })/'
mutant "a name loses the NUL between its parts" "$profile" 's/plain\.append\(0\); plain\.append\(contentsOf: family\.utf8\)/plain.append(contentsOf: family.utf8)/'
mutant "a profile field of nonce and tag alone is accepted" "$profile" 's/guard data\.count >= 12 \+ 16 \+ 1 else/guard data.count >= 12 + 16 else/'

# Encrypted formats.
mutant "the manifest's own version is not checked" "$storage" \
  's/guard record\.version == manifest\.version else/guard record.version == manifest.version || record.sourceDevice >= 0 else/'
mutant "the manifest we already have is accepted again" "$storage" 's/if let current, version <= current, version != 0/if let current, version < current, version != 0/'
mutant "items we did not ask for are accepted" "$storage" 's/guard items\.allSatisfy\(\{ wanted\.contains\(\$0\.key\) \}\) else/guard items.allSatisfy({ wanted.contains(\$0.key) || !\$0.key.isEmpty }) else/'
mutant "a sticker is decrypted before its MAC is checked" "$cipher" \
  's/        guard SignalCrypto\.constantTimeEqual\(mac, Data\(blob\.suffix\(32\)\)\) else \{ throw AttachmentError\.badMAC \}\n        return try (SignalCrypto\.aes256CBCDecrypt\(key: keys\.prefix\(32\), iv: Data\(body\.prefix\(16\)\), Data\(body\.dropFirst\(16\)\)\))/        let plain = try $1\n        guard SignalCrypto.constantTimeEqual(mac, Data(blob.suffix(32))) else { throw AttachmentError.badMAC }\n        return plain/'
mutant "a provisioning envelope is decrypted before its MAC is checked" "$prov" \
  's/(        guard SignalCrypto\.constantTimeEqual\(SignalCrypto\.hmacSHA256\(key: keys\.suffix\(32\), Data\(signed\)\), Data\(body\.suffix\(32\)\)\) else \{\n            throw ProvisioningError\.badMAC\n        \}\n)(        let iv = .*\n        let ciphertext = .*\n        let plaintext = try SignalCrypto\.aes256CBCDecrypt\(key: keys\.prefix\(32\), iv: iv, ciphertext\)\n)/$2$1/'
mutant "the provisioning version is not checked" "$prov" 's/guard body\.first == 1 else/guard body.first == 1 || !body.isEmpty else/'
mutant "a device name's synthetic IV is not checked" "$prov" \
  's/hmacSHA256\(key: key1, plaintext\)\.prefix\(16\), proto\.syntheticIv\) else/hmacSHA256(key: key1, plaintext).prefix(16), proto.syntheticIv) || !plaintext.isEmpty else/'
echo "$killed mutants killed"
