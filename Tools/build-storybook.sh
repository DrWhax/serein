#!/bin/bash
# Builds upstream Signal Desktop's Storybook (the visual reference for SignalUI, plan.md
# Phase 3) with the exact toolchain upstream pins: Node 24.22.0 and pnpm 11.24.0, both
# fetched into .cache/ (Node's tarball is checked against nodejs.org's SHASUMS256).
#
# Signal-Desktop/ stays a read-only reference: it is copied to .cache/storybook-desktop
# and installed/built there. Output: .cache/storybook-desktop/storybook-static.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD
node_version=24.22.0
pnpm_version=11.24.0
cache=$root/.cache
mkdir -p "$cache"

node_dir=$cache/node-v$node_version-darwin-arm64
if [ ! -x "$node_dir/bin/node" ]; then
  (cd "$cache" && curl -fsSLO "https://nodejs.org/dist/v$node_version/node-v$node_version-darwin-arm64.tar.xz" \
    && curl -fsSL "https://nodejs.org/dist/v$node_version/SHASUMS256.txt" | grep " node-v$node_version-darwin-arm64.tar.xz\$" | shasum -a 256 -c - \
    && tar xf "node-v$node_version-darwin-arm64.tar.xz")
fi
export PATH=$node_dir/bin:$cache/pnpm/bin:$PATH
if [ "$(pnpm --version 2>/dev/null)" != "$pnpm_version" ]; then
  npm install -g --prefix "$cache/pnpm" "pnpm@$pnpm_version" --loglevel=error
fi

work=$cache/storybook-desktop
rsync -a --delete --exclude .git --exclude node_modules --exclude storybook-static --exclude '*.tsbuildinfo' Signal-Desktop/ "$work/"
cd "$work"
# Storybook needs no Electron binary; everything else installs as upstream's CI does.
export ELECTRON_SKIP_BINARY_DOWNLOAD=1 CI=1
pnpm install --frozen-lockfile
pnpm run build:storybook
echo "storybook: $work/storybook-static ($(node -e "console.log(Object.keys(require('./storybook-static/index.json').entries).length)") entries)"
