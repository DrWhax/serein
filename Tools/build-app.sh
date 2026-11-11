#!/bin/sh
# Builds Serein.app (release) from App/SignalSafe: the SwiftPM executable plus the
# package resource bundles in Contents/Resources (where Bundle.module looks inside an app),
# an Info.plist, the app icon (from Logo/Serein.png), and a signature.
# Output: App/SignalSafe/.build/Serein.app. The bundle id (org.signalsafe.SignalSafe) and the
# data folder are unchanged, so the Keychain DB key and camera/mic grants carry over.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
pkg="$root/App/SignalSafe"
# Serein's changes to the submodules (SQLCipher for GRDB; libsignal's AES-CBC bridge and
# media sanitizers) live in Tools/vendor-patches; applying them is idempotent.
"$root/Tools/apply-vendor-patches.sh" >/dev/null
for lib in vendor/libsignal/target/aarch64-apple-darwin/release/libsignal_ffi.a \
           Packages/SignalRingRTC/rust/target/aarch64-apple-darwin/release/libsignal_ringrtc.dylib; do
  [ -f "$root/$lib" ] || { echo "build-app: $lib is missing; see README.md, Building" >&2; exit 1; }
done
cd "$pkg"
swift build -c release
products="$pkg/.build/out/Products/Release"
app="$pkg/.build/Serein.app"
rm -rf "$app" "$pkg/.build/SignalSafe.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$products/SignalSafe" "$app/Contents/MacOS/Serein"
# App icon: the trusted logo, resized and packed by the system tools at build time.
iconset="$pkg/.build/Serein.iconset"
rm -rf "$iconset"; mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z $size $size "$root/Logo/Serein.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$root/Logo/Serein.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/Serein.icns"
rm -rf "$iconset"
for b in "$products"/*.bundle; do cp -R "$b" "$app/Contents/Resources/"; done
# Dynamic libraries: SQLCipher.framework (GRDB) and ringrtc's dylib, loaded from
# Contents/Frameworks; the build-tree rpath SwiftPM adds is removed.
mkdir -p "$app/Contents/Frameworks"
cp -R "$products/SQLCipher.framework" "$app/Contents/Frameworks/"
ringrtc="$root/Packages/SignalRingRTC/rust/target/aarch64-apple-darwin/release"
cp "$ringrtc/libsignal_ringrtc.dylib" "$app/Contents/Frameworks/"
bin="$app/Contents/MacOS/Serein"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$bin"
install_name_tool -delete_rpath "$ringrtc" "$bin" 2>/dev/null || true
# The XPC services (Packages/SignalMediaService), each signed with App Sandbox plus its own
# Seatbelt profile (Sandbox/<Service>.sb; Tools/sbpl-entitlements.sh puts the rules in
# com.apple.security.temporary-exception.sbpl, and `;!` lines add entitlements). Each refuses
# to run unless its profile is in force; Tools/check-sandbox-profile.sh probes them.
#   SignalMediaDecoder.xpc       every image, audio and video decode (no network, no files)
#   SignalLinkPreviewParser.xpc  link-preview HTML (no network, no files)
#   SignalLinkPreviewFetcher.xpc fetches link previews from the web (outgoing network only)
#   SignalGifSearch.xpc          Giphy through Signal's content proxy (outgoing network only)
#   SignalVoiceNoteEncoder.xpc   encodes recorded voice notes to MP3 (no network, no files)
svcpkg="$root/Packages/SignalMediaService"
sign="${SIGNALSAFE_SIGN_IDENTITY:--}"
# Who may talk to whom (MediaXPCInterface/XPCPeer.swift): every bundle gets every component's
# signing identifier. With a signing identity a peer must also share this build's Team ID under
# an Apple-issued certificate (SereinXPCSameTeam); ad-hoc signatures have no Team ID, so only
# the identifier can be required.
team=""
if [ "$sign" != "-" ]; then
  tprobe="$pkg/.build/teamid-probe"
  cp /usr/bin/true "$tprobe"
  codesign --force --sign "$sign" --timestamp=none "$tprobe" 2>/dev/null
  team=$(codesign -dv "$tprobe" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  rm -f "$tprobe"
  [ "$team" = "not set" ] && team=""
fi
sameteam=""
[ -n "$team" ] && sameteam="
  <key>SereinXPCSameTeam</key><true/>"
peers="  <key>SereinXPCPeers</key>
  <dict>
    <key>app</key><string>org.signalsafe.SignalSafe</string>
    <key>decoder</key><string>org.signalsafe.SignalMediaDecoder</string>
    <key>parser</key><string>org.signalsafe.SignalLinkPreviewParser</string>
    <key>fetcher</key><string>org.signalsafe.SignalLinkPreviewFetcher</string>
    <key>gifs</key><string>org.signalsafe.SignalGifSearch</string>
    <key>voice</key><string>org.signalsafe.SignalVoiceNoteEncoder</string>
  </dict>$sameteam"
services="SignalMediaDecoder SignalLinkPreviewParser SignalLinkPreviewFetcher SignalGifSearch SignalVoiceNoteEncoder"
service() {   # name product [extra Info.plist lines]
  name=$1 product=$2 extra=${3:-}
  (cd "$svcpkg" && swift build -c release --product "$product")
  dir="$app/Contents/XPCServices/$name.xpc"
  mkdir -p "$dir/Contents/MacOS"
  cp "$svcpkg/.build/out/Products/Release/$product" "$dir/Contents/MacOS/$name"
  cat > "$dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>org.signalsafe.$name</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>XPCService</key>
  <dict>
    <key>ServiceType</key><string>Application</string>
  </dict>
$peers
$extra
</dict>
</plist>
PLIST
  plutil -lint -s "$dir/Contents/Info.plist"
  "$root/Tools/sbpl-entitlements.sh" "$svcpkg/Sandbox/$name.sb" > "$pkg/.build/$name.entitlements"
  plutil -lint -s "$pkg/.build/$name.entitlements"
}
service SignalMediaDecoder SignalMediaDecoderService
service SignalVoiceNoteEncoder SignalVoiceNoteEncoderService
service SignalLinkPreviewParser SignalLinkPreviewParserService
service SignalLinkPreviewFetcher SignalLinkPreviewFetcherService
# Signal's content proxy, as the app's ATS exceptions below have it.
service SignalGifSearch SignalGifSearchService '  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSExceptionDomains</key>
    <dict>
      <key>contentproxy.signal.org</key>
      <dict>
        <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
        <key>NSExceptionMinimumTLSVersion</key><string>TLSv1.2</string>
        <key>NSExceptionRequiresForwardSecrecy</key><true/>
      </dict>
    </dict>
  </dict>'
xpc="$app/Contents/XPCServices/SignalMediaDecoder.xpc"
lpxpc="$app/Contents/XPCServices/SignalLinkPreviewParser.xpc"
# Everything runs under the hardened runtime. Ad-hoc signatures (the default) carry no Team ID,
# so library validation would refuse the bundled SQLCipher/ringrtc: ad-hoc builds add the
# disable-library-validation entitlement (the rest of the hardened runtime stays: no DYLD_*
# injection, no unsigned executable memory, no debugger attach). With
# SIGNALSAFE_SIGN_IDENTITY set to an "Apple Development: …" (free Personal Team from Xcode →
# Settings → Accounts) or "Developer ID Application: …" identity, all code shares one Team ID
# and the exception is left out (`security find-identity -v -p codesigning` lists them). The XPC service never needs it (it loads no libraries of ours).
hardened="--options runtime"
adhoc_ent=""
timestamp="--timestamp=none"
if [ "$sign" = "-" ]; then
  adhoc_ent='  <key>com.apple.security.cs.disable-library-validation</key><true/>'
# A Developer ID identity (given by name or by SHA-1 hash): notarisation needs a secure
# timestamp on every signature, the XPC services' included.
elif security find-identity -v -p codesigning | grep -F -- "$sign" | grep -q '"Developer ID Application'; then
  timestamp="--timestamp"
fi
hardened="$hardened $timestamp"
codesign --force --sign "$sign" $hardened "$app/Contents/Frameworks/libsignal_ringrtc.dylib"
codesign --force --sign "$sign" $hardened "$app/Contents/Frameworks/SQLCipher.framework"
for name in $services; do
  codesign --force --sign "$sign" $timestamp --options runtime --entitlements "$pkg/.build/$name.entitlements" "$app/Contents/XPCServices/$name.xpc"
done
# Each process holds only its own parsers. Swift symbols name their module ($s<length><name>).
decoders='8ImagePNG|9ImageJPEG|8ImageGIF|9ImageWebP|8ImageBMP|12ContainerMP4|9VideoH264|9VideoHEVC|8VideoAV1|9ImageHEIF|8AudioAAC|8AudioMP3|18SignalMediaDecoder'
web='8WebFetch|18LinkPreviewFetcher|9GifSearch'
links() {   # binary pattern message
  if nm "$1" | grep -E "\\\$s($2)" >/dev/null; then echo "error: $3" >&2; exit 1; fi
}
links "$xpc/Contents/MacOS/SignalMediaDecoder" "8HTMLMeta|17LinkPreviewParser|$web" "HTML parser or web client linked into the media decoder"
links "$lpxpc/Contents/MacOS/SignalLinkPreviewParser" "$decoders|$web" "media decoders or web client linked into the link-preview parser"
links "$app/Contents/XPCServices/SignalLinkPreviewFetcher.xpc/Contents/MacOS/SignalLinkPreviewFetcher" "$decoders|8HTMLMeta|9GifSearch" \
  "decoders, HTML parser or GIF search linked into the link-preview fetcher"
links "$app/Contents/XPCServices/SignalGifSearch.xpc/Contents/MacOS/SignalGifSearch" "$decoders|8HTMLMeta|18LinkPreviewFetcher" \
  "decoders, HTML parser or link-preview fetcher linked into the GIF service"
# The voice-note encoder links the MP3 module (its encoder) and nothing else that reads media.
links "$app/Contents/XPCServices/SignalVoiceNoteEncoder.xpc/Contents/MacOS/SignalVoiceNoteEncoder" \
  "8ImagePNG|9ImageJPEG|8ImageGIF|9ImageWebP|8ImageBMP|12ContainerMP4|9VideoH264|9VideoHEVC|8VideoAV1|9ImageHEIF|8AudioAAC|18SignalMediaDecoder|8HTMLMeta|$web" \
  "decoders, HTML parser or web client linked into the voice-note encoder"
# The app neither decodes nor fetches or parses web content: every untrusted parse is in a
# service. (ImagePNG is the one exception: SignalUI's BundledImage decodes our own Resources/Images.)
links "$app/Contents/MacOS/Serein" "9ImageJPEG|8ImageGIF|9ImageWebP|8ImageBMP|12ContainerMP4|9VideoH264|9VideoHEVC|8VideoAV1|9ImageHEIF|8AudioAAC|8AudioMP3|8HTMLMeta|$web" \
  "decoder or web-client symbols linked into the app binary"
# Notification and call sounds (generated WAVs; UNNotificationSound looks in Library/Sounds).
[ -f "$pkg/Resources/Sounds/pop.wav" ] || "$root/Tools/gen-sounds.sh" >/dev/null
mkdir -p "$app/Contents/Library/Sounds"
cp "$pkg"/Resources/Sounds/*.wav "$app/Contents/Library/Sounds/"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Serein</string>
  <key>CFBundleIdentifier</key><string>org.signalsafe.SignalSafe</string>
  <key>CFBundleName</key><string>Serein</string>
  <key>CFBundleDisplayName</key><string>Serein</string>
  <key>CFBundleIconFile</key><string>Serein</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.social-networking</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
$peers
  <key>NSSupportsAutomaticTermination</key><false/>
  <!-- Upstream's usage strings (package.json mac.extendInfo), with the app's name. -->
  <key>NSCameraUsageDescription</key><string>Serein uses your camera for video calling.</string>
  <key>NSMicrophoneUsageDescription</key><string>Serein needs access to your microphone to make and receive phone calls and record voice messages.</string>
  <!-- Signal's own-CA hosts: ATS's system-trust check would reject Signal's private root, so it is
       lifted for exactly these hosts; HTTPClient still requires the chain to end at
       the pinned Signal root, and HTTPClient refuses http:// URLs and redirects. -->
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSExceptionDomains</key>
    <dict>
      <key>storage.signal.org</key>
      <dict>
        <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
        <key>NSExceptionMinimumTLSVersion</key><string>TLSv1.2</string>
        <key>NSExceptionRequiresForwardSecrecy</key><true/>
      </dict>
      <key>cdn.signal.org</key>
      <dict>
        <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
        <key>NSExceptionMinimumTLSVersion</key><string>TLSv1.2</string>
        <key>NSExceptionRequiresForwardSecrecy</key><true/>
      </dict>
      <key>cdn2.signal.org</key>
      <dict>
        <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
        <key>NSExceptionMinimumTLSVersion</key><string>TLSv1.2</string>
        <key>NSExceptionRequiresForwardSecrecy</key><true/>
      </dict>
      <key>cdn3.signal.org</key>
      <dict>
        <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
        <key>NSExceptionMinimumTLSVersion</key><string>TLSv1.2</string>
        <key>NSExceptionRequiresForwardSecrecy</key><true/>
      </dict>
      <key>sfu.voip.signal.org</key>
      <dict>
        <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
        <key>NSExceptionMinimumTLSVersion</key><string>TLSv1.2</string>
        <key>NSExceptionRequiresForwardSecrecy</key><true/>
      </dict>
      <key>storage-staging.signal.org</key>
      <dict>
        <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
        <key>NSExceptionMinimumTLSVersion</key><string>TLSv1.2</string>
        <key>NSExceptionRequiresForwardSecrecy</key><true/>
      </dict>
      <key>cdn-staging.signal.org</key>
      <dict>
        <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
        <key>NSExceptionMinimumTLSVersion</key><string>TLSv1.2</string>
        <key>NSExceptionRequiresForwardSecrecy</key><true/>
      </dict>
      <key>cdn2-staging.signal.org</key>
      <dict>
        <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
        <key>NSExceptionMinimumTLSVersion</key><string>TLSv1.2</string>
        <key>NSExceptionRequiresForwardSecrecy</key><true/>
      </dict>
      <key>cdn3-staging.signal.org</key>
      <dict>
        <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
        <key>NSExceptionMinimumTLSVersion</key><string>TLSv1.2</string>
        <key>NSExceptionRequiresForwardSecrecy</key><true/>
      </dict>
      <key>sfu.staging.voip.signal.org</key>
      <dict>
        <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
        <key>NSExceptionMinimumTLSVersion</key><string>TLSv1.2</string>
        <key>NSExceptionRequiresForwardSecrecy</key><true/>
      </dict>
    </dict>
  </dict>
</dict>
</plist>
PLIST
# The app's data moves into its sandbox container on the first sandboxed launch (macOS reads
# Resources/container-migration.plist when it creates the container): the databases, their
# attachments and the preferences. The Keychain item holding the database key is unaffected.
cat > "$app/Contents/Resources/container-migration.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Move</key>
  <array>
    <string>${ApplicationSupport}/signal-safe</string>
    <string>${ApplicationSupport}/signal-safe-staging</string>
    <string>${Library}/Preferences/org.signalsafe.SignalSafe.plist</string>
  </array>
</dict>
</plist>
PLIST
plutil -lint -s "$app/Contents/Resources/container-migration.plist"
# The app: App Sandbox, network client, camera, microphone, user-selected files, its crash
# reports read-only, and the Seatbelt rules of Sandbox/Serein.sb; it refuses to start without them.
appent="$pkg/.build/SignalSafe.entitlements"
"$root/Tools/sbpl-entitlements.sh" "$svcpkg/Sandbox/Serein.sb" "$adhoc_ent" > "$appent"
plutil -lint -s "$appent"
codesign --force --sign "$sign" $hardened --entitlements "$appent" "$app"
for target in "$app" $(for n in $services; do echo "$app/Contents/XPCServices/$n.xpc"; done); do
  codesign -d --entitlements - "$target" 2>/dev/null | grep -q "com.apple.security.app-sandbox" || { echo "error: $target not sandboxed" >&2; exit 1; }
  codesign -d --entitlements - "$target" 2>/dev/null | grep -q "com.apple.security.temporary-exception.sbpl" || { echo "error: $target lacks its Seatbelt profile" >&2; exit 1; }
done
echo "$app"
