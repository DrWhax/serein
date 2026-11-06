#!/bin/sh
# Builds SignalSafe.app (release) from App/SignalSafe: the SwiftPM executable plus the
# package resource bundles in Contents/Resources (where Bundle.module looks inside an app),
# an Info.plist, and an ad-hoc signature. Output: App/SignalSafe/.build/SignalSafe.app
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
pkg="$root/App/SignalSafe"
cd "$pkg"
swift build -c release
products="$pkg/.build/out/Products/Release"
app="$pkg/.build/SignalSafe.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$products/SignalSafe" "$app/Contents/MacOS/SignalSafe"
for b in "$products"/*.bundle; do cp -R "$b" "$app/Contents/Resources/"; done
# Dynamic libraries: SQLCipher.framework (GRDB) and ringrtc's dylib, loaded from
# Contents/Frameworks; the build-tree rpath SwiftPM adds is removed.
mkdir -p "$app/Contents/Frameworks"
cp -R "$products/SQLCipher.framework" "$app/Contents/Frameworks/"
ringrtc="$root/Packages/SignalRingRTC/rust/target/aarch64-apple-darwin/release"
cp "$ringrtc/libsignal_ringrtc.dylib" "$app/Contents/Frameworks/"
bin="$app/Contents/MacOS/SignalSafe"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$bin"
install_name_tool -delete_rpath "$ringrtc" "$bin" 2>/dev/null || true
# SignalMediaDecoder.xpc (plan.md, sandboxed decoder): built from Packages/SignalMediaService,
# signed with App Sandbox as its only entitlement — no network, no file access.
svcpkg="$root/Packages/SignalMediaService"
(cd "$svcpkg" && swift build -c release --product SignalMediaDecoderService)
xpc="$app/Contents/XPCServices/SignalMediaDecoder.xpc"
mkdir -p "$xpc/Contents/MacOS"
cp "$svcpkg/.build/out/Products/Release/SignalMediaDecoderService" "$xpc/Contents/MacOS/SignalMediaDecoder"
cat > "$xpc/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>SignalMediaDecoder</string>
  <key>CFBundleIdentifier</key><string>org.signalsafe.SignalMediaDecoder</string>
  <key>CFBundleName</key><string>SignalMediaDecoder</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>XPCService</key>
  <dict>
    <key>ServiceType</key><string>Application</string>
    <key>RunLoopType</key><string>NSRunLoop</string>
  </dict>
</dict>
</plist>
PLIST
ent="$pkg/.build/SignalMediaDecoder.entitlements"
cat > "$ent" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key><true/>
</dict>
</plist>
PLIST
# Everything runs under the hardened runtime. Ad-hoc signatures (the default) carry no Team ID,
# so library validation would refuse the bundled SQLCipher/ringrtc: ad-hoc builds add the
# disable-library-validation entitlement (the rest of the hardened runtime stays: no DYLD_*
# injection, no unsigned executable memory, no debugger attach). With
# SIGNALSAFE_SIGN_IDENTITY set to an "Apple Development: …" (free Personal Team from Xcode →
# Settings → Accounts) or "Developer ID Application: …" identity, all code shares one Team ID
# and the exception is left out (`security find-identity -v -p codesigning` lists them). The XPC service never needs it (it loads no libraries of ours).
sign="${SIGNALSAFE_SIGN_IDENTITY:--}"
hardened="--options runtime"
adhoc_ent=""
case "$sign" in
  -) adhoc_ent='  <key>com.apple.security.cs.disable-library-validation</key><true/>' ;;
  "Developer ID"*) hardened="$hardened --timestamp" ;;    # notarisation needs a secure timestamp
esac
codesign --force --sign "$sign" $hardened "$app/Contents/Frameworks/libsignal_ringrtc.dylib"
codesign --force --sign "$sign" $hardened "$app/Contents/Frameworks/SQLCipher.framework"
codesign --force --sign "$sign" --timestamp=none --options runtime --entitlements "$ent" "$xpc"
# The app must not contain decoders: every untrusted parse goes through the service.
# (ImagePNG is the one exception: SignalUI's BundledImage decodes our own Resources/Images.)
if nm "$app/Contents/MacOS/SignalSafe" | grep -E '\$s(9ImageJPEG|8ImageGIF|9ImageWebP|8ImageBMP|12ContainerMP4|9VideoH264|9VideoHEVC|8AudioAAC|8AudioMP3|8HTMLMeta)' >/dev/null; then
  echo "error: decoder symbols linked into the app binary" >&2; exit 1
fi
# Notification and call sounds (generated WAVs; UNNotificationSound looks in Library/Sounds).
[ -f "$pkg/Resources/Sounds/pop.wav" ] || "$root/Tools/gen-sounds.sh" >/dev/null
mkdir -p "$app/Contents/Library/Sounds"
cp "$pkg"/Resources/Sounds/*.wav "$app/Contents/Library/Sounds/"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>SignalSafe</string>
  <key>CFBundleIdentifier</key><string>org.signalsafe.SignalSafe</string>
  <key>CFBundleName</key><string>SignalSafe</string>
  <key>CFBundleDisplayName</key><string>SignalSafe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.social-networking</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <!-- Signal's own-CA hosts: ATS's system-trust check would reject Signal's private root, so it is
       lifted for exactly these hosts; HTTPClient / LinkPreviewFetch still require the chain to end at
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
      <key>contentproxy.signal.org</key>
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
appent="$pkg/.build/SignalSafe.entitlements"
cat > "$appent" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key><true/>
  <key>com.apple.security.device.camera</key><true/>
$adhoc_ent
</dict>
</plist>
PLIST
codesign --force --sign "$sign" $hardened --entitlements "$appent" "$app"
codesign -d --entitlements - "$xpc" 2>/dev/null | grep -q "com.apple.security.app-sandbox" || { echo "error: service not sandboxed" >&2; exit 1; }
echo "$app"
