#!/bin/bash
# Prepare the pinned native reference for the RingRTC interoperability tests.
# --prepare-only installs the verified WebRTC archive for custom fixture builds.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
git -C "$root" submodule update --init -- vendor/ringrtc
"$root/vendor/ringrtc/bin/fetch-artifact" --platform mac-arm64 --release
if [[ "${1:-}" == --prepare-only ]]; then exit 0; fi
cd "$root/Packages/SignalRingRTC/rust"
OUTPUT_DIR="$root/vendor/ringrtc/out" cargo build --release --target aarch64-apple-darwin "$@"
ls -l target/aarch64-apple-darwin/release/libsignal_ringrtc.dylib
