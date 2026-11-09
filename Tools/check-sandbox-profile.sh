#!/bin/sh
# Checks the services' Seatbelt profiles where it matters, in launchd-started XPC services:
#   * a probe service signed with exactly each service's entitlements (App Sandbox plus
#     Packages/SignalMediaService/Sandbox/<Service>.sb) must find every probe denied (files,
#     writes, processes, preferences, network);
#   * the real SignalMediaDecoder.xpc and SignalLinkPreviewParser.xpc from the built app must start
#     under their profiles (they exit otherwise) and do their work: the decoder decodes images,
#     audio and H.264/HEVC video and encodes a voice note; the parser parses a page.
# The host is compiled with MediaXPCInterface's sources, so it calls them as the app does.
# Usage: Tools/check-sandbox-profile.sh   (after Tools/build-app.sh; same SIGNALSAFE_SIGN_IDENTITY)
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
app="$root/App/SignalSafe/.build/Serein.app"
[ -d "$app/Contents/XPCServices/SignalLinkPreviewParser.xpc" ] || { echo "error: build the app first (Tools/build-app.sh)" >&2; exit 1; }
sign="${SIGNALSAFE_SIGN_IDENTITY:--}"
work="$root/App/SignalSafe/.build/sandbox-probe"
rm -rf "$work"; mkdir -p "$work"
src="$root/Tools/sandbox-probe"
iface="$root/Packages/SignalMediaService/Sources/MediaXPCInterface"
swiftc -swift-version 5 -O "$src/Shared.swift" "$src/service/main.swift" -o "$work/probe"
swiftc -swift-version 6 -O -target arm64-apple-macos27.0 -module-name ProbeHost "$iface"/*.swift "$src/host/main.swift" -o "$work/host"
host="$work/ProbeHost.app"
mkdir -p "$host/Contents/MacOS" "$host/Contents/XPCServices"
cp "$work/host" "$host/Contents/MacOS/ProbeHost"
cat > "$host/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>org.signalsafe.sandbox-probe-host</string>
  <key>CFBundleExecutable</key><string>ProbeHost</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
probes=""
for service in SignalLinkPreviewParser SignalMediaDecoder; do
  id="org.signalsafe.sandbox-probe.$service"
  xpc="$host/Contents/XPCServices/Probe$service.xpc"
  mkdir -p "$xpc/Contents/MacOS"
  cp "$work/probe" "$xpc/Contents/MacOS/Probe$service"
  cat > "$xpc/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$id</string>
  <key>CFBundleExecutable</key><string>Probe$service</string>
  <key>CFBundleName</key><string>Probe$service</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>XPCService</key><dict><key>ServiceType</key><string>Application</string></dict>
</dict></plist>
PLIST
  "$root/Tools/sbpl-entitlements.sh" "$root/Packages/SignalMediaService/Sandbox/$service.sb" > "$work/$service.entitlements"
  codesign --force --sign "$sign" --timestamp=none --options runtime --entitlements "$work/$service.entitlements" "$xpc" 2>/dev/null
  cp -R "$app/Contents/XPCServices/$service.xpc" "$host/Contents/XPCServices/"
  probes="$probes $id"
done
codesign --force --sign "$sign" --timestamp=none "$host" 2>/dev/null
codecs="$root/Packages/SignalCodecs/Tests"
res="$root/Packages/SignalMediaService/Tests/SignalMediaDecoderTests/Resources"
set +e
# shellcheck disable=SC2086
out=$("$host/Contents/MacOS/ProbeHost" $probes -- \
  "$codecs/MetadataStripTests/Resources/image.png" "$codecs/MetadataStripTests/Resources/photo.jpg" \
  "$codecs/MetadataStripTests/Resources/anim.gif" "$codecs/MetadataStripTests/Resources/image.webp" \
  "$res/Audio/stereo_44100_vbr_q7.mp3" "$res/Audio/stereo_48000_96k.m4a" "$res/Audio/mono_8000_16k.aac" \
  "$res/Video/high_bframes_aac_faststart.mp4" "$res/Video/main_rotated_90.mp4" "$res/Video/hlg10.mp4" \
  "$codecs/VideoHEVCTests/Resources/ipb8.mp4")
status=$?
set -e
echo "$out"
fail=0
[ $status -eq 0 ] || { echo "check-sandbox-profile: a service call failed" >&2; fail=1; }
echo "$out" | grep -q ' allowed:' && { echo "check-sandbox-profile: a profile allows something it must deny" >&2; fail=1; }
[ "$(echo "$out" | grep -c ' denied:')" -ge 18 ] || { echo "check-sandbox-profile: probes missing" >&2; fail=1; }
echo "$out" | grep -q '^ok: link preview page' || { echo "check-sandbox-profile: the parser did not run under its profile" >&2; fail=1; }
echo "$out" | grep -q '^ok: hlg10.mp4 play' || { echo "check-sandbox-profile: the decoder did not play video under its profile" >&2; fail=1; }
[ $fail -eq 0 ] && echo "check-sandbox-profile: ok"
exit $fail
