import Codecs.Model

/-!
# TIFF: the first directory, its raster and its strips

The model of `ImageTIFF` (`TIFFDecoder.layout` and `TIFFDecoder.pixels`), the decoder of the
uncompressed, strip-based bitmaps AppKit puts on the pasteboard. It is reached only by the media
service's `convertTIFF` (a pasted bitmap becomes a PNG).

* **The directory** (`directory`): the byte order (`II`/`MM`), 42, the first directory's offset,
  then its entries. Fifteen tags are read (`Tag`); every other one is skipped. A known tag may
  appear once, as SHORT or LONG values, at least one. Values of four bytes or fewer sit in the
  entry; longer ones are at an offset, which must leave room for all of them. The next
  directory's offset must be there.
* **The raster** (`layout`): dimensions within the limits, photometric 0–2 (white is zero,
  black is zero, RGB), samples per pixel the colours plus at most one extra sample (alpha
  associated, unassociated or unspecified), 8 or 16 bits, unsigned, no compression, predictor,
  orientation, fill order or planar configuration other than the defaults; rows per strip
  (default: the height), and one offset and one byte count per strip.
* **The strips**: each must hold exactly the rows it covers (`stride` × rows) and lie in the
  input, checked for all strips before any pixel is read.
* **The pixels** (`pixels`): RGBA, eight bits; 16-bit samples keep their high byte; white is
  zero is inverted; associated alpha is divided out.

