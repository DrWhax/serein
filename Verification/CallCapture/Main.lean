import CallCapture.Model
import CallCapture.Props
import CallCapture.Trace
import CallCapture.UI
import CallCapture.Counterexamples

/-!
# The oracle executable

* `oracle replay` reads trace lines on stdin and prints, for each trace, `T <n>` and then one
  observation line per step (`<k> <observation>`). The Swift conformance test compares these
  with what production does.
* `oracle explore <seed> <traces> <length> [any|ui|drained|drained-fifo]` runs random traces
  through the model, checks every property after every step, and prints a minimised
  counterexample for each property it falsifies. `ui`: user events only when the UI offers
  them; `drained`: also only while no main-actor job is pending; `drained-fifo`: also the
  scheduler always runs the oldest job (see `UI.lean`).
* `oracle gen <seed> <traces> <length> [mode]` prints random traces (for Swift).
* `oracle check` reads traces on stdin and prints which properties each falsifies (and at which
  step), and whether it is UI-reachable, drained, and FIFO.
* `oracle counterexamples` prints the counterexample traces proved in `Counterexamples.lean`.
-/

open CallCapture

-- ## Random traces

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

def pendingSetups (s : S) : List Nat := s.ops.filterMap fun | .setup q .. => some q | _ => none
def pendingSources (s : S) : List Nat := s.ops.filterMap fun | .sources i .. => some i | _ => none
def pendingStarts (s : S) : List Nat := s.ops.filterMap fun | .install _ _ j _ => some j | _ => none
def pendingStops (s : S) : List Nat := s.ops.filterMap fun | .tdStart _ _ j _ | .stopping j => some j | _ => none
def runningStreams (s : S) : List Nat :=
  (List.range s.streamNext).filter fun j => match s.streams j with | some (_, .running) => true | _ => false
def ranStreams (s : S) : List Nat :=
  (List.range s.streamNext).filter fun j => match s.streams j with | some (_, ph) => ph.hasRun | _ => false

/-- Weighted candidate events in state `s`. Running the oldest job, events the UI offers now
and completions of pending awaits weigh most, so traces reach calls, shares and frames; the
rest stay possible (other jobs first, duplicates, stale or out-of-order events). Only events
`mode` allows are offered. -/
def candidates (s : S) (mode : String) : List (Nat × Ev) :=
  let user : List Ev :=
    [.openLobby 0 true, .openLobby 0 false, .openLobby 1 true, .openLobby 1 false, .startCall,
     .accept 0 true, .accept 0 false, .accept 1 true, .accept 1 false, .decline 0, .decline 1, .hangUp, .closeCall,
     .setVideo true, .setVideo false, .toggleShare, .pickSource, .cancelPick]
  let user : List (Nat × Ev) := user.filterMap fun e =>
    if uiEnabled s e then
      some ((match e with | .hangUp | .closeCall => 1 | .startCall | .toggleShare | .pickSource => 6 | _ => 3), e)
    else some (1, e)
  let sched : List (Nat × Ev) :=
    match s.jobs with
    | [] => []
    | _ => (14, .run 0) :: ((List.range (min s.jobs.length 5)).drop 1).map fun k => (3, .run k)
  let newest (n : Nat) : List Nat := if n == 0 then [] else [n - 1]
  let env : List (Nat × Ev) :=
    [(1, .nIncoming 0 true), (1, .nIncoming 1 false), (1, .nRejected 0), (1, .nRejected 1)] ++
    (if s.ncall.isSome then
      [(3, .nState .ringing), (3, .nState .accepted), (1, .nState .reconnecting),
       (1, .nEnd .localHangup), (1, .nEnd .remoteHangup), (1, .nEnd .needPermission)] else [])
  let dev : List (Nat × Ev) :=
    (pendingSetups s).flatMap (fun q => [(6, .setupDone q true), (1, .setupDone q false)]) ++
    (match s.pc with
      | .access => [(6, .camAccess true), (1, .camAccess false)]
      | .start => [(6, .camStart true), (1, .camStart false)]
      | .stopUnwanted | .stopAfterStart => [(6, .camStopDone)]
      | _ => []) ++
    (newest s.camNext).map (fun k => (3, .camFrame k)) ++
    (List.range s.camNext).map (fun k => (1, .camFrame k)) ++
    (pendingSources s).flatMap (fun i => [(6, .srcDone i true), (1, .srcDone i false)]) ++
    (pendingStarts s).flatMap (fun j => [(6, .scStartDone j true), (1, .scStartDone j false)]) ++
    (pendingStops s).flatMap (fun j => [(6, .scStopDone j true), (1, .scStopDone j false)]) ++
    (runningStreams s).map (fun j => (4, .scFrame j)) ++
    (ranStreams s).map (fun j => (1, .scFrame j)) ++
    (List.range s.streamNext).map (fun j => (1, .scStopped j))
  (user ++ sched ++ env ++ dev).filter fun (_, e) => enabledIn mode s e

