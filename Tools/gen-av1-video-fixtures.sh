#!/bin/bash
# Synthetic AV1 video clips (ffmpeg test patterns, no external data) for VideoAV1Tests'
# AV1VideoTests: 176x144, 12 or 24 frames, from aomenc with groups of inter tools on —
# single references, motion field projection, alt-refs with hidden frames and
# show_existing_frame, every compound / warp / OBMC / inter-intra tool (rotating, zooming and
# fractal sources), superres (scaled references), segmentation, real-time cyclic refresh.
# Golden: dav1d's MD5 of each output frame (ffmpeg framemd5 with libdav1d), in <name>.md5.
# The decoder must match every frame exactly; the test also checks that together the clips
# use every inter tool the encoders produce (dual filters: neither aomenc nor SVT-AV1 signals them).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/Packages/SignalCodecs/Tests/VideoAV1Tests/Resources/video"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$out"
ffmpeg -v error -y -f lavfi -i "testsrc2=size=176x144:rate=30" -frames:v 12 -pix_fmt yuv420p "$tmp/src.y4m"
ffmpeg -v error -y -f lavfi -i "testsrc2=size=176x144:rate=30" -vf "rotate=a=0.02*t*30:fillcolor=gray,scale=176:144" -frames:v 24 -pix_fmt yuv420p "$tmp/rot.y4m"
ffmpeg -v error -y -f lavfi -i "mandelbrot=size=176x144:rate=30" -frames:v 24 -pix_fmt yuv420p "$tmp/mandel.y4m"
ffmpeg -v error -y -f lavfi -i "testsrc2=size=176x144:rate=30" -vf "zoompan=z='1+0.01*on':d=1:s=176x144" -frames:v 24 -pix_fmt yuv420p "$tmp/zoom.y4m"
OFF="--enable-warped-motion=0 --enable-global-motion=0 --enable-obmc=0 --enable-dual-filter=0 --enable-masked-comp=0 --enable-interintra-comp=0
     --enable-dist-wtd-comp=0 --enable-onesided-comp=0 --enable-smooth-interintra=0 --enable-diff-wtd-comp=0 --enable-interinter-wedge=0
     --enable-interintra-wedge=0 --enable-palette=0 --enable-intrabc=0 --enable-tpl-model=0"
enc() {   # name source frames aomenc-args…
  local name=$1 src=$2 n=$3; shift 3
  aomenc -q --ivf --limit="$n" "$@" -o "$out/$name.ivf" "$tmp/$src.y4m" 2>/dev/null
  ffmpeg -v error -y -c:v libdav1d -i "$out/$name.ivf" -f framemd5 -pix_fmt yuv420p "$out/$name.md5"
  echo "$name: $(grep -vc '^#' "$out/$name.md5") frames, $(stat -f%z "$out/$name.ivf") bytes"
}
Q="--end-usage=q --cq-level=32 --cpu-used=4 --kf-max-dist=999"
# shellcheck disable=SC2086
enc p1 src 12 $Q --lag-in-frames=0 --max-reference-frames=3 --enable-ref-frame-mvs=0 $OFF
# shellcheck disable=SC2086
enc p1mvs src 12 $Q --lag-in-frames=0 --max-reference-frames=3 --enable-ref-frame-mvs=1 $OFF
# shellcheck disable=SC2086
enc alt src 12 $Q --lag-in-frames=16 --auto-alt-ref=1 --enable-ref-frame-mvs=1 $OFF
enc full src 12 $Q --lag-in-frames=16 --auto-alt-ref=1
G="--end-usage=q --cq-level=28 --kf-max-dist=999 --lag-in-frames=16 --auto-alt-ref=1"
# shellcheck disable=SC2086
enc rot rot 24 $G --cpu-used=1
# shellcheck disable=SC2086
enc mandel mandel 24 $G --cpu-used=1
# shellcheck disable=SC2086
enc zoom zoom 24 $G --cpu-used=1
# shellcheck disable=SC2086
enc superres rot 24 $G --cpu-used=3 --superres-mode=1 --superres-denominator=12
# shellcheck disable=SC2086
enc aq mandel 24 $G --cpu-used=3 --aq-mode=1
# shellcheck disable=SC2086
enc obmc zoom 24 $G --cpu-used=0 --enable-warped-motion=0 --enable-global-motion=0
enc cyclic mandel 24 --rt --cpu-used=7 --end-usage=cbr --target-bitrate=300 --aq-mode=3 --lag-in-frames=0
