#!/bin/sh
# Synthetic HEVC test clips (ffmpeg's testsrc2 pattern, no external data) for VideoHEVCTests,
# with goldens from ffmpeg: slice-header fields (trace_headers) and per-frame MD5s of the
# decoded pictures (framemd5) — the decoder must match both exactly.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/Packages/SignalCodecs/Tests/VideoHEVCTests/Resources"
mkdir -p "$out"
gen() {   # name size frames pix_fmt encoder-args…
  name=$1 size=$2 frames=$3 pix=$4; shift 4
  ffmpeg -hide_banner -loglevel error -f lavfi -i "testsrc2=size=$size:rate=30" -frames:v "$frames" -pix_fmt "$pix" "$@" -tag:v hvc1 \
    -movflags +faststart -y "$out/$name.mp4"
  ffmpeg -hide_banner -loglevel error -i "$out/$name.mp4" -f framemd5 -pix_fmt "$pix" -y "$out/$name.framemd5"
  ffmpeg -hide_banner -i "$out/$name.mp4" -c copy -bsf:v trace_headers -f null - 2>&1 | python3 -I "$root/Tools/hevc-trace-golden.py" > "$out/$name.headers.json"
}
# kvazaar (x265 has no tiles): intra-only pictures of several tiles in one slice, which
# VideoHEVC parses tile by tile in parallel; and one slice per tile (the serial path).
gen_kvz() {   # name size frames kvazaar-args…
  name=$1 size=$2 frames=$3; shift 3
  ffmpeg -hide_banner -loglevel error -f lavfi -i "testsrc2=size=$size:rate=30" -frames:v "$frames" -pix_fmt yuv420p -f rawvideo -y "$out/$name.yuv"
  kvazaar -i "$out/$name.yuv" --input-res "$size" -o "$out/$name.hevc" "$@" 2>/dev/null
  rm "$out/$name.yuv"
  ffmpeg -hide_banner -loglevel error -i "$out/$name.hevc" -c copy -tag:v hvc1 -movflags +faststart -y "$out/$name.mp4"
  rm "$out/$name.hevc"
  ffmpeg -hide_banner -loglevel error -i "$out/$name.mp4" -f framemd5 -pix_fmt yuv420p -y "$out/$name.framemd5"
  ffmpeg -hide_banner -i "$out/$name.mp4" -c copy -bsf:v trace_headers -f null - 2>&1 | python3 -I "$root/Tools/hevc-trace-golden.py" > "$out/$name.headers.json"
}
x="log-level=error"
gen intra8_nolf   64x64   4 yuv420p     -c:v libx265 -x265-params "$x:keyint=1:no-deblock=1:no-sao=1:no-wpp=1"
gen intra8        64x64   4 yuv420p     -c:v libx265 -x265-params "$x:keyint=1"
nolf="no-deblock=1:no-sao=1"
gen intra10_nolf   136x72  3 yuv420p10le -c:v libx265 -x265-params "$x:keyint=1:$nolf"
gen intra8big_nolf 320x192 3 yuv420p     -c:v libx265 -x265-params "$x:keyint=1:$nolf:tskip=1:aq-mode=3:rdoq-level=2:qg-size=16"
gen lossless_nolf  64x64   2 yuv420p     -c:v libx265 -x265-params "$x:keyint=1:$nolf:lossless=1"
gen scaling_intra_nolf 128x64 2 yuv420p  -c:v libx265 -x265-params "$x:keyint=1:$nolf:scaling-list=default"
gen intra10       136x72  3 yuv420p10le -c:v libx265 -x265-params "$x:keyint=1"
gen ipb8          136x72 12 yuv420p     -c:v libx265 -x265-params "$x:bframes=3:keyint=12:ref=3"
gen ipb10         136x72 12 yuv420p10le -c:v libx265 -x265-params "$x:bframes=3:keyint=12:ref=3:weightb=1"
gen scaling8      64x64   6 yuv420p     -c:v libx265 -x265-params "$x:scaling-list=default:bframes=2"
gen tiles8        256x128 4 yuv420p     -c:v libx265 -x265-params "$x:no-wpp=1:bframes=0" -x265-params "$x:no-wpp=1"
gen vt10          192x112 10 yuv420p10le -c:v hevc_videotoolbox -profile:v main10 -b:v 400k
gen_kvz kvz_tiles     320x192 3 -p 1 --tiles 3x2 --no-wpp
gen_kvz kvz_tiles_lf  416x240 2 -p 1 --tiles 4x3 --no-wpp --sao full
gen_kvz kvz_tileslices 320x192 2 -p 1 --tiles 2x2 --no-wpp --slices tiles
ls -la "$out"
