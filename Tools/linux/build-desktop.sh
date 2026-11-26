#!/bin/sh
# Run in the Linux toolchain with the patched Serein checkout and sibling QtSwiftUI.
# Pass an empty staging directory, then use it as the Desktop.Dockerfile context.
set -eu
root=${SEREIN_SOURCE:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
stage=${1:?pass an empty output directory}
configuration=${SEREIN_BUILD_CONFIGURATION:-release}
jobs=${SEREIN_BUILD_JOBS:-4}
if [ -d "$stage" ] && [ -n "$(ls -A "$stage")" ]; then
    echo "Use an empty staging directory." >&2
    exit 1
fi
mkdir -p "$stage/bin" "$stage/share/sounds" "$stage/share/licenses" "$stage/share/icons/hicolor/256x256/apps"
build_products() {
    package=$1
    shift
    build_root=${SEREIN_BUILD_CACHE:-"$root/.cache/linux-desktop"}/$(basename "$package")
    for product do
        swift build --package-path "$root/$package" --scratch-path "$build_root" -c "$configuration" -j "$jobs" --product "$product"
    done
    products=$(swift build --package-path "$root/$package" --scratch-path "$build_root" -c "$configuration" --show-bin-path)
    for product do install -m 0755 "$products/$product" "$stage/bin/$product"; done
    for bundle in "$products"/*.resources "$products"/*.bundle; do
        if [ -d "$bundle" ]; then cp -R "$bundle" "$stage/bin/"; fi
    done
}
build_products App/SignalSafe SignalSafe
build_products Packages/SignalMediaService SignalMediaDecoderService SignalVoiceNoteEncoderService \
    SignalLinkPreviewParserService SignalLinkPreviewFetcherService SignalGifSearchService
build_products Packages/SignalCore SignalMessageParserService SignalMessageParserChild
build_products Packages/SignalRingRTC SignalCallingService
if [ -d "$root/App/SignalSafe/Resources/Sounds" ]; then
    cp "$root"/App/SignalSafe/Resources/Sounds/*.wav "$stage/share/sounds/"
else
    # Decode only the project's bundled tones during packaging.
    for sound in "$root"/Signal-Desktop/sounds/*.ogg; do
        test -f "$sound" || { echo "Populate the Signal-Desktop sound fixtures before packaging." >&2; exit 1; }
        ffmpeg -nostdin -loglevel error -i "$sound" -c:a pcm_s16le "$stage/share/sounds/$(basename "$sound" .ogg).wav"
    done
fi
cp "$root/App/SignalSafe/VERSION" "$stage/share/version"
cp "$root/Packages/SignalRingRTC/LICENSE-Opus.txt" "$stage/share/licenses/"
for codec in ImageWebP VideoVP8 VideoVP9; do
    mkdir -p "$stage/share/licenses/$codec"
    for notice in "$root/Packages/SignalCodecs/Sources/$codec/"LICENSE* "$root/Packages/SignalCodecs/Sources/$codec/"NOTICE* "$root/Packages/SignalCodecs/Sources/$codec/"PATENTS*; do
        if [ -f "$notice" ]; then
            cp "$notice" "$stage/share/licenses/$codec/"
        fi
    done
done
cp "$root/Packages/SignalUI/Sources/SignalUI/Resources/Images/serein-logo@2x.png" "$stage/share/icons/hicolor/256x256/apps/org.signalsafe.SignalSafe.png"
cp "$root/Tools/linux/serein-session.py" "$root/Tools/linux/org.signalsafe.SignalSafe.policy" \
    "$root/Tools/linux/org.signalsafe.SignalSafe.desktop" "$stage/"
