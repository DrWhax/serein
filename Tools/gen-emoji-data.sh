#!/bin/sh
# Copies upstream's generated emoji data (scripts/generate-emoji-data.mjs, run by the
# Storybook build: categories, parents, skin-tone variants, short names) into SignalUI's
# resources, where the Fun picker reads it (EmojiData.swift).
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
src="$root/.cache/storybook-desktop/build/emoji-data.json"
[ -f "$src" ] || { echo "missing $src: run Tools/build-storybook.sh first" >&2; exit 1; }
cp "$src" "$root/Packages/SignalUI/Sources/SignalUI/Resources/emoji-data.json"
echo "wrote Packages/SignalUI/Sources/SignalUI/Resources/emoji-data.json"
