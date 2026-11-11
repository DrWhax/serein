import Media.Model
import Media.Props
import Media.Trace

/-!
# The oracle executable

* `oracle db`: database states on stdin (`rows rel now`); prints `permits` for messages 0–3 ×
  paths 0–2, `permits` without a message per path, and the fetched references.
* `oracle apply`: `avail | lightbox video audio cache` on stdin; prints the viewers after
  `applyMediaAvailability`.
* `oracle explore <seed> <traces> <length>`: random sessions, every property after every step.
-/

open Media

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

def init : S := ⟨⟨fun m => if m < 3 then some ⟨false, none⟩ else none, [(0, 0), (1, 0), (1, 1), (2, 2)], 0⟩, ⟨none, none, none, []⟩, [], none, []⟩

def randomEv (s : S) (r : Rng) : Ev × Rng := Id.run do
  let (k, r) := r.below 14
  let (m, r) := r.below 3
  let (p, r) := r.below 3
  let (t, r) := r.below 4
  let ev : Ev := match k with
    | 0 => .openLightbox m [p]
    | 1 => .playVideo m p
    | 2 => .playAudio m p
    | 3 => .decode m p
    | 4 => .decoded (t % (s.decodes.length + 1))
    | 5 => .openSave m p
    | 6 => .confirmSave
    | 7 => .delete m
    | 8 => .erase m
    | 9 => .expireAt m (s.d.now + t)
    | 10 => .tick
    | 11 => .ref m p
    | _ => .update
  (ev, r)

def randomTrace (len : Nat) (r : Rng) : List Ev × Rng := Id.run do
  let mut s := init
  let mut r := r
  let mut out : List Ev := []
  for _ in [0:len] do
    let (e, r') := randomEv s r
    r := r'
    s := step s e
    out := out ++ [e]
  (out, r)

def firstFailure (check : S → Ev → S → Bool) (es : List Ev) : Option Nat :=
  let rec go : List Ev → S → Nat → Option Nat
    | [], _, _ => none
    | e :: es, s, k => let s' := step s e; if check s e s' then go es s' (k + 1) else some k
  go es init 0

def explore (seed count len : Nat) : IO Unit := do
  let mut r : Rng := ⟨UInt64.ofNat seed⟩
  let mut found : List String := []
  for _ in [0:count] do
    let (t, r') := randomTrace len r
    r := r'
    for (name, check) in stepChecks do
      if !found.contains name && (firstFailure check t).isSome then found := found ++ [name]
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
  | ["db"] => forLines fun line => do
      match parseDb line with
      | some d => IO.println (dbAnswer d); return true
      | none => IO.eprintln s!"bad state: {line}"; return false
  | ["apply"] => forLines fun line => do
      match parseApply line with
      | some (a, u) => IO.println (uiCode (apply a u)); return true
      | none => IO.eprintln s!"bad case: {line}"; return false
  | ["explore", seed, count, len] => explore seed.toNat! count.toNat! len.toNat!; return 0
  | _ => IO.eprintln "usage: oracle db | apply | explore <seed> <traces> <length>"; return 2
