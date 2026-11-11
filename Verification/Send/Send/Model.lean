/-!
# Send authorization: the model

What may reach the transport (`SocketManager`'s request, handed to libsignal right after the
`authorize` check), as SignalCore decides it:

* `MessageSender.authorization`, evaluated when a send starts and again immediately before each
  submission: a direct payload's recipient must not be blocked (by service id or by number); a
  group payload's group must not be blocked; and the messages it names must still exist,
  unerased, unless it only retracts them (`OutgoingPayload.onlyRetracts`).
* `GroupSender`'s recipients: the group's members, without us and without contacts we blocked
  (upstream `getValidRecipients` / `getMessageRecipients`), chosen when the send starts.

The submission boundary is the authorization read just before the request goes to libsignal.
What was submitted before a block or a deletion is not recalled.
-/

namespace Send

/-- A DataMessage, as far as authorization reads it: whether it deletes (`delete` or
`adminDelete`), and whether it has any field beyond the delete and the envelope fields every
message has (timestamp, profile key, group context) — a body, attachments, a quote, a reaction,
anything. -/
structure Data where
  retract : Bool
  extra : Bool
  deriving DecidableEq, Repr

/-- A payload's `Content`. -/
inductive Content where
  /-- `dataMessage`. -/
  | data (d : Data)
  /-- `syncMessage.sent`: a transcript of `msg`, or (without one) a recipient update; `story`
  and `edit`: it carries a story or an edit. -/
  | sent (msg : Option Data) (update : Bool) (story : Bool) (edit : Bool)
  /-- `editMessage`, `storyMessage`: message content. -/
  | content
  /-- Receipts, typing, calls, null messages, other syncs: no message content. -/
  | other
  deriving DecidableEq, Repr

/-- It carries message content. -/
def Content.carries : Content → Bool
  | .data d => d.extra
  | .sent m _ story edit => (m.map (·.extra)).getD false || story || edit
  | .content => true
  | .other => false

/-- A DataMessage that only deletes. -/
def Data.onlyDeletes (d : Data) : Bool := d.retract && !d.extra

/-- `OutgoingPayload.onlyRetracts`: a delete for everyone, its transcript, or a recipient update. -/
def Content.onlyRetracts : Content → Bool
  | .data d => d.onlyDeletes
  | .sent (some d) _ story edit => d.onlyDeletes && !story && !edit
  | .sent none update story edit => update && !story && !edit
  | _ => false

/-- A send's target. -/
inductive Target where
  | direct (p : Nat)
  | self
  | group (g : Nat)
  deriving DecidableEq, Repr

inductive Msg | live | erased | gone
  deriving DecidableEq, Repr

structure S where
  /-- Contacts blocked by service id, and by number (contact `p`'s number is `p`). -/
  blockedIds : List Nat
  blockedNums : List Nat
  blockedGroups : List Nat
  msgs : Nat → Msg
  members : Nat → List Nat

def S.blocked (s : S) (p : Nat) : Bool := s.blockedIds.contains p || s.blockedNums.contains p

/-- `MessageSender.authorization(to:groupId:messageIds:retracting:)`. -/
def authorized (s : S) (t : Target) (c : Content) (ids : List Nat) : Bool :=
  (match t with
   | .direct p => !s.blocked p
   | .self => true
   | .group g => !s.blockedGroups.contains g) &&
  (c.onlyRetracts || ids.all fun m => s.msgs m == .live)

/-- `GroupSender`'s recipients: the members we have not blocked (we are not a member here). -/
def recipients (s : S) (g : Nat) : List Nat := (s.members g).filter fun p => !s.blocked p

-- ## The pipeline

inductive Phase where
  | queued
  /-- Started: the first check passed; a group send's recipients are chosen. -/
  | started (to : List Nat)
  deriving DecidableEq, Repr

structure Job where
  target : Target
  content : Content
  ids : List Nat
  phase : Phase
  deriving DecidableEq, Repr

/-- What went out: the target, content, named messages, and (for a group) its recipients. -/
structure Out where
  target : Target
  content : Content
  ids : List Nat
  to : List Nat
  deriving DecidableEq, Repr

structure P where
  s : S
  jobs : List Job
  out : List Out
  refused : Nat

inductive Ev where
  | queue (t : Target) (c : Content) (ids : List Nat)
  /-- The `j`-th job starts (its first check; a group send chooses its recipients). -/
  | start (j : Nat)
  /-- The `j`-th job reaches the transport: checked again, then submitted or refused. -/
  | submit (j : Nat)
  | block (p : Nat) (b : Bool)
  | blockNumber (p : Nat) (b : Bool)
  | blockGroup (g : Nat) (b : Bool)
  /-- A message is erased (deleted for everyone) or removed (deleted, or a story deleted). -/
  | erase (m : Nat)
  | remove (m : Nat)
  deriving DecidableEq, Repr

def setIn (xs : List Nat) (x : Nat) (b : Bool) : List Nat := if b then x :: xs.erase x else xs.erase x

def upd {α : Type} (f : Nat → α) (i : Nat) (v : α) : Nat → α := fun x => if x = i then v else f x

def stepCore (p : P) : Ev → P
  | .queue t c ids => { p with jobs := p.jobs ++ [⟨t, c, ids, .queued⟩] }
  | .start j => match p.jobs[j]? with
    | some x =>
      if x.phase != .queued then p
      else if authorized p.s x.target x.content x.ids then
        let to := match x.target with | .group g => recipients p.s g | _ => []
        { p with jobs := p.jobs.set j { x with phase := .started to } }
      else { p with jobs := p.jobs.eraseIdx j, refused := p.refused + 1 }
    | none => p
  | .submit j => match p.jobs[j]? with
    | some ⟨t, c, ids, .started to⟩ =>
      if authorized p.s t c ids then { p with jobs := p.jobs.eraseIdx j, out := p.out ++ [⟨t, c, ids, to⟩] }
      else { p with jobs := p.jobs.eraseIdx j, refused := p.refused + 1 }
    | _ => p
  | .block q b => { p with s := { p.s with blockedIds := setIn p.s.blockedIds q b } }
  | .blockNumber q b => { p with s := { p.s with blockedNums := setIn p.s.blockedNums q b } }
  | .blockGroup g b => { p with s := { p.s with blockedGroups := setIn p.s.blockedGroups g b } }
  | .erase m => { p with s := { p.s with msgs := upd p.s.msgs m .erased } }
  | .remove m => { p with s := { p.s with msgs := upd p.s.msgs m .gone } }

def step (p : P) (e : Ev) : P := stepCore p e

end Send
