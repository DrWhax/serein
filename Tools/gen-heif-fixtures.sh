#!/bin/bash
# HEIF fixtures for ImageHEIFTests (synthetic ffmpeg test patterns, no external data):
#   AVIF from avifenc (libavif + aom): 8/10-bit, 4:2:0 / 4:4:4 / 4:0:0, grid, alpha (straight and
#     premultiplied, plain and grid), irot, imir 0/1, clap. Goldens: avifdec's y4m (decoded
#     planes, composed grid, alpha; bit-exact) and avifdec's PNG (RGBA after irot / imir / clap;
#     compared within a tolerance, since YUV → RGB conversion is not normative).
#   HEIC from macOS sips (Apple's encoder, trusted synthetic input only): a 512px-tile grid
#     with irot, and an image with an alpha auxiliary item. Golden: ffmpeg's composed planes.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/Packages/SignalCodecs/Tests/ImageHEIFTests/Resources"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$out"
: > "$out/fixtures.txt"

ff() { ffmpeg -hide_banner -loglevel error "$@"; }
ff -f lavfi -i "testsrc2=size=192x128" -frames:v 1 -y "$tmp/color.png"
ff -f lavfi -i "testsrc2=size=256x192" -frames:v 1 -y "$tmp/grid.png"
ff -f lavfi -i "testsrc2=size=160x96,format=rgba,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='255*X/W'" -frames:v 1 -y "$tmp/alpha.png"
ff -f lavfi -i "testsrc2=size=256x192,format=rgba,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='255*Y/H'" -frames:v 1 -y "$tmp/gridalpha.png"
ff -f lavfi -i "testsrc2=size=700x450" -frames:v 1 -y "$tmp/big.png"

# The y4m frame payload's MD5 (Y, U, V, then alpha if present), and whether alpha is in it
# (avifdec writes alpha to y4m only for 4:4:4; 4:2:0 alpha is checked through the PNG).
y4m_md5() { python3 -I - "$1" <<'PY'
import hashlib, sys
b = open(sys.argv[1], 'rb').read()
header = b[:b.index(b'\n')]
i = b.index(b'FRAME') ; i = b.index(b'\n', i) + 1
print(hashlib.md5(b[i:]).hexdigest(), 1 if b'alpha' in header else 0)
PY
}

avif() {   # name source avifenc-args…
  local name=$1 src=$2; shift 2
  avifenc -s 8 -q 70 "$@" "$tmp/$src.png" "$out/$name.avif" >/dev/null
  avifdec "$out/$name.avif" "$tmp/$name.y4m" >/dev/null
  avifdec "$out/$name.avif" "$out/$name.ref.png" >/dev/null
  echo "$name $(y4m_md5 "$tmp/$name.y4m")" >> "$out/fixtures.txt"
}

# (libavif encodes PNG input as 4:4:4 unless told otherwise.)
avif avif8        color     -y 420
avif avif10       color     -y 420 -d 10
avif avif444      color     -y 444
avif avif400      color     -y 400
avif avifgrid     grid      -y 420 -g 2x2
avif avifgrid444  grid      -g 2x2
avif avifalpha    alpha     -y 420
avif avifprem     alpha     -p
avif avifgridalpha gridalpha -y 420 -g 2x2
avif avifrot      color     -y 420 --irot 1
avif avifmir0     color     --imir 0
avif avifmir1     color     --imir 1
avif avifclap     color     --crop 8,4,160,112

heic() {   # name source
  local name=$1 src=$2
  sips -s format heic "$tmp/$src.png" --out "$out/$name.heic" >/dev/null
  ff -i "$out/$name.heic" -frames:v 1 -f rawvideo -pix_fmt yuvj420p -y "$tmp/$name.yuv"
  echo "$name $(md5 -q "$tmp/$name.yuv") 0" >> "$out/fixtures.txt"
}
heic heicgrid  big
heic heicalpha alpha
cat "$out/fixtures.txt"
