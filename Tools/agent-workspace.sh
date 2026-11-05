#!/bin/bash
# Creates an isolated copy of Packages/SignalUI for parallel porting work:
#   .cache/agents/<name>/Packages/SignalUI   (copy; SignalCodecs symlinked)
# Build and test inside it; copy finished new files back into Packages/SignalUI.
set -euo pipefail
cd "$(dirname "$0")/.."
name=${1:?usage: Tools/agent-workspace.sh <name>}
dst=.cache/agents/$name/Packages
mkdir -p "$dst"
rsync -a --delete --exclude .build --exclude .swiftpm Packages/SignalUI/ "$dst/SignalUI/"
ln -sfn "$PWD/Packages/SignalCodecs" "$dst/SignalCodecs"
# The tests locate the repo through #filePath; give the copy a path back to the real tools.
echo "$PWD/$dst/SignalUI"