def pick (cands : List (Nat × Ev)) (r : Rng) : Ev × Rng :=
  let total := cands.foldl (fun acc (w, _) => acc + w) 0
  let (x, r) := r.below total
  let rec go : List (Nat × Ev) → Nat → Ev
    | [], _ => .run 0
    | (w, e) :: rest, x => if x < w then e else go rest (x - w)
  (go cands x, r)

def randomCfg (r : Rng) : Cfg × Rng :=
  -- a third of the traces start next to the wrap-around point of every counter
  let (x, r) := r.below 3
  if x == 0 then ({ gen0 := 0xFFFFFFFFFFFFFFFE, tok0 := 0xFFFFFFFFFFFFFFFE, setupGen0 := 0xFFFFFFFFFFFFFFFF,
                    capGen0 := 0xFFFFFFFFFFFFFFFF }, r)
  else ({}, r)

/-- Run `evs`, then the oldest job until none is pending. -/
def settle (s : S) (evs : List Ev) : S × List Ev :=
  let s := run s evs
  let rec go : Nat → S → List Ev → S × List Ev
    | 0, s, acc => (s, acc)
    | n + 1, s, acc => if s.jobs.isEmpty then (s, acc) else go n (step s (.run 0)) (acc ++ [.run 0])
  go 32 s evs

/-- Starting points: nothing; an accepted outgoing call (video on, camera sending); the same
call presenting a share. Indices come from the model state, so they are right for any `cfg`. -/
def startPrefix (kind : Nat) (s0 : S) : List Ev :=
  if kind == 0 then [] else
  let (s1, p1) := settle s0 [.openLobby 0 true]
  let (s2, p2) := settle s1 [.camAccess true]
  let (s3, p3) := settle s2 [.camStart true]
  let (s4, p4) := settle s3 [.startCall]
  let q := s4.setupNext - 1
  let (s5, p5) := settle s4 [.setupDone q true]
  let (s6, p6) := settle s5 [.nState .ringing]
  let (s7, p7) := settle s6 [.nState .accepted]
  let call := p1 ++ p2 ++ p3 ++ p4 ++ p5 ++ p6 ++ p7
  if kind == 1 then call else
  let (s8, p8) := settle s7 [.toggleShare]
  let i := s8.capNext - 1
  let (s9, p9) := settle s8 [.srcDone i true]
  let (s10, p10) := settle s9 [.pickSource]
  let j := s10.streamNext - 1
  let (_, p11) := settle s10 [.scStartDone j true]
  call ++ p8 ++ p9 ++ p10 ++ p11

def randomTrace (len : Nat) (mode : String) (r : Rng) : Trace × Rng :=
  let (cfg, r) := randomCfg r
  let (k, r) := r.below 4
  let pre := startPrefix (if k < 2 then 0 else k - 1) (S.init cfg)
  let rec go : Nat → S → Rng → List Ev → List Ev × Rng
    | 0, _, r, acc => (acc.reverse, r)
    | n + 1, s, r, acc =>
      let (e, r) := pick (candidates s mode) r
      go n (step s e) r (e :: acc)
  let (evs, r) := go len (run (S.init cfg) pre) r []
  ({ cfg, events := pre ++ evs }, r)

-- ## Checking and minimising

def removeRange (xs : List α) (i n : Nat) : List α := xs.take i ++ xs.drop (i + n)

/-- Delta debugging: drop chunks of events while the trace still fails (and, when `ui`, stays
UI-reachable). Chunk sizes halve down to single events; repeats until nothing more goes. -/
partial def minimise (check : S → Ev → S → Bool) (mode : String) (t : Trace) : Trace :=
  let ok (t : Trace) := (firstFailure check t).isSome && allIn mode t
  let rec pass (t : Trace) (chunk : Nat) (i : Nat) : Trace :=
    if i ≥ t.events.length then t
    else
      let t' := { t with events := removeRange t.events i chunk }
      if ok t' then pass t' chunk i else pass t chunk (i + 1)
  let rec sizes (t : Trace) (chunk : Nat) : Trace :=
    let t' := pass t chunk 0
    if chunk ≤ 1 then t' else sizes t' (chunk / 2)
  let t' := sizes t (max 1 (t.events.length / 2))
  -- also try the default counters
  let t' := if t'.cfg.gen0 != 0 && ok { t' with cfg := {} } then { t' with cfg := {} } else t'
  if t'.events.length < t.events.length || t'.cfg.gen0 != t.cfg.gen0 then minimise check mode t' else t'

