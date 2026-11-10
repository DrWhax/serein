#!/bin/bash
# Applies SignalSafe's patches to vendored submodules (idempotent).
#   libsignal-local-test-server.patch: exports a localhost ConnectionManager to Swift so
#   integration tests can use Signal's mock server (testing only; not used by the app).
#   libsignal-aes-cbc.patch: bridges signal_crypto AES-256-CBC to Swift (Aes256Cbc), so
#   SignalCore needs no CommonCrypto pointer code under -strict-memory-safety.
#   libsignal-media.patch: builds the signal-media feature (WebpSanitizer, Mp4Sanitizer) and
#   compiles its Swift API (SIGNAL_MEDIA_SUPPORTED); used on outgoing stickers and media.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$(pwd)
# In name order: libsignal-media.patch is made on top of the other libsignal patches.
for p in Tools/vendor-patches/*.patch; do
  repo=vendor/libsignal; case "$p" in *grdb-*) repo=vendor/GRDB.swift;; esac
  if git -C "$repo" apply --reverse --check "$root/$p" 2>/dev/null; then
    echo "already applied: $p"
  else
    git -C "$repo" apply "$root/$p"
    echo "applied: $p"
  fi
done
