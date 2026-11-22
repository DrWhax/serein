# Codec components: byte readers, lengths, container boundaries, budgets; the TIFF layout

The tenth verification slice, and the first in SignalCodecs: the parts every decoder is built on.
It contains a Lean 4 model of `ByteCursor`, the grammar combinators, the MP4/HEIF box walker and
the MSB-first bit reader, machine-checked proofs of bounds and budget preservation, Swift tests
comparing production with the model, and mutants. It also models the one decoder that does not
use the grammar combinators, so their budget proof does not cover it: the TIFF decoder's
directory, raster and strips (`ImageTIFF`, reached only by `convertTIFF`, a pasted bitmap's
conversion to PNG).

**The other decoders are not verified.** The proofs are about the models; that production
behaves like them is tested.

```
Tools/verify-codecs.sh                 # everything
SKIP_MUTANTS=1 Tools/verify-codecs.sh
SKIP_SWIFT=1 Tools/verify-codecs.sh    # the Lean side only
```

## 1. What is modelled

| Model | Production |
|---|---|
| `Cursor`, `prim` | `ByteCursor` (`CodecCore/Grammar/ByteSlice.swift`): a position in a region `[start, end)`; `need` before every read; integers big- and little-endian; `bytes`/`rest` (no-copy slices), `skip`, `expect` |
| `G`, `run`, `parseComplete` | `Parser` and `Grammar` (`Parser.swift`): sequencing, `region`, `lengthPrefixed` (u8/u16be/u32be lengths with a maximum), `repeated(count:maxCount:)`, `repeatedToEnd(maxCount:)`, `oneOf` (binary; a list is nested choices) |
| `budget` | what a grammar's repetitions may allocate, from its limits alone |
| `header`, `boxes`, `children` | `BoxGrammar.children` (`ContainerMP4/MP4Grammar.swift`): 32-bit sizes, `largesize`, size 0 (to the end, top level only), `uuid`, a truncated final `mdat` at top level, the file's box budget |
| `readBits`, `peekBits`, `align` | `MSBBitReader` (`Bits/MSBBitReader.swift`), as a specification: bit `i` of the input, MSB first; zeros past the end (`zeroFill`) or a failure (`fail`) |
| `TIFF.directory`, `TIFF.layout`, `TIFF.pixels` (`TIFF.lean`) | `TIFFDecoder.layout` and `TIFFDecoder.pixels` (`ImageTIFF/TIFFDecoder.swift`): the byte order, the first directory (fifteen tags read, others skipped; a tag once, SHORT or LONG, at least one value; values in the entry or at an offset that leaves room for all of them; the next directory's offset present); the raster (dimensions within the limits; photometric 0–2; the colours plus at most one extra sample; 8 or 16 bits, unsigned; no compression, predictor, orientation, fill order or planar configuration but the defaults; rows per strip); each strip exactly the rows it covers and in the input, all checked before any pixel; RGBA pixels (16-bit samples' high byte, white-is-zero inverted, associated alpha divided out). Every failure at production's offset |

## 2. What is proved

| Theorem | Statement |
|---|---|
| `need_spec`, `prim_within` | A primitive read from a cursor in its region stays in it. It advances by what it read, and any slice it hands out lies between where it started and where it stopped. |
| `run_within` | **Reads stay in their region.** For every grammar and every input, a successful run from a cursor in its region ends inside that region, and every byte range it read or handed out lies between where it started and where it ended. Under `region` and `lengthPrefixed`, a sub-grammar runs on exactly the declared bytes, whatever its length field says, so it cannot read neighbouring data. |
| `region_exact` | A region's length is non-negative, and the run continues exactly after it: the sub-grammar consumed all of it. |
| `run_budget` | **Budget preservation.** What a grammar's repetitions allocate never exceeds `budget g`, which depends on its limits only: never on a count or length read from the input. |
| `children_within` | **Container boundaries.** Every box lies in its container, its body after its header, in order and without overlap. |
| `children_budget` | Every box counts against the file's budget (including a truncated final `mdat`), and a successful walk never exceeds it. |
| `bitsVal_lt`, `readBits_spec` | The bit reader's values have `n` bits. Its position never passes the input: it advances by `n`, or with `zeroFill` stops at the end and is marked exhausted. |
| `TIFF.directory_within` | **A TIFF directory's values lie in the input.** Every field a directory keeps has all its values inside the input, whether they sit in the entry or at an offset it gave. |
| `TIFF.tiff_strips_within` | **Strips lie in the input.** Every strip of an accepted bitmap is inside the input. |
| `TIFF.tiff_pixels_exact` | **Exactly width × height pixels.** An accepted bitmap's strips hold exactly the pixels its dimensions say: `pixels` has `4 · width · height` values, which is `PixelBuffer`'s precondition (a mismatch would trap the media service). The core is that `1 + (height − 1) / rows` strips of `min(rows, height − i · rows)` rows cover every row once. |
| `TIFF.tiff_dims`, `TIFF.tiff_budget` | **Limits and budget.** An accepted bitmap's dimensions are positive and within `maxDimension` and `maxPixels`; it has at most four samples per pixel and at most `maxDimension` strips. With `values` checking a field's count before reading it, what the layout holds besides the pixels is bounded by the limits, not by counts in the input. |

The explorer (step 4) also checks these on 40,000 random grammars and box streams, from cursors
anywhere in the input, and the TIFF properties on 4,000 random bitmaps, right and broken.

