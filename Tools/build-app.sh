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
</dict>
</plist>
PLIST
codesign --force --sign - --timestamp=none "$app"
echo "$app"
