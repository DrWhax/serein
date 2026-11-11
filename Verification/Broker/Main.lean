import Broker.Model
import Broker.Props
import Broker.Trace

/-!
# The oracle executable

* `oracle step`: one event per line on stdin (see `Trace.lean`); after each, the state the rig
  compares, flushed. `reset` starts a new run (answer `ok`).
* `oracle deputy`: the link-preview and GIF checks, one per line.
* `oracle explore <seed> <runs> <length>`: random runs (calls of every kind on four inputs,
  replies of every kind to any request at any time, crashes, unsolicited messages, timeouts and
  cancellations), every property after every step.
-/

open Broker

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

def sizes : List Nat := [16, 32, 64]

def randomReply (k x y : Nat) : Reply :=
  match k with
  | 0 | 1 => .thumb (sizes.getD x 16) (sizes.getD y 16)
  | 2 | 3 => .opened y (x != 0)
  | 4 => .voiceId y
  | 5 => .empty
  | 6 => .garbage
  | _ => .error

def randomEv (s : St) (r : Rng) : Ev × Rng := Id.run do
  let (k, r) := r.below 14
  let (a, r) := r.below 4
  let (b, r) := r.below 3
  let (m, r) := r.below (s.reqs.length + 1)
  let (rk, r) := r.below 8
  let ev : Ev := match k with
    | 0 | 1 => .call (.thumb (sizes.getD b 16) a)
    | 2 => .call (.openV a)
    | 3 => .call .start
    | 4 | 5 | 6 | 7 => .reply m (randomReply rk b a)
    | 8 => .crash (if a < 3 then .dec else .voice)
    | 9 => .unsolicited (if a < 2 then .dec else .voice)
    | 10 | 11 => .timeout m
    | _ => .cancel m
  (ev, r)

def explore (seed count len : Nat) : IO Unit := do
  let mut r : Rng := ⟨UInt64.ofNat seed⟩
  let mut found : List String := []
  for _ in [0:count] do
    let mut s := St.init
    for _ in [0:len] do
      let (e, r') := randomEv s r
      r := r'
      s := step s e
      for (name, ok) in checks s do
        if !found.contains name && !ok then found := found ++ [name]
  for (name, _) in checks St.init do
    IO.println (if found.contains name then s!"FAIL {name}" else s!"OK {name}: no violation in {count} runs of {len} events")

def stepMode : IO UInt32 := do
  let stdin ← IO.getStdin
  let stdout ← IO.getStdout
  let mut s := St.init
  repeat
    let line ← stdin.getLine
    if line.isEmpty then break
    let line := line.trimAsciiEnd.toString
    if line.isEmpty then continue
    if line == "reset" then
      s := St.init
      stdout.putStrLn "ok"
    else
      match parseEv s line with
      | some e =>
        s := step s e
        stdout.putStrLn (observe s)
      | none =>
        IO.eprintln s!"bad event: {line}"
        return 1
    stdout.flush
  return 0

def deputyMode : IO UInt32 := do
  let stdin ← IO.getStdin
  repeat
    let line ← stdin.getLine
    if line.isEmpty then break
    let line := line.trimAsciiEnd.toString
    if line.isEmpty then continue
    match deputy line with
    | some a => IO.println a
    | none => IO.eprintln s!"bad case: {line}"; return 1
  return 0

def main (args : List String) : IO UInt32 := do
  match args with
  | ["step"] => stepMode
  | ["deputy"] => deputyMode
  | ["explore", seed, count, len] => explore seed.toNat! count.toNat! len.toNat!; return 0
  | _ => IO.eprintln "usage: oracle step | deputy | explore <seed> <runs> <length>"; return 2
