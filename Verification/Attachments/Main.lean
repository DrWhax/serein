import Attachments.Model
import Attachments.Props
import Attachments.Trace

/-!
# The oracle executable

* `oracle decrypt | download`: cases on stdin (see `Trace.lean`), one answer per line.
* `oracle explore <seed> <runs> <length>`: random runs (attachments of any size against a limit,
  responses genuine, of another upload or forged, of any length; consumers reading; files changed
  on disk), every property after every step.
-/

open Attachments

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
  let (k, r) := r.below 8
  let (id, r) := r.below 5
  let (size, r) := r.below 300
  let (extra, r) := r.below 40
  let (flags, r) := r.below 8
  let (len, r) := r.below 70000
  let (g, r) := r.below 3
  let ev : Ev := match k with
    | 0 | 1 => .arrive { id, upload := id % 3, size, plainLen := if flags < 4 then size else size + extra, pad := size + extra,
                         bucket := size + extra / 2, hasDigest := flags % 2 == 0, hasHash := flags / 2 % 2 == 0, st := .pending, path := none }
    | 2 | 3 | 4 => .download id ⟨if flags < 6 then ciphertextSize (size + extra / 2) else len, if g == 0 then some (id % 3) else if g == 1 then some 7 else none⟩
    | 5 | 6 => .consume id
    | _ => .tamper (len % 6)
  (ev, r)

def explore (seed count len : Nat) : IO Unit := do
  let mut r : Rng := ⟨UInt64.ofNat seed⟩
  let mut found : List String := []
  for _ in [0:count] do
    let (mx, r1) := r.below 400
    r := r1
    let mut s := S.init mx
    for _ in [0:len] do
      let (e, r') := randomEv r
      r := r'
      s := step s e
      for (name, ok) in checks s do
        if !found.contains name && !ok then found := found ++ [name]
  for (name, _) in checks (S.init 0) do
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
  | ["decrypt"] => forLines decryptAnswer
  | ["download"] => forLines downloadAnswer
  | ["explore", seed, count, len] => explore seed.toNat! count.toNat! len.toNat!; return 0
  | _ => IO.eprintln "usage: oracle decrypt | download | explore <seed> <runs> <length>"; return 2
