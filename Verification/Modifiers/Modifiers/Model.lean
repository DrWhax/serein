/-!
# Message modifiers: the model

What SignalCore does with a modifier — a delete for everyone, an admin delete, an edit, a
reaction, a poll vote or termination, a pin or unpin (`MessageModifiers`):

* it names its target by author and timestamp; an edited message also answers to its edits'
  timestamps (`MessageModifiers.target`);
* the decision (`accepts`) is that of `applyDelete`, `applyEdit`, `applyReaction`,
  `applyPollVote`, `applyPollTerminate`, `applyPin`, `applyUnpin`;
* a modifier whose target is not there is kept (`keep`, at most `pendingLimit`, the sender with
  the most waiting losing its oldest first) and applied when the target arrives (`applyPending`),
  in timestamp order; an applied edit applies those that named its revision;
* a message arriving with the author and timestamp of one already stored is a duplicate and
  dropped (`MessageStore.find`), whatever happened to the stored one;
* a message can be removed here (delete for me, expiry).

Accounts and conversations are numbers: account `a`'s 1:1 conversation is `a`, groups are listed
in the `World`, our note-to-self conversation is `us`. Times are in hours.

`resolved` (ghost) records every modifier that found its target, with the target as it was and
whether it was accepted.
-/

namespace Modifiers

inductive Kind | delete | adminDelete | edit | reaction | vote | terminate | pin | unpin
  deriving DecidableEq, Repr, Inhabited

/-- `ModifierSource`: someone else's message, a sync from another of our devices, this device. -/
inductive Src | other | sync | here
  deriving DecidableEq, Repr, Inhabited

structure Mod where
  kind : Kind
  sender : Nat
  /-- The conversation it was sent in. -/
  conv : Nat
  src : Src
  /-- The target's author and timestamp. -/
  author : Nat
  target : Nat
  /-- The modifier's own timestamp (an edit's: its revision's). -/
  ts : Nat
  server : Nat
  deriving DecidableEq, Repr, Inhabited

