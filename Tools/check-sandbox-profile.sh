#!/bin/sh
# Checks the Seatbelt profiles where it matters, in launchd-started XPC services:
#   * a probe service signed with exactly each profile's entitlements (App Sandbox plus
#     Packages/SignalMediaService/Sandbox/<Profile>.sb) must be able to do what that process
#     needs and nothing else: the decoder and the parser nothing at all (no files, writes,
#     processes, preferences or network), the link-preview fetcher and the GIF service HTTPS to
#     the web but no user files, writes, processes or connections to this machine, and the app
#     (Serein.sb) its container and the network but no programs and no home directory;
#   * the real services from the built app must start under their profiles (they exit
#     otherwise) and do their work for a host signed as the app: the decoder decodes images,
#     audio and video, shows an AVIF and converts a HEIC, the voice-note encoder encodes a
#     voice note (and the decoder refuses to); the fetcher
#     fetches a page (live network; SANDBOX_CHECK_SITE, default https://signal.org/) that the
#     parser parses, the parser refuses HTML from the host, and the GIF service lists Giphy's
#     trending GIFs through Signal's content proxy;
#   * the same services refuse a host signed with any other identifier (their code-signing
#     requirements, MediaXPCInterface/XPCPeer.swift).
# The host is compiled with MediaXPCInterface's sources, so it calls them as the app does.
# Usage: Tools/check-sandbox-profile.sh   (after Tools/build-app.sh; same SIGNALSAFE_SIGN_IDENTITY)
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
app="$root/App/SignalSafe/.build/Serein.app"
services="SignalMediaDecoder SignalLinkPreviewParser SignalLinkPreviewFetcher SignalGifSearch SignalVoiceNoteEncoder"
for s in $services; do
  [ -d "$app/Contents/XPCServices/$s.xpc" ] || { echo "error: build the app first (Tools/build-app.sh)" >&2; exit 1; }
