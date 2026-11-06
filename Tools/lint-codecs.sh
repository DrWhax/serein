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

# Shipping code outside the codecs: four audited `unsafe` lines are allowed, one in each of
# these files: the Keychain read (SecItemCopyMatching's C out-pointer), the copy of validated
# PCM samples into an AVAudioPCMBuffer, the upload of validated video planes into Metal
# textures (no safe write APIs in macOS 27; both approved by the user 2026-11-05), and the copy
# of locked local camera / screen-capture pixel-buffer planes for ringrtc (no safe read API;
# approved 2026-11-06).
others=$(find Packages App -name '*.swift' -not -path 'Packages/SignalCodecs/*' -not -path '*/Tests/*' -not -path '*/.build/*' -not -name 'Package.swift' 2>/dev/null || true)
allowed='Packages/SignalCore/Sources/SignalCore/Database/KeychainKeyStore.swift'
allowed2='Packages/SignalUI/Sources/SignalUI/Audio/PCMBuffer.swift'
allowed3='Packages/SignalUI/Sources/SignalUI/Video/VideoTexture.swift'
allowed4='Packages/SignalUI/Sources/SignalUI/Video/CaptureFrames.swift'
hits=$(grep -nE '(^|[^A-Za-z_])unsafe[[:space:]]+[A-Za-z_(&\[]|@unsafe\b|nonisolated\(unsafe\)' $others | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' \
  | grep -vE '^[^:]+\.pb\.swift:[0-9]+:[[:space:]]*static nonisolated\(unsafe\) let defaultInstance = _StorageClass\(\)$' || true)
# (protoc-gen-swift emits that copy-on-write default storage; it is never mutated.)
if [ -n "$(echo "$hits" | grep -v "^$allowed:" | grep -v "^$allowed2:" | grep -v "^$allowed3:" | grep -v "^$allowed4:" | grep . || true)" ] \
   || [ "$(echo "$hits" | grep -c "^$allowed:" || true)" -gt 1 ] || [ "$(echo "$hits" | grep -c "^$allowed2:" || true)" -gt 1 ] \
   || [ "$(echo "$hits" | grep -c "^$allowed3:" || true)" -gt 1 ] || [ "$(echo "$hits" | grep -c "^$allowed4:" || true)" -gt 1 ]; then
  echo "$hits"
  echo "lint: unsafe escape in shipping code (allowed: one line each in $allowed, $allowed2, $allowed3 and $allowed4)" >&2; fail=1
fi

# Every package manifest we own enables strict memory safety on every target.
for manifest in Packages/*/Package.swift; do
  targets=$(grep -cE '\.(target|executableTarget|testTarget)\(' "$manifest" || true)
  enabled=$(grep -cE 'swiftSettings: *(strict|memorySafety|memorySafety *\+|\[\.swiftLanguageMode\(\.v5\)\] *\+ *memorySafety)' "$manifest" || true)
  if ! grep -q 'strictMemorySafety()' "$manifest" || ! grep -q 'treatWarning("StrictMemorySafety", as: .error)' "$manifest" || [ "$enabled" -lt "$targets" ]; then
    echo "lint: $manifest: strict memory safety not enabled on all $targets targets ($enabled found)" >&2; fail=1
  fi
done

# SignalCore never links a decoder: media goes to the sandboxed service through MediaXPCInterface.
core=$(find Packages/SignalCore/Sources -name '*.swift' 2>/dev/null || true)
if [ -n "$core" ] && grep -nE '^\s*(@preconcurrency\s+)?(public\s+|internal\s+)?import\s+(Image[A-Za-z]+|Blurhash|Encode[A-Za-z]+|CodecCore|HTMLMeta|MetadataStrip|Container[A-Za-z0-9]+|Audio[A-Z][A-Za-z0-9]*|Video[A-Z][A-Za-z0-9]*|SignalMediaDecoder)\b' $core; then
  echo "lint: SignalCore imports a decoder module (only MediaXPCInterface is allowed)" >&2; fail=1
fi
# …and its library target's dependency list (up to the test target) names no decoder product.
if sed -n '/name: "SignalCore",/,/testTarget/p' Packages/SignalCore/Package.swift | grep -v testTarget \
   | grep -nE '"(SignalMediaDecoder|EncodePNG|EncodeJPEG|CodecCore|HTMLMeta|Blurhash|Image[A-Za-z]+|Container[A-Za-z0-9]+|AudioAAC|AudioMP3|VideoH264|MetadataStrip)"'; then
  echo "lint: SignalCore's library target depends on a decoder product" >&2; fail=1
fi

# Shipping code anywhere in the repo (tests and the differential oracle excluded).
shipping=$(find App Packages -name '*.swift' -not -path '*/Tests/*' -not -path '*/.build/*' 2>/dev/null || true)
if [ -n "$shipping" ] && grep -nE 'CGImageSource|NSImage\(data|NSImage\(contentsOf|UIImage\(data|NSBitmapImageRep|CIImage\(data|AVAsset|AVPlayer|AVAudioFile|AVAudioPlayer([^N]|$)|VTDecompression|AudioFileOpen|ExtAudioFile|compression_decode' $shipping; then
  echo "lint: Apple media decoder used in shipping code" >&2; fail=1
fi

[ $fail -eq 0 ] && echo "lint-codecs: ok"
exit $fail
