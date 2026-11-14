# SignalCodecs

Memory-safe Swift parsers and decoders for every untrusted media format SignalSafe
handles. No ImageIO, CoreGraphics, AVFoundation, VideoToolbox, AudioToolbox, Compression
or Foundation in the library targets (`../../Tools/lint-codecs.sh` enforces this).

## LangSec structure

Every format is a two-stage pipeline:

1. **Grammar** (`XGrammar.swift`): recognises the whole input with combinators from
   `CodecCore/Grammar` and returns a typed AST, or a `ParseFailure(offset, rule, reason, path)`.
   Length fields bound sub-grammars (`Grammar.lengthPrefixed`, `ByteCursor.bytes`), and
   every repeat count and dimension is checked against `DecodeLimits` before allocation.
   Ambiguity policy is written at the top of each grammar file.
2. **Decoder** (`XDecoder.swift`): consumes only the AST. Entropy-coded payloads are read
   through checked bit readers (`LSBBitReader`), and their parameters (Huffman tables etc.)
   are validated by the grammar first.

Raw input storage is not visible outside `CodecCore`, so decoders cannot bypass the readers.

## Status (Phase 1 complete)

| Module | Format | Conformance (public corpus, reference) | ImageIO differential |
|---|---|---|---|
| CodecCore | grammar combinators, cursors, bit readers/writers, CRC-32, Adler-32, Deflate/zlib (inflate + compressor) | vectors, malformed streams, truncations, round trips | — |
| ImagePNG | PNG, APNG | PngSuite (162 valid, 14 corrupt rejected, Adam7 = non-interlaced) | 130 files ±1 |
| ImageGIF | GIF87a/89a, animation | GIF test suite (R. Ancell), 84 tests | painted pixels, suite + Pillow GIFs |
| ImageBMP | BMP (incl. OS/2, bitfields, RLE), ICO/CUR, XBM | BMP Suite 2.8 g/q/b; Pillow ICO/XBM | BMP, ICO; XBM via Pillow PNG rendering (ImageIO has no XBM) |
| ImageJPEG | baseline, extended, progressive JPEG; EXIF orientation; CMYK/YCCK | bit-exact with libjpeg-turbo `djpeg -dct int` on 116 files | PSNR > 30 dB, orientation tag equality |
| ImageWebP | VP8 lossy, VP8L lossless, ALPH, animation | bit-exact with libwebp `dwebp` on 144 stills; frame-exact with WebPAnimDecoder on 40 animations | stills and frames |
| Blurhash | encode/decode | bit-exact with woltapp's C reference (480 encodes, 777 decodes) | hash of ImageIO-decoded pixels |
| EncodePNG | PNG writer | lossless round trip through the strict decoder on PngSuite | ImageIO reads identical pixels |
| EncodeJPEG | baseline JPEG writer | byte-identical to libjpeg-turbo `cjpeg -baseline` (216 cases) | decoders agree, fidelity vs source |

Every documented deviation (a file a reference decoder renders differently by design) is listed in
the test that skips it, with the reason. Reference data is produced by `Tools/gen-codec-references.py`.

## Commands

```sh
swift test                                   # unit, PngSuite, differential
../../Tools/lint-codecs.sh                   # security gate
swift build -c release -Xswiftc -sanitize=address --product codec-fuzz
.build/release/codec-fuzz png Tests/DifferentialTests/Resources/PngSuite 1000000 <seed>
.build/release/codec-fuzz png <corpus> --dump <seed> <iteration> crash.png   # reproduce
```

`codec-fuzz` is a deterministic structure-aware mutator (it repairs chunk CRCs so mutations
reach Inflate and the decoder). Coverage-guided libFuzzer needs the swift.org toolchain;
Xcode's toolchain rejects `-sanitize=fuzzer`.

`DifferentialTests` is the only target allowed to use Apple decoders, as a test oracle on
the trusted PngSuite corpus. It strips gAMA/cHRM/sRGB/iCCP/sBIT from the oracle's copy
because SignalSafe does no colour management.

## Parser security audit — 2026-11-14

This pass focused on attacker-controlled counts, resource amplification, and dimensions at the
container/decoder boundary. It is not a proof that the codecs are free of memory-safety or
algorithmic-complexity bugs.

