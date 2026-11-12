#!/bin/sh
# Verifies the broker model (Verification/Broker): the app's channels to its sandboxed helpers,
# and their conformance with production MediaXPCInterface, in one go:
#   1. no `sorry`, `admit`, axioms or other escape hatches in the Lean sources;
#   2. `lake build`: the kernel checks every proof;
#   3. the audit: property definitions, a hash of every definition the theorem statements depend
#      on (transitively), and the theorem statements must equal audit-expected.txt, and every
#      theorem may depend only on propext, Classical.choice and Quot.sound;
#   4. the explorer's verdict per property (fixed seed) must equal explore-expected.txt;
#   5. Swift: production MediaXPCClient and XPCChannel against hostile in-process helpers (any
#      reply to any message, again, late, on ended sessions; crashes; unsolicited messages;
#      timeouts; cancelled callers), every event against the Lean oracle; and the GIF URL and
#      parser-endpoint flows (SEREIN_BROKER_CASES, default 3000);
#   6. mutants: each check weakened in production must make step 5 fail. Each is applied to the
#      working tree and the file restored afterwards (also on interrupt).
#
#   Tools/verify-broker.sh                    everything
#   SKIP_SWIFT=1 Tools/verify-broker.sh       only the Lean side
#   SKIP_MUTANTS=1 Tools/verify-broker.sh     without step 6
#   UPDATE_EXPECTED=1 Tools/verify-broker.sh  rewrite the expected files (review the diff!)
#   ONLY='<mutant name>' Tools/verify-broker.sh  step 6 for that mutant only
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
dir="$root/Verification/Broker"
cd "$dir"

if ! command -v lake >/dev/null 2>&1 && [ -f "$HOME/.elan/env" ]; then . "$HOME/.elan/env"; fi
command -v lake >/dev/null 2>&1 || { echo "error: Lean is not installed (brew install elan-init)" >&2; exit 1; }
echo "toolchain: $(cat lean-toolchain)"

echo "== 1. escape hatches"
if grep -rnE '\b(sorry|admit|native_decide|implemented_by|extern|unsafe|axiom)\b|skipKernelTC|ofReduceBool|debug\.' \
     --include='*.lean' Broker Main.lean Broker.lean Audit.lean; then
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
cd "$root/Packages/SignalMediaService"

echo "== 5. Swift: runs against the oracle"
status=0
SEREIN_BROKER_ORACLE="$oracle" SEREIN_BROKER_CASES="${SEREIN_BROKER_CASES:-3000}" \
  swift test --filter 'BrokerConformanceTests' > "$tmp/swift" 2>&1 || status=$?
grep -E 'Test run|passed after|failed after|disagree|model ' "$tmp/swift" | tail -40
[ "$status" -eq 0 ] || exit "$status"

if [ "${SKIP_MUTANTS:-}" = 1 ]; then echo "== 6. mutants: skipped"; exit 0; fi
echo "== 6. mutants: each planted bug must make production and the model disagree"
# mutant <name> <file> <perl substitution> [what must fail]
killed=0
mutant() {
  name="$1"; file="$root/$2"; expr="$3"; expect="${4:-disagree.* at step}"
  if [ -n "${ONLY:-}" ] && [ "$name" != "$ONLY" ]; then return; fi
  cp "$file" "$backup"
  mutated="$file"
  perl -0pi -e "$expr" "$file"
  if cmp -s "$file" "$backup"; then echo "error: mutant '$name' did not apply" >&2; exit 1; fi
  if [ "${DRY_RUN:-}" = 1 ]; then restore; echo "applies: $name"; return; fi
  SEREIN_BROKER_ORACLE="$oracle" SEREIN_BROKER_CASES=2000 \
    swift test --filter 'BrokerConformanceTests' > "$tmp/mutant" 2>&1 && survived=1 || survived=0
  restore
  if [ "$survived" = 1 ]; then echo "error: mutant '$name' survived the conformance tests" >&2; exit 1; fi
  if ! grep -qE "$expect" "$tmp/mutant"; then
    echo "error: mutant '$name' failed, but not as expected (did it build?)" >&2; tail -20 "$tmp/mutant" >&2; exit 1
  fi
  killed=$((killed + 1))
  echo "killed: $name — $(grep -m1 -E "$expect" "$tmp/mutant" | sed 's/^[^a-zA-Z]*//' | cut -c1-100)"
}
t=Packages/SignalMediaService/Sources/MediaXPCInterface/XPCTransport.swift
c=Packages/SignalMediaService/Sources/MediaXPCInterface/MediaXPC.swift
q=Packages/SignalMediaService/Sources/MediaXPCInterface/Containment.swift
w=Packages/SignalMediaService/Sources/MediaXPCInterface/WebServices.swift
mutant "a cancelled caller keeps waiting" "$t" \
  's/\} onCancel: \{\n            outcome\.finish\(\.failure\(CancellationError\(\)\)\)\n        \}/} onCancel: {\n        }/'
