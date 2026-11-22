#!/bin/sh
# The QA run (QA.md): every Lean slice (Tools/verify-*.sh: proofs, audit, explorer, the Swift
# conformance rig, mutants), every package's tests, the codec lint, the built app's sandbox
# check and the crypto vectors, one after another. Prints a table; exits 1 if any step failed.
#
#   Tools/qa.sh                        # everything, mutants included (slow)
#   QUICK=1 Tools/qa.sh                # without mutants
#   Tools/qa.sh lean:broker test:media # only these steps
#   Tools/qa.sh --list
#
# Lean runs first: the package tests' conformance suites run only when their slice's oracle is
# built, and a test step fails if any of them was skipped for that reason. Logs: .build/qa/.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 1
logs="$root/.build/qa"
mkdir -p "$logs"

slices="attachments broker callboundary calls codecs crypto group identity media modifiers queue resend send"
all="interop:prepare"
for s in $slices; do all="$all lean:$s"; done
all="$all test:codecs test:core test:i18n test:media test:ringrtc test:ui test:app lint:codecs lint:calling calling:playout calling:speech calling:speech-relay calling:turn-streams calling:sfu app:sandbox calling:staged vectors"

if [ "${1:-}" = "--list" ]; then
  for s in $all; do echo "$s"; done
  exit 0
fi
steps=${*:-$all}
for s in $steps; do
  case " $all " in *" $s "*) ;; *) echo "error: unknown step '$s' (Tools/qa.sh --list)" >&2; exit 2 ;; esac
done

package() {
  case "$1" in
    codecs) echo Packages/SignalCodecs ;; core) echo Packages/SignalCore ;; i18n) echo Packages/SignalI18n ;;
    media) echo Packages/SignalMediaService ;; ringrtc) echo Packages/SignalRingRTC ;; ui) echo Packages/SignalUI ;;
    app) echo App/SignalSafe ;;
  esac
}

run() {
  step=$1
  case "$step" in
    interop:prepare) Tools/build-ringrtc-ffi.sh ;;
    lean:*)
      s=${step#lean:}
      if [ -n "${QUICK:-}" ]; then SKIP_MUTANTS=1 "Tools/verify-$s.sh"; else "Tools/verify-$s.sh"; fi ;;
    test:*)
      (cd "$(package "${step#test:}")" && swift test) || return 1
      # A conformance suite whose oracle is missing is skipped, not failed: count that as failing.
      if grep -q "build the oracle" "$logs/$step.log"; then
        echo "error: conformance suites skipped (oracle not built): run the lean: steps first" >&2
        return 1
      fi ;;
    lint:codecs) Tools/lint-codecs.sh ;;
    lint:calling) python3 Tools/check-calling-safety.py ;;
    calling:playout) Tools/check-calling-playout.sh ;;
    calling:speech) python3 Tools/check-calling-speech.py --endpoint ;;
    calling:speech-relay) Tools/with-calling-turn.py python3 Tools/check-calling-speech.py --endpoint --relay ;;
    calling:turn-streams)
      SEREIN_TEST_VIDEO_LOSS=1 swift test --package-path Packages/SignalRingRTC -c release --enable-testable-imports --filter DirectVideoInteropTests || return 1
      Tools/with-calling-turn.py swift test --package-path Packages/SignalRingRTC -c release --enable-testable-imports --filter DirectVideoInteropTests || return 1
      SEREIN_TEST_ASYMMETRIC_TURN=1 Tools/with-calling-turn.py swift test --package-path Packages/SignalRingRTC -c release --enable-testable-imports --filter DirectVideoInteropTests || return 1
      Tools/with-calling-turn.py swift test --package-path Packages/SignalRingRTC -c release --enable-testable-imports --filter 'recoversForcedRelay|asymmetricRelay' || return 1
      Tools/with-calling-turn.py --stun-only swift test --package-path Packages/SignalRingRTC -c release --enable-testable-imports --filter twoWaySpeechWithServerReflexive || return 1
      for transport in tcp tls; do
        Tools/with-calling-turn.py --transport "$transport" swift test --package-path Packages/SignalRingRTC --filter TURN || return 1
      done
      Tools/with-calling-turn.py --transport tcp python3 Tools/check-calling-speech.py --endpoint --relay || return 1
      Tools/with-calling-turn.py --transport tls python3 Tools/check-calling-speech.py --relay ;;
    calling:sfu)
      for transport in udp tcp tls; do
        Tools/with-calling-sfu.py --transport "$transport" swift test --package-path Packages/SignalRingRTC -c release --enable-testable-imports --filter GroupMediaInteropTests || return 1
      done
      SEREIN_TEST_VIDEO_LOSS=1 Tools/with-calling-sfu.py swift test --package-path Packages/SignalRingRTC -c release --enable-testable-imports --filter GroupCallInteropTests || return 1
      SEREIN_TEST_VIDEO_LAYERS=1 SEREIN_TEST_NATIVE_SVC=1 SEREIN_TEST_SWIFT_SVC=1 Tools/with-calling-sfu.py swift test --package-path Packages/SignalRingRTC -c release --enable-testable-imports --filter GroupCallInteropTests || return 1
      Tools/with-calling-sfu.py --require-approval swift test --package-path Packages/SignalRingRTC -c release --enable-testable-imports --filter GroupAdmissionTests || return 1
      if [ -n "${SEREIN_TEST_SFU_ENDORSEMENT_BINARY:-}" ]; then
        Tools/with-calling-sfu.py --endorsements sh -ec '
        swift test --package-path Packages/SignalRingRTC -c release --enable-testable-imports --filter GroupAdmissionTests
        swift test --package-path Packages/SignalCore -c release --enable-testable-imports --filter verifiesUpstreamSFUAdmissionEndorsements' || return 1
      fi ;;
    app:sandbox) Tools/build-app.sh && Tools/check-sandbox-profile.sh ;;
    calling:staged) python3 Tools/check-staged-calling.py "${SEREIN_TEST_CALLING_APP:-App/SignalSafe/.build/Serein.app}" ;;
    vectors) Tools/crypto-vectors/check.sh ;;
  esac
}

