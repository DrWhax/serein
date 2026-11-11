import Codecs.Model
import Codecs.Props
import Codecs.Trace

/-!
# The oracle executable

* `oracle grammar | cursor | boxes | bits`: cases on stdin (see `Trace.lean`).
* `oracle explore <seed> <cases> <size>`: random grammars on random bytes (regions, length
  prefixes, repetitions with any counts and limits, choices), and random box streams; that reads
  stay in their regions, budgets hold and boxes stay in their containers, for every run.
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
  | ["explore", seed, count, size] => explore seed.toNat! count.toNat! size.toNat!; return 0
  | _ => IO.eprintln "usage: oracle grammar | cursor | boxes | bits | explore <seed> <cases> <size>"; return 2
