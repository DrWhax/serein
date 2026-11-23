#!/bin/sh
# Builds the disk image for a release tag and attaches it, with its SHA-256, to the GitHub
# release. Run by .github/workflows/release-binary.yml when a release is published, or by hand:
#
#   Tools/release-binary.sh v0.2.2              build dist/Serein-0.2.2.dmg and upload it
#   Tools/release-binary.sh v0.2.2 --no-upload  build only
#
# Signing follows Tools/make-installer.sh: ad-hoc unless SIGNALSAFE_SIGN_IDENTITY is set (an
# ad-hoc build opens on other Macs only after `xattr -dr com.apple.quarantine Serein.app`);
# NOTARY_PROFILE also notarises. Uploading needs gh authenticated (GH_TOKEN in Actions).
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
tag=${1:?usage: Tools/release-binary.sh <tag> [--no-upload]}
upload=1
[ "${2:-}" = "--no-upload" ] && upload=0
version=${tag#v}

# The app's version is hardcoded in build-app.sh (CFBundleShortVersionString, twice): a binary
# for this tag must carry the same number.
built=$(sed -n 's/.*<key>CFBundleShortVersionString<\/key><string>\([^<]*\)<\/string>.*/\1/p' "$root/Tools/build-app.sh" | sort -u)
if [ "$built" != "$version" ]; then
  echo "error: tag $tag, but Tools/build-app.sh builds version $built; bump CFBundleShortVersionString (twice) first" >&2
  exit 1
fi
# Build what the tag points at, not uncommitted work (vendor/ patches are build-app's own).
if git -C "$root" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  if [ "$(git -C "$root" rev-parse HEAD)" != "$(git -C "$root" rev-parse "$tag^{commit}")" ]; then
    echo "error: HEAD is not $tag; check it out first" >&2
    exit 1
  fi
fi
if [ -n "$(git -C "$root" status --porcelain --untracked-files=no -- . ':!vendor')" ]; then
  echo "error: the working tree has uncommitted changes" >&2
  exit 1
fi

"$root/Tools/make-installer.sh"
dmg="$root/dist/Serein-$version.dmg"
[ -f "$dmg" ] || { echo "error: $dmg was not built" >&2; exit 1; }
(cd "$root/dist" && shasum -a 256 "Serein-$version.dmg" > "Serein-$version.dmg.sha256")
cat "$dmg.sha256"

if [ "$upload" = 1 ]; then
  gh release upload "$tag" "$dmg" "$dmg.sha256" --clobber
  echo "release-binary: attached Serein-$version.dmg to $tag"
fi
