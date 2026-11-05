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
