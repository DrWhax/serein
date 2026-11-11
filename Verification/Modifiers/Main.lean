import Modifiers.Model
import Modifiers.Props
import Modifiers.Trace

/-!
# The oracle executable

* `oracle decide | run | kept`: cases on stdin (see `Trace.lean`), one answer per line.
* `oracle explore <seed> <traces> <length>`: random runs (messages arriving, duplicated and
  removed; modifiers of every kind arriving before or after their targets, replayed, from members
  and strangers, in the right conversation or another), every property after every step.
-/

open Modifiers

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

def Rng.subset (r : Rng) (xs : List Nat) (p : Nat) : List Nat × Rng := Id.run do
  let mut r := r
  let mut out := []
  for x in xs do
    let (k, r') := r.below p
    r := r'
    if k == 0 then out := out ++ [x]
  (out, r)

def randomWorld (r : Rng) : World × Rng := Id.run do
  let (m10, r) := r.subset [0, 1, 2, 3] 2
  let (a10, r) := r.subset m10 2
  let (o10, r) := r.below 2
  let (m11, r) := r.subset [0, 1, 2, 3] 2
  let (a11, r) := r.subset m11 2
  let (o11, r) := r.below 2
  let (bl, r) := r.subset [1, 2, 3] 5
  let (bg, r) := r.subset [10, 11] 5
  ({ us := 0, groups := [⟨10, m10, a10, o10 == 0⟩, ⟨11, m11, a11, o11 == 0⟩], blocked := bl, blockedGroups := bg }, r)

def convs : List Nat := [0, 1, 2, 3, 10, 11]

def randomEv (r : Rng) : Ev × Rng := Id.run do
  let (k, r) := r.below 10
  let (a, r) := r.below 4
  let (t, r) := r.below 10
  let (c, r) := r.below 6
  let (sv, r) := r.below 70
  let (flags, r) := r.below 64
  let (st, r) := r.subset [1, 2, 3] 2
  if k < 3 then
    let conv := if a == 0 then convs[c]! else [a, 10, 11][c % 3]!
    return (.recv { gen := 0, author := a, sentAt := t + 1, conv, server := sv, outgoing := a == 0, sentTo := st,
                    viewOnce := flags % 8 == 0, voice := flags % 8 == 1, poll := flags % 4 == 2, terminated := false,
                    giftBadge := flags / 8 % 6 == 0, pinned := false, deleted := false, erased := false, rev := 0, revs := [] }, r)
  if k == 9 then
    let (x, r) := r.below 4
    return (if x == 0 then .forget a (t + 1) else .tick (x * 20), r)
  let (kind, r) := r.below 8
  let (s, r) := r.below 4
  let (src, r) := r.below 3
  let (own, r) := r.below 5
  let (ts, r) := r.below 14
  let kind := kindOf kind
  let author := if own > 0 && (kind == .delete || kind == .edit || kind == .terminate) then s else a
  let src := if s == 0 then srcOf src else .other
  (.mod { kind, sender := s, conv := convs[c]!, src, author, target := t + 1, ts := ts + 1, server := sv }, r)

def explore (seed count len : Nat) : IO Unit := do
  let mut r : Rng := ⟨UInt64.ofNat seed⟩
  let mut found : List String := []
  for _ in [0:count] do
    let (w, r1) := randomWorld r
    r := r1
    let mut s := S.init
    for _ in [0:len] do
      let (e, r') := randomEv r
      r := r'
      let s' := step w s e
      for (name, ok) in stepChecks w s s' do
        if !found.contains name && !ok then found := found ++ [name]
      s := s'
  for (name, _) in stepChecks { us := 0, groups := [], blocked := [], blockedGroups := [] } S.init S.init do
    IO.println (if found.contains name then s!"FAIL {name}" else s!"OK {name}: no violation in {count} traces of {len} events")

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
  | ["decide"] => forLines decideAnswer
  | ["run"] => forLines runAnswer
  | ["kept"] => forLines keptAnswer
  | ["explore", seed, count, len] => explore seed.toNat! count.toNat! len.toNat!; return 0
  | _ => IO.eprintln "usage: oracle decide | run | kept | explore <seed> <traces> <length>"; return 2
