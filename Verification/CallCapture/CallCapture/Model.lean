/-!
# Serein call/capture lifecycle: an executable model of the production Swift

One pure transition function `step : S → Ev → S`. The effects a step requests are the
post-state's `out` field (newest first; `effects` gives them in emission order).

What is modelled, and where it lives in Swift:

* `SignalSession` call/capture coordination: `App/SignalSafe/Sources/SignalSafe/Calls.swift`
  and `CallLinksAndPresenting.swift` (activeCall, ringingCall, callLocalVideo, cameraSends,
  callGeneration, callSetupTask, screenCapture + screenShareToken, lastScreenShareToken,
  presentingSources), including the frame and stop callbacks it gives the camera and each
  `ScreenShareCapture`.
* `CaptureReconciler` (`Packages/SignalUI/Sources/SignalUI/Calling/CaptureReconciler.swift`),
  without `restart()` (camera switching is out of scope for this slice).
* `ScreenShareCapture`'s generation / teardown / install logic and `ScreenStreamOutput`'s
  running flag (`Packages/SignalUI/Sources/SignalUI/Calling/ScreenShare.swift`).
* The environment the app talks to, reduced to what the app reads or is told:
  `CallingService` + RingRTC (one direct-call slot, `isPresenting`, `cameraEnabled`,
  `setupGeneration`, the `onEvent` / `onCameraNeeded` messages), the camera device, and
  ScreenCaptureKit streams.

## Scheduling

Everything the Swift code runs on the main actor is a *job*: a `Task { }` it spawned that has
not started yet, the continuation of an `await` whose environment call has completed, or the
hop that brings a callback to the main actor (a calling-service message, a camera or screen
frame, a stream error). Jobs wait in `jobs` in the order they were made; the scheduler event
`run k` runs the `k`-th one to its next suspension. Nothing else orders them: Swift does not
promise that the main actor runs jobs first in, first out, so any pending job may go next, and
user and device events may come between any two jobs. `run 0` every time is the FIFO schedule.

So a step is one of: a user action (its synchronous handler; tasks it spawns only become
jobs), an environment or device event (the device's side happens now: a completion, a frame,
an error; the code that reacts to it becomes a job), or `run k`. An `await` on the environment
is a pending op (`ops`, or the reconciler's `pc`) until its completion event.

Counters keep the implementation's numeric semantics: `gen`, `lastTok`, `setupGen` and each
capture's `gen` are `UInt64` with wrapping `+` (Swift `&+=`). Indices that only exist for the
proofs (ghost state: instance, native-call, share, stream and camera-session numbers, and the
record of ended instances) are `Nat` or `Bool` and never influence a transition.
-/

namespace CallCapture

abbrev Conv := Nat

inductive Stage where
  | lobby | inCall
  deriving DecidableEq, Repr, Inhabited

/-- `DirectCallState` as the app stores it, and RingRTC's `CallState` without `ended`
(an ended native call leaves the slot instead). -/
inductive DState where
  | prering | ringing | accepted | reconnecting
  deriving DecidableEq, Repr, Inhabited

inductive EndReason where
  | localHangup | remoteHangup | needPermission
  deriving DecidableEq, Repr

/-- The `CallingEvent`s of a direct call, with RingRTC's call id (`id`; distinct for distinct
calls, rejected offers included). `outgoing` echoes the `setup` token its setup passed. -/
inductive CEv where
  | outgoing (c : Conv) (video : Bool) (id : Nat) (setup : UInt64)
  | incoming (c : Conv) (video : Bool) (id : Nat)
  | state (c : Conv) (st : DState) (id : Nat)
  /-- `callStateChange(state: .ended)`; reason `none` is a rejected offer (no call of ours). -/
  | ended (c : Conv) (r : Option EndReason) (id : Nat)
  deriving DecidableEq, Repr

/-- A message on its way from `CallingService` to the session. `owner` is ghost: the
native call it is about (`none`: a rejected offer, not a call). -/
inductive Msg where
  | ev (owner : Option Nat) (e : CEv)
  | camNeeded (on : Bool)
  deriving DecidableEq, Repr

/-- RingRTC's direct call (`rtc.call` / `callsLookup`). `id` is ghost. -/
structure NCall where
  id : Nat
  conv : Conv
  st : DState
  incoming : Bool
  /-- `rtc.accept` was called for it: an incoming call becomes accepted only after that. -/
  acceptedHere : Bool
  /-- The app asked RingRTC to hang it up (hangup, endCall, decline): after that it only ends. -/
  hungUp : Bool
  deriving DecidableEq, Repr

/-- `ActiveCallState` (the fields the lifecycle reads), plus ghosts: `inst` numbers each
call the app opens; `authorized` records whether this call had an authorized start. `callId`
(real): the direct call the screen shows, once known. -/
structure ACall where
  conv : Conv
  stage : Stage
  direct : Option DState
  live : Bool
  inst : Nat
  authorized : Bool
  callId : Option Nat
  deriving DecidableEq, Repr

/-- Where the reconciler's pass is. `sched`: its Task exists but has not started.
`accessDone`, `startDone`, `stopDone`: the device call it awaits has completed and its
continuation is a pending job (`Job.recRet`). -/
inductive RPc where
  | idle | sched | stopUnwanted | access | start | stopAfterStart
  | accessDone (granted : Bool) | startDone (ok : Bool) | stopDone
  deriving DecidableEq, Repr

