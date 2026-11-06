#!/bin/bash
# Builds Packages/SignalRingRTC/rust (SignalSafe's C ABI over ringrtc, a dylib) against the
# prebuilt WebRTC that vendor/ringrtc fetched (Phase 0: bin/fetch-artifact … in vendor/ringrtc).
set -euo pipefail
cd "$(dirname "$0")/../Packages/SignalRingRTC/rust"
OUTPUT_DIR="$(cd ../../../vendor/ringrtc/out && pwd)" cargo build --release --target aarch64-apple-darwin "$@"
ls -l target/aarch64-apple-darwin/release/libsignal_ringrtc.dylib
