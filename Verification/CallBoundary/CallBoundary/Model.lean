/-!
# The calling boundary: what SignalCalling.xpc can make the app do

ringrtc (WebRTC) runs in the calling service, a process that reads what remote peers send. A
model of the app's side of that boundary:

* `RemoteCallEndpoint` (`CallXPC.swift`): the client's endpoint in the service and its
  **generation**. A command runs on the live endpoint, or on a new one (with `setSelfUuid`
  replayed) when there is none; a command from a call or group call carries the generation it
  was made on and is refused once that has passed. A command or event wait that finds the
  endpoint gone moves the generation on (`lost`); the next wait reports the loss once.
* `RingRTC` (`RingRTC.swift`, `RingRTC+Events.swift`): what the service's events may make the
  app do. 1:1 signalling only to the current call's peer or the sender of an offer the app
  passed in; an incoming call only for such an offer; a call message only to ourselves, a member
  (given by the app) of a Signal group call ringrtc runs, or a participant of a call-link call;
  a group message only to a Signal group with a call (or one whose ring was just cancelled), its
  recipients as call messages; a group ring only from someone whose call message the app passed
  in. A reported loss ends every call and group call made on the lost generations.

The service is the adversary: any event at any time while the endpoint is live (events reach
the app only through the live endpoint's wait), and it may lose the endpoint at any time. It
also chooses the call ids and client ids it answers. Time is abstract: `expireSender` and
`expireRing` are the 120 s window passing. The Swift rig (`CallBoundaryConformanceTests`) runs
production RingRTC over production RemoteCallEndpoint against a hostile in-process service.
-/

namespace CallBoundary

/-- Who sent a command: RingRTC itself, the current 1:1 call, or a group call client. -/
inductive Origin
  | rtc
  | call
  | group
  deriving DecidableEq, Repr

/-- A command the service ran: on endpoint `ep`, from `origin`, made on generation `gen`. -/
structure Cmd where
  ep : Nat
  origin : Origin
  gen : Nat
  deriving DecidableEq, Repr

/-- The current 1:1 call (`RingRTC.call`): it stays after it ends. -/
structure CallR where
  peer : Nat
  id : Nat
  gen : Nat
  ended : Bool
  deriving DecidableEq, Repr

/-- A group call client (`groupCallByClientId`). -/
structure GroupR where
  client : Nat
  group : Nat
  /-- A call-link call (no group, no members). -/
  link : Bool
  gen : Nat
  /-- `setGroupMembers`: the app's. -/
  members : List Nat
  /-- The remote devices the service reports. -/
  participants : List Nat
  deriving DecidableEq, Repr

/-- What the app does at the service's request (the handlers RingRTC calls). -/
inductive Out
  | signal (peer callId : Nat)
  | incoming (peer callId : Nat)
  | message (to : Nat)
  | groupMessage (group : Nat) (to : List Nat)
  | ring (sender group : Nat)
  /-- A group call client's `onEnded` (the service ended it, or its endpoint was lost). -/
  | groupEnded (client : Nat)
  deriving DecidableEq, Repr

structure St where
  /-- The client's endpoint (`RemoteCallEndpoint.state.id`), by creation index. -/
  ep : Option Nat
  eps : Nat
  /-- The generation each endpoint was made on. -/
  epGen : List Nat
  gen : Nat
  /-- Losses reported (generations below this one have been ended). -/
  reported : Nat
  /-- Endpoints the service lost. -/
  gone : List Nat
  /-- `setSelfUuid` recorded for replay. -/
  config : Bool
  /-- Ghost: the endpoints `setSelfUuid` ran on. -/
  configOn : List Nat
  /-- RingRTC knows our own uuid. -/
  selfKnown : Bool
  call : Option CallR
  /-- `callInfoByCallId`: the offers passed in, (call id, peer). -/
  offers : List (Nat × Nat)
  /-- By client id, ascending. -/
  groups : List GroupR
  /-- Every group call client object the app made (the latest per client id), whether RingRTC
  still has it or not: the app may hold one after it ended (CallingService, the call UI). -/
  held : List GroupR
  /-- `callMessageSenders` (within the window). -/
  senders : List Nat
  /-- `cancelledRings` (within the window). -/
  cancelled : List Nat
  /-- Ghost: what the app did for the service, in order. -/
  out : List Out
  /-- Ghost: the commands the service ran, in order. -/
  cmds : List Cmd
  deriving Repr

/-- RingRTC's start: `RemoteCallEndpoint` makes its first endpoint at once. -/
def St.init : St := ⟨some 0, 1, [0], 0, 0, [], false, [], false, none, [], [], [], [], [], [], []⟩

/-- Our own uuid. -/
def selfId : Nat := 0

inductive Ev
  -- The app (RingRTC's callers).
  | setSelf
  /-- `startOutgoingCall`; the service answers `callId`. -/
  | start (peer callId : Nat)
  /-- `handleCallingMessage` with an offer. -/
  | offer (peer callId : Nat)
  /-- `handleCallingMessage` with an opaque message from `sender`. -/
  | callMsg (sender : Nat)
  /-- `getGroupCall` (`link` false) or `getCallLinkCall`; the service answers `client`. -/
  | group (gid client : Nat) (link : Bool)
  /-- `setGroupMembers` on group call `client`. -/
  | members (client : Nat) (ms : List Nat)
  /-- The current call sends a command (`updateDataMode`). -/
  | callCmd
  /-- Group call `client` sends a command (`react`): the app's object, ended or not. -/
  | groupCmd (client : Nat)
  | cancelRing (gid : Nat)
  | expireSender (u : Nat)
  | expireRing (gid : Nat)
  -- The calling service, through the live endpoint's event wait.
  | incoming (peer callId : Nat)
  | signal (peer callId : Nat)
  | message (to : Nat)
  | groupMessage (gid : Nat) (to : List Nat)
  | ring (sender gid : Nat)
  | callEnded (callId : Nat)
  | devices (client : Nat) (us : List Nat)
  | groupEnded (client : Nat)
  -- Losing the endpoint.
  /-- The service loses the client's endpoint (it crashed, or was ended). -/
  | crash
  /-- One turn of the event pump: report a loss, or find one. -/
  | wait
  deriving DecidableEq, Repr

/-- `RemoteCallEndpoint.command`: refused if made on another generation; otherwise on the live
endpoint, or a new one with `setSelfUuid` replayed. If the service lost the endpoint, the
command fails and the generation moves on. Whether the service ran it. -/
def send (s : St) (o : Origin) (g : Option Nat) : St × Bool :=
  match g with
  | some g' => if g' = s.gen then sendLive s o else (s, false)
  | none => sendLive s o
where
  sendLive (s : St) (o : Origin) : St × Bool :=
    match s.ep with
    | some e =>
      if e ∈ s.gone then ({ s with ep := none, gen := s.gen + 1 }, false)
      else ({ s with cmds := s.cmds ++ [⟨e, o, s.gen⟩] }, true)
    | none =>
      let e := s.eps
      let replay : List Cmd := if s.config then [⟨e, .rtc, s.gen⟩] else []
      ({ s with ep := some e, eps := e + 1, epGen := s.epGen ++ [s.gen],
                configOn := if s.config then s.configOn ++ [e] else s.configOn,
                cmds := s.cmds ++ replay ++ [⟨e, o, s.gen⟩] }, true)

/-- The command's state. -/
def run (s : St) (o : Origin) (g : Option Nat) : St := (send s o g).1

def lookup (offers : List (Nat × Nat)) (callId : Nat) : Option Nat :=
  (offers.find? (·.1 = callId)).map (·.2)

def findGroup (s : St) (client : Nat) : Option GroupR := s.groups.find? (·.client = client)

def findHeld (s : St) (client : Nat) : Option GroupR := s.held.find? (·.client = client)

/-- Insert by client id (replacing one with the same id). -/
def insertGroup (g : GroupR) : List GroupR → List GroupR
  | [] => [g]
  | h :: t => if g.client < h.client then g :: h :: t else if g.client = h.client then g :: t else h :: insertGroup g t

def updGroup (client : Nat) (f : GroupR → GroupR) (gs : List GroupR) : List GroupR :=
  gs.map fun g => if g.client = client then f g else g

/-- Whether the endpoint is up for events: the client holds it and the service has it. -/
def live (s : St) : Bool :=
  match s.ep with
  | some e => !(s.gone.contains e)
  | none => false

/-- `maySignal` -/
def maySignal (s : St) (peer callId : Nat) : Bool :=
  (match s.call with
   | some c => c.peer == peer && c.id == callId
   | none => false) || lookup s.offers callId == some peer

/-- `mayMessage` -/
def mayMessage (s : St) (to : Nat) : Bool :=
  (s.selfKnown && to == selfId) ||
    s.groups.any fun g => (!g.link && g.members.contains to) || (g.link && g.participants.contains to)

/-- `mayMessageGroup`, and every recipient as a call message. -/
def mayGroupMessage (s : St) (gid : Nat) (to : List Nat) : Bool :=
  (s.groups.any (fun g => !g.link && g.group == gid) || s.cancelled.contains gid) && to.all (mayMessage s)

/-- `endpointLost(gen - 1)`: the current call, if made before, ends (its own commands are
refused: they carry the lost generation); every group call client made before is dropped and
told (`onEnded`), in client order. -/
def report (s : St) : St :=
  let old := s.groups.filter (·.gen < s.gen)
  { s with
    call := s.call.map fun c => if c.gen < s.gen then { c with ended := true } else c,
    offers := match s.call with
      | some c => if c.gen < s.gen && !c.ended then s.offers.filter (·.1 ≠ c.id) else s.offers
      | none => s.offers,
    groups := s.groups.filter (·.gen ≥ s.gen),
    out := s.out ++ old.map (Out.groupEnded ·.client),
    reported := s.gen }

def step (s : St) : Ev → St
  | .setSelf =>
    let s1 := { s with selfKnown := true, config := true }
    match send s1 .rtc none with
    | (s2, true) => match s2.ep with
      | some e => if e ∈ s2.configOn then s2 else { s2 with configOn := s2.configOn ++ [e] }
      | none => s2
    | (s2, false) => s2
  | .start peer callId =>
    match send s .rtc none with
    | (s1, true) => { s1 with call := some ⟨peer, callId, s1.gen, false⟩ }
    | (s1, false) => s1
  | .offer peer callId => run { s with offers := (callId, peer) :: s.offers.filter (·.1 ≠ callId) } .rtc none
  | .callMsg u => run { s with senders := u :: s.senders.erase u } .rtc none
  | .group gid client link =>
    match send s .rtc none with
    | (s1, true) =>
      if client = 0 then s1
      else { s1 with groups := insertGroup ⟨client, gid, link, s1.gen, [], []⟩ s1.groups,
                     held := insertGroup ⟨client, gid, link, s1.gen, [], []⟩ s1.held }
    | (s1, false) => s1
  | .members client ms =>
    match findGroup s client with
    | some g => run { s with groups := updGroup client (fun g => { g with members := ms }) s.groups } .group (some g.gen)
    | none => s
  | .callCmd =>
    match s.call with
    | some c => run s .call (some c.gen)
    | none => s
  | .groupCmd client =>
    match findHeld s client with
    | some g => run s .group (some g.gen)
    | none => s
  | .cancelRing gid => run { s with cancelled := gid :: s.cancelled.erase gid } .rtc none
  | .expireSender u => { s with senders := s.senders.erase u }
  | .expireRing gid => { s with cancelled := s.cancelled.erase gid }
  | .incoming peer callId =>
    if live s && lookup s.offers callId == some peer then
      { s with call := some ⟨peer, callId, s.gen, false⟩, out := s.out ++ [.incoming peer callId] }
    else s
  | .signal peer callId =>
    if !live s then s
    else if maySignal s peer callId then run { s with out := s.out ++ [.signal peer callId] } .rtc none
    else run s .rtc none
  | .message to =>
    if live s && mayMessage s to then { s with out := s.out ++ [.message to] } else s
  | .groupMessage gid to =>
    if live s && mayGroupMessage s gid to then { s with out := s.out ++ [.groupMessage gid to] } else s
  | .ring u gid =>
    if live s && s.senders.contains u then { s with out := s.out ++ [.ring u gid] } else s
  | .callEnded callId =>
    if !live s then s else
    let s1 := { s with offers := s.offers.filter (·.1 ≠ callId) }
    match s1.call with
    | some c =>
      if c.id = callId && !c.ended then
        let s2 := { s1 with call := some { c with ended := true } }
        run (run (run s2 .call (some c.gen)) .call (some c.gen)) .call (some c.gen)
      else s1
    | none => s1
  | .devices client us =>
    if live s then { s with groups := updGroup client (fun g => { g with participants := us }) s.groups } else s
  | .groupEnded client =>
    if !live s then s else
    match findGroup s client with
    | some g =>
      let s1 := run { s with groups := s.groups.filter (·.client ≠ client) } .group (some g.gen)
      { s1 with out := s1.out ++ [.groupEnded client] }
    | none => s
  | .crash =>
    match s.ep with
    | some e => if e ∈ s.gone then s else { s with gone := s.gone ++ [e] }
    | none => s
  | .wait =>
    if s.reported < s.gen then report s
    else match s.ep with
      | some e => if e ∈ s.gone then { s with ep := none, gen := s.gen + 1 } else s
      | none => s

def run' (s : St) (es : List Ev) : St := es.foldl step s

end CallBoundary