/-- The physical camera (fake device): session `k` is the `k`-th `device.start`. -/
inductive CamDev where
  | off | starting (k : Nat) | on (k : Nat) | stopping (k : Nat)
  deriving DecidableEq, Repr

/-- One `ScreenShareCapture` object. `content`: its `sources()` succeeded, so `filter(for:)`
can resolve a picked source. `inst` is ghost: the call it was created under. -/
structure Cap where
  tok : UInt64
  gen : UInt64
  stream : Option Nat
  content : Bool
  inst : Nat
  /-- Ghost: how often `gen` has been bumped (it wraps; this does not). -/
  bumps : Nat
  deriving DecidableEq, Repr

instance : Inhabited Cap := ⟨⟨0, 0, none, false, 0, 0⟩⟩

/-- A ScreenCaptureKit stream, physically. -/
inductive SPh where
  | starting | running | failed | stopping | stopped | stopFailed
  deriving DecidableEq, Repr

/-- What `startPresenting`'s task captured: token, call generation, conversation. -/
structure PT where
  tok : UInt64
  gen : UInt64
  conv : Conv
  deriving DecidableEq, Repr

/-- A suspended `await` on the environment, until its completion event. -/
inductive Op where
  /-- `callSetupTask` awaiting `startOutgoingDirectCall` (`inst` ghost). -/
  | setup (q : Nat) (gen sgen : UInt64) (c : Conv) (video : Bool) (inst : Nat)
  /-- `togglePresenting`'s task awaiting `capture.sources()`. -/
  | sources (i : Nat) (tok gen : UInt64) (c : Conv)
  /-- `capture.start` in `teardown`, awaiting `stopCapture` of the old stream `j`. -/
  | tdStart (i : Nat) (cg : UInt64) (j : Nat) (pt : PT)
  /-- `install` awaiting `startCapture` of stream `j`. -/
  | install (i : Nat) (cg : UInt64) (j : Nat) (pt : PT)
  /-- A stop awaiting `stopCapture` of stream `j`; nothing runs after it. -/
  | stopping (j : Nat)
  deriving DecidableEq, Repr

/-- Main-actor work that is runnable and has not run (see *Scheduling*). -/
inductive Job where
  -- tasks spawned with `Task { }`, not started
  | recPass
  | capStop (i : Nat)
  /-- `cancelled`: `releaseCallMedia` called `callSetupTask?.cancel()` before it started. -/
  | setupStart (gen : UInt64) (c : Conv) (video : Bool) (inst : Nat) (cancelled : Bool)
  | sources (i : Nat) (tok gen : UInt64) (c : Conv)
  | present (i : Nat) (pt : PT)
  -- continuations of awaits whose environment call completed
  /-- `startOutgoingDirectCall` returned (`r`) or threw. -/
  | setupRet (q : Nat) (gen : UInt64) (c : Conv) (r : Bool) (placed : Option Nat)
  /-- The reconciler's device call returned; `pc` holds which and the result. -/
  | recRet
  | sourcesRet (i : Nat) (tok gen : UInt64) (c : Conv) (ok : Bool)
  | installRet (i : Nat) (cg : UInt64) (j : Nat) (pt : PT) (ok : Bool)
  /-- `teardown()` inside `start` returned (stream `j` stopped). -/
  | teardownRet (i : Nat) (cg : UInt64) (j : Nat) (pt : PT)
  /-- A stop's `stopCapture` returned; nothing runs after it. -/
  | stopRet (j : Nat)
  -- callbacks hopping to the main actor
  /-- `onEvent` / `onCameraNeeded`'s `Task { @MainActor … }`. -/
  | msg (m : Msg)
  /-- The camera's frame callback: `cameraFrame(_:)`. -/
  | camFrame (k : Nat)
  /-- A share's frame callback: `screenFrame(_:token:)` with the token it captured. -/
  | scFrame (i : Nat) (tok : UInt64)
  /-- A share's stop callback: `screenShareStopped(token:error:)`. -/
  | scStopped (i : Nat) (tok : UInt64)
  deriving DecidableEq, Repr

inductive Src where
  | camera (k : Nat) | screen (i : Nat)
  deriving DecidableEq, Repr

/-- Requested effects: device requests, frames to the call, and calls into CallingService. -/
inductive Eff where
  | camAccessReq
  | camStartReq (k : Nat)
  | camStopReq
  | camPreview (k : Nat)
  | sendFrame (src : Src)
  | scSourcesReq (i : Nat)
  | scStartReq (i j : Nat)
  | scStopReq (j : Nat)
  | svcStart (c : Conv) (video : Bool)
  | svcAccept (c : Conv) (video : Bool)
  | svcDecline (c : Conv)
  | svcHangup (excludeRinging : Bool)
  /-- `endCall(conversationId:callId:)`; `none`: whatever direct call the conversation has. -/
  | svcEndCall (c : Conv) (id : Option Nat)
  | svcSetVideo (c : Conv) (on : Bool)
  /-- `none` is the empty conversation id `""` (no call has it). -/
  | svcSetPresenting (c : Option Conv) (on : Bool)
  deriving DecidableEq, Repr

