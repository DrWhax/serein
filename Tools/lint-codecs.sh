#!/bin/bash
# Security gate for SignalCodecs (see plan: "Security gate").
#  1. Library targets must not import Apple media/decoding frameworks or Foundation.
#  2. No Unsafe* pointer APIs outside Sources/CodecCore/Unsafe/.
#  3. No Apple image/media decoding entry points anywhere in shipping code.
#  4. Every Swift target is built with -strict-memory-safety (StrictMemorySafety as an
#     error), and the codec libraries contain no `unsafe` escapes at all.
# Raw-byte access is additionally enforced by the compiler: ByteSlice/ByteCursor
# storage is not public, so decoders can only read through cursors/bit readers.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=Packages/SignalCodecs/Sources
fail=0

libs=$(find "$SRC" -name '*.swift' -not -path "$SRC/codec-fuzz/*")

if grep -nE '^\s*(@preconcurrency\s+)?(public\s+|internal\s+|private\s+)?import\s+(Foundation|ImageIO|CoreGraphics|CoreImage|AVFoundation|AVFAudio|VideoToolbox|AudioToolbox|CoreMedia|CoreVideo|Compression|AppKit|UIKit|Accelerate|zlib|Darwin|Glibc)\b' $libs; then
  echo "lint: forbidden framework import in a SignalCodecs library target" >&2; fail=1
fi

# Scoped libm imports (import func Darwin.cosf, ...) only in CodecCore/Math/LibM.swift.
if grep -nE '^\s*import\s+(func|var|struct|class|enum|typealias)\s+Darwin\.' $libs | grep -v "^$SRC/CodecCore/Math/LibM.swift:" | grep -q .; then
  grep -nE '^\s*import\s+(func|var|struct|class|enum|typealias)\s+Darwin\.' $libs | grep -v "^$SRC/CodecCore/Math/LibM.swift:"
  echo "lint: Darwin import outside CodecCore/Math/LibM.swift" >&2; fail=1
fi
if grep -nE '^\s*import\s+(var|struct|class|enum|typealias)\s+Darwin\.' "$SRC/CodecCore/Math/LibM.swift"; then
  echo "lint: LibM.swift may only import functions" >&2; fail=1
fi

if grep -nE '\bUnsafe(Mutable)?(Raw)?(Buffer)?Pointer\b|withUnsafe|unsafeBitCast|unsafeDowncast|Unmanaged' $libs | grep -v "^$SRC/CodecCore/Unsafe/"; then
  echo "lint: unsafe pointer API outside CodecCore/Unsafe" >&2; fail=1
fi

# Codec libraries compile under -strict-memory-safety with zero opt-outs.
if grep -nE '(^|[^A-Za-z_])unsafe[[:space:]]+[A-Za-z_(&\[]|@unsafe\b|@safe\b|nonisolated\(unsafe\)|@unchecked[[:space:]]+Sendable' $libs; then
  echo "lint: unsafe escape (unsafe expr, @unsafe/@safe, nonisolated(unsafe), @unchecked Sendable) in a codec library" >&2; fail=1
fi

# Shipping code outside the codecs: the single allowed `unsafe` is the Keychain read
# (SecItemCopyMatching's C out-pointer) in SignalCore/Database/KeychainKeyStore.swift.
others=$(find Packages App -name '*.swift' -not -path 'Packages/SignalCodecs/*' -not -path '*/Tests/*' -not -path '*/.build/*' -not -name 'Package.swift' 2>/dev/null || true)
allowed='Packages/SignalCore/Sources/SignalCore/Database/KeychainKeyStore.swift'
hits=$(grep -nE '(^|[^A-Za-z_])unsafe[[:space:]]+[A-Za-z_(&\[]|@unsafe\b|nonisolated\(unsafe\)' $others | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' \
  | grep -vE '^[^:]+\.pb\.swift:[0-9]+:[[:space:]]*static nonisolated\(unsafe\) let defaultInstance = _StorageClass\(\)$' || true)
# (protoc-gen-swift emits that copy-on-write default storage; it is never mutated.)
if [ -n "$(echo "$hits" | grep -v "^$allowed:" | grep . || true)" ] || [ "$(echo "$hits" | grep -c "^$allowed:" || true)" -gt 1 ]; then
  echo "$hits"
  echo "lint: unsafe escape in shipping code (only one allowed: the Keychain read in $allowed)" >&2; fail=1
fi

# Every package manifest we own enables strict memory safety on every target.
for manifest in Packages/*/Package.swift; do
  targets=$(grep -cE '\.(target|executableTarget|testTarget)\(' "$manifest" || true)
  enabled=$(grep -cE 'swiftSettings: *(strict|memorySafety|memorySafety *\+|\[\.swiftLanguageMode\(\.v5\)\] *\+ *memorySafety)' "$manifest" || true)
  if ! grep -q 'strictMemorySafety()' "$manifest" || ! grep -q 'treatWarning("StrictMemorySafety", as: .error)' "$manifest" || [ "$enabled" -lt "$targets" ]; then
    echo "lint: $manifest: strict memory safety not enabled on all $targets targets ($enabled found)" >&2; fail=1
  fi
done

# Shipping code anywhere in the repo (tests and the differential oracle excluded).
shipping=$(find App Packages -name '*.swift' -not -path '*/Tests/*' -not -path '*/.build/*' 2>/dev/null || true)
if [ -n "$shipping" ] && grep -nE 'CGImageSource|NSImage\(data|NSImage\(contentsOf|UIImage\(data|NSBitmapImageRep|CIImage\(data|AVAsset|AVPlayer|AVAudioFile|AVAudioPlayer|VTDecompression|AudioFileOpen|ExtAudioFile|compression_decode' $shipping; then
  echo "lint: Apple media decoder used in shipping code" >&2; fail=1
fi

[ $fail -eq 0 ] && echo "lint-codecs: ok"
exit $fail
