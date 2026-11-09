#!/bin/sh
# Regenerates SignalCore's upstream crypto vectors from the Signal-Desktop checkout.
# Needs Node 22+ and network access for the first `npm install`.
set -eu
cd "$(dirname "$0")"
root=../..
[ -d node_modules ] || npm install --no-audit --no-fund
mkdir -p generated
# Desktop builds this at compile time (pnpm run build:protobuf); same .proto files here.
(cd "$root/Signal-Desktop" && "$OLDPWD/node_modules/.bin/protopiler" --module esm --output "$OLDPWD/generated/compiled.std.js" protos)
node --no-warnings --import ./register.mjs generate.mjs "$root/Packages/SignalCore/Tests/SignalCoreTests/Resources/Crypto/upstream-vectors.json"
