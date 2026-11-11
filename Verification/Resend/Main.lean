import Resend.Model
import Resend.Props
import Resend.Trace

/-!
# The oracle executable

* `oracle run`: runs on stdin (see `Trace.lean`), one line of answers per run.
* `oracle explore <seed> <runs> <length>`: random runs (sends to devices, receipts, time passing,
  stories and lists changing, retry requests from anyone's any device about any timestamp, and
  repeated), every property after every step.
-/

open Resend

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

def randomEv (r : Rng) : Ev × Rng := Id.run do
  let (k, r) := r.below 12
  let (a, r) := r.below 4
  let (d, r) := r.below 3
  let (ts, r) := r.below 8
  let (c, r) := r.below 4
  let (x, r) := r.below 8
  let ev : Ev := match k with
    | 0 | 1 | 2 => .send (ts * 5) c a ((List.range 3).filter fun i => (x >>> i) % 2 == 1)
    | 3 => .receipt a d (ts * 5)
    | 4 => .tick (x * 2)
    | 5 => .story (ts * 5) (x % 2)
    | 6 => .setList ⟨x % 2, d == 0, x == 7, (List.range 4).filter fun i => (ts >>> i) % 2 == 1⟩
    | _ => .retry a d (ts * 5)
  (ev, r)

def explore (seed count len : Nat) : IO Unit := do
  let mut r : Rng := ⟨UInt64.ofNat seed⟩
  let mut found : List String := []
  let w : World := ⟨[2]⟩
  for _ in [0:count] do
    let mut s := S.init
    for _ in [0:len] do
      let (e, r') := randomEv r
      r := r'
      s := step w s e
      for (name, ok) in checks s do
        if !found.contains name && !ok then found := found ++ [name]
  for (name, _) in checks S.init do
    IO.println (if found.contains name then s!"FAIL {name}" else s!"OK {name}: no violation in {count} runs of {len} events")

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
  | ["run"] => forLines runAnswer
  | ["explore", seed, count, len] => explore seed.toNat! count.toNat! len.toNat!; return 0
  | _ => IO.eprintln "usage: oracle run | explore <seed> <runs> <length>"; return 2