/-- The names of the properties a trace falsifies (one replay, every check at every step). -/
def failing (t : Trace) : List String :=
  let rec go : List Ev → S → List String → List String
    | [], _, acc => acc
    | e :: es, s, acc =>
      let s' := step s e
      let acc := stepChecks.foldl (fun acc (name, check) =>
        if acc.contains name || check s e s' then acc else acc ++ [name]) acc
      go es s' acc
  go t.events (S.init t.cfg) []

def explore (seed count len : Nat) (mode : String) : IO Unit := do
  let mut r : Rng := ⟨UInt64.ofNat seed⟩
  let mut found : List (String × Trace) := []
  for _ in [0:count] do
    let (t, r') := randomTrace len mode r
    r := r'
    for name in failing t do
      if (found.lookup name).isNone then
        found := found ++ [(name, minimise (stepChecks.lookup name).get! mode t)]
  for (name, _) in stepChecks do
    match found.lookup name with
    | none => IO.println s!"OK {name}: no violation in {count} traces of {len} events"
    | some t =>
      let at_ := (firstFailure (stepChecks.lookup name).get! t).getD 0
      IO.println s!"FAIL {name} (step {at_}, {t.events.length} events, ui: {allIn "ui" t}, drained: {allIn "drained" t}, fifo: {fifoTrace t})"
      IO.println s!"  {t.code}"

-- ## Replay

def replay (t : Trace) : List String :=
  let rec go : List Ev → S → Nat → List String → List String
    | [], _, _, acc => acc.reverse
    | e :: es, s, k, acc => let s' := step s e; go es s' (k + 1) (s!"{k} {obs s'}" :: acc)
  go t.events (S.init t.cfg) 0 []

def replayStdin : IO UInt32 := do
  let stdin ← IO.getStdin
  let mut n := 0
  repeat
    let line ← stdin.getLine
    if line.isEmpty then break
    let line := line.trimAsciiEnd.toString
    if line.isEmpty || line.startsWith "#" then continue
    match Trace.parse line with
    | .error msg => IO.eprintln msg; return 1
    | .ok t =>
      IO.println s!"T {n}"
      for l in replay t do IO.println l
      n := n + 1
  return 0

def main (args : List String) : IO UInt32 := do
  match args with
  | ["replay"] => replayStdin
  | "explore" :: seed :: count :: len :: rest =>
    explore seed.toNat! count.toNat! len.toNat! (rest.headD "any")
    return 0
  | "gen" :: seed :: count :: len :: rest =>
    let mut r : Rng := ⟨UInt64.ofNat seed.toNat!⟩
    for _ in [0:count.toNat!] do
      let (t, r') := randomTrace len.toNat! (rest.headD "any") r
      r := r'
      IO.println t.code
    return 0
  | ["check"] =>
    let stdin ← IO.getStdin
    repeat
      let line ← stdin.getLine
      if line.isEmpty then break
      let line := line.trimAsciiEnd.toString
      if line.isEmpty || line.startsWith "#" then continue
      match Trace.parse line with
      | .error msg => IO.eprintln msg; return 1
      | .ok t =>
        let fails := stepChecks.filterMap fun (name, check) => (firstFailure check t).map fun k => s!"{name}@{k}"
        IO.println s!"ui={allIn "ui" t} drained={allIn "drained" t} fifo={fifoTrace t} fails=[{", ".intercalate fails}] {t.code}"
    return 0
  | ["expand"] =>
    -- `drain` in a trace: run the oldest job until none is pending (written out as `run.0`s);
    -- `drain.n`: the same, but the oldest `n` jobs stay pending
    let stdin ← IO.getStdin
    repeat
      let line ← stdin.getLine
      if line.isEmpty then break
      let line := line.trimAsciiEnd.toString
      if line.isEmpty || line.startsWith "#" then IO.println line; continue
      match line.splitOn "|" with
      | [head, body] =>
        match Trace.parse (head ++ "|") with
        | .error msg => IO.eprintln msg; return 1
        | .ok t0 =>
          let mut s := S.init t0.cfg
          let mut out : List Ev := []
          for tok in (body.splitOn " ").filter (· ≠ "") do
            if tok == "drain" then
              let (s', evs) := settle s []
              s := s'; out := out ++ evs
            else if tok.startsWith "drain." then
              -- keep the oldest `n` jobs pending, run the rest oldest first
              let n := (tok.drop 6).toString.toNat!
              let mut fuel := 64
              while s.jobs.length > n && fuel > 0 do
                s := step s (.run n); out := out ++ [.run n]; fuel := fuel - 1
            else match Ev.parse tok with
              | some e => s := step s e; out := out ++ [e]
              | none => IO.eprintln s!"bad event '{tok}'"; return 1
          IO.println ({ t0 with events := out } : Trace).code
      | _ => IO.eprintln s!"bad trace line: {line}"; return 1
    return 0
  | ["counterexamples"] =>
    for (name, t) in counterexampleTraces do IO.println s!"# {name}\n{t.code}"
    return 0
  | _ =>
    IO.eprintln "usage: oracle replay | check | counterexamples | explore|gen <seed> <traces> <length> [any|ui|drained|drained-fifo]"
    return 2