# The line that says how it went: tests (summed over a package's test runs), mutants killed,
# or the last line.
summary() {
  log=$1
  runs=$(grep -cE "Test run with [0-9]+ tests?" "$log")
  line=""
  if [ "$runs" -gt 0 ]; then
    tests=$(grep -E "Test run with [0-9]+ tests?" "$log" | sed -E 's/.*Test run with ([0-9]+) tests?.*/\1/' | paste -sd+ - | bc)
    line="$tests test$([ "$tests" = 1 ] || echo s) in $runs run$([ "$runs" = 1 ] || echo s)"
  fi
  xc=$(grep -E "^[[:space:]]*Executed [0-9]+ tests" "$log" | grep -v "Executed 0 tests" | tail -1 | sed 's/^[[:space:]]*//; s/ in .*//')
  [ -n "$xc" ] && line="${line:+$line; }XCTest: $xc"
  other=$(grep -E "mutants killed|check-sandbox-profile: ok|lint-codecs: ok|upstream read all" "$log" | tail -1 | sed 's/^[^A-Za-z0-9]*//')
  [ -n "$other" ] && line="${line:+$line; }$other"
  [ -n "$line" ] || line=$(grep -v '^[[:space:]]*$' "$log" | tail -1)
  echo "$line" | cut -c1-110
}

failed=0
table=""
for step in $steps; do
  log="$logs/$step.log"
  printf '%-18s ' "$step"
  start=$(date +%s)
  if run "$step" > "$log" 2>&1; then status=ok; else status=FAIL; failed=1; fi
  secs=$(( $(date +%s) - start ))
  echo "$status ($(( secs / 60 ))m$(( secs % 60 ))s)"
  table="$table$(printf '%-18s %-4s %6ss  %s' "$step" "$status" "$secs" "$(summary "$log")")
"
done

echo
echo "== QA $(git rev-parse --short HEAD)$(git diff --quiet || echo ' + uncommitted changes')$([ -n "${QUICK:-}" ] && echo ', QUICK (no mutants)')"
printf '%s' "$table"
echo "logs: $logs"
[ $failed = 0 ] && echo "QA: ok" || echo "QA: FAILED"
exit $failed
