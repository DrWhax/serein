import Send.Model
import Send.Props
import Send.Trace

/-!
# The oracle executable

* `oracle decide`: decision cases on stdin (`ids nums groups msgs members | target content
  named`); prints `auth retract carries [recipients]` for each — what the Swift rig compares with
  `MessageSender.authorization`, `OutgoingPayload.onlyRetracts` and `GroupSender`'s recipients.
* `oracle explore <seed> <traces> <length>`: random pipeline traces, every property after every step.
* `oracle check`: which properties each pipeline trace on stdin falsifies.
-/

open Send

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

def init : P := ⟨⟨[], [], [], fun _ => .live, fun _ => [0, 1, 2]⟩, [], [], 0⟩

def randomEv (p : P) (r : Rng) : Ev × Rng := Id.run do
  let (kind, r) := r.below 12
  let (a, r) := r.below 3
  let (b, r) := r.below 2
  let (c, r) := r.below 2
  let (d, r) := r.below 2
  let (x, r) := r.below 8
  let n := p.jobs.length
  let content : Content := match x % 6 with
    | 0 => .data ⟨b == 1, c == 1⟩
    | 1 => .data ⟨true, false⟩
    | 2 => .sent (if d == 0 then some ⟨b == 1, c == 1⟩ else none) (b == 1) (c == 1 && x == 2) false
    | 3 => .content
    | 4 => .other
    | _ => .sent none true false false
  let target : Target := match x % 3 with | 0 => .direct a | 1 => .group 0 | _ => .self
  let ev : Ev :=
    if kind < 3 then .queue target content [a, (a + b) % 3]
    else if kind < 5 && n > 0 then .start (x % n)
    else if kind < 7 && n > 0 then .submit (x % n)
    else if kind < 8 then .block a (b == 1)
    else if kind < 9 then .blockNumber a (b == 1)
    else if kind < 10 then .blockGroup 0 (b == 1)
    else if kind < 11 then .erase a
    else .remove a
  (ev, r)

def randomTrace (len : Nat) (r : Rng) : List Ev × Rng := Id.run do
  let mut p := init
  let mut r := r
  let mut out : List Ev := []
  for _ in [0:len] do
    let (e, r') := randomEv p r
    r := r'
    p := step p e
    out := out ++ [e]
  (out, r)

def firstFailure (check : P → Ev → P → Bool) (es : List Ev) : Option Nat :=
  let rec go : List Ev → P → Nat → Option Nat
    | [], _, _ => none
    | e :: es, p, k => let p' := step p e; if check p e p' then go es p' (k + 1) else some k
  go es init 0

def traceCode (es : List Ev) : String := " ".intercalate (es.map Ev.code)

def explore (seed count len : Nat) : IO Unit := do
  let mut r : Rng := ⟨UInt64.ofNat seed⟩
  let mut found : List (String × List Ev) := []
  for _ in [0:count] do
    let (t, r') := randomTrace len r
    r := r'
    for (name, check) in stepChecks do
      if (found.lookup name).isNone && (firstFailure check t).isSome then found := found ++ [(name, t)]
  for (name, _) in stepChecks do
    match found.lookup name with
    | none => IO.println s!"OK {name}: no violation in {count} traces of {len} events"
    | some t => IO.println s!"FAIL {name}\n  {traceCode t}"

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
  | ["decide"] =>
    forLines fun line => do
      match parseCase line with
      | none => IO.eprintln s!"bad case: {line}"; return false
      | some (s, t, c, named) =>
        let to := match t with | .group g => recipients s g | _ => []
        IO.println s!"{b01 (authorized s t c named)} {b01 c.onlyRetracts} {b01 c.carries} [{numsCode to}]"
        return true
  | ["check"] =>
    forLines fun line => do
      match ((line.splitOn " ").filter (· ≠ "")).mapM Ev.parse with
      | none => IO.eprintln s!"bad trace: {line}"; return false
      | some es =>
        let fails := stepChecks.filterMap fun (name, check) => (firstFailure check es).map fun k => s!"{name}@{k}"
        IO.println s!"fails=[{", ".intercalate fails}] {traceCode es}"
        return true
  | ["explore", seed, count, len] => explore seed.toNat! count.toNat! len.toNat!; return 0
  | _ => IO.eprintln "usage: oracle decide | check | explore <seed> <traces> <length>"; return 2
