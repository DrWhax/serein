import Identity.Model
import Identity.Props
import Identity.Trace

/-!
# The oracle executable

* `oracle replay`: trace lines on stdin; prints `T <n>`, then `<k> <observation>` per step.
* `oracle gen <seed> <traces> <length>`: random traces (for the Swift rig).
* `oracle explore <seed> <traces> <length>`: every property after every step of random traces;
  `OK` or `FAIL` (with a minimised trace) per property.
* `oracle check`: which properties each trace on stdin falsifies, and where.
-/

open Identity

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

/-- One random event that is possible in `s` (indices in range). -/
def randomEv (s : S) (r : Rng) : Ev × Rng := Id.run do
  let (kind, r) := r.below 20
  let (p, r) := r.below 3
  let (k, r) := r.below 4
  let (x, r) := r.below 8
  let (y, r) := r.below 8
  let h := s.held.length
  let ev : Ev :=
    if kind < 4 then .key p k
    else if kind < 7 then .view p
    else if kind < 9 && h > 0 then .confirm ((List.range (1 + x % 3)).map fun n => (y + n * 5) % h)
    else if kind < 11 && s.pending.length > 0 then .commit (x % s.pending.length)
    else if kind < 12 && s.pending.length > 0 then .race (x % s.pending.length) p k
    else if kind < 14 && h > 0 then .verify (y % h) (x % 3 != 0)
    else if kind < 15 then .account (x % 2) (y % 2)
    else if kind < 16 then .window p
    else if kind < 18 then .storage p k (match y % 3 with | 0 => .dflt | 1 => .verified | _ => .unverified) (x == 0)
    else if s.jobs.length > 0 then .sync (x % s.jobs.length)
    else .view p
  (ev, r)

def randomTrace (len : Nat) (r : Rng) : List Ev × Rng := Id.run do
  let mut s := S.init
  let mut r := r
  let mut out : List Ev := []
  for _ in [0:len] do
    let (e, r') := randomEv s r
    r := r'
    s := step s e
    out := out ++ [e]
  (out, r)

/-- The step at which `check` first fails, if any. -/
def firstFailure (check : S → Ev → S → Bool) (es : List Ev) : Option Nat :=
  let rec go : List Ev → S → Nat → Option Nat
    | [], _, _ => none
    | e :: es, s, k => let s' := step s e; if check s e s' then go es s' (k + 1) else some k
  go es S.init 0

def removeRange (xs : List α) (i n : Nat) : List α := xs.take i ++ xs.drop (i + n)

partial def minimise (check : S → Ev → S → Bool) (t : List Ev) : List Ev :=
  let ok (t : List Ev) := (firstFailure check t).isSome
  let rec pass (t : List Ev) (chunk i : Nat) : List Ev :=
    if i ≥ t.length then t
    else let t' := removeRange t i chunk; if ok t' then pass t' chunk i else pass t chunk (i + 1)
  let rec sizes (t : List Ev) (chunk : Nat) : List Ev :=
    let t' := pass t chunk 0
    if chunk ≤ 1 then t' else sizes t' (chunk / 2)
  let t' := sizes t (max 1 (t.length / 2))
  if t'.length < t.length then minimise check t' else t'

def explore (seed count len : Nat) : IO Unit := do
  let mut r : Rng := ⟨UInt64.ofNat seed⟩
  let mut found : List (String × List Ev) := []
  for _ in [0:count] do
    let (t, r') := randomTrace len r
    r := r'
    for (name, check) in stepChecks do
      if (found.lookup name).isNone && (firstFailure check t).isSome then
        found := found ++ [(name, minimise check t)]
  for (name, check) in stepChecks do
    match found.lookup name with
    | none => IO.println s!"OK {name}: no violation in {count} traces of {len} events"
    | some t =>
      IO.println s!"FAIL {name} (step {(firstFailure check t).getD 0}, {t.length} events)"
      IO.println s!"  {traceCode t}"

def replay (es : List Ev) : List String :=
  let rec go : List Ev → S → Nat → List String → List String
    | [], _, _, acc => acc.reverse
    | e :: es, s, k, acc => let s' := step s e; go es s' (k + 1) (s!"{k} {obs s'}" :: acc)
  go es S.init 0 []

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
      match parseTrace line with
      | .error msg => IO.eprintln msg; return false
      | .ok es =>
        IO.println s!"T {← n.get}"
        for l in replay es do IO.println l
        n.modify (· + 1)
        return true
  | ["check"] =>
    forLines fun line => do
      match parseTrace line with
      | .error msg => IO.eprintln msg; return false
      | .ok es =>
        let fails := stepChecks.filterMap fun (name, check) => (firstFailure check es).map fun k => s!"{name}@{k}"
        IO.println s!"fails=[{", ".intercalate fails}] {traceCode es}"
        return true
  | ["explore", seed, count, len] => explore seed.toNat! count.toNat! len.toNat!; return 0
  | ["gen", seed, count, len] =>
    let mut r : Rng := ⟨UInt64.ofNat seed.toNat!⟩
    for _ in [0:count.toNat!] do
      let (t, r') := randomTrace len.toNat! r
      r := r'
      IO.println (traceCode t)
    return 0
  | _ => IO.eprintln "usage: oracle replay | check | explore|gen <seed> <traces> <length>"; return 2
