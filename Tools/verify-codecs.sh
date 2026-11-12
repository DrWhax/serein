#!/bin/sh
# Verifies the codec-components model (Verification/Codecs) and its conformance with the production
# SignalCodecs, in one go:
#   1. no `sorry`, `admit`, axioms or other escape hatches in the Lean sources;
#   2. `lake build`: the kernel checks every proof;
#   3. the audit: property definitions, a hash of every definition the theorem statements depend
#      on (transitively), and the theorem statements must equal audit-expected.txt, and every
#      theorem may depend only on propext, Classical.choice and Quot.sound;
#   4. the explorer's verdict per property (fixed seed) must equal explore-expected.txt;
#   5. Swift: SignalCodecs' byte cursor, parser combinators, MP4 box grammar and bit reader on
#      random grammars, inputs and box streams, against the Lean oracle (SEREIN_CODECS_CASES,
#      default 5000);
#   6. mutants: each check weakened in production must make step 5 fail. Each is applied to the
#      working tree and the file restored afterwards (also on interrupt).
#
#   Tools/verify-codecs.sh                    everything
#   SKIP_SWIFT=1 Tools/verify-codecs.sh       only the Lean side
#   SKIP_MUTANTS=1 Tools/verify-codecs.sh     without step 6
#   UPDATE_EXPECTED=1 Tools/verify-codecs.sh  rewrite the expected files (review the diff!)
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
dir="$root/Verification/Codecs"
cd "$dir"

if ! command -v lake >/dev/null 2>&1 && [ -f "$HOME/.elan/env" ]; then . "$HOME/.elan/env"; fi
command -v lake >/dev/null 2>&1 || { echo "error: Lean is not installed (brew install elan-init)" >&2; exit 1; }
echo "toolchain: $(cat lean-toolchain)"

echo "== 1. escape hatches"
if grep -rnE '\b(sorry|admit|native_decide|implemented_by|extern|unsafe|axiom)\b|skipKernelTC|ofReduceBool|debug\.' \
     --include='*.lean' Codecs Main.lean Codecs.lean Audit.lean; then
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

echo "== 4. explorer verdicts (40000 random grammars and box streams, seed 2026)"
./.lake/build/bin/oracle explore 2026 40000 40 | grep -E '^(OK|FAIL)' | sed -E 's/^(OK|FAIL) ([A-Za-z0-9-]+).*/\2 \1/' > "$tmp/explore"
if [ "${UPDATE_EXPECTED:-}" = 1 ]; then cp "$tmp/explore" explore-expected.txt; fi
if ! diff -u explore-expected.txt "$tmp/explore"; then
  echo "error: a property's verdict changed (review, then UPDATE_EXPECTED=1)" >&2; exit 1
fi
echo "$(grep -c ' OK$' explore-expected.txt) hold, $(grep -c ' FAIL$' explore-expected.txt) falsified"

if [ "${SKIP_SWIFT:-}" = 1 ]; then echo "== 5. Swift: skipped"; exit 0; fi
oracle="$dir/.lake/build/bin/oracle"
cd "$root/Packages/SignalCodecs"

echo "== 5. Swift: runs against the oracle"
status=0
SEREIN_CODECS_ORACLE="$oracle" SEREIN_CODECS_CASES="${SEREIN_CODECS_CASES:-5000}" \
  swift test --filter 'CodecConformanceTests' > "$tmp/swift" 2>&1 || status=$?
grep -E 'Test run|passed after|failed after|disagree|model ' "$tmp/swift" | tail -40
[ "$status" -eq 0 ] || exit "$status"

if [ "${SKIP_MUTANTS:-}" = 1 ]; then echo "== 6. mutants: skipped"; exit 0; fi
echo "== 6. mutants: each planted bug must make production and the model disagree"
# mutant <name> <file> <perl substitution> [what must fail]
killed=0
mutant() {
  name="$1"; file="$root/$2"; expr="$3"; expect="${4:-disagree.* at step|swiftpm-testing-helper|Fatal error|unexpected signal}"
  cp "$file" "$backup"
  mutated="$file"
  perl -0pi -e "$expr" "$file"
  if cmp -s "$file" "$backup"; then echo "error: mutant '$name' did not apply" >&2; exit 1; fi
  if [ "${DRY_RUN:-}" = 1 ]; then restore; echo "applies: $name"; return; fi
  SEREIN_CODECS_ORACLE="$oracle" SEREIN_CODECS_CASES=2000 \
    swift test --filter 'CodecConformanceTests' > "$tmp/mutant" 2>&1 && survived=1 || survived=0
  restore
  if [ "$survived" = 1 ]; then echo "error: mutant '$name' survived the conformance tests" >&2; exit 1; fi
  if ! grep -qE "$expect" "$tmp/mutant"; then
    echo "error: mutant '$name' failed, but not as expected (did it build?)" >&2; tail -20 "$tmp/mutant" >&2; exit 1
  fi
  killed=$((killed + 1))
  echo "killed: $name — $(grep -m1 -E "$expect" "$tmp/mutant" | sed 's/^[^a-zA-Z]*//' | cut -c1-100)"
}
slice=Packages/SignalCodecs/Sources/CodecCore/Grammar/ByteSlice.swift
parser=Packages/SignalCodecs/Sources/CodecCore/Grammar/Parser.swift
box=Packages/SignalCodecs/Sources/ContainerMP4/MP4Grammar.swift
bits=Packages/SignalCodecs/Sources/CodecCore/Bits/MSBBitReader.swift
mutant "a read checks the storage, not its region" "$slice" \
  's/if n < 0 \|\| n > end - position \{/if n < 0 || n > storage.count - position {/' 'disagree.* at step|Fatal error|unexpected signal|exited with|crashed|swiftpm-testing-helper'
