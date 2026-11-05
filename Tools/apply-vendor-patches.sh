#!/bin/bash
# Applies SignalSafe's patches to vendored submodules (idempotent).
#   libsignal-local-test-server.patch: exports a localhost ConnectionManager to Swift so
#   integration tests can use Signal's mock server (testing only; not used by the app).
#   libsignal-aes-cbc.patch: bridges signal_crypto AES-256-CBC to Swift (Aes256Cbc), so
#   SignalCore needs no CommonCrypto pointer code under -strict-memory-safety.
set -euo pipefail
cd "$(dirname "$0")/.."
for p in Tools/vendor-patches/*.patch; do
  repo=vendor/libsignal; case "$p" in *grdb-*) repo=vendor/GRDB.swift;; esac
  if git -C "$repo" apply --reverse --check "../../$p" 2>/dev/null; then
    echo "already applied: $p"
  else
    git -C "$repo" apply "../../$p"
    echo "applied: $p"
  fi
done
