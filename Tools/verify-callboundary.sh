#!/bin/sh
# Verifies the calling boundary (Verification/CallBoundary): what SignalCalling.xpc, the process
# that runs ringrtc and reads what remote peers send, can make the app do, and how the app's
# endpoint in it is lost and replaced; and their conformance with production RingRTC and
# RemoteCallEndpoint (Packages/SignalRingRTC), in one go:
#   1. no `sorry`, `admit`, axioms or other escape hatches in the Lean sources;
#   2. `lake build`: the kernel checks every proof;
#   3. the audit: the definitions, a hash of every definition the theorem statements depend on
#      (transitively), and the theorem statements must equal audit-expected.txt, and every
#      theorem may depend only on propext, Classical.choice and Quot.sound;
#   4. the explorer's verdict per property (fixed seed) must equal explore-expected.txt;
#   5. Swift: production RingRTC over production RemoteCallEndpoint against a hostile in-process
#      calling service (made-up events of every kind, the ids it chooses, lost endpoints), every
#      event against the Lean oracle (SEREIN_CALLBOUNDARY_CASES runs of 25 events, default 200);
#   6. mutants: each check weakened in production must make step 5 fail. Each is applied to the
#      working tree and the file restored afterwards (also on interrupt).
#
#   Tools/verify-callboundary.sh                    everything
#   SKIP_SWIFT=1 Tools/verify-callboundary.sh       only the Lean side
#   SKIP_MUTANTS=1 Tools/verify-callboundary.sh     without step 6
#   UPDATE_EXPECTED=1 Tools/verify-callboundary.sh  rewrite the expected files (review the diff!)
#   ONLY='<mutant name>' Tools/verify-callboundary.sh  step 6 for that mutant only
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
dir="$root/Verification/CallBoundary"
cd "$dir"

if ! command -v lake >/dev/null 2>&1 && [ -f "$HOME/.elan/env" ]; then . "$HOME/.elan/env"; fi
command -v lake >/dev/null 2>&1 || { echo "error: Lean is not installed (brew install elan-init)" >&2; exit 1; }
echo "toolchain: $(cat lean-toolchain)"

echo "== 1. escape hatches"
if grep -rnE '\b(sorry|admit|native_decide|implemented_by|extern|unsafe|axiom)\b|skipKernelTC|ofReduceBool|debug\.' \
     --include='*.lean' CallBoundary Main.lean CallBoundary.lean Audit.lean; then
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
grep -E ' (OK|FAIL)$' "$tmp/explore-raw" > "$tmp/explore"
if [ "${UPDATE_EXPECTED:-}" = 1 ]; then cp "$tmp/explore" explore-expected.txt; fi
if ! diff -u explore-expected.txt "$tmp/explore"; then
  echo "error: a property's verdict changed (review, then UPDATE_EXPECTED=1)" >&2; exit 1
fi
echo "$(grep -c ' OK$' explore-expected.txt) hold, $(grep -c ' FAIL$' explore-expected.txt) falsified"

if [ "${SKIP_SWIFT:-}" = 1 ]; then echo "== 5. Swift: skipped"; exit 0; fi
oracle="$dir/.lake/build/bin/oracle"
cd "$root/Packages/SignalRingRTC"

echo "== 5. Swift: runs against the oracle"
status=0
SEREIN_CALLBOUNDARY_ORACLE="$oracle" SEREIN_CALLBOUNDARY_CASES="${SEREIN_CALLBOUNDARY_CASES:-200}" \
  swift test --filter 'CallBoundaryConformanceTests' > "$tmp/swift" 2>&1 || status=$?
grep -E 'Test run|passed after|failed after|disagree|production |model |outputs seen' "$tmp/swift" | tail -40
[ "$status" -eq 0 ] || exit "$status"

