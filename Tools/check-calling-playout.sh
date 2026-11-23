#!/bin/sh
# Exercise the production strict Swift PCM renderer with the production calling Seatbelt profile.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/serein-calling-playout.XXXXXX")
trap 'rm -rf "$work"' EXIT
contents="$work/PCMProbe.app/Contents"
mkdir -p "$contents/MacOS"
cat > "$contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.serein.tests.strict-pcm</string>
<key>CFBundleExecutable</key><string>PCMProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>NSMicrophoneUsageDescription</key><string>Check simultaneous microphone and speaker operation in the Serein calling sandbox.</string>
</dict></plist>
PLIST
xcrun swiftc -O -parse-as-library -swift-version 6 -strict-memory-safety -warnings-as-errors \
    -module-cache-path "$work/modules" -target arm64-apple-macos27.0 "$root/Packages/SignalRingRTC/Sources/SwiftCalling/CallEchoControl.swift" \
    "$root/Packages/SignalRingRTC/Sources/SwiftCalling/MicrophoneProcessing.swift" \
    "$root/Packages/SignalRingRTC/Sources/SwiftCalling/CallSpeaker.swift" \
    "$root/Packages/SignalRingRTC/Sources/SwiftCalling/EngineMicrophone.swift" \
    "$root/Packages/SignalRingRTC/Sources/SwiftCalling/CallMicrophone.swift" \
    "$root/Packages/SignalMediaService/Sources/MediaXPCInterface/ServiceSandbox.swift" \
    "$root/Tools/calling-safety/ProbeEcho.swift" "$root/Tools/calling-safety/ProbePlayout.swift" -o "$contents/MacOS/PCMProbe"
"$root/Tools/sbpl-entitlements.sh" "$root/Packages/SignalMediaService/Sandbox/SignalCalling.sb" > "$work/entitlements.plist"
codesign --force --sign - --timestamp=none --options runtime --entitlements "$work/entitlements.plist" "$work/PCMProbe.app"
"$contents/MacOS/PCMProbe" "$@"