- **MP4 sample runs:** `stsc`, `stts` and `ctts` runs are checked against the remaining samples
  before iteration. A Swift `for ... where index < n` still iterated the entire attacker-chosen
  range after the samples ran out. Timing and composition totals must now match the sample table.
  The malformed-count probes failed before the fix; valid fixtures still decode.
  Reference: [Apple's sample-to-chunk table](https://developer.apple.com/documentation/quicktime-file-format/sample-to-chunk_atom/sample-to-chunk_table)
  and [time-to-sample table](https://developer.apple.com/documentation/quicktime-file-format/time-to-sample_atom/time-to-sample_table).
- **HEIF/AVIF allocation:** declared dimensions are checked before decoding; the coded AV1/HEVC
  dimensions must agree before picture allocation. Grids have aggregate decoded-pixel and input
  budgets, not just an output-size check. Item extents are bounded before concatenation, and
  the container has a global extent-count budget (zero-width extent fields otherwise amplify
  a tiny `iloc` into millions of slices). Padded tile pixels count against the image budget.
- **HEVC headers:** nonpositive conformance-window output is rejected in the SPS parser.
  Previously it could reach reconstruction with zero/negative dimensions. In-band SPS updates
  receive the same format restrictions and pixel checks as initial parameter sets. HEIF decoding
  permits only one picture, rather than buffering arbitrary extra pictures inside a still item.
- **Metadata stripping:** chunk-offset relocation uses sorted range ends and prefix sums, with
  binary search per offset, instead of scanning every removed range for every chunk.
- **Limit arithmetic:** dimension multiplication reports overflow instead of trapping when
  custom limits permit very large values.

Regressions: `MP4SecurityTests`, `HEIFExtentSecurityTests`, `HEIFSecurityTests`,
`HEVCSecurityTests`, and `MetadataSecurityTests`. Existing golden/differential fixtures remain
part of validation. A bounded mutation smoke run used seed `20261114`: 2,000 PNG, 1,000 MP4,
300 AAC, 300 MP3 and 100 H.264 inputs completed without crashes. This was not coverage-guided
fuzzing or an ASan campaign. Longer isolated fuzzing of the entropy decoders and stricter total
working-set limits remain worthwhile; pixel limits alone are not a process-RSS bound.

### Sanitizer follow-up

`codec-fuzz` now accepts `hevc`, `av1` (still OBU streams), and `av1video` (IVF
inter-frame streams). HEVC mutations operate on access units with the seed's hvcC;
AV1 video mutations operate on IVF temporal units, retaining framing to reach entropy
and reconstruction code. AV1 still mutations currently operate on the whole OBU stream.
Each input logs its exact seed and iteration before decoding; replay with
`codec-fuzz TARGET CORPUS --run SEED ITERATION`. Keep the same corpus and toolchain.

Build and run from the repo root, for example:

```sh
swift build --package-path Packages/SignalCodecs --scratch-path /tmp/codec-asan \
  --product codec-fuzz -Xswiftc -sanitize=address
python3 Tools/fuzz-codec-campaign.py /tmp/codec-asan/debug/codec-fuzz hevc \
  Packages/SignalCodecs/Tests/VideoHEVCTests/Resources \
  --iterations 20000 --seed 20261116 --log /tmp/hevc-asan.log
```

The runner disables core dumps, records results beside the log, and kills the process on
its wall-time or sampled RSS limit. It cleans up the child even if monitoring fails.
The campaign is deterministic mutation testing with ASan, not coverage-guided fuzzing.
Leak detection is disabled; memory use is observed separately. A campaign time limit is
not evidence that a single input hung: inspect the iteration log and replay that input.

AV1 video now also accepts `DecodeLimits` and checks frame dimensions before allocation;
`AV1LimitTests` verifies rejection before any reconstruction job is queued.

Validation on 2026-11-14: ASan debug builds completed 25,000 HEVC and 25,000 AV1
still-image mutations (5,000 each at seed 20261115, 20,000 each at seed 20261116)
without a crash or sanitizer report. The largest sampled RSS in those campaigns was
690,224 KiB. Corpus fixtures and the AV1 video limit regression also passed. These
campaigns exercise the bundled small fixtures, not arbitrary production-sized media.

The AV1 inter-frame campaign (seed 20261116) reached its 600-second campaign budget
at iteration 8,408: 8,408 inputs had completed, and the interrupted input replayed with
`--run 20261116 8408` in 0.11 seconds (normal concealed-error outcome). Thus 8,409
video inputs were verified without a crash or sanitizer report; the requested 20,000-input
campaign did **not** complete. Its largest sampled RSS was 797,696 KiB. The runner
correctly returned failure for the campaign timeout; this was not a decoder hang.
