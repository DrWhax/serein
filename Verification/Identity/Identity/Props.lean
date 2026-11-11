import Identity.Model

/-!
# The properties, as checks on one step

Each check takes the peers `ps` it looks at; `Proofs.lean` proves them for every list of peers
(so for every peer). The explorer and the Swift rig check them on peers 0–2.
-/

namespace Identity

/-- The trust state of peers `ps`: rows, grants and notices. -/
def trust (ps : List Nat) (s : S) : List (Option Row × Option (Nat × Src) × Nat × Nat × Nat) :=
  ps.map fun p => (s.rows p, s.grant p, s.keyChanges p, s.localNotices p, s.remoteNotices p)

/-- A commit step: the state its transaction starts from, and the reviewed batch. -/
def commitOf (s : S) : Ev → Option (S × List Snap)
  | .commit k => s.pending[k]?.map fun xs => ({ s with last := .none, pending := s.pending.eraseIdx k }, xs)
  | .race k p kk =>
    let t := saveKey p kk { s with last := .none }
    t.pending[k]?.map fun xs => ({ t with pending := t.pending.eraseIdx k }, xs)
  | _ => none

/-- **Stale review**: a batch with one identity that no longer validates (a newer key of that
peer, or another account of ours), or a verification of such an identity, changes no trust
state and queues no sync. -/
def staleNoChange (ps : List Nat) (s : S) (e : Ev) (s' : S) : Bool :=
  match commitOf s e with
  | some (t, xs) => xs.all (valid t) || (trust ps s' == trust ps t && s'.jobs == t.jobs)
  | none => match e with
    | .verify i _ => match s.held[i]? with
      | some x => valid s x || (trust ps s' == trust ps s && s'.jobs == s.jobs)
      | none => true
    | _ => true

/-- **Targets the reviewed keys, all or nothing**: a commit changes only rows of reviewed peers,
never their key, and only when that key is the reviewed one; a batch that validates is applied
whole (every reviewed peer approved, and not unverified, under the reviewed key). A
verification changes only the reviewed peer's row, under the reviewed key. -/
def targets (ps : List Nat) (s : S) (e : Ev) (s' : S) : Bool :=
  match commitOf s e with
  | some (t, xs) =>
    (ps.all fun p => t.rows p == s'.rows p ||
      (match t.rows p, s'.rows p with
       | some r, some r' => r.key == r'.key && xs.any (fun x => x.peer == p && x.key == r.key)
       | _, _ => false)) &&
    (!xs.all (valid t) || xs.all fun x => match s'.rows x.peer with
       | some r' => r'.key == x.key && r'.approved && r'.verified != .unverified
       | none => false)
  | none => match e with
    | .verify i b => match s.held[i]? with
      | some x => ps.all fun p => s.rows p == s'.rows p ||
          (p == x.peer && match s.rows p, s'.rows p with
            | some r, some r' => r.key == r'.key && r.key == x.key && (!b || (r'.verified == .verified && r'.approved))
            | _, _ => false)
      | none => true
    | _ => true

/-- **Trust follows the key**: every approved or verified row was granted for exactly the key on
record; when the user granted it, that key had been shown to them. -/
def grantShown (ps : List Nat) (_s : S) (_e : Ev) (s' : S) : Bool :=
  ps.all fun p => match s'.rows p with
    | some r => !(r.approved || r.verified == .verified) || match s'.grant p with
      | some (k, src) => k == r.key && (src != .user || s'.shown.any fun x => x.peer == p && x.key == k)
      | none => false
    | none => true

/-- **Syncs carry reviewed keys**: every Verified sync, queued or sent, carries a key that was
shown to the user for that peer; and a sync job sends exactly what it carries (it never looks
the key up again), while no other step sends one. -/
def syncShown (_s : S) (_e : Ev) (s' : S) : Bool :=
  (s'.jobs ++ s'.sent).all fun j => s'.shown.any fun x => x.peer == j.peer && x.key == j.key

def syncExact (s : S) (e : Ev) (s' : S) : Bool :=
  match e with
  | .sync j => match s.jobs[j]? with
    | some x => s'.sent == s.sent ++ [x]
    | none => s'.sent == s.sent
  | _ => s'.sent == s.sent

/-- **Either key changing invalidates the review**: a new key for a peer leaves its row neither
approved nor verified, drops its grant, and every held safety number with the old key stops
validating; a new account of ours does the same for every safety number of the old one. -/
def keyChangeRevokes (s : S) (e : Ev) (s' : S) : Bool :=
  match e with
  | .key p k => match s.rows p with
    | some r => r.key == k ||
        ((match s'.rows p with
          | some r' => !r'.approved && r'.verified != .verified && s'.grant p == none
          | none => false) &&
         s'.held.all fun x => x.peer != p || x.key != r.key || !valid s' x)
    | none => true
  | .account a k => (a == s.aci && k == s.ourKey) ||
      s'.held.all fun x => !(x.aci == s.aci && x.ourKey == s.ourKey) || !valid s' x
  | _ => true

/-- **No substitution by storage**: after the first sync, a ContactRecord with another key never
replaces the key on record or its trust. -/
def storageNoSubstitute (s : S) (e : Ev) (s' : S) : Bool :=
  match e with
  | .storage p k _ false => match s.rows p with
    | some r => r.key == k || (s'.rows p == s.rows p && s'.grant p == s.grant p)
    | none => true
  | _ => true

def peers : List Nat := [0, 1, 2]

/-- Every property, for the explorer and the rig (peers 0–2). -/
def stepChecks : List (String × (S → Ev → S → Bool)) :=
  [("stale-no-change", staleNoChange peers), ("targets", targets peers), ("grant-shown", grantShown peers),
   ("sync-shown", syncShown), ("sync-exact", syncExact), ("key-change-revokes", keyChangeRevokes),
   ("storage-no-substitute", storageNoSubstitute)]

end Identity
