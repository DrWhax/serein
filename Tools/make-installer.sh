#!/bin/sh
# Builds the Serein installer: a disk image holding Serein.app next to an Applications link,
# so installing is a drag. Output: dist/Serein-<version>.dmg
#
#   SIGNALSAFE_SIGN_IDENTITY=<identity> Tools/make-installer.sh
#
# Environment:
#   SIGNALSAFE_SIGN_IDENTITY  codesign identity (name or SHA-1) for the app and the disk image;
#                             unset: ad-hoc, which runs only on this Mac.
#   NOTARY_PROFILE            a `xcrun notarytool store-credentials` keychain profile: the image
#                             is notarised and stapled. Needs a "Developer ID Application"
#                             identity; without it, other Macs' Gatekeeper refuses the app.
#   SKIP_BUILD=1              package the existing App/SignalSafe/.build/Serein.app as is.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
app="$root/App/SignalSafe/.build/Serein.app"
sign="${SIGNALSAFE_SIGN_IDENTITY:--}"

if [ "${SKIP_BUILD:-0}" != 1 ]; then
  "$root/Tools/build-app.sh"
fi
[ -d "$app" ] || { echo "error: $app not found (run without SKIP_BUILD)" >&2; exit 1; }

# The bundle must be intact before it is shipped: every nested signature valid.
codesign --verify --deep --strict "$app"

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
dist="$root/dist"
dmg="$dist/Serein-$version.dmg"
stage="$root/App/SignalSafe/.build/dmg-stage"
mkdir -p "$dist"
rm -rf "$stage" "$dmg"
mkdir -p "$stage"
trap 'rm -rf "$stage"' EXIT

# ditto keeps the bundle's signatures, extended attributes and symlinks intact.
ditto "$app" "$stage/Serein.app"
ln -s /Applications "$stage/Applications"

# A compressed (LZFSE), read-only image.
hdiutil create -quiet -volname "Serein" -srcfolder "$stage" -fs HFS+ -format ULFO -ov "$dmg"
hdiutil verify -quiet "$dmg"

if [ "$sign" != "-" ]; then
  codesign --force --sign "$sign" --timestamp=none "$dmg"
fi

if [ -n "${NOTARY_PROFILE:-}" ]; then
  if ! security find-identity -v -p codesigning | grep -F -- "$sign" | grep -q '"Developer ID Application'; then
    echo "error: notarisation needs a Developer ID Application identity (SIGNALSAFE_SIGN_IDENTITY)" >&2
    exit 1
  fi
  codesign --force --sign "$sign" --timestamp "$dmg"
  xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
else
  echo "note: not notarised (set NOTARY_PROFILE with a Developer ID identity); other Macs' Gatekeeper will block it" >&2
fi

echo "$dmg ($(du -h "$dmg" | cut -f1))"