structure Row where
  /-- Ghost: which stored message this is (a message removed and received again is another). -/
  gen : Nat
  author : Nat
  sentAt : Nat
  conv : Nat
  server : Nat
  outgoing : Bool
  /-- An outgoing message's recipients it was sent to. -/
  sentTo : List Nat
  viewOnce : Bool
  voice : Bool
  poll : Bool
  terminated : Bool
  giftBadge : Bool
  pinned : Bool
  /-- Deleted for everyone; erased (contents gone: deleted, or a view-once opened). -/
  deleted : Bool
  erased : Bool
  /-- The timestamp of the revision shown (the original's, or the newest edit applied), and
  the edits' timestamps (`edited_messages`). -/
  rev : Nat
  revs : List Nat
  deriving DecidableEq, Repr, Inhabited

structure Group where
  conv : Nat
  members : List Nat
  admins : List Nat
  /-- Attributes editable by members (`accessControl.attributes == MEMBER`). -/
  openAttrs : Bool
  deriving DecidableEq, Repr

structure World where
  us : Nat
  groups : List Group
  /-- Blocked accounts (and so their 1:1 conversations) and blocked groups. -/
  blocked : List Nat
  blockedGroups : List Nat
  deriving DecidableEq, Repr

/-- `deleteMaxAge` + `deleteGracePeriod` and `maxEditAge` (remote config unset), in hours. -/
def deleteWindow : Nat := 48
def editWindow : Nat := 48
/-- `pendingLimit`, `pendingMaxAge` (hours). -/
def pendingLimit : Nat := 500
def pendingMaxAge : Nat := 48

def World.group (w : World) (c : Nat) : Option Group := w.groups.find? (·.conv == c)

/-- `senderBelongs` (`isValidSenderAciForConversation`). -/
def belongs (w : World) (s c : Nat) : Bool :=
  s == w.us || match w.group c with
    | some g => g.members.contains s
    | none => c == s

/-- `MessageModifiers.isBlocked`. -/
def blockedIn (w : World) (c s : Nat) : Bool :=
  w.blocked.contains s || match w.group c with
    | some _ => w.blockedGroups.contains c
    | none => w.blocked.contains c

def isAdmin (w : World) (c s : Nat) : Bool :=
  match w.group c with
  | some g => g.admins.contains s
  | none => false

/-- `canSenderEditGroupAttributes`. -/
def canEditAttrs (w : World) (c s : Nat) : Bool :=
  match w.group c with
  | some g => g.members.contains s && (g.admins.contains s || g.openAttrs)
  | none => true

def within (a b n : Nat) : Bool := a - b ≤ n && b - a ≤ n

/-- `inTargetConversation`: someone else's modifier is sent in its target's conversation. -/
def inConv (r : Row) (m : Mod) : Bool := r.conv == m.conv || m.src != .other

/-- For our outgoing target: the sender was sent it (`wasSent`). -/
def sentToSender (r : Row) (m : Mod) : Bool := !r.outgoing || r.sentTo.contains m.sender

/-- `editable`. -/
def editable (r : Row) : Bool := !r.deleted && !r.erased && !r.viewOnce && !r.voice

/-- An edit's checks other than its order: by the author, in the message's conversation (any
device), on time and not blocked unless ours. -/
def editValid (w : World) (r : Row) (m : Mod) : Bool :=
  editable r && m.sender == r.author && r.conv == m.conv && (within m.server r.server editWindow || m.src != .other) &&
    (m.src != .other || !blockedIn w r.conv m.sender)

/-- `pinnable` (`validatePinnedMessageTarget`). -/
def pinnable (w : World) (r : Row) (m : Mod) : Bool :=
  !r.deleted && !r.giftBadge && inConv r m && !blockedIn w r.conv m.sender && belongs w m.sender r.conv
    && canEditAttrs w r.conv m.sender

/-- The decision, once the target is found. -/
def accepts (w : World) (r : Row) (m : Mod) : Bool :=
  match m.kind with
  | .delete => !r.deleted && inConv r m && r.conv != w.us && m.sender == r.author && within m.server r.server deleteWindow
  | .adminDelete => !r.deleted && inConv r m && r.conv != w.us && isAdmin w r.conv m.sender && within m.server r.server deleteWindow
  | .edit => editValid w r m && r.rev < m.ts
  | .reaction => !r.deleted && !r.viewOnce &&
      (m.sender == w.us || (r.conv == m.conv && belongs w m.sender r.conv && !blockedIn w r.conv m.sender && sentToSender r m))
  | .vote => !r.deleted && r.poll && !r.terminated && belongs w m.sender r.conv &&
      (m.sender == w.us || (inConv r m && !blockedIn w r.conv m.sender && sentToSender r m))
  | .terminate => r.poll && !r.terminated && m.sender == r.author && inConv r m
  | .pin => pinnable w r m
  | .unpin => pinnable w r m && r.pinned

/-- What an accepted modifier does to its target (`erase` for the deletes). -/
def effect (r : Row) (m : Mod) : Row :=
  match m.kind with
  | .delete | .adminDelete => { r with deleted := true, erased := true, revs := [], pinned := false, poll := false, terminated := false }
  | .edit => { r with rev := m.ts, revs := m.ts :: r.revs }
  | .terminate => { r with terminated := true }
  | .pin => { r with pinned := true }
  | .unpin => { r with pinned := false }
  | .reaction | .vote => r

/-- The target: the same author, and the timestamp is the message's or one of its edits'. -/
def resolves (r : Row) (m : Mod) : Bool := r.author == m.author && (r.sentAt == m.target || r.revs.contains m.target)

/-- `MessageModifiers.target`: by the message's own timestamp first, then its edits'. -/
def lookup (rows : List Row) (m : Mod) : Option Row :=
  (rows.find? fun r => r.author == m.author && r.sentAt == m.target) <|>
    (rows.find? fun r => r.author == m.author && r.revs.contains m.target)

/-! ## The waiting list -/

structure Entry where
  mod : Mod
  /-- When it was kept. -/
  stored : Nat
  deriving DecidableEq, Repr, Inhabited

def count (l : List Entry) (s : Nat) : Nat := (l.filter (·.mod.sender == s)).length

/-- Scanning in order, the first entry whose sender has the most entries. -/
def heaviestFrom (c : Entry → Nat) : Option Entry → List Entry → Option Entry
  | b, [] => b
  | none, e :: es => heaviestFrom c (some e) es
  | some b, e :: es => heaviestFrom c (if c b < c e then some e else some b) es

def heaviest (l : List Entry) : Option Entry := heaviestFrom (fun e => count l e.mod.sender) none l

/-- One eviction: the oldest entry of the sender with the most waiting. -/
def evict (l : List Entry) : List Entry :=
  match heaviest l with
  | some b => l.erase b
  | none => l

def trim (limit : Nat) : Nat → List Entry → List Entry
  | 0, l => l
  | n + 1, l => if limit < l.length then trim limit n (evict l) else l

/-- `MessageModifiers.kept`: entries older than `pendingMaxAge` go, `e` joins, then evictions
down to the limit. -/
def kept (l : List Entry) (e : Entry) (limit now : Nat) : List Entry :=
  let l' := l.filter (fun x => now - x.stored ≤ pendingMaxAge) ++ [e]
  trim limit l'.length l'

/-! ## The receiver -/

structure S where
  rows : List Row
  pending : List Entry
  next : Nat
  now : Nat
  /-- Ghost: every modifier that found its target: the target as it was, and the decision. -/
  resolved : List (Mod × Row × Bool)
  /-- Ghost: a nested application ran out of fuel (never, if the fuel suffices). -/
  exhausted : Bool
  deriving Repr

def S.init : S := ⟨[], [], 0, 0, [], false⟩

def targets (k : Nat × Nat) (e : Entry) : Bool := e.mod.author == k.1 && e.mod.target == k.2

/-- Applies the entries waiting for `k` (author, timestamp), taken off the list first, in
timestamp order (`applyPending`). -/
def sortTs (l : List Entry) : List Entry := l.mergeSort fun a b => a.mod.ts ≤ b.mod.ts

def update (rows : List Row) (g : Nat) (f : Row → Row) : List Row := rows.map fun x => if x.gen == g then f x else x

/-- `MessageModifiers.apply`: find the target; none — keep it (`keep`) or drop it; found —
decide, apply, and after an edit apply what waited for its revision. -/
def applyMod (w : World) : Nat → S → Mod → Bool → S
  | 0, s, _, _ => { s with exhausted := true }
  | n + 1, s, m, keep =>
    match lookup s.rows m with
    | none => if keep then { s with pending := kept s.pending ⟨m, s.now⟩ pendingLimit s.now } else s
    | some r =>
      let ok := accepts w r m
      let s1 := { s with resolved := (m, r, ok) :: s.resolved }
      if ok then
        let s2 := { s1 with rows := update s1.rows r.gen (effect · m) }
        if m.kind == .edit then
          let k := (m.sender, m.ts)
          (sortTs (s2.pending.filter (targets k))).foldl (fun s e => applyMod w n s e.mod false)
            { s2 with pending := s2.pending.filter (!targets k ·) }
        else s2
      else s1

inductive Ev
  /-- A message arrives (its `gen`, `rev`, `revs`, flags set on arrival are ignored). -/
  | recv (r : Row)
  /-- A modifier arrives, or is made here. -/
  | mod (m : Mod)
  /-- The message is removed here (delete for me, expiry). -/
  | forget (author sentAt : Nat)
  | tick (n : Nat)
  deriving Repr

def fresh (s : S) (r : Row) : Row :=
  { r with gen := s.next, rev := r.sentAt, revs := [], deleted := false, erased := false, pinned := false, terminated := false }

def step (w : World) (s : S) : Ev → S
  | .recv r =>
    if s.rows.any (fun x => x.author == r.author && x.sentAt == r.sentAt) then s
    else
      let r := fresh s r
      let k := (r.author, r.sentAt)
      let s1 := { s with rows := s.rows ++ [r], next := s.next + 1 }
      (sortTs (s1.pending.filter (targets k))).foldl (fun s e => applyMod w (s1.pending.length + 1) s e.mod false)
        { s1 with pending := s1.pending.filter (!targets k ·) }
  | .mod m => applyMod w (s.pending.length + 2) s m (m.src != .here)
  | .forget a t => { s with rows := s.rows.filter fun x => !(x.author == a && x.sentAt == t) }
  | .tick n => { s with now := s.now + n }

def run (w : World) (s : S) (evs : List Ev) : S := evs.foldl (step w) s

inductive Reach (w : World) : S → Prop
  | init : Reach w S.init
  | step {s} (e : Ev) : Reach w s → Reach w (step w s e)

/-- Rows by their ghost identity. -/
def S.get (s : S) (g : Nat) : Option Row := s.rows.find? (·.gen == g)

end Modifiers
