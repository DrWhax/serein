#!/bin/sh
# Verifies the media-revocation model (Verification/Media) and its conformance with production
# (SignalCore's MediaAvailability, the app's applyMediaAvailability), in one go:
#   1. no `sorry`, `admit`, axioms or other escape hatches in the Lean sources;
#   2. `lake build`: the kernel checks every proof;
#   3. the audit: property definitions, a hash of every definition the theorem statements depend
#      on (transitively), and the theorem statements must equal audit-expected.txt, and every
#      theorem may depend only on propext, Classical.choice and Quot.sound;
#   4. the explorer's verdict per property (fixed seed) must equal explore-expected.txt;
#   5. Swift: MediaAvailability.permits / fetch on random states of a real database, and the
#      session's applyMediaAvailability on random viewers, against the Lean oracle
#      (SEREIN_MEDIA_CASES, default 3000 each); the export's re-check after the save panel;
#   6. mutants: each check weakened in production must make step 5 fail. Each is applied to the
#      working tree and the file restored afterwards (also on interrupt).
#
#   Tools/verify-media.sh                    everything
#   SKIP_SWIFT=1 Tools/verify-media.sh       only the Lean side
#   SKIP_MUTANTS=1 Tools/verify-media.sh     without step 6
#   UPDATE_EXPECTED=1 Tools/verify-media.sh  rewrite the expected files (review the diff!)
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
dir="$root/Verification/Media"
cd "$dir"

if ! command -v lake >/dev/null 2>&1 && [ -f "$HOME/.elan/env" ]; then . "$HOME/.elan/env"; fi
command -v lake >/dev/null 2>&1 || { echo "error: Lean is not installed (brew install elan-init)" >&2; exit 1; }
echo "toolchain: $(cat lean-toolchain)"

echo "== 1. escape hatches"
if grep -rnE '\b(sorry|admit|native_decide|implemented_by|extern|unsafe|axiom)\b|skipKernelTC|ofReduceBool|debug\.' \
     --include='*.lean' Media Main.lean Media.lean Audit.lean; then
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

echo "== 4. explorer verdicts (40000 random sessions of 50 events, seed 2026)"
./.lake/build/bin/oracle explore 2026 40000 50 > "$tmp/explore-raw"
grep -E '^(OK|FAIL)' "$tmp/explore-raw" | sed -E 's/^(OK|FAIL) ([A-Za-z0-9-]+).*/\2 \1/' > "$tmp/explore"
if [ "${UPDATE_EXPECTED:-}" = 1 ]; then cp "$tmp/explore" explore-expected.txt; fi
if ! diff -u explore-expected.txt "$tmp/explore"; then
  echo "error: a property's verdict changed (review, then UPDATE_EXPECTED=1)" >&2; exit 1
fi
echo "$(grep -c ' OK$' explore-expected.txt) hold, $(grep -c ' FAIL$' explore-expected.txt) falsified"

if [ "${SKIP_SWIFT:-}" = 1 ]; then echo "== 5. Swift: skipped"; exit 0; fi
oracle="$dir/.lake/build/bin/oracle"

# swift_tests <package dir> <filter> <output> [cases]
swift_tests() {
  (cd "$root/$1" && SEREIN_MEDIA_ORACLE="$oracle" SEREIN_MEDIA_CASES="${4:-${SEREIN_MEDIA_CASES:-3000}}" swift test --filter "$2") > "$3" 2>&1
}
echo "== 5. Swift: decisions and viewers against the oracle, the export's re-check"
status=0
swift_tests Packages/SignalCore 'MediaAvailabilityConformanceTests' "$tmp/core" || status=$?
grep -E 'Test run|passed after|failed after|disagree|model ' "$tmp/core" | tail -10
[ "$status" -eq 0 ] || exit "$status"
swift_tests App/SignalSafe 'MediaApplyConformanceTests' "$tmp/app" || status=$?
grep -E 'Test run|passed after|failed after|disagree|model ' "$tmp/app" | tail -10
[ "$status" -eq 0 ] || exit "$status"

