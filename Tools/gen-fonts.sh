#!/bin/bash
# Converts upstream's bundled WOFF2 fonts (trusted, build-time input) to TrueType for
# SignalUI's resource bundle: Inter v3.19, SignalSymbols (variable), MonoSpecial and the
# story fonts. Uses fontTools in .cache/pyenv (pinned). CoreText registers the TTFs at
# runtime (process scope); nothing parses fonts from the network.
set -euo pipefail
cd "$(dirname "$0")/.."
venv=.cache/pyenv
if [ ! -x "$venv/bin/python" ]; then
  python3 -m venv "$venv"
  "$venv/bin/pip" install --quiet "fonttools[woff]==4.60.1"
fi
out=Packages/SignalUI/Sources/SignalUI/Resources/Fonts
mkdir -p "$out"
fonts=(inter-v3.19/Inter-Regular inter-v3.19/Inter-Italic inter-v3.19/Inter-Medium inter-v3.19/Inter-SemiBold
       inter-v3.19/Inter-SemiBoldItalic inter-v3.19/Inter-Bold inter-v3.19/Inter-BoldItalic
       signal-symbols/SignalSymbolsVariable mono-special/MonoSpecial-Regular stories/Hatsuishi-Regular)
for f in "${fonts[@]}"; do
  "$venv/bin/python" -I -c '
import sys
from fontTools.ttLib import TTFont
font = TTFont(sys.argv[1])
font.flavor = None
font.save(sys.argv[2])
' "Signal-Desktop/fonts/$f.woff2" "$out/$(basename "$f").ttf"
done
cp Signal-Desktop/fonts/stories/*.ttf "$out/"

# Signal's large emoji font (Storybook and the app's optional-fonts asset load it from
# updates.signal.org): pinned by SHA-256, then both emoji fonts go CBDT → sbix for CoreText.
large=.cache/emoji-font/desktop-32-64-v2.0.4.woff2
large_sha=7e90ca91e97f2b63962d9630e68d0a0a4e7c5ebde139f46855231a6876515e56
if [ ! -f "$large" ]; then
  mkdir -p .cache/emoji-font
  curl -sSfL -o "$large" https://updates.signal.org/static/android/emoji/font/desktop-32-64-v2.0.4.woff2
fi
echo "$large_sha  $large" | shasum -a 256 -c --quiet
"$venv/bin/python" -I Tools/gen-emoji-fonts.py "$out"
ls "$out" | wc -l | xargs echo "fonts:"
