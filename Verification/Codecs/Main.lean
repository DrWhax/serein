import Codecs.Model
import Codecs.Props
import Codecs.Trace
import Codecs.TIFF

/-!
# The oracle executable

* `oracle grammar | cursor | boxes | bits | tiff`: cases on stdin (see `Trace.lean`).
* `oracle explore <seed> <cases> <size>`: random grammars on random bytes (regions, length
  prefixes, repetitions with any counts and limits, choices), and random box streams; that reads
  stay in their regions, budgets hold and boxes stay in their containers, for every run. Then
  random TIFF bitmaps (a tenth as many), right and broken: that strips stay in the input, pixels
  are exactly width × height, and the budget and limits hold, for every accepted one.
-/

open Codecs

structure Rng where
  s : UInt64

def Rng.next (r : Rng) : UInt64 × Rng :=
  let s := r.s + 0x9E3779B97F4A7C15
  let z := (s ^^^ (s >>> 30)) * 0xBF58476D1CE4E5B9
  let z := (z ^^^ (z >>> 27)) * 0x94D049BB133111EB
  (z ^^^ (z >>> 31), ⟨s⟩)

def Rng.below (r : Rng) (n : Nat) : Nat × Rng :=
  let (x, r) := r.next
  (if n == 0 then 0 else x.toNat % n, r)

def randomPrim (r : Rng) : Prim × Rng :=
  let (k, r) := r.below 11
  let (n, r) := r.below 6
  (match k with
   | 0 => .u8 | 1 => .u16be | 2 => .u16le | 3 => .u24be | 4 => .u32be | 5 => .u64be
   | 6 => .bytes ((n : Int) - 1) | 7 => .skip n | 8 => .expect [n] | 9 => .rest | _ => .u32le, r)

def randomG : Nat → Rng → G × Rng
  | 0, r => let (p, r) := randomPrim r; (.prim p, r)
  | d + 1, r =>
    let (k, r) := r.below 8
    let (n, r) := r.below 8
    let (m, r) := r.below 5
    match k with
    | 0 | 1 => let (p, r) := randomPrim r; (.prim p, r)
    | 2 => let (a, r) := randomG d r; let (b, r) := randomG d r; (.seq a b, r)
    | 3 => let (a, r) := randomG d r; (.region ((n : Int) - 1) a, r)
    | 4 => let (a, r) := randomG d r; (.lenPrefixed (if m % 2 == 0 then .u8 else .u16be) (n * 2) a, r)
    | 5 => let (a, r) := randomG d r; (.repeated ((n : Int) - 1) m a, r)
    | 6 => let (a, r) := randomG d r; (.toEnd m a, r)
    | _ => let (a, r) := randomG d r; let (b, r) := randomG d r; (.oneOf a b, r)

def withinB (c : Cursor) (r : R) : Bool :=
  r.c.start == c.start && r.c.stop == c.stop && c.pos ≤ r.c.pos && r.c.pos ≤ c.stop &&
    r.reads.all fun x => c.pos ≤ x.1 && x.1 ≤ x.2 && x.2 ≤ r.c.pos

