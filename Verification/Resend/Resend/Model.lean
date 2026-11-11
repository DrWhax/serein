/-!
# Retry and resend authorization: the model

A DecryptionErrorMessage from a requester's device about a message we sent at a timestamp asks
us to send it again (`Messenger.resend`). The answer is a database read, `SendLog.answer`:

* the **send log** (`SendLog.record`) keeps, per payload (timestamp and content), the devices it
  was delivered to; a delivery receipt removes a device (`deleteRecipient`); payloads older
  than a day go (`prune`);
* the lookup (`SendLog.find`) takes the oldest payload at that timestamp logged as delivered to
  **that requester's that device**, and not older than a day;
* a story to distribution lists goes back only while the requester is still a member of a list
  (not a block list, not deleted) one of our stories at that timestamp went to (`storyListed`);
* one (requester, device, timestamp) is answered at most `retryLimit` times (`RetryLimiter`);
* the answer: the payload, to the requester; a NullMessage (it carries nothing) when nothing is
  logged; nothing at all past the limit or for a story the requester may no longer see.

What the resend then passes through — `MessageSender.authorization` (blocked contacts, messages
removed since) — is the send slice's subject.

Accounts, devices, contents and lists are numbers. Times are in hours. `delivered` and `out`
(ghost) record every delivery a send made and every answer.
-/

namespace Resend

def maxAge : Nat := 24
def retryLimit : Nat := 5

structure World where
  /-- Contents that are stories to distribution lists. -/
  story : List Nat
  deriving DecidableEq, Repr

structure Payload where
  id : Nat
  ts : Nat
  content : Nat
  deriving DecidableEq, Repr

/-- `sendLogRecipients`: payload, recipient, device. -/
structure Row where
  id : Nat
  recipient : Nat
  device : Nat
  deriving DecidableEq, Repr

structure SList where
  id : Nat
  block : Bool
  deleted : Bool
  members : List Nat
  deriving DecidableEq, Repr

inductive Answer
  | resend (p : Payload)
  | null
  | nothing
  deriving DecidableEq, Repr

/-- An answer given: who asked (requester, device, timestamp), to whom it went, what it carried
(`none`: a NullMessage). -/
structure Out where
  requester : Nat
  device : Nat
  ts : Nat
  dest : Nat
  carried : Option (Nat × Nat)
  deriving DecidableEq, Repr

structure S where
  payloads : List Payload
  rows : List Row
  next : Nat
  now : Nat
  /-- Our stories: (timestamp, list). -/
  stories : List (Nat × Nat)
  lists : List SList
  /-- `RetryLimiter`: requests so far per (requester, device, timestamp). -/
  counts : List ((Nat × Nat × Nat) × Nat)
  /-- Ghost: every delivery a send made: (timestamp, content, account, device). -/
  delivered : List (Nat × Nat × Nat × Nat)
  out : List Out
  deriving Repr

def S.init : S := ⟨[], [], 1, 0, [], [], [], [], []⟩

/-- `prune`: payloads older than a day go, with their rows. -/
def prune (s : S) (now : Nat) : S :=
  let payloads := s.payloads.filter (now ≤ ·.ts + maxAge)
  { s with payloads, rows := s.rows.filter fun r => payloads.any (·.id == r.id) }

/-- `SendLog.record`: the payload (shared by timestamp and content), a row per device, then
pruning. -/
def payloadFor (s : S) (ts content : Nat) : S × Nat :=
  match s.payloads.find? (fun p => p.ts == ts && p.content == content) with
  | some p => (s, p.id)
  | none => ({ s with payloads := s.payloads ++ [(⟨s.next, ts, content⟩ : Payload)], next := s.next + 1 }, s.next)

/-- `INSERT OR IGNORE INTO sendLogRecipients`. -/
def addRow (id recipient : Nat) (rows : List Row) (d : Nat) : List Row :=
  if rows.contains ⟨id, recipient, d⟩ then rows else rows ++ [⟨id, recipient, d⟩]

def record (s : S) (ts content recipient : Nat) (devices : List Nat) : S :=
  let s1 := (payloadFor s ts content).1
  let id := (payloadFor s ts content).2
  prune { s1 with rows := devices.foldl (addRow id recipient) s1.rows, delivered := s1.delivered ++ devices.map (ts, content, recipient, ·) } s1.now

/-- `deleteRecipient`, after a delivery receipt. -/
def receipt (s : S) (recipient device ts : Nat) : S :=
  let atTs := s.payloads.filter (·.ts == ts)
  let rows := s.rows.filter fun r => !(r.recipient == recipient && r.device == device && atTs.any (·.id == r.id))
  { s with rows, payloads := s.payloads.filter fun p => !(p.ts == ts && !rows.any (·.id == p.id)) }

/-- `SendLog.find`. -/
def find (s : S) (requester device ts : Nat) : Option Payload :=
  s.payloads.find? fun p => p.ts == ts && s.now ≤ p.ts + maxAge && s.rows.contains ⟨p.id, requester, device⟩

/-- `storyListed`. -/
def listed (s : S) (requester ts : Nat) : Bool :=
  s.stories.any fun (t, l) => t == ts && s.lists.any fun L => L.id == l && !L.block && !L.deleted && L.members.contains requester

/-- `SendLog.answer`. -/
def answer (w : World) (s : S) (requester device ts answered : Nat) : Answer :=
  if retryLimit ≤ answered then .nothing
  else match find s requester device ts with
    | none => .null
    | some p => if w.story.contains p.content && !listed s requester ts then .nothing else .resend p

def countOf (s : S) (k : Nat × Nat × Nat) : Nat := ((s.counts.find? (·.1 == k)).map (·.2)).getD 0

def bump (counts : List ((Nat × Nat × Nat) × Nat)) (k : Nat × Nat × Nat) (n : Nat) : List ((Nat × Nat × Nat) × Nat) :=
  (k, n + 1) :: counts.filter (·.1 != k)

inductive Ev
  | send (ts content recipient : Nat) (devices : List Nat)
  | receipt (recipient device ts : Nat)
  | tick (n : Nat)
  | story (ts list : Nat)
  | setList (l : SList)
  /-- A DecryptionErrorMessage from `requester`'s `device` about our message at `ts`. -/
  | retry (requester device ts : Nat)
  deriving Repr

def step (w : World) (s : S) : Ev → S
  | .send ts c r ds => record s ts c r ds
  | .receipt r d ts => receipt s r d ts
  | .tick n => { s with now := s.now + n }
  | .story ts l => { s with stories := s.stories ++ [(ts, l)] }
  | .setList l => { s with lists := l :: s.lists.filter (·.id != l.id) }
  | .retry a d ts =>
    let k := (a, d, ts)
    let n := countOf s k
    let s := { s with counts := bump s.counts k n }
    match answer w s a d ts n with
    | .resend p => { s with out := s.out ++ [⟨a, d, ts, a, some (p.ts, p.content)⟩] }
    | .null => { s with out := s.out ++ [⟨a, d, ts, a, none⟩] }
    | .nothing => s

def run (w : World) (s : S) (evs : List Ev) : S := evs.foldl (step w) s

inductive Reach (w : World) : S → Prop
  | init : Reach w S.init
  | step {s} (e : Ev) : Reach w s → Reach w (step w s e)

end Resend