if [ "${SKIP_MUTANTS:-}" = 1 ]; then echo "== 6. mutants: skipped"; exit 0; fi
echo "== 6. mutants: each planted bug must make step 5 fail"
# mutant <name> <file> <perl substitution> <package dir> <test filter> [what must fail]
mutant() {
  name="$1"; file="$root/$2"; expr="$3"; package="$4"; filter="$5"; expect="${6:-disagree.* at step}"
  cp "$file" "$backup"
  mutated="$file"
  perl -0pi -e "$expr" "$file"
  if cmp -s "$file" "$backup"; then echo "error: mutant '$name' did not apply" >&2; exit 1; fi
  swift_tests "$package" "$filter" "$tmp/mutant" 1000 && survived=1 || survived=0
  restore
  if [ "$survived" = 1 ]; then echo "error: mutant '$name' survived" >&2; exit 1; fi
  if ! grep -qE "$expect" "$tmp/mutant"; then
    echo "error: mutant '$name' failed, but not as expected (did it build?)" >&2; tail -20 "$tmp/mutant" >&2; exit 1
  fi
  echo "killed: $name — $(grep -m1 -E "$expect" "$tmp/mutant" | sed 's/^[^a-zA-Z]*//' | cut -c1-100)"
}
core=Packages/SignalCore
avail=$core/Sources/SignalCore/Attachments/MediaAvailability.swift
app=App/SignalSafe
viewers=$app/Sources/SignalSafe/MediaAvailability.swift
mutant "permits ignores which message" "$avail" \
  's/AND \(\? IS NULL OR a\.messageId = \?\)/AND (? IS NULL OR ? IS NOT NULL)/' "$core" 'MediaAvailabilityConformanceTests'
mutant "permits ignores erasure" "$avail" \
  's/AND \(\? IS NULL OR a\.messageId = \?\) AND COALESCE\(m\.json ->> .\$\.isErased., 0\) = 0/AND (? IS NULL OR a.messageId = ?)/' "$core" 'MediaAvailabilityConformanceTests'
mutant "permits ignores expiry" "$avail" \
  's/AND \(m\.expiresAt IS NULL OR m\.expiresAt > \?\)\)\n/AND (? IS NOT NULL))\n/' "$core" 'MediaAvailabilityConformanceTests'
mutant "fetch ignores erasure" "$avail" \
  's/WHERE COALESCE\(m\.json ->> .\$\.isErased., 0\) = 0 AND \(m\.expiresAt/WHERE (m.expiresAt/' "$core" 'MediaAvailabilityConformanceTests'
mutant "fetch ignores expiry" "$avail" \
  's/AND \(m\.expiresAt IS NULL OR m\.expiresAt > \?\)\n(\s*""", arguments: \[now\]\))/AND (? IS NOT NULL)\n$1/' "$core" 'MediaAvailabilityConformanceTests'
mutant "the export does not check again after the panel" "$avail" \
  's/guard try permits\(db, path: path, messageId: messageId\) else/guard !path.isEmpty else/' "$core" 'MediaAvailabilityConformanceTests' 'Test exportRechecksTheMessage\(\) (recorded an issue|failed)'
mutant "the lightbox is kept by any message's reference to its file" "$viewers" \
  's/a\.path\.map \{ state\.messagePaths\[box\.messageId\]\?\.contains\(\$0\) != true \} \?\? false/a.path.map { !state.paths.contains(\$0) } ?? false/' "$app" 'MediaApplyConformanceTests'
mutant "the lightbox ignores whether its message is live" "$viewers" \
  's/!state\.messageIds\.contains\(box\.messageId\) \|\| //' "$app" 'MediaApplyConformanceTests'
mutant "the inline video is kept by any message's reference" "$viewers" \
  's/state\.messagePaths\[video\.messageId\]\?\.contains\(video\.path\) != true/!state.paths.contains(video.path)/' "$app" 'MediaApplyConformanceTests'
mutant "the voice note is kept by any message's reference" "$viewers" \
  's/activeAudioPath\.map\(\{ state\.messagePaths\[id\]\?\.contains\(\$0\) == true \}\)/activeAudioPath.map({ state.paths.contains(\$0) \&\& !id.isEmpty })/' "$app" 'MediaApplyConformanceTests'
mutant "decoded pixels outlive the last reference" "$viewers" \
  's/for \(key, path\) in imagePaths where !state\.paths\.contains\(path\)/for (key, path) in imagePaths where path.isEmpty/' "$app" 'MediaApplyConformanceTests'
echo "11 mutants killed"
