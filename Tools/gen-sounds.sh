#!/bin/sh
# Bundled sounds (plan Phase 0 "sounds"): upstream's sounds/*.ogg converted on the build host
# by afconvert to 16-bit PCM WAV, so the app never decodes Vorbis. build-app.sh puts them in
# SignalSafe.app/Contents/Library/Sounds, where UNNotificationSound(named:) finds them.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/App/SignalSafe/Resources/Sounds"
mkdir -p "$out"
for f in "$root"/Signal-Desktop/sounds/*.ogg; do
  name=$(basename "$f" .ogg)
  afconvert -f WAVE -d LEI16 "$f" "$out/$name.wav"
done
ls "$out"
