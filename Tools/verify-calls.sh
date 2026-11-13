#!/bin/sh
# Verifies the call/capture lifecycle model (Verification/CallCapture) and its conformance with
# the production Swift, in one go:
#   1. no `sorry`, `admit`, axioms or other escape hatches in the Lean sources;
#   2. `lake build`: the kernel checks every proof and counterexample;
#   3. the audit: the property definitions, a hash of every definition the theorem statements
#      depend on (transitively), and the theorem statements must equal audit-expected.txt, and
#      every theorem may depend only on propext, Classical.choice and Quot.sound;
#   4. the explorer's verdict per property and schedule (fixed seed) must equal explore-expected.txt;
#   5. Swift: production SignalSession, CaptureReconciler, ScreenShareCapture and their callbacks
#      against the Lean oracle, step by step, on the regression traces and random traces
#      (SEREIN_CALL_TRACES per generator, default 2000), plus regression tests for D1–D5;
#   6. mutants: production with a callback wired to the wrong token, each D1–D5 fix undone, and
#      two other planted bugs must make step 5 report a disagreement. Each mutant is applied to the working tree and the
#      file restored afterwards (also on interrupt).
#
#   Tools/verify-calls.sh                    everything
#   SKIP_SWIFT=1 Tools/verify-calls.sh       only the Lean side
#   SKIP_MUTANTS=1 Tools/verify-calls.sh     without step 6
#   UPDATE_EXPECTED=1 Tools/verify-calls.sh  rewrite the expected files (review the diff!)
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
dir="$root/Verification/CallCapture"
cd "$dir"

if ! command -v lake >/dev/null 2>&1 && [ -f "$HOME/.elan/env" ]; then . "$HOME/.elan/env"; fi
command -v lake >/dev/null 2>&1 || { echo "error: Lean is not installed (brew install elan-init)" >&2; exit 1; }
echo "toolchain: $(cat lean-toolchain)"

echo "== 1. escape hatches"
if grep -rnE '\b(sorry|admit|native_decide|implemented_by|extern|unsafe|axiom)\b|skipKernelTC|ofReduceBool|debug\.' \
     --include='*.lean' CallCapture Main.lean CallCapture.lean Audit.lean; then
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
lake env lean Audit.lean > "$tmp/audit" 2>&1
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

echo "== 4. explorer verdicts (40000 random traces of 80 events per schedule, seed 2026)"
for m in any ui drained drained-fifo; do
  ./.lake/build/bin/oracle explore 2026 40000 80 "$m" > "$tmp/explore-raw"
  grep -E '^(OK|FAIL)' "$tmp/explore-raw" | sed -E "s/^(OK|FAIL) ([A-Za-z0-9-]+).*/$m \2 \1/"
done > "$tmp/explore"
if [ "${UPDATE_EXPECTED:-}" = 1 ]; then cp "$tmp/explore" explore-expected.txt; fi
if ! diff -u explore-expected.txt "$tmp/explore"; then
  echo "error: a property's verdict changed (review, then UPDATE_EXPECTED=1)" >&2; exit 1
fi
echo "$(grep -c ' OK$' explore-expected.txt) hold, $(grep -c ' FAIL$' explore-expected.txt) falsified (over any / ui / drained / drained-fifo)"

if [ "${SKIP_SWIFT:-}" = 1 ]; then echo "== 5. Swift: skipped"; exit 0; fi
oracle="$dir/.lake/build/bin/oracle"
cd "$root/App/SignalSafe"

echo "== 5. Swift: conformance with the oracle, D1–D5 regressions"
status=0
SEREIN_CALL_ORACLE="$oracle" SEREIN_CALL_TRACES="${SEREIN_CALL_TRACES:-2000}" \
  swift test --filter 'CallCaptureConformanceTests|CallCaptureDefectRegressions' > "$tmp/swift" 2>&1 || status=$?
grep -E 'Test run|passed after|failed after|disagree|minimised|cfg ' "$tmp/swift" | grep -vE 'recorded a known issue' | tail -40
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
  SEREIN_CALL_ORACLE="$oracle" SEREIN_CALL_TRACES=300 \
    swift test --filter 'CallCaptureConformanceTests' > "$tmp/mutant" 2>&1 && survived=1 || survived=0
  restore
  if [ "$survived" = 1 ]; then echo "error: mutant '$name' survived the conformance tests" >&2; exit 1; fi
  if ! grep -qE 'disagree.* at step' "$tmp/mutant"; then
    echo "error: mutant '$name' failed without a disagreement (did it build?)" >&2; tail -20 "$tmp/mutant" >&2; exit 1
  fi
  echo "killed: $name — $(grep -m1 -oE 'disagree.* at step [0-9]+ \([^)]*\)' "$tmp/mutant")"
}
presenting=App/SignalSafe/Sources/SignalSafe/CallLinksAndPresenting.swift
mutant "frame callback reads the current token" "$presenting" \
  's/self\?\.screenFrame\(frame, token: token\)/self?.screenFrame(frame, token: self?.screenShareToken ?? token)/'
mutant "stop callback reads the current token" "$presenting" \
  's/self\?\.screenShareStopped\(token: token, error: error\)/self?.screenShareStopped(token: self?.screenShareToken ?? token, error: error)/'
mutant "pick task skips its start check" "$presenting" \
  's/(spawn\("screen\.present"\) \{ \[self\] in\n(?:[ ]*\/\/[^\n]*\n)*)[ ]*guard isCurrentScreenShare\(token, generation: generation, conversationId: id\) else \{ return \}\n/$1/'
mutant "stream output ignores its stop" Packages/SignalUI/Sources/SignalUI/Calling/ScreenShare.swift \
  's/        if running \{ onFrame\(frame\) \}\n    \}\n\n    \/\/\/ The stream stopped/        _ = running\n        onFrame(frame)\n    }\n\n    \/\/\/ The stream stopped/'
calls=App/SignalSafe/Sources/SignalSafe/Calls.swift
# The D1–D5 fixes, each undone.
mutant "D1: the service keeps the video it was started with" "$calls" \
  's/if callLocalVideo != video \{ callControl\?\.setOutgoingVideo\(conversationId: id, enabled: callLocalVideo\) \}/_ = video/'
mutant "D2: state events matched by conversation" "$calls" \
  's/guard let a = activeCall, a\.callId == callId, a\.isLive else \{/guard let a = activeCall, a.conversationId == id, a.isLive else {/'
mutant "D3: accepting keeps the call on screen" "$calls" \
  's/        if activeCall != nil \{ endCallUI\(\) \}\n//'
mutant "D4: a second share leaves the first running" "$presenting" \
  's/        if screenCapture != nil \{ clearScreenShare\(\) \}\n//'
mutant "D5: setup task skips its start check" "$calls" \
  's/guard self\?\.callGeneration == generation else \{ return \}\n[ ]*defer/defer/'
mutant "D5: sources task skips its start check" "$presenting" \
  's/(spawn\("screen\.sources"\) \{ \[self\] in\n(?:[ ]*\/\/[^\n]*\n)*)[ ]*guard isCurrentScreenShare\(token, generation: generation, conversationId: id\) else \{ return \}\n/$1/'
echo "10 mutants killed"
