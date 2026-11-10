#!/bin/bash
# Synthetic AV1 still-image streams (ffmpeg test patterns, no external data) for
# VideoAV1Tests: one key frame each, from aomenc (all-intra or good-quality mode) or
# SVT-AV1 (--avif), with the tool under test switched on. Golden: the MD5 of dav1d's raw
# output (Y, U, V; 16-bit little-endian above 8 bits; film grain applied), cross-checked
# against aomdec. The decoder must match it exactly; AV1CoverageTests checks that together
# the fixtures use every tool.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/Packages/SignalCodecs/Tests/VideoAV1Tests/Resources"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$out"
: > "$out/fixtures.txt"

# gen name size pattern pix_fmt encoder(ai|good|svt) encoder-args…
gen() {
  local name=$1 size=$2 pattern=$3 pix=$4 enc=$5; shift 5
  local src="$pattern=size=$size"
  case "$pattern" in noisy) src="testsrc2=size=$size,noise=alls=30:allf=t" ;; esac
  ffmpeg -hide_banner -loglevel error -f lavfi -i "$src" -frames:v 1 -pix_fmt "$pix" -strict -1 -y "$tmp/$name.y4m"
  case "$enc" in
    ai)   aomenc -q --allintra --limit=1 --obu "$@" -o "$out/$name.obu" "$tmp/$name.y4m" 2>/dev/null ;;
    good) aomenc -q --limit=1 --obu "$@" -o "$out/$name.obu" "$tmp/$name.y4m" 2>/dev/null ;;
    svt)  SvtAv1EncApp --avif 1 -i "$tmp/$name.y4m" -b "$tmp/$name.ivf" "$@" >/dev/null 2>&1
          python3 -I - "$tmp/$name.ivf" "$out/$name.obu" <<'IVF'
import sys
b = open(sys.argv[1], 'rb').read()
assert b[:4] == b'DKIF'
i = int.from_bytes(b[6:8], 'little')
n = int.from_bytes(b[i:i + 4], 'little')
open(sys.argv[2], 'wb').write(b[i + 12:i + 12 + n])
IVF
          ;;
  esac
  dav1d -q --muxer yuv -i "$out/$name.obu" -o "$tmp/$name.dav1d.yuv" 2>/dev/null
  local md5
  md5=$(md5 -q "$tmp/$name.dav1d.yuv")
  if aomdec --rawvideo --codec=av1 -o "$tmp/$name.aom.yuv" "$out/$name.obu" 2>/dev/null; then
    local aom
    aom=$(md5 -q "$tmp/$name.aom.yuv")
    if [ "$aom" != "$md5" ]; then echo "note: $name: aomdec $aom != dav1d $md5 (layout may differ)" >&2; fi
  fi
  echo "$name $md5" >> "$out/fixtures.txt"
}

gen basic8          64x64    testsrc2  yuv420p ai
gen odd8            77x53    testsrc2  yuv420p ai
gen big8            320x200  testsrc2  yuv420p ai     --cpu-used=6
gen sb128           320x200  testsrc2  yuv420p ai     --sb-size=128
gen tiles8          512x256  testsrc2  yuv420p ai     --tile-columns=1 --tile-rows=1
gen ten420          136x72   testsrc2  yuv420p10le ai --bit-depth=10 --input-bit-depth=10
gen i444            96x64    testsrc2  yuv444p ai     --profile=1 --i444
gen ten444          96x64    testsrc2  yuv444p10le ai --profile=1 --i444 --bit-depth=10 --input-bit-depth=10
gen mono            80x48    testsrc2  gray ai        --monochrome
gen lossless        64x64    testsrc2  yuv420p ai     --lossless=1
gen qm              128x96   testsrc2  yuv420p ai     --enable-qm=1 --qm-min=4 --qm-max=10
gen screen          256x160  testsrc   yuv420p ai     --tune-content=screen --enable-palette=1 --enable-intrabc=1
gen screen444       128x96   testsrc   yuv444p ai     --profile=1 --i444 --tune-content=screen
gen palette10       128x96   testsrc   yuv420p10le ai --bit-depth=10 --input-bit-depth=10 --tune-content=screen
gen nocdef          128x96   testsrc2  yuv420p ai     --enable-cdef=0 --enable-restoration=1
gen restoration     256x160  testsrc2  yuv420p ai     --enable-restoration=1 --cpu-used=0
gen superres        200x120  testsrc2  yuv420p ai     --superres-mode=1 --superres-kf-denominator=12
gen grain           128x96   testsrc2  yuv420p ai     --film-grain-test=1
gen grain10         128x96   testsrc2  yuv420p10le ai --bit-depth=10 --input-bit-depth=10 --film-grain-test=2
gen grain444        96x64    testsrc2  yuv444p ai     --profile=1 --i444 --film-grain-test=3
gen deltaq          256x160  testsrc2  yuv420p ai     --deltaq-mode=3 --aq-mode=1
gen segments        256x160  testsrc2  yuv420p ai     --aq-mode=1
gen fullhdr         64x64    testsrc2  yuv420p ai     --full-still-picture-hdr
gen highq           128x96   testsrc2  yuv420p ai     --end-usage=q --cq-level=1
gen lowq            128x96   testsrc2  yuv420p ai     --end-usage=q --cq-level=63
gen goodcdef        352x288  testsrc2  yuv420p good --cpu-used=4
gen goodaq          352x288  noisy     yuv420p good --cpu-used=4 --aq-mode=1
gen deltalf         352x288  noisy     yuv420p ai   --deltaq-mode=3 --delta-lf-mode=1
gen cdef8           352x288  noisy     yuv420p ai   --cpu-used=2 --enable-cdef=1
gen svt             352x288  noisy     yuv420p svt
gen svtscreen       352x288  testsrc2  yuv420p svt  --scm 1
gen svtgrain        352x288  noisy     yuv420p svt  --film-grain 10
cat "$out/fixtures.txt"