Every read goes through the cursor of `Model.lean` (or the same `need` check) and fails where
production's does: offsets are absolute, and every check on the raster after the directory
fails at offset 0 (`invalid`, or `limit` for the dimensions and the input's size).
-/

namespace Codecs.TIFF

/-- The tags `TIFFDecoder` reads. -/
inductive Tag
  | width | height | bits | compression | photometric | fillOrder | offsets | orientation
  | samples | rows | byteCounts | planar | predictor | extraSamples | sampleFormat
  deriving DecidableEq, Repr

def Tag.code : Tag → Nat
  | .width => 256 | .height => 257 | .bits => 258 | .compression => 259 | .photometric => 262
  | .fillOrder => 266 | .offsets => 273 | .orientation => 274 | .samples => 277 | .rows => 278
  | .byteCounts => 279 | .planar => 284 | .predictor => 317 | .extraSamples => 338 | .sampleFormat => 339

def allTags : List Tag :=
  [.width, .height, .bits, .compression, .photometric, .fillOrder, .offsets, .orientation, .samples, .rows,
   .byteCounts, .planar, .predictor, .extraSamples, .sampleFormat]

def Tag.ofCode (n : Nat) : Option Tag := allTags.find? (·.code == n)

/-- A field: SHORT (two bytes each) or LONG (four), how many values, and where they start. -/
structure Field where
  short : Bool
  count : Nat
  lo : Nat
  deriving DecidableEq, Repr

def Field.width (f : Field) : Nat := if f.short then 2 else 4

abbrev Fields := Tag → Option Field

def Fields.set (fs : Fields) (t : Tag) (f : Field) : Fields := fun u => if u = t then some f else fs u

structure Dir where
  big : Bool
  fields : Fields

/-- A semantic check: `.ok ()`, or the failure. -/
def check (b : Bool) (e : Fail) : Except Fail Unit := if b then .ok () else .error e

/-- `Order.short` / `Order.long`: `k` bytes at the cursor, in the file's byte order. -/
def rd (bs : List Nat) (big : Bool) (k : Nat) (c : Cursor) : Except Fail (Nat × Cursor) :=
  if need c k then .ok (if big then be bs c.pos k else le bs c.pos k, advance c k)
  else .error ⟨c.pos, .unexpectedEnd⟩

/-- One directory entry at `c`: tag, type, count, then the four-byte value or offset. -/
def entry (bs : List Nat) (big : Bool) (fs : Fields) (c : Cursor) : Except Fail (Fields × Cursor) := do
  let (code, c) ← rd bs big 2 c
  let (type, c) ← rd bs big 2 c
  let (count, c) ← rd bs big 4 c
  let slot := c.pos
  check (need c 4) ⟨c.pos, .unexpectedEnd⟩
  let c := advance c 4
  match Tag.ofCode code with
  | none => pure (fs, c)
  | some t =>
    check ((fs t).isNone && (type == 3 || type == 4) && 0 < count) ⟨c.pos, .invalid⟩
    let size := count * (if type == 3 then 2 else 4)
    if size ≤ 4 then pure (fs.set t ⟨type == 3, count, slot⟩, c)
    else
      let voff := if big then be bs slot 4 else le bs slot 4
      check (voff ≤ bs.length) ⟨0, .unexpectedEnd⟩
      check (size ≤ bs.length - voff) ⟨voff, .unexpectedEnd⟩
      pure (fs.set t ⟨type == 3, count, voff⟩, c)

def entries (bs : List Nat) (big : Bool) : Nat → Fields → Cursor → Except Fail (Fields × Cursor)
  | 0, fs, c => .ok (fs, c)
  | k + 1, fs, c => do
    let (fs, c) ← entry bs big fs c
    entries bs big k fs c

/-- `II` (little-endian) or `MM` (big-endian). -/
def order (mark pos : Nat) : Except Fail Bool :=
  if mark == 0x4949 then .ok false else if mark == 0x4d4d then .ok true else .error ⟨pos, .invalid⟩

def directory (bs : List Nat) : Except Fail Dir := do
  let (mark, c) ← rd bs true 2 ⟨0, 0, bs.length⟩
  let big ← order mark c.pos
  let (magic, c) ← rd bs big 2 c
  check (magic == 42) ⟨c.pos, .invalid⟩
  let (off, _) ← rd bs big 4 c
  check (need ⟨0, 0, bs.length⟩ off) ⟨0, .unexpectedEnd⟩
  let (count, e) ← rd bs big 2 ⟨0, off, bs.length⟩
  let (fs, e) ← entries bs big count (fun _ => none) e
  check (need e 4) ⟨e.pos, .unexpectedEnd⟩
  pure ⟨big, fs⟩

/-- A raster check after the directory fails here. -/
def bad : Fail := ⟨0, .invalid⟩

/-- `Directory.values`: exactly `count` values, or a failure (checked before anything is read). -/
def values (bs : List Nat) (d : Dir) (t : Tag) (count : Nat) : Except Fail (List Nat) :=
  match d.fields t with
  | some f =>
    if f.count == count then
      .ok ((List.range count).map fun i => if d.big then be bs (f.lo + i * f.width) f.width else le bs (f.lo + i * f.width) f.width)
    else .error bad
  | none => .error bad

/-- `Directory.scalar`: one value, or the default when the tag is absent. -/
def scalar (bs : List Nat) (d : Dir) (t : Tag) (dflt : Option Nat) : Except Fail Nat :=
  match d.fields t, dflt with
  | none, some v => .ok v
  | _, _ => do
    let vs ← values bs d t 1
    pure (vs.headD 0)

structure Limits where
  maxDimension : Nat
  maxPixels : Nat
  maxInput : Nat
  deriving Repr

/-- `DecodeLimits.checkDimensions`. -/
def checkDims (lim : Limits) (w h : Nat) : Except Fail Unit :=
  if w == 0 || h == 0 then .error bad
  else if lim.maxDimension < w || lim.maxDimension < h || lim.maxPixels < w * h then .error ⟨0, .limit⟩
  else .ok ()

/-- Compression, predictor, orientation, fill order and planar configuration: the defaults. -/
def defaults (bs : List Nat) (d : Dir) : Except Fail Unit := do
  for t in [Tag.compression, .predictor, .orientation, .fillOrder, .planar] do
    let v ← scalar bs d t (some 1)
    check (v == 1) bad

/-- Unsigned samples, if the sample format is given. -/
def unsigned (bs : List Nat) (d : Dir) (samples : Nat) : Except Fail Unit :=
  if (d.fields .sampleFormat).isSome then do
    let formats ← values bs d .sampleFormat samples
    check (formats.all (· == 1)) bad
  else .ok ()

/-- The strips, from strip `i` on: each exactly `stride` × the rows it covers, in the input. -/
def strips (len height rows stride : Nat) : Nat → List (Nat × Nat) → Except Fail (List (Nat × Nat))
  | _, [] => .ok []
  | i, (o, n) :: rest =>
    if n != stride * min rows (height - i * rows) then .error bad
    else if len < o then .error ⟨0, .unexpectedEnd⟩
    else if len - o < n then .error ⟨o, .unexpectedEnd⟩
    else match strips len height rows stride (i + 1) rest with
      | .ok s => .ok ((o, n) :: s)
      | .error e => .error e

structure Layout where
  big : Bool
  width : Nat
  height : Nat
  photometric : Nat
  samples : Nat
  bits : Nat
  extra : Nat
  /-- (offset, byte count) of each strip. -/
  strips : List (Nat × Nat)
  deriving Repr

def layout (bs : List Nat) (lim : Limits) : Except Fail Layout := do
  check (bs.length ≤ lim.maxInput) ⟨0, .limit⟩
  let d ← directory bs
  let width ← scalar bs d .width none
  let height ← scalar bs d .height none
  checkDims lim width height
  let photo ← scalar bs d .photometric none
  let samples ← scalar bs d .samples (some 1)
  let colors := if photo == 2 then 3 else 1
  check (photo ≤ 2 && (samples == colors || samples == colors + 1)) bad
  defaults bs d
  let bits ← values bs d .bits samples
  let b0 := bits.headD 0
  check ((b0 == 8 || b0 == 16) && bits.all (· == b0)) bad
  unsigned bs d samples
  let extra ← scalar bs d .extraSamples (some 0)
  check (if colors < samples then extra ≤ 2 else extra == 0) bad
  let rows ← scalar bs d .rows (some height)
  check (0 < rows) bad
  let count := 1 + (height - 1) / rows
  let offsets ← values bs d .offsets count
  let sizes ← values bs d .byteCounts count
  let stride := width * samples * (b0 / 8)
  let ss ← strips bs.length height rows stride 0 (offsets.zip sizes)
  pure ⟨d.big, width, height, photo, samples, b0, extra, ss⟩

/-! ## The pixels -/

def Layout.colors (L : Layout) : Nat := if L.photometric == 2 then 3 else 1

/-- Bytes per pixel. -/
def Layout.bpp (L : Layout) : Nat := L.samples * (L.bits / 8)

def sample (bs : List Nat) (L : Layout) (p : Nat) : Nat :=
  if L.bits == 8 then byteAt bs p else (if L.big then be bs p 2 else le bs p 2) / 256

/-- Associated alpha divided out (rounded, at most 255). -/
def straight (L : Layout) (v a : Nat) : Nat :=
  if L.extra != 1 || a == 255 then v else if a == 0 then 0 else min 255 ((v * 255 + a / 2) / a)

def pixel (bs : List Nat) (L : Layout) (p : Nat) : List Nat :=
  let w := L.bits / 8
  let first := sample bs L p
  let red := if L.photometric == 0 then 255 - first else first
  let green := if L.colors == 3 then sample bs L (p + w) else red
  let blue := if L.colors == 3 then sample bs L (p + 2 * w) else red
  let last := if L.colors < L.samples then sample bs L (p + L.colors * w) else 255
  let alpha := if L.extra == 0 then 255 else last
  [straight L red alpha, straight L green alpha, straight L blue alpha, alpha]

/-- `k` pixels from `p`. -/
def stripPixels (bs : List Nat) (L : Layout) : Nat → Nat → List Nat
  | 0, _ => []
  | k + 1, p => pixel bs L p ++ stripPixels bs L k (p + L.bpp)

/-- `TIFFDecoder.pixels`: every strip's pixels, in order. -/
def pixels (bs : List Nat) (L : Layout) : List Nat :=
  L.strips.foldr (fun s acc => stripPixels bs L (s.2 / L.bpp) s.1 ++ acc) []

end Codecs.TIFF
