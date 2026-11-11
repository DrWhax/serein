/-!
# Identity-key trust and the safety-number review: the model

A pure model of SignalCore's identity store (`ProtocolStore.saveIdentity`, `setVerified`,
`setApproval`, `needsApproval`), of the two user actions that change trust
(`Messenger.approveIdentities` and `Messenger.setVerified`, each one database transaction), of the
storage service's ContactRecord merge (`StorageRecords.mergeContact`, identity part), and of the
Verified syncs those actions queue.

Peers, keys and our accounts are small numbers; the Swift rig maps them to service ids and
generated identity keys. `ghost` fields record what the user was shown and who granted trust;
no transition reads them.
-/

namespace Identity

/-- `VerifiedStatus`. -/
inductive VS | dflt | verified | unverified
  deriving DecidableEq, Repr

/-- One `identityKeys` row (`ProtocolStore.IdentityRow`). `recent`: its timestamp is within
`approvalWindow` of now. -/
structure Row where
  key : Nat
  firstUse : Bool
  recent : Bool
  verified : VS
  /-- `nonblockingApproval` -/
  approved : Bool
  deriving DecidableEq, Repr

/-- A safety number the UI holds (`ReviewedIdentity`): our ACI and identity key, their id and
the key it was computed from. -/
structure Snap where
  aci : Nat
  ourKey : Nat
  peer : Nat
  key : Nat
  deriving DecidableEq, Repr

/-- A queued Verified sync (`ConversationJob.verifiedSync`), or one sent. -/
structure Sync where
  peer : Nat
  key : Nat
  verified : Bool
  deriving DecidableEq, Repr

/-- Who granted the current approval or verification of a key (ghost). -/
inductive Src | user | sync
  deriving DecidableEq, Repr

/-- The result of the last user action. -/
inductive Res | none | ok | stale
  deriving DecidableEq, Repr

