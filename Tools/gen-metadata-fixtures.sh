#!/bin/bash
# Fixtures for SignalCodecs' MetadataStripTests: small images and videos of every format
# MetadataStrip handles, carrying the metadata a phone or camera writes (GPS, camera,
# dates, XMP, IPTC, comments), added with exiftool. Test-time only.
#
#   Tools/gen-metadata-fixtures.sh
set -euo pipefail
cd "$(dirname "$0")/.."
out=Packages/SignalCodecs/Tests/MetadataStripTests/Resources
core=Packages/SignalCore/Tests/SignalCoreTests/Resources/Metadata
mkdir -p "$out"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

ffmpeg -v error -y -f lavfi -i testsrc=size=96x64 -frames:v 1 -q:v 3 "$tmp/base.jpg"
ffmpeg -v error -y -f lavfi -i testsrc=size=96x64 -frames:v 1 "$tmp/base.png"
ffmpeg -v error -y -f lavfi -i testsrc=size=96x64:rate=10 -frames:v 5 "$tmp/base.gif"
cwebp -quiet -q 80 "$tmp/base.png" -o "$tmp/base.webp"
ffmpeg -v error -y -f lavfi -i testsrc=size=96x64:rate=30 -frames:v 6 -c:v libx264 -profile:v baseline -pix_fmt yuv420p "$tmp/moov_last.mp4"
ffmpeg -v error -y -i "$tmp/moov_last.mp4" -c copy -movflags +faststart "$tmp/faststart.mp4"
ffmpeg -v error -y -i "$tmp/moov_last.mp4" -c copy -f mov "$tmp/clip.mov"
sips -s format heic "$tmp/base.jpg" --out "$tmp/base.heic" >/dev/null

tags=(-GPSLatitude=48.8577 -GPSLatitudeRef=N -GPSLongitude=2.2950 -GPSLongitudeRef=E -Make=SecretMake -Model=SecretModel
      -DateTimeOriginal="2024:01:02 03:04:05" -XMP-dc:Creator=SecretCreator)
cp "$tmp/base.jpg" "$out/photo.jpg"
exiftool -q -overwrite_original "${tags[@]}" -Orientation#=6 -IPTC:Keywords=SecretKeyword -Comment=SecretComment "$out/photo.jpg"
cp "$tmp/base.png" "$out/image.png"
exiftool -q -overwrite_original "${tags[@]}" -PNG:Comment=SecretComment "$out/image.png"
cp "$tmp/base.webp" "$out/image.webp"
exiftool -q -overwrite_original "${tags[@]}" "$out/image.webp"
cp "$tmp/base.gif" "$out/anim.gif"
exiftool -q -overwrite_original -XMP-dc:Creator=SecretCreator -Comment=SecretComment "$out/anim.gif"
cp "$tmp/base.heic" "$out/photo.heic"
exiftool -q -overwrite_original "${tags[@]}" "$out/photo.heic"
for v in moov_last faststart; do
  cp "$tmp/$v.mp4" "$out/$v.mp4"
  exiftool -q -overwrite_original -Title=SecretTitle -GPSCoordinates="48.8577, 2.2950" -Make=SecretMake "$out/$v.mp4"
done
cp "$tmp/clip.mov" "$out/clip.mov"
exiftool -q -overwrite_original -Title=SecretTitle -GPSCoordinates="48.8577, 2.2950" -Make=SecretMake "$out/clip.mov"
mkdir -p "$core" && cp "$out"/* "$core"/
ls -l "$out"