## 3. Production changes made for this slice

**C1: a truncated final `mdat` counts against the box budget.** `BoxGrammar.children`
appended it without counting, so a file could hold `maxBoxes + 1` boxes. Now it is counted and
checked like every other box.

**TIFF (a seam, no defect found).** `TIFFDecoder.decode` was split into `layout` (everything
checked before any pixel is read) and `pixels`, so the rig can compare each with the model. The
behaviour is unchanged.

## 4. What is only tested against Swift

`CodecConformanceTests` (a new SignalCodecs test target), 5,000 cases each:
- **`randomGrammars`**: grammars up to depth 4 of every combinator and primitive, with negative,
  zero and too-large lengths and counts, built from production's `Grammar` and `Parser` on random
  bytes. `parseComplete`'s result is compared: success with the items allocated, or the
  failure's offset and kind.
- **`randomCursors`**: sequences of every read on a region inside a larger array (so reading past
  the region would read real bytes); values, slices, positions, failures.
- **`randomBoxes`**: streams of boxes of five types with right sizes, sizes smaller than their
  header, longer than what follows, size 0, `largesize`, `uuid`, truncation, at top level or
  inside a container, with random budgets. The boxes (type, offset, body) and the count are
  compared.
- **`randomBits`**: reads of 0–32 bits, peeks and alignments under both policies.
- **`randomTIFFs`**: bitmaps in both byte orders, grey and RGB, 8 and 16 bits, each kind of
  extra sample, one or several strips, SHORT and LONG fields with values in the entry or after
  it; and broken ones: fields missing, repeated, of another type, with no values or one too many;
  unsupported photometric, bit depth, sample format, compression, predictor, orientation, fill
  order or planar values; rows per strip of 0; byte counts off by one; offsets out of the input;
  dimensions over random limits; corrupt bytes, cuts, a missing next-directory offset. The layout
  (byte order, raster, every strip's offset and size) and the pixels (their count and a hash),
  or the failure's offset and kind, are compared. About one in six is accepted.

Mutants (step 6), each of which must fail step 5:
- the cursor: reads checked against the storage instead of the region; negative lengths accepted;
  `u16le` read big-endian; `u64be` halves swapped; literals never mismatching; `rest` not moving
  the cursor;
- the combinators: regions not consumed completely; length limits ignored; length-prefixed bodies
  reading past their length; repeat counts and repeat-to-end limits ignored; rules that consume
  nothing accepted; choices reporting the nearest failure;
- the box walker: boxes smaller than their header; size 0 inside a container; `uuid` not
  skipped; the truncated `mdat` not counted (C1 undone); the box budget unchecked;
- the bit reader: the fail policy filling zeros; zero fill one bit short; alignment dropping a
  byte too many;
- the TIFF decoder: a repeated tag, a field of another type or with no values accepted; the next
  directory's offset not required; a field's value count not checked; the input's size or the
  dimensions not checked against the limits; compressed strips, mixed bit depths, signed samples
  or a fourth kind of extra sample accepted; zero rows per strip accepted; the strip count rounded
  down; a strip's byte count not checked; the last strip required to be whole; 16-bit samples
  keeping their low byte; white-is-zero not inverted; associated alpha not divided out.

All 39 are killed.

## 5. Assumptions and limitations

- Only these components and the TIFF layout are modelled. The decoders built on them (PNG, JPEG,
  GIF, WebP, BMP, ICO, HEIF, AV1, H.264, HEVC, AAC, MP3) rely on them for bounds but are not
  modelled. Their own arithmetic (sample tables, pixel budgets in `DecodeLimits`, entropy
  decoding) is tested elsewhere (the codec tests and the differential tests), not here.
- TIFF: the theorems are about the model. That production follows it (accepts and refuses the
  same bitmaps, at the same offsets, with the same strips and pixels) is tested by `randomTIFFs`
  and its mutants. That production allocates only what the model accounts for (the directory's
  dictionary of at most fifteen tags; `values` arrays, made only after their count matches; the
  strips; then the output) is read from the code, not tested. The pixel conversion (16-bit
  samples, white-is-zero, dividing out alpha) is compared with the model, not proved correct
  against a TIFF reader; a media-service test converts a bitmap AppKit wrote and compares its
  pixels with the original.
- `MP4Limits.maxDepth` is not enforced. Nothing recurses on attacker-chosen nesting: the
  demuxer descends a fixed path (moov, trak, mdia, minf, stbl, …), so depth is bounded by the
  code.
- `oneOf` is modelled binary. Production's list form is the same as nested binary choices (the
  furthest failure, the first on ties).
- `u64be`'s failure after its first half leaves the cursor moved by 4. Failed cursors are
  discarded (`oneOf` tries alternatives on copies), so the model does not track it.
- The bit reader is compared with its specification, not modelled as its buffered
  implementation; the rig is what ties the two.

## 6. Files

`Codecs/Model.lean`, `Codecs/Props.lean`, `Codecs/Proofs.lean`, `Codecs/TIFF.lean` (the TIFF
model), `Codecs/TIFFProofs.lean`, `Codecs/Trace.lean`, `Main.lean` (the `oracle`: `grammar`,
`cursor`, `boxes`, `bits`, `tiff`, `explore`), `Audit.lean`, `audit-expected.txt`,
`explore-expected.txt`.