structure S where
  /-- Our account: ACI and identity key (the `Messenger`'s `account`). -/
  aci : Nat
  ourKey : Nat
  rows : Nat → Option Row
  /-- Safety numbers the UI holds, in the order they were shown. -/
  held : List Snap
  /-- Confirmed reviews whose commit (`approveIdentities`, in its task) has not run yet. -/
  pending : List (List Snap)
  /-- Queued Verified syncs. -/
  jobs : List Sync
  /-- Verified syncs sent to our devices. -/
  sent : List Sync
  keyChanges : Nat → Nat
  localNotices : Nat → Nat
  remoteNotices : Nat → Nat
  last : Res
  /-- Ghost: every safety number ever shown. -/
  shown : List Snap
  /-- Ghost: the key the current approval or verification of each peer was granted for. -/
  grant : Nat → Option (Nat × Src)

def S.init : S where
  aci := 0
  ourKey := 0
  rows := fun _ => none
  held := []
  pending := []
  jobs := []
  sent := []
  keyChanges := fun _ => 0
  localNotices := fun _ => 0
  remoteNotices := fun _ => 0
  last := .none
  shown := []
  grant := fun _ => none

def upd {α : Type} (f : Nat → α) (i : Nat) (v : α) : Nat → α := fun x => if x = i then v else f x
def bump (f : Nat → Nat) (i : Nat) : Nat → Nat := upd f i (f i + 1)

/-- `isNonBlockingApprovalRequired` / `isUntrusted`. -/
def Row.needsApproval (r : Row) : Bool := !r.firstUse && r.recent && !r.approved

/-- What `identitiesNeedingApproval` lists: unverified, or untrusted. -/
def Row.needsReview (r : Row) : Bool := r.verified == .unverified || r.needsApproval

/-- `isTrustedForSending` for the key on record. -/
def Row.trusted (r : Row) : Bool := r.verified != .unverified && !r.needsApproval

-- ## The identity store

/-- `ProtocolStore.saveIdentity(p, k)`: a message, pre-key bundle or profile brought key `k`. -/
def saveKey (p k : Nat) (s : S) : S :=
  match s.rows p with
  | none => { s with rows := upd s.rows p (some ⟨k, true, true, .dflt, false⟩) }
  | some r =>
    if r.key != k then
      let marked := r.verified == .verified || r.verified == .unverified
      { s with rows := upd s.rows p (some ⟨k, false, true, if marked then .unverified else .dflt, false⟩),
               keyChanges := bump s.keyChanges p, grant := upd s.grant p none }
    else s

/-- `ReviewedIdentity.validate`: our account is the one the safety number was computed for, and
the key on record is the one it shows. -/
def valid (s : S) (x : Snap) : Bool :=
  x.aci == s.aci && x.ourKey == s.ourKey &&
    (match s.rows x.peer with | some r => r.key == x.key | none => false)

/-- One identity of `applyApproval`: an unverified contact goes back to the default state (notice,
queued Verified sync with the reviewed key), then the key on record is approved. -/
def approveOne (s : S) (x : Snap) : S :=
  match s.rows x.peer with
  | none => s
  | some r =>
    let s := if r.verified == .unverified then
        { s with rows := upd s.rows x.peer (some { r with verified := .dflt }),
                 localNotices := bump s.localNotices x.peer, jobs := s.jobs ++ [⟨x.peer, x.key, false⟩] }
      else s
    match s.rows x.peer with
    | some r => { s with rows := upd s.rows x.peer (some { r with approved := true }),
                         grant := upd s.grant x.peer (some (x.key, .user)) }
    | none => s

/-- `approveIdentities`: one transaction; every identity is validated before anything changes. -/
def approve (xs : List Snap) (s : S) : S :=
  if xs.all (valid s) then { xs.foldl approveOne s with last := .ok } else { s with last := .stale }

/-- `setVerified(identity, b)`: one transaction. -/
def setVer (x : Snap) (b : Bool) (s : S) : S :=
  if !valid s x then { s with last := .stale }
  else match s.rows x.peer with
  | none => { s with last := .ok }
  | some r =>
    let st := if b then VS.verified else .dflt
    if r.verified == st then { s with last := .ok }
    else
      let r' := if b then { r with verified := st, firstUse := false, approved := true } else { r with verified := st }
      { s with rows := upd s.rows x.peer (some r'), localNotices := bump s.localNotices x.peer,
               jobs := s.jobs ++ [⟨x.peer, x.key, b⟩],
               grant := if b then upd s.grant x.peer (some (x.key, .user)) else s.grant, last := .ok }

/-- `mergeContact`'s identity part (`updateIdentityAfterSync`): a ContactRecord from our storage
service with key `k` and state `v`. It takes the key only on the first sync, when we have none,
or when it is the key we have; it then needs no approval (it comes from our own devices). -/
def storage (p k : Nat) (v : VS) (first : Bool) (s : S) : S :=
  let lo := s.rows p
  let keysMatch := match lo with | some r => r.key == k | none => false
  if first || lo.isNone || keysMatch then
    let oldV := match lo with | some r => r.verified | none => .dflt
    let s := if lo.isSome && !keysMatch then { s with keyChanges := bump s.keyChanges p } else s
    let s := if !keysMatch || oldV != v then
        { s with rows := upd s.rows p (some ⟨k, lo.isNone, true, v, true⟩), grant := upd s.grant p (some (k, .sync)) }
      else s
    let became := v == .verified && (lo.isNone || oldV != .verified)
    let noLonger := v != .verified && lo.isSome && oldV == .verified
    if !(lo.isSome && !keysMatch) && (became || noLonger) then { s with remoteNotices := bump s.remoteNotices p } else s
  else s

-- ## Events

inductive Ev where
  /-- The UI shows `p`'s safety number (`safetyNumber(with:)`), computed from the key on record. -/
  | view (p : Nat)
  /-- "Send anyway" on a review of the held safety numbers at these indices: the commit task. -/
  | confirm (is : List Nat)
  /-- The `k`-th confirmed review's task runs `approveIdentities`. -/
  | commit (k : Nat)
  /-- The same, racing a key change of `p` to `key` (Swift: started while that write holds the
  database; the model: the key change, then the commit). -/
  | race (k p key : Nat)
  /-- The safety-number sheet's toggle: `setVerified(held[i], b)`. -/
  | verify (i : Nat) (b : Bool)
  /-- `saveIdentity(p, k)`. -/
  | key (p k : Nat)
  /-- Our account is now ACI `a` with identity key `k` (re-link, re-registration). -/
  | account (a k : Nat)
  /-- `p`'s approval window passes. -/
  | window (p : Nat)
  /-- A ContactRecord merge. -/
  | storage (p k : Nat) (v : VS) (first : Bool)
  /-- The `j`-th queued Verified sync job runs. -/
  | sync (j : Nat)
  deriving DecidableEq, Repr

def showSnap (p : Nat) (s : S) : S :=
  match s.rows p with
  | some r => let x : Snap := ⟨s.aci, s.ourKey, p, r.key⟩; { s with held := s.held ++ [x], shown := s.shown ++ [x] }
  | none => s

def commitAt (k : Nat) (s : S) : S :=
  match s.pending[k]? with
  | some xs => approve xs { s with pending := s.pending.eraseIdx k }
  | none => s

def stepCore (s : S) : Ev → S
  | .view p => showSnap p s
  | .confirm is => { s with pending := s.pending ++ [is.filterMap (s.held[·]?)] }
  | .commit k => commitAt k s
  | .race k p kk => commitAt k (saveKey p kk s)
  | .verify i b => match s.held[i]? with | some x => setVer x b s | none => s
  | .key p k => saveKey p k s
  | .account a k => { s with aci := a, ourKey := k }
  | .window p => match s.rows p with
    | some r => { s with rows := upd s.rows p (some { r with recent := false }) }
    | none => s
  | .storage p k v f => storage p k v f s
  | .sync j => match s.jobs[j]? with
    | some x => { s with jobs := s.jobs.eraseIdx j, sent := s.sent ++ [x] }
    | none => s

def step (s : S) (e : Ev) : S := stepCore { s with last := .none } e

def run (s : S) : List Ev → S
  | [] => s
  | e :: es => run (step s e) es

inductive Reach : S → Prop where
  | init : Reach S.init
  | step {s : S} (e : Ev) : Reach s → Reach (step s e)

end Identity
