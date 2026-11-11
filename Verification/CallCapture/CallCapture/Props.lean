import CallCapture.Model

/-!
# The security properties, as decidable checks on one step

Each check looks at a pre-state `s`, the event `e`, and `s' = step s e`. The theorems in
`Proofs.lean` and `Counterexamples.lean` are about these same definitions; the explorer in
`Main.lean` evaluates them on random traces to find counterexamples.

Vocabulary (all defined from state, none from the property being checked):

* A call *instance* is one `ACall` the app opened (`inst`, ghost). Instance `a` is *live* in
  `s` when it is `s.active` and `live` (`instLive`). It has *ended* (`s.ended a`) once a step
  took it from live to not live; `step` records that, whatever the step was.
* A share `i` (the `i`-th `ScreenShareCapture`) is *current* when `s.share` names it, and
  *obsolete* otherwise (stopped or replaced; share numbers are never reused). It is *revoked*
  when it is obsolete or the call instance it was created in is not live.
* The user's camera authorization is `userVideo`: their last explicit choice (lobby, accept,
  video button). Turning video off revokes it.
* A message *belongs* to a native call (`owner`, ghost). It is *foreign* to the active
  instance `a` unless that native call was started by `a`'s own setup or accepted by `a`.
  A native call has *ended* once it left RingRTC's slot.
* Most app code runs in jobs: a step `run k` runs job `k`, and the property looks at what that
  job belongs to.
-/

namespace CallCapture

def curShare (s : S) : Option Nat := s.share.map (·.1)

def shareRevoked (s : S) (i : Nat) : Bool := curShare s != some i || !instLive s (s.caps i).inst

def streamOwner (s : S) (j : Nat) : Option Nat := (s.streams j).map (·.1)

def streamLive (s : S) (j : Nat) : Bool :=
  match s.streams j with
  | some (_, .starting) | some (_, .running) | some (_, .stopping) => true
  | _ => false

def opMentions (j : Nat) : Op → Bool
  | .install _ _ j' _ | .tdStart _ _ j' _ | .stopping j' => j' == j
  | _ => false

/-- The job a `run` event runs. -/
def jobOf (s : S) : Ev → Option Job
  | .run k => s.jobs[k]?
  | _ => none

-- ## T1: an event belonging to an obsolete call cannot mutate its replacement

/-- The call event a step hands to the session (its hop runs), with its owner. -/
def evMsg (s : S) (e : Ev) : Option (Option Nat × CEv) :=
  match jobOf s e with
  | some (.msg (.ev o ev)) => some (o, ev)
  | _ => none

