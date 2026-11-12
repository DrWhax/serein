/-!
# The broker: the app's channels to its sandboxed helpers

A model of `XPCChannel` (`MediaXPCInterface/XPCTransport.swift`) and `MediaXPCClient`
(`MediaXPC.swift`, with `MediaQuarantine` in `Containment.swift`) for two helpers: the media
decoder (`dec`) and the voice-note encoder (`voice`), each behind one channel.

* A channel has at most one live session. A request is sent on it (opening a new one if there
  is none) and is **outstanding** until the first of: its reply, its failure (the session
  ended), its timeout, its caller's cancellation. Only that first ending reaches the caller.
* The helper is the adversary. It answers any message it was sent with anything, at any time,
  on a session that ended or not, again after it already answered, or never; it sends messages
  nobody asked for; it crashes (ends its sessions). The system (XPC) is trusted for what the
  Swift rig checks it does: a reply goes to the message it answers, at most once, and only
  while that message's session is up; when a session ends, every message on it still waiting
  fails; a message nobody asked for is dropped (the app sets no handler for them).
* A reply is decoded as the request's own result type and validated with the request's own
  parameters (`accept`). A reply after its request ended is too late: if it names a session the
  helper opened for it (`late`), the client closes it (`release`).
* Inputs (the untrusted bytes a decoder request carries) are quarantined after two strikes: a
  timeout strikes twice, an ended session once per input in flight on it.

The Swift rig (`BrokerConformanceTests`) runs production `MediaXPCClient` against a hostile
in-process helper on every event and compares with `step`.
-/

namespace Broker

inductive Ch
  | dec
  | voice
  deriving DecidableEq, Repr, Inhabited

