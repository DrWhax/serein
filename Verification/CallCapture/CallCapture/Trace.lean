import CallCapture.Model

/-!
# Traces and observations: the text format shared with the Swift conformance test

A trace line is `cfg <gen0> <tok0> <setupGen0> <capGen0> | <event> <event> …`.
After each step the oracle prints one observation line; Swift prints the same fields from the
production objects, and the two are compared field by field. Ghost state (call instances,
native-call owners, `authorized`) is never printed: Swift has no such fields.
-/

namespace CallCapture

def b01 (b : Bool) : String := if b then "1" else "0"

def DState.code : DState → String
  | .prering => "P" | .ringing => "R" | .accepted => "A" | .reconnecting => "X"

def DState.ofCode : String → Option DState
  | "P" => some .prering | "R" => some .ringing | "A" => some .accepted | "X" => some .reconnecting
  | _ => none

def EndReason.code : EndReason → String
  | .localHangup => "L" | .remoteHangup => "R" | .needPermission => "N"

def EndReason.ofCode : String → Option EndReason
  | "L" => some .localHangup | "R" => some .remoteHangup | "N" => some .needPermission | _ => none

def Ev.code : Ev → String
  | .openLobby c v => s!"open.{c}.{b01 v}"
  | .startCall => "start"
  | .accept c v => s!"accept.{c}.{b01 v}"
  | .decline c => s!"decline.{c}"
  | .hangUp => "hangup"
  | .closeCall => "close"
  | .setVideo b => s!"video.{b01 b}"
  | .toggleShare => "toggle"
  | .pickSource => "pick"
  | .cancelPick => "cancel"
  | .run k => s!"run.{k}"
  | .nIncoming c v => s!"nin.{c}.{b01 v}"
  | .nState st => s!"nst.{st.code}"
  | .nEnd r => s!"nend.{r.code}"
  | .nRejected c => s!"nrej.{c}"
  | .setupDone q ok => s!"setup.{q}.{b01 ok}"
  | .camAccess g => s!"cacc.{b01 g}"
  | .camStart ok => s!"cstart.{b01 ok}"
  | .camStopDone => "cstop"
  | .camFrame k => s!"cframe.{k}"
  | .srcDone i ok => s!"src.{i}.{b01 ok}"
  | .scStartDone j ok => s!"sstart.{j}.{b01 ok}"
  | .scStopDone j ok => s!"sstop.{j}.{b01 ok}"
  | .scFrame i => s!"sframe.{i}"
  | .scStopped j => s!"serr.{j}"

def parseBool : String → Option Bool
  | "1" => some true | "0" => some false | _ => none

def Ev.parse (t : String) : Option Ev :=
  match t.splitOn "." with
  | ["open", c, v] => do pure (.openLobby (← c.toNat?) (← parseBool v))
  | ["start"] => some .startCall
  | ["accept", c, v] => do pure (.accept (← c.toNat?) (← parseBool v))
  | ["decline", c] => do pure (.decline (← c.toNat?))
  | ["hangup"] => some .hangUp
  | ["close"] => some .closeCall
  | ["video", b] => do pure (.setVideo (← parseBool b))
  | ["toggle"] => some .toggleShare
  | ["pick"] => some .pickSource
  | ["cancel"] => some .cancelPick
  | ["run", k] => do pure (.run (← k.toNat?))
  | ["nin", c, v] => do pure (.nIncoming (← c.toNat?) (← parseBool v))
  | ["nst", x] => do pure (.nState (← DState.ofCode x))
  | ["nend", r] => do pure (.nEnd (← EndReason.ofCode r))
  | ["nrej", c] => do pure (.nRejected (← c.toNat?))
  | ["setup", q, ok] => do pure (.setupDone (← q.toNat?) (← parseBool ok))
  | ["cacc", g] => do pure (.camAccess (← parseBool g))
  | ["cstart", ok] => do pure (.camStart (← parseBool ok))
  | ["cstop"] => some .camStopDone
  | ["cframe", k] => do pure (.camFrame (← k.toNat?))
  | ["src", i, ok] => do pure (.srcDone (← i.toNat?) (← parseBool ok))
  | ["sstart", j, ok] => do pure (.scStartDone (← j.toNat?) (← parseBool ok))
  | ["sstop", j, ok] => do pure (.scStopDone (← j.toNat?) (← parseBool ok))
  | ["sframe", i] => do pure (.scFrame (← i.toNat?))
  | ["serr", j] => do pure (.scStopped (← j.toNat?))
  | _ => none

structure Trace where
  cfg : Cfg
  events : List Ev

def Trace.code (t : Trace) : String :=
  s!"cfg {t.cfg.gen0} {t.cfg.tok0} {t.cfg.setupGen0} {t.cfg.capGen0} | " ++ " ".intercalate (t.events.map Ev.code)

def Trace.parse (line : String) : Except String Trace := do
  match line.splitOn "|" with
  | [head, body] =>
    let nums := (head.splitOn " ").filter (· ≠ "") |>.drop 1
    let n (k : Nat) : Except String UInt64 :=
      match nums[k]? >>= String.toNat? with
      | some v => if v < UInt64.size then pure (UInt64.ofNat v) else throw s!"counter out of range: {line}"
      | none => throw s!"bad cfg: {line}"
    let cfg : Cfg := { gen0 := ← n 0, tok0 := ← n 1, setupGen0 := ← n 2, capGen0 := ← n 3 }
    let toks := (body.splitOn " ").filter (· ≠ "")
    let evs ← toks.mapM fun t => match Ev.parse t with
      | some e => pure e
      | none => throw s!"bad event '{t}'"
    pure { cfg, events := evs }
  | _ => throw s!"bad trace line: {line}"