done
sign="${SIGNALSAFE_SIGN_IDENTITY:--}"
# A new directory for every run: launchd remembers which XPC services a host bundle path holds,
# so hosts rebuilt at a path used before get the earlier run's services (or none). Only the
# previous run is kept.
runs="$root/App/SignalSafe/.build/sandbox-probe"
mkdir -p "$runs"
last=$(ls -t "$runs" | head -1)
for old in "$runs"/*; do [ -e "$old" ] && [ "$(basename "$old")" != "$last" ] && rm -rf "$old"; done
work=$(mktemp -d "$runs/run.XXXXXX")
src="$root/Tools/sandbox-probe"
iface="$root/Packages/SignalMediaService/Sources/MediaXPCInterface"
sandbox="$root/Packages/SignalMediaService/Sandbox"
swiftc -swift-version 5 -O "$src/Shared.swift" "$src/service/main.swift" "$iface/ServiceSandbox.swift" -o "$work/probe"
swiftc -swift-version 6 -O -target arm64-apple-macos27.0 -module-name ProbeHost "$iface"/*.swift "$src/host/main.swift" -o "$work/host"

# makehost <bundle> <signing identifier>: a host app with the probe services and copies of the
# real services.
makehost() {
  mh_bundle=$1 mh_ident=$2 mh_exe=$(basename "$1" .app)
  mkdir -p "$mh_bundle/Contents/MacOS" "$mh_bundle/Contents/XPCServices"
  cp "$work/host" "$mh_bundle/Contents/MacOS/$mh_exe"
  cat > "$mh_bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$mh_ident</string>
  <key>CFBundleExecutable</key><string>$mh_exe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
  for s in $services; do cp -R "$app/Contents/XPCServices/$s.xpc" "$mh_bundle/Contents/XPCServices/"; done
}
host="$work/ProbeHost.app"
makehost "$host" org.signalsafe.SignalSafe
probes=""
for profile in SignalMediaDecoder SignalLinkPreviewParser SignalLinkPreviewFetcher SignalGifSearch SignalVoiceNoteEncoder Serein; do
  id="org.signalsafe.sandbox-probe.$profile"
  xpc="$host/Contents/XPCServices/Probe$profile.xpc"
  mkdir -p "$xpc/Contents/MacOS"
  cp "$work/probe" "$xpc/Contents/MacOS/Probe$profile"
  cat > "$xpc/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$id</string>
  <key>CFBundleExecutable</key><string>Probe$profile</string>
  <key>CFBundleName</key><string>Probe$profile</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>XPCService</key><dict><key>ServiceType</key><string>Application</string></dict>
</dict></plist>
PLIST
  "$root/Tools/sbpl-entitlements.sh" "$sandbox/$profile.sb" > "$work/$profile.entitlements"
  codesign --force --sign "$sign" --timestamp=none --options runtime --entitlements "$work/$profile.entitlements" "$xpc" 2>/dev/null
  probes="$probes $id"
done
# Signed as the app (the identifier the services require; with an identity, also its Team ID).
codesign --force --sign "$sign" --timestamp=none -i org.signalsafe.SignalSafe "$host" 2>/dev/null
refused="$work/RefusedHost.app"
makehost "$refused" org.signalsafe.not-the-app
codesign --force --sign "$sign" --timestamp=none -i org.signalsafe.not-the-app "$refused" 2>/dev/null

# Launch Services learns the new bundles first (their XPC services are found through it).
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$lsregister" -f "$host" "$refused" 2>/dev/null || true

codecs="$root/Packages/SignalCodecs/Tests"
res="$root/Packages/SignalMediaService/Tests/SignalMediaDecoderTests/Resources"
set +e
# shellcheck disable=SC2086
out=$("$host/Contents/MacOS/ProbeHost" $probes -- \
  "$codecs/MetadataStripTests/Resources/image.png" "$codecs/MetadataStripTests/Resources/photo.jpg" \
  "$codecs/MetadataStripTests/Resources/anim.gif" "$codecs/MetadataStripTests/Resources/image.webp" \
  "$res/Audio/stereo_44100_vbr_q7.mp3" "$res/Audio/stereo_48000_96k.m4a" "$res/Audio/mono_8000_16k.aac" \
  "$res/Video/high_bframes_aac_faststart.mp4" "$res/Video/main_rotated_90.mp4" "$res/Video/hlg10.mp4" \
  "$codecs/VideoHEVCTests/Resources/ipb8.mp4" \
  "$res/Image/avifrot.avif" "$res/Image/heicgrid.heic")
status=$?
refusal=$("$refused/Contents/MacOS/RefusedHost" --refused)
refusedStatus=$?
set -e
echo "$out"
echo "other identifier: $refusal"
fail=0
[ $status -eq 0 ] || { echo "check-sandbox-profile: a service call failed" >&2; fail=1; }
[ $refusedStatus -eq 0 ] || { echo "check-sandbox-profile: a service served a host not signed as the app" >&2; fail=1; }
# What each profile must allow and may allow; everything else must be denied.
echo "$out" | python3 -I -c '
import sys
offline = "pass the offline services\u0027 start-up check"
online = "pass the web services\u0027 start-up check"
req = "compile a code-signing requirement"
must = {"SignalMediaDecoder": {offline, req}, "SignalLinkPreviewParser": {offline, req}, "SignalVoiceNoteEncoder": {offline, req},
        "SignalLinkPreviewFetcher": {"https to the web", online, req}, "SignalGifSearch": {"https to the web", online, req},
        "Serein": {"https to the web", "write its container", req}}
system = {"read a system file", "read /etc/hosts"}
mach = "look up a Mach service"
may = {"SignalMediaDecoder": {online}, "SignalLinkPreviewParser": {online}, "SignalVoiceNoteEncoder": {online},
       "SignalLinkPreviewFetcher": system | {mach}, "SignalGifSearch": system | {mach},
       "Serein": system | {mach, "open an IOKit device", "tcp to 127.0.0.1", "list /Users", "write preferences"}}
seen, bad = {p: {} for p in must}, []
for line in sys.stdin:
    if not line.startswith("org.signalsafe.sandbox-probe."): continue
    name, rest = line.strip().split(" ", 1)
    profile = name.rsplit(".", 1)[1]
    verdict, what = rest.split(": ", 1)
    seen[profile][what] = verdict
for p, results in seen.items():
    if len(results) < 10: bad.append(f"{p}: probes missing ({len(results)})")
    for what, verdict in results.items():
        if verdict == "allowed" and what not in must[p] | may[p]: bad.append(f"{p} allows {what}")
        if verdict == "denied" and what in must[p]: bad.append(f"{p} cannot {what}")
for b in bad: print("check-sandbox-profile: " + b, file=sys.stderr)
sys.exit(1 if bad else 0)
' || fail=1
for line in "voice note" "decoder refuses voice notes: refused" "link preview fetch" "parser refuses html from the app: refused" "gif search" "hlg10.mp4 play" "avifrot.avif displayImage" "heicgrid.heic convertHEIC"; do
  echo "$out" | grep -q "^ok: $line" || { echo "check-sandbox-profile: '$line' did not run under its profile" >&2; fail=1; }
done
[ $fail -eq 0 ] && echo "check-sandbox-profile: ok"
exit $fail