/-- What the app asks. `release` is the client's own: it closes a session the helper opened. -/
inductive Kind
  /-- `thumbnail(bytes, size:)`: a `size`×`size` PNG of input `input`. -/
  | thumb (size input : Nat)
  /-- `openVideo(bytes)`: opens a playback session in the decoder. -/
  | openV (input : Nat)
  /-- `startVoiceNote` (`mic` false: the app hands it samples) or `recordVoiceNote` (`mic` true:
  the service records the microphone, after the user's permission): opens a recording session
  in the voice-note service. The two differ in the request and in their budgets only. -/
  | start (mic : Bool)
  /-- `closeVideo(u)` (decoder) or `cancelVoiceNote(u)` (voice). -/
  | release (c : Ch) (u : Nat)
  deriving DecidableEq, Repr

def Kind.ch : Kind → Ch
  | .thumb .. => .dec
  | .openV _ => .dec
  | .start _ => .voice
  | .release c _ => c

/-- The untrusted bytes a request hands the decoder: what quarantine is keyed by. -/
def Kind.input : Kind → Option Nat
  | .thumb _ i => some i
  | .openV i => some i
  | _ => none

/-- What the helper sends back to one message. -/
inductive Reply
  /-- A `Thumbnail` of `w`×`h`. -/
  | thumb (w h : Nat)
  /-- An `OpenedVideo` naming session `u`; `valid`: its `VideoInfo` passes `validated()`. -/
  | opened (u : Nat) (valid : Bool)
  /-- A UUID: a recording session. -/
  | voiceId (u : Nat)
  /-- `MediaEmpty`. -/
  | empty
  /-- Bytes that are none of these (or more than the request's `maxReplyBytes`). -/
  | garbage
  /-- An error string, or no payload at all (another XPC type in its place). -/
  | error
  deriving DecidableEq, Repr

inductive Val
  | thumb (w h : Nat)
  | session (u : Nat)
  | empty
  deriving DecidableEq, Repr

inductive Err
  | timedOut
  | lost
  | cancelled
  /-- The reply was refused: undecodable as the request's type, or invalid for its parameters. -/
  | refused
  /-- The helper answered with an error. -/
  | helper
  /-- Not sent: the input is quarantined. -/
  | quarantined
  deriving DecidableEq, Repr

inductive Status
  | pending
  | ok (v : Val)
  | failed (e : Err)
  deriving DecidableEq, Repr

structure Req where
  kind : Kind
  /-- The session it was sent on; none: refused before sending (a quarantined input). -/
  sess : Option Nat
  status : Status
  /-- Its reply handler has run: a reply or a failure (the system runs it once). -/
  answered : Bool
  deriving DecidableEq, Repr

structure Sess where
  ch : Ch
  ended : Bool
  deriving DecidableEq, Repr

structure St where
  /-- Every request, in the order made. -/
  reqs : List Req
  /-- Every session ever opened; its index is its id. -/
  sess : List Sess
  live : Ch → Option Nat
  strikes : Nat → Nat
  /-- Ghost: the replies the system delivered, by request. -/
  delivered : List (Nat × Reply)

def St.init : St := ⟨[], [], fun _ => none, fun _ => 0, []⟩

/-- `MediaQuarantine.strikesToQuarantine` -/
def quarantineAt : Nat := 2

/-- A reply delivered while its request is outstanding: what the caller gets, and a session to
release (the one the reply names, when its answer is refused). The reply is decoded as the
request's own type and validated with the request's own parameters. -/
def accept : Kind → Reply → Status × Option Nat
  | .thumb size _, .thumb w h => (if w = size ∧ h = size then .ok (.thumb w h) else .failed .refused, none)
  | .openV _, .opened u true => (.ok (.session u), none)
  | .openV _, .opened u false => (.failed .refused, some u)
  | .start _, .voiceId u => (.ok (.session u), none)
  | .release .., .empty => (.ok .empty, none)
  | _, .error => (.failed .helper, none)
  | _, _ => (.failed .refused, none)

/-- A reply after its request ended: the session it names, if the request opens one. -/
def late : Kind → Reply → Option Nat
  | .openV _, .opened u _ => some u
  | .start _, .voiceId u => some u
  | _, _ => none

/-- Whether session `id` has ended (or does not exist). -/
def ended (s : St) (id : Nat) : Bool := (s.sess[id]?.map (·.ended)).getD true

/-- The channel's session: the live one, or a new one (`XPCChannel.current`). -/
def opened (s : St) (c : Ch) : St :=
  match s.live c with
  | some _ => s
  | none => { s with sess := s.sess ++ [⟨c, false⟩], live := fun c' => if c' = c then some s.sess.length else s.live c' }

/-- A request sent on its channel's session. -/
def send (s : St) (k : Kind) : St :=
  { opened s k.ch with reqs := (opened s k.ch).reqs ++ [⟨k, (opened s k.ch).live k.ch, .pending, false⟩] }

def quarantined (s : St) (k : Kind) : Bool :=
  match k.input with
  | some i => decide (quarantineAt ≤ s.strikes i)
  | none => false

/-- The app's request (`release` is not the app's). -/
def call (s : St) (k : Kind) : St :=
  match k with
  | .release .. => s
  | _ => if quarantined s k then { s with reqs := s.reqs ++ [⟨k, none, .failed .quarantined, true⟩] } else send s k

/-- What a delivered reply does to its request: an outstanding one ends with `accept`'s answer;
an ended one keeps its ending, and the reply is late. -/
def answer (q : Req) (r : Reply) : Status × Option Nat :=
  if q.status = .pending then accept q.kind r else (q.status, late q.kind r)

/-- The helper answers request `m`'s message with `r`. The system delivers it only once, and only
while the message's session is up. -/
def reply (s : St) (m : Nat) (r : Reply) : St :=
  match s.reqs[m]? with
  | none => s
  | some q =>
    match q.sess with
    | none => s
    | some id =>
      if q.answered = true ∨ ended s id = true then s else
      let s1 : St := { s with reqs := s.reqs.set m { q with answered := true, status := (answer q r).1 },
                              delivered := s.delivered ++ [(m, r)] }
      match (answer q r).2 with
      | some u => send s1 (.release q.kind.ch u)
      | none => s1

/-- A request on session `id` when it ends: its handler runs with a failure; a waiting one is lost. -/
def endReq (id : Nat) (q : Req) : Req :=
  if q.sess = some id ∧ q.answered = false then
    { q with answered := true, status := if q.status = .pending then .failed .lost else q.status }
  else q

/-- Whether input `i` was in flight on session `id`. -/
def inFlight (s : St) (id i : Nat) : Bool :=
  s.reqs.any fun q => decide (q.sess = some id ∧ q.status = .pending ∧ q.kind.input = some i)

/-- The helper's session on channel `c` ends (it crashed, exited, or ended it): every request
waiting on it is lost, each input in flight on it takes one strike, and the next request opens a
new session. -/
def crash (s : St) (c : Ch) : St :=
  match s.live c with
  | none => s
  | some id =>
    { s with
      reqs := s.reqs.map (endReq id)
      sess := s.sess.set id ⟨c, true⟩
      live := fun c' => if c' = c then none else s.live c'
      strikes := fun i => s.strikes i + if inFlight s id i then 1 else 0 }

def bump (f : Nat → Nat) (i : Option Nat) (n : Nat) : Nat → Nat :=
  fun j => if i = some j then f j + n else f j

/-- The watchdog: an outstanding request times out; its input is quarantined at once. -/
def timeout (s : St) (m : Nat) : St :=
  match s.reqs[m]? with
  | none => s
  | some q =>
    if q.status = .pending then
      { s with reqs := s.reqs.set m { q with status := .failed .timedOut }, strikes := bump s.strikes q.kind.input quarantineAt }
    else s

/-- The caller's task is cancelled: an outstanding request ends at once. -/
def cancel (s : St) (m : Nat) : St :=
  match s.reqs[m]? with
  | none => s
  | some q => if q.status = .pending then { s with reqs := s.reqs.set m { q with status := .failed .cancelled } } else s

inductive Ev
  | call (k : Kind)
  | reply (m : Nat) (r : Reply)
  | crash (c : Ch)
  /-- A message from the helper that no request asked for. -/
  | unsolicited (c : Ch)
  | timeout (m : Nat)
  | cancel (m : Nat)
  deriving DecidableEq, Repr

def step (s : St) : Ev → St
  | .call k => call s k
  | .reply m r => reply s m r
  | .crash c => crash s c
  | .unsolicited _ => s
  | .timeout m => timeout s m
  | .cancel m => cancel s m

inductive Reach : St → Prop
  | init : Reach St.init
  | step {s : St} (e : Ev) : Reach s → Reach (step s e)

/-- The channel an event is about. -/
def chOf (s : St) : Ev → Option Ch
  | .call k => some k.ch
  | .reply m _ => (s.reqs[m]?).map (·.kind.ch)
  | .timeout m => (s.reqs[m]?).map (·.kind.ch)
  | .cancel m => (s.reqs[m]?).map (·.kind.ch)
  | .crash c => some c
  | .unsolicited c => some c

/-! ## Data the app turns into requests to other helpers

The link-preview and GIF flows (`WebServices.swift`): what a helper returns that the app then
hands to another helper. Abstract here; the rig checks production computes the same. -/

/-- A URL as the GIF service returns it: https or not, which host (0–4: `media0…4.giphy.com`),
an explicit port, credentials. -/
structure Url where
  https : Bool
  host : Nat
  port : Bool
  user : Bool
  deriving DecidableEq, Repr

/-- `PaginatedGifResults.isGiphyCdnURL` -/
def cdn (u : Url) : Bool := u.https && decide (u.host < 5) && !u.port && !u.user

/-- `PaginatedGifResults.validated` on a page's URLs: refused unless every one is a CDN URL. -/
def pageAccepted (us : List Url) : Bool := us.all cdn

/-- `GifSearchClient.file`: asked of the GIF service only for a CDN URL. -/
def fileAsked (u : Url) : Bool := cdn u

/-- The parser service's answer to the app's empty message: an XPC endpoint under `endpoint` or
not (an entry of another XPC type counts as none), and how many payload bytes. -/
structure EndpointReply where
  endpoint : Option Nat
  payload : Nat
  deriving DecidableEq, Repr

/-- `LinkPreviewFetcherClient.parserEndpoint`: the endpoint handed to the fetcher with the fetch
(at most `maxReply` 0 payload bytes); none: no fetch. -/
def handed (r : EndpointReply) : Option Nat := if r.payload = 0 then r.endpoint else none

end Broker