-- ## Observations

def CEv.code : CEv → String
  | .outgoing c v n _ => s!"out.{c}.{b01 v}.{n}"
  | .incoming c v n => s!"in.{c}.{b01 v}.{n}"
  | .state c st n => s!"st.{c}.{st.code}.{n}"
  | .ended c r n => s!"end.{c}.{match r with | some r => r.code | none => "-"}.{n}"

def Msg.code : Msg → String
  | .ev _ e => e.code
  | .camNeeded b => s!"cam.{b01 b}"

def Eff.code : Eff → String
  | .camAccessReq => "ca"
  | .camStartReq k => s!"cs{k}"
  | .camStopReq => "cx"
  | .camPreview k => s!"cp{k}"
  | .sendFrame (.camera k) => s!"fc{k}"
  | .sendFrame (.screen i) => s!"fs{i}"
  | .scSourcesReq i => s!"ss{i}"
  | .scStartReq i j => s!"sb{i}.{j}"
  | .scStopReq j => s!"se{j}"
  | .svcStart c v => s!"start{c}.{b01 v}"
  | .svcAccept c v => s!"accept{c}.{b01 v}"
  | .svcDecline c => s!"decline{c}"
  | .svcHangup e => s!"hangup{b01 e}"
  | .svcEndCall c id => s!"end{c}.{match id with | some n => toString n | none => "-"}"
  | .svcSetVideo c on => s!"video{c}.{b01 on}"
  | .svcSetPresenting c on => s!"present{match c with | some c => toString c | none => "-"}.{b01 on}"

def SPh.code : SPh → String
  | .starting => "starting" | .running => "running" | .failed => "failed"
  | .stopping => "stopping" | .stopped => "stopped" | .stopFailed => "stopfailed"

/-- The reconciler's suspension as Swift can see it: which device call is outstanding (or has
returned and its continuation has not run yet). -/
def RPc.code : RPc → String
  | .idle => "idle" | .sched => "sched" | .access | .accessDone _ => "access" | .start | .startDone _ => "start"
  | .stopUnwanted | .stopAfterStart | .stopDone => "stop"

def CamDev.code : CamDev → String
  | .off => "off" | .starting k => s!"starting{k}" | .on k => s!"on{k}" | .stopping k => s!"stopping{k}"

def Op.code : Op → String
  | .setup q .. => s!"setup{q}"
  | .sources i .. => s!"sources{i}"
  | .tdStart _ _ j _ | .stopping j => s!"stop{j}"
  | .install _ _ j _ => s!"start{j}"

/-- A pending job as Swift can name it: a task by the label it was spawned with, a continuation
by the await it continues, a hop by its callback. -/
def Job.code : Job → String
  | .recPass => "rec"
  | .capStop _ => "capstop"
  | .setupStart .. => "setup"
  | .sources .. => "sources"
  | .present .. => "present"
  | .setupRet q .. => s!"ret.setup{q}"
  | .recRet => "ret.cam"
  | .sourcesRet i .. => s!"ret.src{i}"
  | .installRet _ _ j _ _ => s!"ret.sstart{j}"
  | .teardownRet _ _ j _ | .stopRet j => s!"ret.sstop{j}"
  | .msg m => m.code
  | .camFrame _ => "cframe"
  | .scFrame .. => "sframe"
  | .scStopped .. => "serr"

def insertSorted (x : String) : List String → List String
  | [] => [x]
  | y :: ys => if x ≤ y then x :: y :: ys else y :: insertSorted x ys

def sortStrings (xs : List String) : List String := xs.foldr insertSorted []

def obs (s : S) : String :=
  let a := match s.active with
    | some a => s!"{a.conv}.{match a.stage with | .lobby => "L" | .inCall => "C"}.{match a.direct with | some d => d.code | none => "-"}.{b01 a.live}.{match a.callId with | some n => toString n | none => "-"}"
    | none => "-"
  let caps := (List.range s.capNext).map fun i =>
    let c := s.caps i
    s!"{i}.{c.tok}.{c.gen}.{match c.stream with | some j => toString j | none => "-"}"
  let streams := (List.range s.streamNext).map fun j =>
    match s.streams j with
    | some (i, ph) => s!"{j}.{i}.{ph.code}{if s.outOff j then ".off" else ""}"
    | none => s!"{j}.-"
  let nc := match s.ncall with
    | some n => s!"{n.conv}.{n.st.code}.{b01 n.incoming}.{b01 n.acceptedHere}"
    | none => "-"
  String.intercalate " "
    [ s!"A={a}", s!"R={match s.ringing with | some (c, n) => s!"{c}.{n}" | none => "-"}",
      s!"V={b01 s.localVideo}", s!"S={b01 s.camSends}", s!"G={s.gen}", s!"T={b01 s.setupTask}",
      s!"SH={match s.share with | some (i, t) => s!"{i}.{t}" | none => "-"}", s!"LT={s.lastTok}",
      s!"SRC={b01 s.sources}", s!"PC={s.pc.code}", s!"RUN={b01 s.running}", s!"AG={b01 s.again}",
      s!"DEV={s.camDev.code}", s!"CAPS={",".intercalate caps}", s!"ST={",".intercalate streams}",
      s!"OPS={",".intercalate (sortStrings (s.ops.map Op.code))}",
      s!"N={nc}", s!"P={b01 s.presenting}", s!"CE={b01 s.camEnabled}", s!"SG={s.setupGen}",
      s!"J={",".intercalate (s.jobs.map Job.code)}",
      s!"E={",".intercalate ((effects s).map Eff.code)}" ]

end CallCapture
