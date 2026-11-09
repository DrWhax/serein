#!/bin/sh
# Checks the Swift crypto port against the Signal-Desktop checkout, both ways:
#   1. the committed vectors are what this checkout's TypeScript produces now (if Desktop
#      moved on, this is where a changed construction shows up: regenerate with generate.sh
#      and run the SignalCore tests);
#   2. what Swift encrypts, upstream's own code decrypts (verify.mjs).
# Needs Node 22+, the Signal-Desktop checkout, and network for the first `npm install`.
set -eu
cd "$(dirname "$0")"
root=../..
vectors="$root/Packages/SignalCore/Tests/SignalCoreTests/Resources/Crypto/upstream-vectors.json"
[ -d node_modules ] || npm install --no-audit --no-fund
mkdir -p generated
(cd "$root/Signal-Desktop" && "$OLDPWD/node_modules/.bin/protopiler" --module esm --output "$OLDPWD/generated/compiled.std.js" protos)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

node --no-warnings --import ./register.mjs generate.mjs "$work/vectors.json" 2>"$work/generate.log" >/dev/null || { cat "$work/generate.log"; exit 1; }
if cmp -s "$work/vectors.json" "$vectors"; then
  echo "vectors: up to date with Signal-Desktop $(git -C "$root/Signal-Desktop" rev-parse --short HEAD)"
else
  echo "vectors: OUT OF DATE. Signal-Desktop is at $(git -C "$root/Signal-Desktop" rev-parse --short HEAD); the committed file was made from $(sed -n 's/.*"desktopCommit": "\([0-9a-f]\{9\}\).*/\1/p' "$vectors")."
  echo "         Run Tools/crypto-vectors/generate.sh, then the SignalCore tests: a failure there is a construction upstream changed."
  exit 1
fi

(cd "$root/Packages/SignalCore" && CRYPTO_VECTORS_EXPORT="$work/swift.json" swift test --filter UpstreamVectorTests/exportsForUpstream >"$work/swift.log" 2>&1) || { tail -30 "$work/swift.log"; exit 1; }
[ -s "$work/swift.json" ] || { echo "the Swift test wrote nothing"; exit 1; }
node --no-warnings --import ./register.mjs verify.mjs "$work/swift.json" 2>"$work/verify.log" || { cat "$work/verify.log"; exit 1; }