def explore (seed count size : Nat) : IO Unit := do
  let mut r : Rng := ⟨UInt64.ofNat seed⟩
  let mut within := true
  let mut budgetOk := true
  let mut boxesOk := true
  let mut succeeded := 0
  for _ in [0:count] do
    let (g, r1) := randomG 4 r
    let (len, r2) := r1.below size
    let mut rr := r2
    let mut bs : List Nat := []
    for _ in [0:len] do
      let (b, r') := rr.below 8
      bs := bs ++ [b]
      rr := r'
    r := rr
    let (lo, r3) := r.below (len + 1)
    r := r3
    let c : Cursor := ⟨lo, lo, len⟩
    match run bs g c with
    | .ok res =>
      succeeded := succeeded + 1
      if !withinB c res then within := false
      if budget g < res.items then budgetOk := false
    | .error _ => pure ()
    -- The same bytes as boxes.
    match children bs 0 bs.length (len % 2 == 0) 0 3 with
    | .ok (bxs, n) =>
      if !(bxs.all fun b => b.offset + 8 ≤ b.lo && b.lo ≤ b.hi && b.hi ≤ bs.length) || n != bxs.length || (n > 3) then boxesOk := false
    | .error _ => pure ()
  IO.println (if within then s!"OK reads-within: {succeeded} of {count} runs succeeded" else "FAIL reads-within")
  IO.println (if budgetOk then "OK budget" else "FAIL budget")
  IO.println (if boxesOk then "OK boxes-within" else "FAIL boxes-within")

/-! ## Random TIFF bitmaps -/

/-- `v` in `k` bytes, in the file's byte order. -/
def bytesOf (big : Bool) (k v : Nat) : List Nat :=
  let le := (List.range k).map fun i => v / 256 ^ i % 256
  if big then le.reverse else le

/-- A bitmap: the header, the strip data, the directory (entries `(tag, type, values)`), then
the values longer than four bytes. -/
def tiffFile (big : Bool) (fields : List (Nat × Nat × List Nat)) (data : List Nat) : List Nat :=
  let ifd := 8 + data.length
  let after := ifd + 2 + 12 * fields.length + 4
  let (entries, longer) := fields.foldl (init := (([] : List Nat), ([] : List Nat))) fun (entries, longer) (tag, type, vs) =>
    let raw := vs.flatMap (bytesOf big (if type == 3 then 2 else 4))
    let inline := raw.length ≤ 4
    let slot := if inline then raw ++ List.replicate (4 - raw.length) 0 else bytesOf big 4 (after + longer.length)
    (entries ++ bytesOf big 2 tag ++ bytesOf big 2 type ++ bytesOf big 4 vs.length ++ slot, if inline then longer else longer ++ raw)
  (if big then [0x4d, 0x4d] else [0x49, 0x49]) ++ bytesOf big 2 42 ++ bytesOf big 4 ifd ++ data ++
    bytesOf big 2 fields.length ++ entries ++ [0, 0, 0, 0] ++ longer

def randomTIFF (r : Rng) : List Nat × Rng := Id.run do
  let mut r := r
  let (big, r1) := r.below 2; r := r1
  let (w, r1) := r.below 6; r := r1
  let (h, r1) := r.below 6; r := r1
  let (photo, r1) := r.below 4; r := r1
  let (extraSample, r1) := r.below 2; r := r1
  let (wide, r1) := r.below 3; r := r1
  let (extra, r1) := r.below 4; r := r1
  let (rows, r1) := r.below (h + 2); r := r1
  let w := w + 1
  let h := h + 1
  let colors := if photo == 2 then 3 else 1
  let samples := colors + extraSample
  let bits := if wide == 2 then 16 else 8
  let stride := w * samples * (bits / 8)
  let count := if rows == 0 then 1 else 1 + (h - 1) / rows
  let mut data : List Nat := []
  for _ in [0:stride * h] do
    let (b, r1) := r.below 256; r := r1
    data := data ++ [b]
  let offsets := (List.range count).map fun i => 8 + i * rows * stride
  let sizes := (List.range count).map fun i => stride * min rows (h - i * rows)
  let (short, r1) := r.below 2; r := r1
  let mut fields : List (Nat × Nat × List Nat) :=
    [(256, 3 + short, [w]), (257, 4 - short, [h]), (258, 3, List.replicate samples bits), (262, 3, [photo]),
     (273, 3 + short, offsets), (277, 3, [samples]), (278, 3, [rows]), (279, 4, sizes)]
  if extraSample == 1 || extra == 3 then fields := fields ++ [(338, 3, [extra % 3])]
  -- Breakage: a field dropped, repeated, of another type, or with a value changed.
  let (k, r1) := r.below 10; r := r1
  let (i, r1) := r.below fields.length; r := r1
  match k with
  | 0 => fields := fields.eraseIdx i
  | 1 => fields := fields ++ [fields.getD i (0, 0, [])]
  | 2 => fields := fields.modify i fun (t, _, vs) => (t, 5, vs)
  | 3 => fields := fields.modify i fun (t, ty, vs) => (t, ty, vs.map (· + 1))
  | 4 => fields := fields ++ [(259, 3, [5])]
  | _ => pure ()
  let mut bs := tiffFile (big == 1) fields data
  let (k, r1) := r.below 8; r := r1
  if k == 0 then
    let (at', r1) := r.below bs.length; r := r1
    let (v, r1) := r.below 256; r := r1
    bs := bs.set at' v
  if k == 1 then
    let (n, r1) := r.below (bs.length + 1); r := r1
    bs := bs.take n
  return (bs, r)

def exploreTIFF (seed count : Nat) : IO Unit := do
  let mut r : Rng := ⟨UInt64.ofNat (seed + 1)⟩
  let mut ok := true
  let mut accepted := 0
  for _ in [0:count] do
    let (bs, r1) := randomTIFF r
    let (d, r2) := r1.below 40
    let (p, r3) := r2.below 2000
    r := r3
    let lim : TIFF.Limits := ⟨d + 1, p + 1, 1 <<< 20⟩
    match TIFF.layout bs lim with
    | .ok L =>
      accepted := accepted + 1
      let within := L.strips.all fun s => s.1 + s.2 ≤ bs.length
      let exact := (TIFF.pixels bs L).length == 4 * (L.width * L.height)
      let budget := L.samples ≤ 4 && L.strips.length ≤ lim.maxDimension
      let dims := 0 < L.width && 0 < L.height && L.width ≤ d + 1 && L.height ≤ d + 1 && L.width * L.height ≤ p + 1
      if !(within && exact && budget && dims) then ok := false
    | .error _ => pure ()
  IO.println (if ok then s!"OK tiff: {accepted} of {count} bitmaps accepted" else "FAIL tiff")

def forLines (f : String → Option String) : IO UInt32 := do
  let stdin ← IO.getStdin
  repeat
    let line ← stdin.getLine
    if line.isEmpty then break
    let line := line.trimAsciiEnd.toString
    if line.isEmpty || line.startsWith "#" then continue
    match f line with
    | some a => IO.println a
    | none => IO.eprintln s!"bad case: {line}"; return 1
  return 0

def main (args : List String) : IO UInt32 := do
  match args with
  | ["grammar"] => forLines grammarAnswer
  | ["cursor"] => forLines cursorAnswer
  | ["boxes"] => forLines boxesAnswer
  | ["bits"] => forLines bitsAnswer
  | ["tiff"] => forLines tiffAnswer
  | ["explore", seed, count, size] =>
    explore seed.toNat! count.toNat! size.toNat!
    exploreTIFF seed.toNat! (count.toNat! / 10)
    return 0
  | _ => IO.eprintln "usage: oracle grammar | cursor | boxes | bits | tiff | explore <seed> <cases> <size>"; return 2
