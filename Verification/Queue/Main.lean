import Queue.Model
import Queue.Props
import Queue.Trace

/-!
# The oracle executable

* `oracle replay`: traces of user and environment events on stdin; after each, the actor's own
  work is settled (`settle`) and the observation printed — what the Swift rig compares with the
  real `JobQueue` once it is quiet.
* `oracle explore <seed> <traces> <length>`: random traces of every event, including the
  scheduler's (any pending work first), every property after every step.
* `oracle gen <seed> <traces> <length>`: random traces of user and environment events.
-/

open Queue

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

def userEv (j : Nat) (r : Rng) : Ev × Rng :=
  let (k, r) := r.below 10
  let ev : Ev := match k with
    | 0 => .start | 1 => .stop | 2 => .stopAndWait | 3 | 4 => .enqueue j
    | 5 => .handlerReturns .ok | 6 => .handlerReturns .permanent | 7 => .handlerReturns .retry
    | 8 => .handlerReturns .cancelled | _ => .start
  (ev, r)

def anyEv (s : S) (j : Nat) (r : Rng) : Ev × Rng :=
  let (k, r) := r.below 3
  if k == 0 then userEv j r
  else
    let (x, r) := r.below 3
    let ev : Ev := match x with | 0 => .runLoop | 1 => .runWake | _ => .runReturn (s.returns.length / 2)
    (ev, r)

def stepChecks' := stepChecks

def explore (seed count len : Nat) : IO Unit := do
  let mut r : Rng := ⟨UInt64.ofNat seed⟩
  let mut found : List String := []
  for _ in [0:count] do
    let mut s := S.init []
    for i in [0:len] do
      let (e, r') := anyEv s i r
      r := r'
      let s' := step s e
      for (name, check) in stepChecks do
        if !found.contains name && !check s e s' then found := found ++ [name]
      s := s'
  for (name, _) in stepChecks do
    IO.println (if found.contains name then s!"FAIL {name}" else s!"OK {name}: no violation in {count} traces of {len} events")

def forLines (f : String → IO Bool) : IO UInt32 := do
  let stdin ← IO.getStdin
  repeat
    let line ← stdin.getLine
    if line.isEmpty then break
    let line := line.trimAsciiEnd.toString
    if line.isEmpty || line.startsWith "#" then continue
    if !(← f line) then return 1
  return 0

def main (args : List String) : IO UInt32 := do
  match args with
  | ["replay"] =>
    let n ← IO.mkRef 0
    forLines fun line => do
      match ((line.splitOn " ").filter (· ≠ "")).mapM Ev.parse with
      | none => IO.eprintln s!"bad trace: {line}"; return false
      | some es =>
        IO.println s!"T {← n.get}"
        let mut s := S.init []
        let mut k := 0
        for e in es do
          s := settle 64 (step s e)
          IO.println s!"{k} {obs s}"
          k := k + 1
        n.modify (· + 1)
        return true
  | ["explore", seed, count, len] => explore seed.toNat! count.toNat! len.toNat!; return 0
  | ["gen", seed, count, len] =>
    let mut r : Rng := ⟨UInt64.ofNat seed.toNat!⟩
    for _ in [0:count.toNat!] do
      let mut out : List String := []
      for i in [0:len.toNat!] do
        let (e, r') := userEv i r
        r := r'
        out := out ++ [e.code]
      IO.println (" ".intercalate out)
    return 0
  | _ => IO.eprintln "usage: oracle replay | explore|gen <seed> <traces> <length>"; return 2