structure S where
  -- SignalSession
  active : Option ACall
  /-- `ringingCall`: the conversation and the call id. -/
  ringing : Option (Conv × Nat)
  localVideo : Bool
  camSends : Bool
  gen : UInt64
  /-- `callSetupTask != nil`. -/
  setupTask : Bool
  /-- `screenCapture` (capture index) with `screenShareToken`; Swift sets and clears both together. -/
  share : Option (Nat × UInt64)
  lastTok : UInt64
  sources : Bool
  -- CaptureReconciler
  pc : RPc
  running : Bool
  again : Bool
  -- ScreenShareCapture objects, streams (with their output's running flag), pending awaits
  caps : Nat → Cap
  capNext : Nat
  streams : Nat → Option (Nat × SPh)
  streamNext : Nat
  /-- `ScreenStreamOutput.stop()` was called for stream `j`'s output: it passes no more frames. -/
  outOff : Nat → Bool
  ops : List Op
  -- the main actor's pending jobs
  jobs : List Job
  -- environment: CallingService + RingRTC
  ncall : Option NCall
  presenting : Bool
  camEnabled : Bool
  setupGen : UInt64
  nativeNext : Nat
  setupNext : Nat
  -- environment: camera
  camDev : CamDev
  camNext : Nat
  -- ghosts
  instNext : Nat
  genN : Nat
  nativeInst : Nat → Option Nat
  /-- The user's last explicit camera choice (lobby, accept, or the video button). -/
  userVideo : Bool
  /-- Call instances that have ended: they were live and stopped being live (`step` records it). -/
  ended : Nat → Bool
  -- configuration (initial counter values; `capGen0` is each new capture's generation)
  capGen0 : UInt64
  tok0 : UInt64
  -- per-step scratch
  out : List Eff

/-- Initial counters: a session may have lived long enough for any `UInt64` value. -/
structure Cfg where
  gen0 : UInt64 := 0
  tok0 : UInt64 := 0
  setupGen0 : UInt64 := 0
  capGen0 : UInt64 := 0
  deriving Repr

def S.init (cfg : Cfg := {}) : S where
  active := none
  ringing := none
  localVideo := false
  camSends := false
  gen := cfg.gen0
  setupTask := false
  share := none
  lastTok := cfg.tok0
  sources := false
  pc := .idle
  running := false
  again := false
  caps := fun _ => default
  capNext := 0
  streams := fun _ => none
  streamNext := 0
  outOff := fun _ => false
  ops := []
  jobs := []
  ncall := none
  presenting := false
  camEnabled := false
  setupGen := cfg.setupGen0
  nativeNext := 0
  setupNext := 0
  camDev := .off
  camNext := 0
  instNext := 0
  genN := 0
  nativeInst := fun _ => none
  userVideo := false
  ended := fun _ => false
  capGen0 := cfg.capGen0
  tok0 := cfg.tok0
  out := []

/-- Function update. -/
def upd {α : Type} (f : Nat → α) (i : Nat) (v : α) : Nat → α := fun x => if x = i then v else f x

-- ## Primitive actions

def emit (x : Eff) (s : S) : S := { s with out := x :: s.out }
def spawn (l : Job) (s : S) : S := { s with jobs := s.jobs ++ [l] }
def enqueue (m : Msg) (s : S) : S := { s with jobs := s.jobs ++ [.msg m] }
def addOp (o : Op) (s : S) : S := { s with ops := s.ops ++ [o] }
def dropOp (o : Op) (s : S) : S := { s with ops := s.ops.erase o }
def setCap (i : Nat) (c : Cap) (s : S) : S := { s with caps := upd s.caps i c }
def setStream (j : Nat) (v : Option (Nat × SPh)) (s : S) : S := { s with streams := upd s.streams j v }

def activeLive (s : S) : Bool := match s.active with | some a => a.live | none => false

/-- Call instance `a` is on screen and live. -/
def instLive (s : S) (a : Nat) : Bool :=
  match s.active with | some b => b.inst == a && b.live | none => false

/-- `cameraWanted`: a live call (or lobby) with our video on. -/
def wanted (s : S) : Bool := activeLive s && s.localVideo

def shareTokIs (s : S) (t : UInt64) : Bool := match s.share with | some (_, t') => t' == t | none => false

/-- `isCurrentScreenShare(token, generation:, conversationId:)`. -/
def isCurrent (s : S) (pt : PT) : Bool :=
  shareTokIs s pt.tok && s.gen == pt.gen &&
    (match s.active with | some a => a.conv == pt.conv && a.live | none => false)

def hasCall (s : S) (c : Conv) : Bool := match s.ncall with | some n => n.conv == c | none => false

-- ## The environment's side of CallingService (what the fake service does when called)

/-- `CallingService.hangup(excludeRinging:)`. The native calls end later (`nEnd`). -/
def markHungUp (c : Option Conv) (s : S) : S :=
  match s.ncall with
  | some n => if c.all (· == n.conv) then { s with ncall := some { n with hungUp := true } } else s
  | none => s

def svcHangup (excl : Bool) (s : S) : S :=
  let s := emit (.svcHangup excl) s
  let s := match s.ncall with
    | some n => if excl && n.st == DState.ringing && n.incoming then s else markHungUp none s
    | none => s
  enqueue (.camNeeded false) { s with setupGen := s.setupGen + 1, presenting := false }

/-- `CallingService.endCall(conversationId:callId:)`: that conversation's direct call, and with
an id only that call. -/
def svcEndCall (c : Conv) (id : Option Nat) (s : S) : S :=
  let s := emit (.svcEndCall c id) s
  match s.ncall with
  | some n => if n.conv == c && id.all (· == n.id) then { s with ncall := some { n with hungUp := true } } else s
  | none => s

/-- `acceptDirectCall(conversationId:asVideoCall:callId:)`: only the call that rang. -/
def svcAccept (c : Conv) (v : Bool) (id : Option Nat) (s : S) : S :=
  let s := emit (.svcAccept c v) s
  match s.ncall with
  | some n => if n.conv == c && id.all (· == n.id) then { s with camEnabled := v, ncall := some { n with acceptedHere := true } } else s
  | none => s

def svcDecline (c : Conv) (id : Option Nat) (s : S) : S :=
  let s := emit (.svcDecline c) s
  match s.ncall with
  | some n => if n.conv == c && id.all (· == n.id) then { s with ncall := some { n with hungUp := true } } else s
  | none => s

def svcSetVideo (c : Conv) (on : Bool) (s : S) : S :=
  let s := emit (.svcSetVideo c on) s
  enqueue (.camNeeded (on && hasCall s c)) { s with camEnabled := on }

def svcSetPresenting (c : Option Conv) (p : Bool) (s : S) : S :=
  let s := emit (.svcSetPresenting c p) s
  match c with
  | some c' =>
    if hasCall s c' then
      let s := { s with presenting := p }
      if p then enqueue (.camNeeded false) s
      else if s.camEnabled then enqueue (.camNeeded true) s else s
    else if p then s else { s with presenting := false }
  | none => if p then s else { s with presenting := false }

-- ## CaptureReconciler

def devStop (s : S) : S :=
  { s with camDev := match s.camDev with | .on k => .stopping k | d => d }

/-- `reconcile()` from its first check; `true` when it suspended. -/
def recR1 (s : S) : S × Bool :=
  if !wanted s then
    if s.running then ({ devStop (emit .camStopReq s) with running := false, pc := .stopUnwanted }, true)
    else (s, false)
  else if s.running then (s, false)
  else ({ emit .camAccessReq s with pc := .access }, true)

/-- `reconcile()` returned: `while again` loops once more, else the pass ends. -/
def recEnd (s : S) : S :=
  if s.again then
    match recR1 { s with again := false } with
    | (s', true) => s'
    | (s', false) => { s' with pc := .idle }
  else { s with pc := .idle }

/-- The pass Task's first run. -/
def recPass (s : S) : S :=
  match recR1 { s with again := false } with
  | (s', true) => s'
  | (s', false) => recEnd s'

/-- `update()`. -/
def updateCamera (s : S) : S :=
  if s.pc == .idle then spawn .recPass { s with pc := .sched } else { s with again := true }

/-- The permission prompt is answered (environment); the pass continues in a job. -/
def camAccessEnv (g : Bool) (s : S) : S :=
  if s.pc == .access then spawn .recRet { s with pc := .accessDone g } else s

/-- The camera finished starting (environment). -/
def camStartEnv (ok : Bool) (s : S) : S :=
  if s.pc != .start then s else
  let k := match s.camDev with | .starting k => k | _ => 0
  spawn .recRet { s with pc := .startDone ok, camDev := if ok then .on k else .off }

/-- The camera finished stopping (environment). -/
def camStopEnv (s : S) : S :=
  match s.pc with
  | .stopUnwanted | .stopAfterStart => spawn .recRet { s with pc := .stopDone, camDev := .off }
  | _ => s

/-- After `requestAccess()` returned `g`. -/
def camAccessDone (g : Bool) (s : S) : S :=
  if !g then recEnd s            -- "camera: no permission"
  else if !wanted s then recEnd s     -- hung up while the prompt was open
  else
    let k := s.camNext
    { emit (.camStartReq k) s with pc := .start, camNext := k + 1, camDev := .starting k }

/-- After `device.start()` returned (`ok`) or threw. -/
def camStartDone (ok : Bool) (s : S) : S :=
  if !ok then recEnd s   -- "camera failed"
  else
    let s := { s with running := true }
    if !wanted s then { devStop (emit .camStopReq s) with running := false, pc := .stopAfterStart }
    else recEnd s

/-- The pass's continuation (`Job.recRet`). -/
def recResume (s : S) : S :=
  match s.pc with
  | .accessDone g => camAccessDone g s
  | .startDone ok => camStartDone ok s
  | .stopDone => recEnd s
  | _ => s

/-- The camera produced a frame of session `k` (environment): its callback hops to the main actor. -/
def camFrameEnv (k : Nat) (s : S) : S := if k < s.camNext then spawn (.camFrame k) s else s

/-- `cameraFrame(_:)` for a frame of camera session `k`. -/
def camFrame (k : Nat) (s : S) : S :=
  if !wanted s then s
  else
    let s := emit (.camPreview k) s
    if s.camSends && !s.presenting then emit (.sendFrame (.camera k)) s else s

/-- `setCameraSending(_:)`. -/
def setCameraSending (b : Bool) (s : S) : S := updateCamera { s with camSends := b }

-- ## ScreenShareCapture

def capBegin (i : Nat) (s : S) : S :=
  setCap i { s.caps i with gen := (s.caps i).gen + 1, bumps := (s.caps i).bumps + 1 } s

/-- `output.stop()` (its output passes no more frames), then `stopCapture()` is requested. -/
def stopStream (j : Nat) (s : S) : S :=
  let owner := match s.streams j with | some (o, _) => o | none => 0
  emit (.scStopReq j) (setStream j (some (owner, .stopping)) { s with outOff := upd s.outOff j true })

/-- `teardown()`: `some j` when it awaits `stopCapture` of stream `j`. -/
def capTeardown (i : Nat) (s : S) : S × Option Nat :=
  match (s.caps i).stream with
  | some j => (stopStream j (setCap i { s.caps i with stream := none } s), some j)
  | none => (s, none)

/-- `ScreenShareCapture.stop()`. -/
def capStop (i : Nat) (s : S) : S :=
  match capTeardown i (capBegin i s) with
  | (s', some j) => addOp (.stopping j) s'
  | (s', none) => s'

/-- `start(_:)` after `teardown()`: the generation check, then `install` awaits `startCapture`. -/
def capStartAfterTeardown (i : Nat) (cg : UInt64) (pt : PT) (s : S) : S :=
  if cg != (s.caps i).gen then s      -- CancellationError: the session's task does nothing
  else
    let j := s.streamNext
    let s := setStream j (some (i, .starting)) { s with streamNext := j + 1 }
    addOp (.install i cg j pt) (emit (.scStartReq i j) s)

def capStart (i : Nat) (pt : PT) (s : S) : S :=
  let s := capBegin i s
  let cg := (s.caps i).gen
  match capTeardown i s with
  | (s', some j) => addOp (.tdStart i cg j pt) s'
  | (s', none) => capStartAfterTeardown i cg pt s'

-- ## SignalSession: presenting

/-- `clearScreenShare()`: the share goes; its capture's pending start is cancelled at once
(`cancelStart`), and the capture is stopped. -/
def clearShare (s : S) : S :=
  match s.share with
  | some (i, _) => spawn (.capStop i) (capBegin i { s with share := none })
  | none => s

/-- `stopPresenting(conversationId:)`. -/
def stopPresenting (c : Option Conv) (s : S) : S :=
  let s := clearShare { s with sources := false }
  if s.presenting then svcSetPresenting (match c with | some c => some c | none => s.active.map (·.conv)) false s
  else s

/-- `togglePresenting()` (screen-recording permission granted). -/
def toggleShare (s : S) : S :=
  match s.active with
  | none => s
  | some a =>
    if s.presenting then stopPresenting none s
    else
      let s := clearShare s       -- a share not presenting (yet, or any more) goes, with its capture
      let tok := s.lastTok + 1
      let i := s.capNext
      let s := { s with lastTok := tok, capNext := i + 1, share := some (i, tok),
                        caps := upd s.caps i { tok := tok, gen := s.capGen0, stream := none, content := false, inst := a.inst, bumps := 0 } }
      spawn (.sources i tok s.gen a.conv) s

/-- `togglePresenting`'s task starts: unless its share is no longer current, it asks for the sources. -/
def sourcesLeaf (i : Nat) (tok gen : UInt64) (c : Conv) (s : S) : S :=
  if !isCurrent s ⟨tok, gen, c⟩ then s
  else addOp (.sources i tok gen c) (emit (.scSourcesReq i) s)

def findSources (i : Nat) : List Op → Option (UInt64 × UInt64 × Conv)
  | [] => none
  | .sources i' tok gen c :: rest => if i' = i then some (tok, gen, c) else findSources i rest
  | _ :: rest => findSources i rest

/-- `sources()` of capture `i` returned (`ok`) or threw (environment). -/
def srcEnv (i : Nat) (ok : Bool) (s : S) : S :=
  match findSources i s.ops with
  | none => s
  | some (tok, gen, c) => spawn (.sourcesRet i tok gen c ok) (dropOp (.sources i tok gen c) s)

/-- The sources task after `sources()`. -/
def srcDone (i : Nat) (tok gen : UInt64) (c : Conv) (ok : Bool) (s : S) : S :=
  if ok then
    let s := setCap i { s.caps i with content := true } s
    if isCurrent s ⟨tok, gen, c⟩ then { s with sources := true } else s
  else if shareTokIs s tok then clearShare s else s

/-- `startPresenting(_:)`. -/
def pickSource (s : S) : S :=
  let s := { s with sources := false }
  match s.active, s.share with
  | some a, some (i, tok) => if a.live then spawn (.present i ⟨tok, s.gen, a.conv⟩) s else s
  | _, _ => s

/-- `startPresenting`'s task starts: `filter(for:)` throws `sourceGone` unless the capture's
sources loaded; that error is handled like a failed start. -/
def presentLeaf (i : Nat) (pt : PT) (s : S) : S :=
  if !isCurrent s pt then s
  else if (s.caps i).content then capStart i pt s
  else if shareTokIs s pt.tok then clearShare s else s

def findInstall (j : Nat) : List Op → Option (Nat × UInt64 × PT)
  | [] => none
  | .install i cg j' pt :: rest => if j' = j then some (i, cg, pt) else findInstall j rest
  | _ :: rest => findInstall j rest

/-- Stream `j` finished starting (`ok`) or failed (environment). -/
def scStartEnv (j : Nat) (ok : Bool) (s : S) : S :=
  match findInstall j s.ops with
  | none => s
  | some (i, cg, pt) =>
    spawn (.installRet i cg j pt ok) (setStream j (some (i, if ok then .running else .failed)) (dropOp (.install i cg j pt) s))

/-- `install` after `startCapture()`, then `startPresenting`'s task. -/
def installDone (i : Nat) (cg : UInt64) (j : Nat) (pt : PT) (ok : Bool) (s : S) : S :=
  if !ok then (if shareTokIs s pt.tok then clearShare s else s)      -- "screen share failed"
  else if cg != (s.caps i).gen then addOp (.stopping j) (stopStream j s)   -- overtaken while starting
  else
    let s := setCap i { s.caps i with stream := some j } s
    if !isCurrent s pt then capStop i s                      -- the call or share ended meanwhile
    else svcSetPresenting (some pt.conv) true s

def findStop (j : Nat) : List Op → Option Op
  | [] => none
  | (.tdStart i cg j' pt) :: rest => if j' = j then some (.tdStart i cg j' pt) else findStop j rest
  | (.stopping j') :: rest => if j' = j then some (.stopping j') else findStop j rest
  | _ :: rest => findStop j rest

/-- Stream `j` finished stopping (`ok`) or `stopCapture` threw (environment). -/
def scStopEnv (j : Nat) (ok : Bool) (s : S) : S :=
  match findStop j s.ops with
  | none => s
  | some o =>
    let owner := match s.streams j with | some (o, _) => o | none => 0
    let s := setStream j (some (owner, if ok then .stopped else .stopFailed)) (dropOp o s)
    match o with
    | .tdStart i cg _ pt => spawn (.teardownRet i cg j pt) s
    | _ => spawn (.stopRet j) s

/-- Whether a stream in phase `ph` can still deliver a frame: once it has run, frames already
on their way may arrive while and after it stops (ScreenCaptureKit gives no guarantee). -/
def SPh.hasRun : SPh → Bool
  | .running | .stopping | .stopped | .stopFailed => true
  | .starting | .failed => false

/-- Stream `j` delivers a frame (environment): its output passes it on, unless stopped, to the
capture's frame callback, which hops to the main actor with the share's token. -/
def scFrameEnv (j : Nat) (s : S) : S :=
  match s.streams j with
  | some (i, ph) => if ph.hasRun && !s.outOff j then spawn (.scFrame i (s.caps i).tok) s else s
  | none => s

/-- `screenFrame(_:token:)` for a frame of share `i` carrying token `tok`. -/
def scFrame (i : Nat) (tok : UInt64) (s : S) : S :=
  if shareTokIs s tok && s.presenting && activeLive s then emit (.sendFrame (.screen i)) s
  else s

/-- Stream `j`'s delegate reports it stopped with an error (environment, `didStopWithError`):
a running stream stops, its output passes no more frames, and the stop callback hops to the
main actor with the share's token. -/
def scStoppedEnv (j : Nat) (s : S) : S :=
  match s.streams j with
  | some (i, ph) =>
    let s := if ph == .running then setStream j (some (i, .stopped)) s else s
    spawn (.scStopped i (s.caps i).tok) { s with outOff := upd s.outOff j true }
  | none => s

/-- `screenShareStopped(token:error:)`. -/
def scStopped (tok : UInt64) (s : S) : S := if shareTokIs s tok then stopPresenting none s else s

-- ## SignalSession: calls

/-- `Task.cancel()` of a setup task that has not started (cancelling one that has is the same as
the hang-up's `setupGeneration` bump, which the service checks). -/
def Job.cancel : Job → Job
  | .setupStart g c v inst _ => .setupStart g c v inst true
  | l => l

/-- `releaseCallMedia(conversationId:)`: the one teardown. -/
def releaseCallMedia (c : Option Conv) (s : S) : S :=
  let s := { s with gen := s.gen + 1, genN := s.genN + 1, setupTask := false, jobs := s.jobs.map Job.cancel }
  let s := stopPresenting c s
  let s := svcHangup true s
  updateCamera { s with camSends := false }

/-- `endCallUI()`. -/
def endCallUI (s : S) : S := releaseCallMedia (s.active.map (·.conv)) { s with active := none }

/-- `endStrayCall(_:callId:)`. -/
def endStrayCall (c : Conv) (id : Option Nat) (s : S) : S :=
  match s.ncall with
  | some n => if n.conv != c then s
              else if n.st == .ringing && (s.ringing.map (·.1)) == some c && (id.isNone || (s.ringing.map (·.2)) == id) then s
              else svcEndCall c id s
  | none => s

def ownedBy (owner : Option Nat) (inst : Nat) (s : S) : Bool :=
  match owner with | some n => s.nativeInst n == some inst | none => false

/-- `handleCallingEvent(_:)`: events apply only to the call on screen (by call id); a lobby takes
only the outgoing call of its own setup (the token is `callGeneration` when it started). -/
def handleEv (owner : Option Nat) (e : CEv) (s : S) : S :=
  match e with
  | .outgoing c v n setup =>
    match s.active with
    | some a =>
      if a.conv == c && a.live && a.callId.isNone && setup == s.gen then
        let s := { s with active := some { conv := c, stage := .inCall, direct := some .prering, live := true,
                                           inst := a.inst, authorized := a.authorized || ownedBy owner a.inst s, callId := some n } }
        -- the user's video choice stands; the service hears it if it changed during setup
        if s.localVideo != v then svcSetVideo c s.localVideo s else s
      else endStrayCall c (some n) s
    | none => endStrayCall c (some n) s
  | .incoming c _ n => if s.active.isNone then { s with ringing := some (c, n) } else s
  | .state c st n =>
    match s.active with
    | some a =>
      if a.callId == some n && a.live then
        { s with active := some { a with direct := some st, authorized := a.authorized || ownedBy owner a.inst s } }
      else if st == .accepted then endStrayCall c (some n) s else s
    | none => if st == .accepted then endStrayCall c (some n) s else s
  | .ended c r n =>
    let s := if (s.ringing.map (·.2)) == some n then { s with ringing := none } else s
    match s.active with
    | some a =>
      if a.callId == some n && a.live then
        if r == some .needPermission then releaseCallMedia (some c) { s with active := some { a with live := false } }
        else endCallUI s
      else s
    | none => s

/-- A message from the service, once its hop runs. -/
def runMsg (m : Msg) (s : S) : S :=
  match m with
  | .ev o e => handleEv o e s
  | .camNeeded b => setCameraSending b s

/-- `openCallLobby(_:video:)` for a 1:1 conversation. -/
def openLobby (c : Conv) (v : Bool) (s : S) : S :=
  if s.active.isSome then s
  else
    let s := { s with active := some ⟨c, .lobby, none, true, s.instNext, false, none⟩, instNext := s.instNext + 1,
                      localVideo := v, userVideo := v }
    updateCamera { s with camSends := false }

/-- `startCallFromLobby()` (direct call). -/
def startCall (s : S) : S :=
  match s.active with
  | some a =>
    if a.live && !s.setupTask then spawn (.setupStart s.gen a.conv s.localVideo a.inst false) { s with setupTask := true }
    else s
  | none => s

def setupDone (gen : UInt64) (c : Conv) (r : Bool) (placed : Option Nat) (s : S) : S :=
  if r then
    -- left during setup: the call this setup placed ends (none placed: nothing to end)
    let s := match placed with | some n => if s.gen != gen then svcEndCall c (some n) s else s | none => s
    if s.gen == gen then { s with setupTask := false } else s
  else
    let s := if s.gen == gen then endCallUI s else s
    if s.gen == gen then { s with setupTask := false } else s

/-- `callSetupTask` starts: it calls `startOutgoingDirectCall` (the `q`-th such call). In a
cancelled task, the service's first `await` (its recipient lookup, a GRDB read) throws
`CancellationError`, and the task goes on to its `catch`. -/
def setupLeaf (gen : UInt64) (c : Conv) (v : Bool) (inst : Nat) (cancelled : Bool) (s : S) : S :=
  if s.gen != gen then s      -- it starts after a hang-up: no call is asked for
  else
  let q := s.setupNext
  let s := emit (.svcStart c v) { s with setupNext := q + 1 }
  if cancelled then setupDone gen c false none s
  else addOp (.setup q gen s.setupGen c v inst) s

def findSetup (q : Nat) : List Op → Option (UInt64 × UInt64 × Conv × Bool × Nat)
  | [] => none
  | .setup q' gen sgen c v inst :: rest => if q' = q then some (gen, sgen, c, v, inst) else findSetup q rest
  | _ :: rest => findSetup q rest

/-- `startOutgoingDirectCall` completes (environment). The service throws `cancelled` when
there was a hang-up since the setup began, and returns without starting a call while RingRTC
already has one; otherwise RingRTC has the call and its outgoing event is on its way. -/
def setupEnv (q : Nat) (ok : Bool) (s : S) : S :=
  match findSetup q s.ops with
  | none => s
  | some (gen, sgen, c, v, inst) =>
    let s := dropOp (.setup q gen sgen c v inst) s
    let r := s.setupGen == sgen && ok
    let placed := if r && s.ncall.isNone then some s.nativeNext else none
    let s := if r then
        match s.ncall with
        | some _ => s
        | none =>
          let n := s.nativeNext
          enqueue (.ev (some n) (.outgoing c v n gen))
            { s with ncall := some ⟨n, c, .prering, false, false, false⟩, nativeNext := n + 1, camEnabled := v,
                     nativeInst := upd s.nativeInst n (some inst) }
      else s
    spawn (.setupRet q gen c r placed) s

/-- `acceptCall(_:video:)`: a call on screen is torn down first (the ringing call is spared). -/
def acceptCall (c : Conv) (v : Bool) (s : S) : S :=
  let callId := match s.ringing with | some (c', n) => if c' == c then some n else none | none => none
  let s := if s.active.isSome then endCallUI s else s
  let inst := s.instNext
  let s := { s with ringing := none, active := some ⟨c, .inCall, some .accepted, true, inst, true, callId⟩,
                    instNext := inst + 1, localVideo := v, userVideo := v }
  -- ghost: the call the user accepted (the one that rang) belongs to this instance
  let s := match callId with
    | some n => { s with nativeInst := upd s.nativeInst n (some inst) }
    | none => s
  updateCamera (svcAccept c v callId s)

def declineCall (c : Conv) (s : S) : S :=
  let callId := match s.ringing with | some (c', n) => if c' == c then some n else none | none => none
  svcDecline c callId { s with ringing := none }

def hangUp (s : S) : S := endCallUI (svcHangup false s)

/-- `setCallVideo(_:)`. -/
def setVideo (on : Bool) (s : S) : S :=
  let s := { s with localVideo := on, userVideo := on }
  match s.active with
  | none => s
  | some a => updateCamera (if a.stage == .inCall then svcSetVideo a.conv on s else s)

-- ## The environment's own moves

def nIncoming (c : Conv) (v : Bool) (s : S) : S :=
  match s.ncall with
  | some _ => s
  | none =>
    let n := s.nativeNext
    enqueue (.ev (some n) (.incoming c v n)) { s with ncall := some ⟨n, c, .prering, true, false, false⟩, nativeNext := n + 1 }

def nState (st : DState) (s : S) : S :=
  match s.ncall with
  | none => s
  | some n =>
    if n.st == st || n.hungUp || (st == .accepted && n.incoming && !n.acceptedHere) then s
    else
      let s := { s with ncall := some { n with st := st } }
      let s := if st == .accepted && s.camEnabled then enqueue (.camNeeded true) s else s
      enqueue (.ev (some n.id) (.state n.conv st n.id)) s

def nEnd (r : EndReason) (s : S) : S :=
  match s.ncall with
  | none => s
  | some n =>
    let s := enqueue (.camNeeded false) { s with ncall := none, presenting := false }
    enqueue (.ev (some n.id) (.ended n.conv (some r) n.id)) s

/-- RingRTC rejects an offer (expired, glare): `ended` with the offer's own call id. -/
def nRejected (c : Conv) (s : S) : S :=
  let n := s.nativeNext
  enqueue (.ev none (.ended c none n)) { s with nativeNext := n + 1 }

-- ## Events and the step function

inductive Ev where
  -- the user
  | openLobby (c : Conv) (video : Bool)
  | startCall
  | accept (c : Conv) (video : Bool)
  | decline (c : Conv)
  | hangUp
  | closeCall
  | setVideo (on : Bool)
  | toggleShare
  | pickSource
  | cancelPick
  -- the scheduler: run the `k`-th pending job
  | run (k : Nat)
  -- the calling service and RingRTC
  | nIncoming (c : Conv) (video : Bool)
  | nState (st : DState)
  | nEnd (r : EndReason)
  | nRejected (c : Conv)
  | setupDone (q : Nat) (ok : Bool)
  -- the camera
  | camAccess (granted : Bool)
  | camStart (ok : Bool)
  | camStopDone
  | camFrame (k : Nat)
  -- ScreenCaptureKit (`scFrame` and `scStopped` name a stream)
  | srcDone (i : Nat) (ok : Bool)
  | scStartDone (j : Nat) (ok : Bool)
  | scStopDone (j : Nat) (ok : Bool)
  | scFrame (j : Nat)
  | scStopped (j : Nat)
  deriving DecidableEq, Repr

/-- User actions and environment events (`run` is handled by `step`). -/
def handle : Ev → S → S
  | .openLobby c v => openLobby c v
  | .startCall => startCall
  | .accept c v => acceptCall c v
  | .decline c => declineCall c
  | .hangUp => hangUp
  | .closeCall => endCallUI
  | .setVideo on => setVideo on
  | .toggleShare => toggleShare
  | .pickSource => pickSource
  | .cancelPick => fun s => clearShare { s with sources := false }
  | .run _ => id
  | .nIncoming c v => nIncoming c v
  | .nState st => nState st
  | .nEnd r => nEnd r
  | .nRejected c => nRejected c
  | .setupDone q ok => setupEnv q ok
  | .camAccess g => camAccessEnv g
  | .camStart ok => camStartEnv ok
  | .camStopDone => camStopEnv
  | .camFrame k => camFrameEnv k
  | .srcDone i ok => srcEnv i ok
  | .scStartDone j ok => scStartEnv j ok
  | .scStopDone j ok => scStopEnv j ok
  | .scFrame j => scFrameEnv j
  | .scStopped j => scStoppedEnv j

/-- A job, run to its next suspension. -/
def runJob : Job → S → S
  | .recPass => recPass
  | .capStop i => capStop i
  | .setupStart g c v inst x => setupLeaf g c v inst x
  | .sources i tok gen c => sourcesLeaf i tok gen c
  | .present i pt => presentLeaf i pt
  | .setupRet _ gen c r placed => setupDone gen c r placed
  | .recRet => recResume
  | .sourcesRet i tok gen c ok => srcDone i tok gen c ok
  | .installRet i cg j pt ok => installDone i cg j pt ok
  | .teardownRet i cg _ pt => capStartAfterTeardown i cg pt
  | .stopRet _ => id
  | .msg m => runMsg m
  | .camFrame k => camFrame k
  | .scFrame i tok => scFrame i tok
  | .scStopped _ tok => scStopped tok

/-- One event, without the ghost record of ended instances. -/
def stepCore (s : S) (e : Ev) : S :=
  match e with
  | .run k =>
    match s.jobs[k]? with
    | some l => runJob l { s with out := [], jobs := s.jobs.eraseIdx k }
    | none => { s with out := [] }
  | e => handle e { s with out := [] }

/-- Ghost: an instance live before the step and not after it has ended (computed from the
state before the step, so no handler can change the record). -/
def noteEnded (s s' : S) : S := { s' with ended := fun a => s.ended a || (instLive s a && !instLive s' a) }

def step (s : S) (e : Ev) : S := noteEnded s (stepCore s e)

def effects (s : S) : List Eff := s.out.reverse

/-- Run a trace from `s`. -/
def run (s : S) : List Ev → S
  | [] => s
  | e :: es => run (step s e) es

/-- Reachable states from any initial counter configuration. -/
inductive Reach : S → Prop where
  | init (cfg : Cfg) : Reach (S.init cfg)
  | step {s : S} (e : Ev) : Reach s → Reach (step s e)

end CallCapture