if [ "${SKIP_MUTANTS:-}" = 1 ]; then echo "== 6. mutants: skipped"; exit 0; fi
echo "== 6. mutants: each planted bug must make production and the model disagree"
# mutant <name> <file> <perl substitution> [what must fail]
killed=0
mutant() {
  name="$1"; file="$root/$2"; expr="$3"; expect="${4:-disagree in run}"
  if [ -n "${ONLY:-}" ] && [ "$name" != "$ONLY" ]; then return; fi
  cp "$file" "$backup"
  mutated="$file"
  perl -0pi -e "$expr" "$file"
  if cmp -s "$file" "$backup"; then echo "error: mutant '$name' did not apply" >&2; exit 1; fi
  if [ "${DRY_RUN:-}" = 1 ]; then restore; echo "applies: $name"; return; fi
  SEREIN_CALLBOUNDARY_ORACLE="$oracle" SEREIN_CALLBOUNDARY_CASES=120 \
    swift test --filter 'CallBoundaryConformanceTests' > "$tmp/mutant" 2>&1 && survived=1 || survived=0
  restore
  if [ "$survived" = 1 ]; then echo "error: mutant '$name' survived the conformance tests" >&2; exit 1; fi
  if ! grep -qE "$expect" "$tmp/mutant"; then
    echo "error: mutant '$name' failed, but not as expected (did it build?)" >&2; tail -20 "$tmp/mutant" >&2; exit 1
  fi
  killed=$((killed + 1))
  echo "killed: $name — $(grep -m1 -E "$expect" "$tmp/mutant" | sed 's/^[^a-zA-Z]*//' | cut -c1-100)"
}
r=Packages/SignalRingRTC/Sources/SignalRingRTC/RingRTC.swift
v=Packages/SignalRingRTC/Sources/SignalRingRTC/RingRTC+Events.swift
k=Packages/SignalRingRTC/Sources/SignalRingRTC/Call.swift
g=Packages/SignalRingRTC/Sources/SignalRingRTC/GroupCall.swift
x=Packages/SignalRingRTC/Sources/CallXPC/CallXPC.swift
# What the service may ask for.
mutant "signalling goes to anyone" "$r" \
  's/if let call, call\.remoteUserId == remoteUserId, call\.callId == callId \{ return true \}\n        return callInfoByCallId\[callId\]\?\.peer == remoteUserId/return true/'
mutant "signalling to the call's peer under any call id" "$r" \
  's/call\.remoteUserId == remoteUserId, call\.callId == callId \{ return true \}/call.remoteUserId == remoteUserId { return true }/'
mutant "an incoming call needs no offer" "$v" \
  's/        guard callInfoByCallId\[callId\]\?\.peer == remoteUserId else \{[^\n]*\n//'
mutant "an incoming call for an offer from someone else" "$v" \
  's/guard callInfoByCallId\[callId\]\?\.peer == remoteUserId else/guard callInfoByCallId[callId] != nil else/'
mutant "a Signal group call's participants count as members" "$r" \
  's/case \.signalGroup: g\.members\.contains \{ \$0\.userId == recipient \}/case .signalGroup: g.members.contains { \$0.userId == recipient } || (g.remoteDeviceStates ?? []).contains { \$0.userId == recipient }/'
mutant "call messages to ourselves are dropped" "$r" \
  's/        if let selfUuid, recipient == selfUuid \{ return true \}\n//'
mutant "call messages go to anyone" "$v" \
  's/guard mayMessage\(recipient\) else/guard true else/'
mutant "group messages go to any group" "$r" \
  's/groupCallByClientId\.values\.contains \{ \$0\.groupId == groupId \} \|\| isRecent\(cancelledRings, groupId\)/!groupId.isEmpty/'
mutant "a group message's recipients are not checked" "$v" \
  's/guard mayMessageGroup\(groupId\), recipients\.allSatisfy\(mayMessage\) else/guard mayMessageGroup(groupId) else/'
mutant "rings come from anyone" "$v" \
  's/guard isRecent\(callMessageSenders, sender\) else/guard !sender.isEmpty else/'
# Generations and losses.
mutant "a call's commands ignore its generation" "$k" \
  's/_ = try\? endpoint\.command\(name, fields, generation: generation\)/_ = try? endpoint.command(name, fields, generation: nil)/'
mutant "a group call's commands ignore its generation" "$g" \
  's/_ = try\? endpoint\.command\(name, f, generation: generation\)/_ = try? endpoint.command(name, f, generation: nil)/'
mutant "the endpoint does not check generations" "$x" \
  's/        if let generation, generation != self\.generation \{ throw RingRTCError\.lost \}\n//'
mutant "a loss does not move the generation on" "$x" \
  's/            s\.generation \+= 1\n//'
mutant "a loss is never reported" "$x" \
  's/if s\.reported < s\.generation \{/if s.reported < s.generation \&\& s.closed {/'
mutant "a reported loss leaves the call running" "$r" \
  's/            call\.endedReason = \.internalFailure\n            call\.state = \.ended\n/            call.endedReason = .internalFailure\n/'
mutant "a reported loss leaves the group calls" "$r" \
  's/guard let g = groupCallByClientId\[id\], g\.generation <= generation else \{ continue \}/guard let g = groupCallByClientId[id], g.generation < generation else { continue }/'
mutant "a new endpoint does not get setSelfUuid" "$x" \
  's/for c in config \{ _ = try\? run\(id, c\.name, c\.fields\) \}/_ = config.count/'
echo "$killed mutants killed"
