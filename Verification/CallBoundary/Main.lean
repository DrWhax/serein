import CallBoundary.Model
import CallBoundary.Props
import CallBoundary.Trace

/-!
# The oracle executable

* `oracle step`: one event per line on stdin (see `Trace.lean`); after each, the state the rig
  compares, flushed. `reset` starts a new run (answer `ok`).
* `oracle explore <seed> <runs> <length>`: random runs (the app's calls and the service's
  events of every kind, on three peers, four users, two groups and three clients, with crashes,
  pump turns and the window passing), every property after every step.
-/

open CallBoundary

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

def randomList (r : Rng) : List Nat × Rng := Id.run do
  let (n, r) := r.below 3
  let mut r := r
  let mut out := []
  for _ in [0:n] do
    let (u, r') := r.below 4
    r := r'
    out := out ++ [u]
  (out, r)

def randomEv (r : Rng) : Ev × Rng := Id.run do
  let (k, r) := r.below 24
  let (p, r) := r.below 3
  let (c, r) := r.below 4
  let (u, r) := r.below 4
  let (g, r) := r.below 2
  let (cl, r) := r.below 3
  let (us, r) := randomList r
  let ev : Ev := match k with
    | 0 => .setSelf
    | 1 => .start p c
    | 2 => .offer p c
    | 3 => .callMsg u
    | 4 => .group g (cl + 1) (u % 2 == 1)
    | 5 => .members (cl + 1) us
    | 6 => .callCmd
    | 7 => .groupCmd (cl + 1)
    | 8 => .cancelRing g
    | 9 => .expireSender u
    | 10 => .expireRing g
    | 11 | 12 => .incoming p c
    | 13 => .signal p c
    | 14 => .message u
    | 15 => .groupMessage g us
    | 16 => .ring u g
    | 17 => .callEnded c
    | 18 => .devices (cl + 1) us
    | 19 => .groupEnded (cl + 1)
    | 20 => .crash
    | _ => .wait
  (ev, r)

/-- The properties after a step from `s` with `e`. -/
def checks (s : St) (e : Ev) : List (String × Bool) :=
  let t := step s e
  [("out-allowed", outAllowedB s e), ("commands-reach-their-generation", cmdsGenB t), ("loss-ends-older-calls", endedB t),
   ("live-endpoint-has-self", configuredB t), ("stale-commands-refused", staleRefusedB s e),
   ("message-to-app-known", messageAppKnownB s e)]

def explore (seed count len : Nat) : IO Unit := do
  let mut r : Rng := ⟨UInt64.ofNat seed⟩
  let mut failed : List String := []
  for _ in [0:count] do
    let mut s := St.init
    for _ in [0:len] do
      let (e, r') := randomEv r
      r := r'
      for (name, ok) in checks s e do
        if !ok && !failed.contains name then failed := failed ++ [name]
      s := step s e
  let names := (checks St.init .wait).map (·.1)
  for n in names do
    IO.println s!"{n} {if failed.contains n then "FAIL" else "OK"}"

partial def stepLoop (s : St) : IO Unit := do
  let stdin ← IO.getStdin
  let stdout ← IO.getStdout
  let l ← stdin.getLine
  if l.isEmpty then return
  let l := l.trimAsciiEnd.toString
  if l == "reset" then
    stdout.putStrLn "ok"; stdout.flush
    stepLoop St.init
  else match parse l with
    | some e =>
      let t := step s e
      stdout.putStrLn (line t); stdout.flush
      stepLoop t
    | none =>
      stdout.putStrLn s!"error: {l}"; stdout.flush
      stepLoop s

def main (args : List String) : IO Unit := do
  match args with
  | ["step"] => stepLoop St.init
  | ["explore", seed, count, len] => explore seed.toNat! count.toNat! len.toNat!
  | _ => IO.println "usage: oracle step | oracle explore <seed> <runs> <length>"