mutant "the watchdog does not end the request" "$t" \
  's/outcome\.finish\(\.failure\(XPCServiceError\.timedOut\)\)/_ = outcome/'
mutant "a reply after the end is dropped" "$t" \
  's/if !outcome\.finish\(received\.flatMap \{ m in Result \{ try read\(m\) \} \}\), let late, case \.success\(let m\) = received \{ late\(m\) \}/_ = outcome.finish(received.flatMap { m in Result { try read(m) } })/'
mutant "an old session's end drops the live one" "$t" \
  's/guard let live = st\.live, live\.id == id else \{ return nil \}/guard let live = st.live else { return nil }/' \
  "an old session's notice dropped the live one"
mutant "the endpoint entry is read whatever its XPC type" "$t" \
  's/if Self\.entry\(dictionary, Self\.endpointKey, "OS_xpc_endpoint"\) != nil \{/do {/'
mutant "one crash strikes an input once per request" "$q" \
  's/guard s\.lostOn\[key, default: \[\]\]\.insert\(session\)\.inserted else \{ return \}/s.lostOn[key, default: []].insert(session)/'
mutant "every crash counts as the same one" "$q" \
  's/s\.lostOn\[key, default: \[\]\]\.insert\(session\)\.inserted/s.lostOn[key, default: []].insert(session \& 0).inserted/'
mutant "an ended session strikes nothing" "$q" \
  's/            s\.add\(key, 1, capacity: capacity\)/            s.add(key, 0, capacity: capacity)/'
mutant "a timeout does not quarantine" "$c" \
  's/quarantine\.strike\(key, MediaQuarantine\.strikesToQuarantine\)/quarantine.strike(key, 1)/'
mutant "a quarantined input is sent" "$c" \
  's/if let key, quarantine\.isQuarantined\(key\) \{/if let key, quarantine.isQuarantined(key), request.isVoiceNote {/'
mutant "a video session opened too late is kept" "$c" \
  's/\{ \[weak self\] o in self\?\.release\(\.closeVideo\(o\.session\)\) \}/{ _ in }/'
mutant "a video session whose answer is refused is kept" "$c" \
  's/\} catch \{\n            release\(\.closeVideo\(o\.session\)\)\n            throw error/} catch {\n            throw error/'
mutant "a recording opened too late is kept" "$c" \
  's/\{ \[weak self\] id in self\?\.release\(\.cancelVoiceNote\(id\)\) \}/{ _ in }/'
mutant "a recording from the microphone opened too late is kept" "$c" \
  's/\(\.recordVoiceNote, UUID\.self\) \{ \[weak self\] id in self\?\.release\(\.cancelVoiceNote\(id\)\) \}/(.recordVoiceNote, UUID.self)/'
mutant "every release goes to the decoder" "$c" \
  's/Task \{ _ = try\? await self\.callData\(request\) \}/Task { _ = try? await self.channel.send(try MediaXPCWire.encode(request), maxReply: request.maxReplyBytes) }/'
mutant "a thumbnail is checked against a fixed size" "$c" \
  's/Thumbnail\.self\)\.validated\(size: size\)/Thumbnail.self).validated(size: 64)/'
mutant "the parser's answer may carry a payload" "$w" \
  's/try await parser\.request\(XPCMessage\(\), maxReply: 0\)/try await parser.request(XPCMessage(), maxReply: 1)/'
mutant "a GIF file is fetched from any URL" "$w" \
  's/guard PaginatedGifResults\.isGiphyCdnURL\(url\) else \{ throw MediaProcessingError\.unsupportedFormat \}\n//'
mutant "a GIF URL with a port counts as the CDN" "$w" \
  's/c\.port == nil, c\.user == nil/c.user == nil/'
mutant "a page's preview URLs are not checked" "$w" \
  's/ok\(\$0\.previewMedia\) && ok\(\$0\.attachmentMedia\)/ok(\$0.attachmentMedia)/'
echo "$killed mutants killed"
