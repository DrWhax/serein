import Group.Model
import Group.Props
import Group.Trace

/-!
# The oracle executable

* `oracle plan | rotation | auth`: decision cases on stdin (see `Trace.lean`), one answer per line.
* `oracle explore <seed> <traces> <length>`: random runs (membership and device changes, key
  expiry, sends planning, distributing and submitting in any order), every property after
  every step.
-/

open Group

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

def randomEv (s : S) (r : Rng) : Ev × Rng := Id.run do
  let (k, r) := r.below 12
  let (a, r) := r.below 5
  let (b, r) := r.below 5
  let (x, r) := r.below 8
  let n := s.jobs.length
  let ev : Ev := match k with
    | 0 => .add a
    | 1 => .remove a
    | 2 => .refresh a ((List.range (x % 3)).map (· + b))
    | 3 => .expire
    | 4 => .queue [a, b, (a + b) % 5, (a + 2) % 5] (x == 0)
    | 5 | 6 => if n > 0 then .plan (x % n) else .queue [a, b] false
    | 7 | 8 => if n > 0 then .distribute (x % n) else .add a
    | _ => if n > 0 then .submit (x % n) else .remove b
  (ev, r)

def init : S := S.init [0, 1, 2, 3] fun a => [0, a + 1]

def explore (seed count len : Nat) : IO Unit := do
  let mut r : Rng := ⟨UInt64.ofNat seed⟩
  let mut found : List String := []
  for _ in [0:count] do
    let mut s := init
    for _ in [0:len] do
      let (e, r') := randomEv s r
      r := r'
      let s' := step s e
      for (name, check) in stepChecks do
        if !found.contains name && !check s e s' then found := found ++ [name]
      s := s'
  for (name, _) in stepChecks do
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
  | ["plan"] => forLines planAnswer
  | ["rotation"] => forLines rotationAnswer
  | ["auth"] => forLines authAnswer
  | ["explore", seed, count, len] => explore seed.toNat! count.toNat! len.toNat!; return 0
  | _ => IO.eprintln "usage: oracle plan | rotation | auth | explore <seed> <traces> <length>"; return 2
