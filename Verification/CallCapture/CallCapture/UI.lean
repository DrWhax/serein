import CallCapture.Model
import CallCapture.Trace

/-!
# What the UI offers, and under which schedule

Used to classify counterexamples and to restrict random traces. These are restrictions on the
order of events, not on time: the model has no clock, and nothing here says how fast anyone is.

* `uiEnabled`: the user event is one the UI offers in that state (CallManager shows the
  incoming bar only without an active call, the lobby has no share button, the source picker
  only while sources are shown, …). Environment, device and scheduler events are always possible.
* `drainedEnabled`: also, the user acts only while no main-actor job is pending: every task the
  app spawned has started, every completed await has continued, every callback has hopped. A
  trace in which a user event comes while jobs are pending is *UI-reachable with pending
  callbacks*: whether it happens depends on how the main actor interleaves AppKit events with
  its queue, which this model does not decide.
* `fifoEnabled`: the scheduler always runs the oldest pending job (`run 0`). Swift does not
  promise this order, so the proofs assume nothing about it; it only classifies counterexamples.
-/

namespace CallCapture

/-- User events the UI offers in state `s` (environment, device and scheduler events are always possible). -/
def uiEnabled (s : S) : Ev → Bool
  | .openLobby .. => s.active.isNone
  | .startCall => match s.active with | some a => a.stage == .lobby && a.live && !s.setupTask | none => false
  -- CallManager shows the incoming bar only when there is no active call
  | .accept c _ | .decline c => (s.ringing.map (·.1)) == some c && s.active.isNone
  | .hangUp => match s.active with | some a => a.stage == .inCall && a.live | none => false
  | .closeCall => match s.active with | some a => a.stage == .lobby || !a.live | none => false
  | .setVideo _ => match s.active with | some a => a.live | none => false
  | .toggleShare => match s.active with | some a => a.stage == .inCall && a.live | none => false
  | .pickSource | .cancelPick => s.sources
  | _ => true

def isUserEv : Ev → Bool
  | .openLobby .. | .startCall | .accept .. | .decline _ | .hangUp | .closeCall | .setVideo _
  | .toggleShare | .pickSource | .cancelPick => true
  | _ => false

/-- Offered by the UI, and (for user events) no main-actor job pending. -/
def drainedEnabled (s : S) (e : Ev) : Bool := uiEnabled s e && (!isUserEv e || s.jobs.isEmpty)

/-- The scheduler runs the oldest pending job. -/
def fifoEnabled : Ev → Bool
  | .run k => k == 0
  | _ => true

/-- Modes: `any`; `ui`; `drained`; `drained-fifo` (drained, and the FIFO schedule). -/
def enabledIn (mode : String) (s : S) (e : Ev) : Bool :=
  match mode with
  | "ui" => uiEnabled s e
  | "drained" => drainedEnabled s e
  | "drained-fifo" => drainedEnabled s e && fifoEnabled e
  | _ => true

/-- The first step (index) at which `check` fails, if any. -/
def firstFailure (check : S → Ev → S → Bool) (t : Trace) : Option Nat :=
  let rec go : List Ev → S → Nat → Option Nat
    | [], _, _ => none
    | e :: es, s, k => let s' := step s e; if check s e s' then go es s' (k + 1) else some k
  go t.events (S.init t.cfg) 0

def allIn (mode : String) (t : Trace) : Bool :=
  let rec go : List Ev → S → Bool
    | [], _ => true
    | e :: es, s => enabledIn mode s e && go es (step s e)
  go t.events (S.init t.cfg)

/-- Every scheduler event runs the oldest pending job. -/
def fifoTrace (t : Trace) : Bool := t.events.all fifoEnabled

end CallCapture