/-- The step changed nothing the active call is made of, and did not end its native call. -/
def leavesActive (s s' : S) : Bool :=
  s'.active == s.active && s'.gen == s.gen && s'.share == s.share && s'.localVideo == s.localVideo &&
  s'.setupTask == s.setupTask &&
  !(effects s').any (fun x => match x with
      | .svcHangup _ => true
      | .svcEndCall c id =>
        match s.ncall, s.active with
        | some n, some a => n.conv == c && id.all (· == n.id) && s.nativeInst n.id == some a.inst
        | _, _ => false
      | _ => false)

/-- T1 for events of native calls. -/
def t1 (s : S) (e : Ev) (s' : S) : Bool :=
  match evMsg s e, s.active with
  | some (some n, _), some a => s.nativeInst n == some a.inst || leavesActive s s'
  | _, _ => true

/-- What conversation keying does give: an event about another conversation leaves the
active call alone. -/
def t1OtherConv (s : S) (e : Ev) (s' : S) : Bool :=
  match evMsg s e, s.active with
  | some (_, ev), some a =>
    let c := match ev with | .outgoing c _ _ _ | .incoming c _ _ | .state c _ _ | .ended c _ _ => c
    c == a.conv || leavesActive s s'
  | _, _ => true

/-- T1 for synthetic events (a rejected offer: no call of ours at all). -/
def t1Rejected (s : S) (e : Ev) (s' : S) : Bool :=
  match evMsg s e, s.active with
  | some (none, _), some _ => leavesActive s s'
  | _, _ => true

-- ## T2: an obsolete share cannot submit frames or stop its replacement

def t2Frames (s : S) (_e : Ev) (s' : S) : Bool :=
  (effects s').all fun x => match x with
    | .sendFrame (.screen i) => curShare s == some i
    | _ => true

/-- The share a step belongs to: the device events of its streams and sources, and every job
that carries it (its tasks, the continuations of its awaits, its frame and stop callbacks). -/
def evShare (s : S) : Ev → Option Nat
  | .srcDone i _ => some i
  | .scFrame j | .scStopped j | .scStartDone j _ | .scStopDone j _ => streamOwner s j
  | .run k =>
    match s.jobs[k]? with
    | some (.capStop i) | some (.sources i ..) | some (.present i _) | some (.sourcesRet i ..)
    | some (.installRet i ..) | some (.teardownRet i ..) | some (.scFrame i _) | some (.scStopped i _) => some i
    | some (.stopRet j) => streamOwner s j
    | _ => none
  | _ => none

def t2Stop (s : S) (e : Ev) (s' : S) : Bool :=
  match evShare s e, s.share with
  | some i, some (m, _) =>
    if i == m then true
    else
      s'.share == s.share && s'.presenting == s.presenting &&
      (effects s').all fun x => match x with
        | .scStopReq j => streamOwner s j != some m
        | .svcSetPresenting _ _ => false
        | _ => true
  | _, _ => true

-- ## T3: revocation prevents new capture authorization for that session

/-- A camera start is requested, and camera frames are sent, only for a live call whose user
has video on now. -/
def t3Camera (_s : S) (_e : Ev) (s' : S) : Bool :=
  (effects s').all fun x => match x with
    | .camStartReq _ | .sendFrame (.camera _) => wanted s' && s'.userVideo
    | _ => true

/-- The app asks the service to start a call (`startOutgoingDirectCall`) only from the setup
of a live call instance. -/
def t3CallRequest (s : S) (e : Ev) (s' : S) : Bool :=
  match jobOf s e with
  | some (.setupStart _ _ _ a _) => instLive s a || !(effects s').any (fun x => match x with | .svcStart .. => true | _ => false)
  | _ => true

/-- RingRTC places a call (it takes the microphone and rings the contact) only for the setup of
a live call instance. -/
def t3Call (s : S) (e : Ev) (s' : S) : Bool :=
  match e with
  | .setupDone q _ =>
    match findSetup q s.ops with
    | some (_, _, _, _, a) => instLive s a || s'.nativeNext == s.nativeNext
    | none => true
  | _ => true

/-- Screen sources (the shareable windows, with screenshots for thumbnails) are requested only
for a share that is not revoked. -/
def t3ScreenSources (_s : S) (_e : Ev) (s' : S) : Bool :=
  (effects s').all fun x => match x with
    | .scSourcesReq i => !shareRevoked s' i
    | _ => true

/-- A screen stream is started only for a share that is not revoked. -/
def t3Screen (_s : S) (_e : Ev) (s' : S) : Bool :=
  (effects s').all fun x => match x with
    | .scStartReq i _ => !shareRevoked s' i
    | _ => true

/-- T3 for obsolete shares: no stream is started for a share that has been stopped or replaced. -/
def t3ScreenObsolete (_s : S) (_e : Ev) (s' : S) : Bool :=
  (effects s').all fun x => match x with
    | .scStartReq i _ => curShare s' == some i
    | _ => true

/-- The camera is started only while the app wants it (a live call with `callLocalVideo` on),
whatever the user last chose. -/
def camStartWanted (_s : S) (_e : Ev) (s' : S) : Bool :=
  !(effects s').any (fun x => match x with | .camStartReq _ => true | _ => false) || wanted s'

-- ## T4: capture completion after revocation cannot publish and requires cleanup

/-- Not presenting switched on. -/
def noPresentOn (s' : S) : Bool :=
  !(effects s').any (fun x => match x with | .svcSetPresenting _ true => true | _ => false)

/-- A stream start whose continuation runs once its share is revoked: the stream is stopped
and presenting is not switched on. -/
def t4Screen (s : S) (e : Ev) (s' : S) : Bool :=
  match jobOf s e with
  | some (.installRet i _ j _ true) =>
    !shareRevoked s i || ((effects s').contains (.scStopReq j) && noPresentOn s')
  | _ => true

/-- T4 for obsolete shares: a stream start whose continuation runs after its share was stopped
or replaced is stopped, and presenting is not switched on. -/
def t4ScreenObsolete (s : S) (e : Ev) (s' : S) : Bool :=
  match jobOf s e with
  | some (.installRet i _ j _ true) =>
    curShare s == some i || ((effects s').contains (.scStopReq j) && noPresentOn s')
  | _ => true

/-- Frames of a share go out only while the share is current and its own call is live. -/
def t4ScreenPublish (s : S) (_e : Ev) (s' : S) : Bool :=
  (effects s').all fun x => match x with
    | .sendFrame (.screen i) => !shareRevoked s i
    | _ => true

/-- A camera start whose continuation runs once the camera is no longer wanted stops it. -/
def t4Camera (s : S) (e : Ev) (s' : S) : Bool :=
  match jobOf s e, s.pc with
  | some .recRet, .startDone true => wanted s || (effects s').contains .camStopReq
  | _, _ => true

-- ## T5: an ended call cannot become accepted again without a distinct authorized start

/-- Instance `a` is on screen, live and accepted. -/
def acceptedLive (s : S) (a : Nat) : Bool :=
  match s.active with
  | some b => b.inst == a && b.live && b.direct == some .accepted
  | none => false

/-- **T5** (per instance, with its terminal history): a call instance that has ended is never
live and accepted afterwards. A new start is a new instance; whether it was authorized is
`acceptAuthorized`. -/
def t5 (s : S) (_e : Ev) (s' : S) : Bool :=
  match s'.active with
  | some b => !(s.ended b.inst && acceptedLive s' b.inst)
  | none => true

/-- Acceptance requires authorization: the active call is accepted only if it had an authorized
start (the user accepted it, or its own setup started the native call that reports it). -/
def acceptAuthorized (_s : S) (_e : Ev) (s' : S) : Bool :=
  match s'.active with
  | some b => b.direct != some .accepted || b.authorized
  | none => true

-- ## Cleanup obligations (state invariants)

/-- A pending job that will act on stream `j`: a continuation of an await on it, or a stop of
the capture that holds it. -/
def jobMentions (s : S) (j : Nat) : Job → Bool
  | .installRet _ _ j' _ _ | .teardownRet _ _ j' _ | .stopRet j' => j' == j
  | .capStop i => (s.caps i).stream == some j
  | _ => false

/-- Every physically live stream is either the current share's, or has an await or a job
pending on it (whose code stops it if it is no longer wanted). -/
def noOrphanStream (s : S) : Bool :=
  (List.range s.streamNext).all fun j =>
    !streamLive s j ||
    (match streamOwner s j with | some i => !shareRevoked s i | none => false) ||
    s.ops.any (opMentions j) || s.jobs.any (jobMentions s j)

/-- The camera is not left running unwanted with no pass to stop it. -/
def noIdleUnwantedCamera (s : S) : Bool := !(s.running && !wanted s && s.pc == .idle)

/-- Every check, by name. -/
def stepChecks : List (String × (S → Ev → S → Bool)) :=
  [("T1", t1), ("T1-rejected-offer", t1Rejected), ("T1-other-conversation", t1OtherConv), ("T2-frames", t2Frames), ("T2-stop", t2Stop),
   ("T3-camera", t3Camera), ("T3-camera-app", camStartWanted), ("T3-call-request", t3CallRequest), ("T3-call", t3Call), ("T3-screen-sources", t3ScreenSources),
   ("T3-screen", t3Screen),
   ("T3-screen-obsolete", t3ScreenObsolete), ("T4-screen", t4Screen), ("T4-screen-obsolete", t4ScreenObsolete),
   ("T4-screen-publish", t4ScreenPublish), ("T4-camera", t4Camera),
   ("T5", t5), ("accept-authorized", acceptAuthorized),
   ("cleanup-streams", fun _ _ s' => noOrphanStream s'),
   ("cleanup-camera", fun _ _ s' => noIdleUnwantedCamera s')]

end CallCapture