mutant "a negative length is accepted" "$slice" \
  's/if n < 0 \|\| n > end - position \{/if n > end - position {/' 'disagree.* at step|Fatal error|unexpected signal|exited with|crashed|swiftpm-testing-helper'
mutant "u16le reads big-endian" "$slice" \
  's/return UInt16\(storage\[position \+ 1\]\) << 8 \| UInt16\(storage\[position\]\)/return UInt16(storage[position]) << 8 | UInt16(storage[position + 1])/'
mutant "u64be swaps its halves" "$slice" \
  's/return UInt64\(hi\) << 32 \| UInt64\(lo\)/return UInt64(lo) << 32 | UInt64(hi)/'
mutant "a literal never mismatches" "$slice" \
  's/where storage\[position \+ i\] != b \{/where storage[position + i] != b \&\& i < 0 {/'
mutant "rest leaves the cursor where it was" "$slice" \
  's/defer \{ position = end \}/defer { position = max(position, start) }/'
mutant "a region need not be consumed completely" "$parser" \
  's/let slice = try c\.bytes\(length, name\)\n            return try body\.parseComplete\(slice\)/let slice = try c.bytes(length, name)\n            return try body.parsePrefix(slice).0/'
mutant "a length prefix ignores its limit" "$parser" \
  's/guard raw >= 0, raw <= L\(clamping: maxLength\) else/guard raw >= 0 else/'
mutant "a length-prefixed body reads past its length" "$parser" \
  's/let slice = try c\.bytes\(Int\(raw\), name\)\n            return try body\.parseComplete\(slice\)/_ = raw\n            return try body.parsePrefix(c.rest()).0/'
mutant "a repeat count may exceed its limit" "$parser" \
  's/guard count <= maxCount else/guard count <= maxCount || maxCount >= 0 else/'
mutant "repeat-to-end ignores its limit" "$parser" \
  's/guard out\.count < maxCount else/guard out.count < maxCount || maxCount >= 0 else/'
mutant "repeat-to-end accepts a rule that consumes nothing" "$parser" \
  's/if c\.position == before \{ throw/if c.position == before \&\& before < 0 { throw/'
mutant "a choice reports the nearest failure" "$parser" \
  's/if best == nil \|\| error\.offset > best!\.offset/if best == nil || error.offset < best!.offset/'
mutant "a box smaller than its header is accepted" "$box" \
  's/guard size >= UInt64\(header\) else/guard size >= UInt64(header) || size > 0 else/'
mutant "size 0 is accepted inside a container" "$box" \
  's/guard topLevel else \{ throw c\.fail\("box\.size", \.invalid\("size 0 inside a container"\)\) \}/_ = topLevel/'
mutant "a uuid user type is not skipped" "$box" \
  's/_ = try c\.bytes\(16, "box\.usertype"\)\n                header \+= 16/header += 16/'
mutant "the truncated mdat is not counted" "$box" \
  's/                    count \+= 1\n                    guard count <= limits\.maxBoxes else \{ throw c\.fail\("box", \.limitExceeded\("more than \\\(limits\.maxBoxes\) boxes"\)\) \}\n                    out\.append/                    out.append/'
mutant "the box budget is not checked" "$box" \
  's/guard count <= limits\.maxBoxes else \{ throw c\.fail\("box", \.limitExceeded\("more than \\\(limits\.maxBoxes\) boxes"\)\) \}\n            out\.append/guard count <= limits.maxBoxes || count > 0 else { throw c.fail("box", .limitExceeded("budget")) }\n            out.append/'
mutant "the fail policy fills zeros" "$bits" \
  's/guard policy == \.zeroFill else \{/guard policy == .zeroFill || n > 0 else {/'
mutant "zero fill gives one bit too few" "$bits" \
  's/count = n  \/\/ missing bits are zeros/count = n - 1  \/\/ missing bits are zeros/' 'disagree.* at step|Fatal error|unexpected signal|exited with|crashed|swiftpm-testing-helper'
mutant "align drops a whole byte more" "$bits" \
  's/let drop = count % 8\n/let drop = count % 8 + (count >= 8 ? 8 : 0)\n/'
echo "$killed mutants killed"
