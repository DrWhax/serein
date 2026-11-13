/-!
# Group authorization and sender-key rotation: the model

A group send of SignalCore (`GroupSender.send`, `sendViaSenderKey`), from the moment it plans to
its submission, while the group's membership and members' device lists change, other sends run,
sends stop part-way and are retried:

* **A membership change takes effect when it is committed to the local group state.** A send
  plans from the membership at that moment (`GroupSendPlan.make`): content goes to members only;
  a group update also reaches those it removes, one by one, never with our sender key.
* Before encrypting, the send rotates our sender key if a device recorded as having it belongs to
  an account that is not among its targets (`SenderKeyInfo.rotation`), then distributes the key to
  target devices lacking it. Planning reserves potential holders in the database before any
  delivery; completions record the captured generation, separately from reservations.
* Every submission — a key distribution, content, an update — is checked against the membership at
  that moment (`MessageSender.authorization`); a refused send plans again.

Accounts and devices are numbers. `holders` (ghost) records every key distribution delivered.
-/

namespace Group

structure Job where
  /-- The recipients the caller asked for (chosen before any upload). -/
  rs : List Nat
  /-- A group update (no content), or content. -/
  update : Bool
  /-- `none`: not planned; `some (targets, outside, pending)`: planned — the members it goes to
  with our key, the non-members a group update reaches one by one, and the targets whose
  devices still need the key. -/
  plan : Option (List Nat × List Nat × List Nat)
  /-- Key generation captured by this send; distribution may finish after a reset. -/
  generation : Nat := 0
  /-- Devices reserved before any delivery; later device refreshes cannot change this snapshot. -/
  reserved : List (Nat × Nat) := []
  deriving DecidableEq, Repr

structure S where
  members : List Nat
  devices : Nat → List Nat
  /-- Our sender key (its generation), whether it must be replaced (expired, a member's identity
  changed), and the devices recorded as having it. -/
  epoch : Nat
  stale : Bool
  /-- Conservative reservations: may include devices whose delivery has not completed. -/
  distributed : List (Nat × Nat)
  jobs : List Job
  /-- Ghost: every key distribution delivered (account, device, generation). -/
  holders : List (Nat × Nat × Nat)
  /-- What went out: (account, kind) with kind `content`, `update` or `key`. -/
  out : List (Nat × String)
  /-- Confirmed deliveries of the current generation, separate from reservations. -/
  delivered : List (Nat × Nat)

def devs (s : S) (as : List Nat) : List (Nat × Nat) := as.flatMap fun a => (s.devices a).map (a, ·)

/-- `SenderKeyInfo.rotation`: reset if a recorded device not among this send's devices belongs to
an account that is not a target; then the key goes to target devices that lack it (all of them
after a reset). -/
def rotation (distributed current : List (Nat × Nat)) (targets : List Nat) : Bool × List (Nat × Nat) :=
  let reset := distributed.any fun d => !current.contains d && !targets.contains d.1
  (reset, if reset then current else current.filter fun d => !distributed.contains d)

/-- `GroupSendPlan.make` (we are not a member here): members, the outside a group update reaches,
and the content dropped. -/
def planOf (members rs : List Nat) (update : Bool) : List Nat × List Nat :=
  let rs := rs.eraseDups
  (rs.filter members.contains, if update then rs.filter (!members.contains ·) else [])

inductive Ev where
  | add (a : Nat)
  | remove (a : Nat)
  /-- A device-list refresh (a 409/410 answer, a profile fetch): `a` now has devices `ds`. -/
  | refresh (a : Nat) (ds : List Nat)
  /-- Our key must be replaced (it expired, or a member's identity key changed). -/
  | expire
  | queue (rs : List Nat) (update : Bool)
  /-- The `k`-th send atomically plans, rotates, and reserves all potential holders. -/
  | plan (k : Nat)
  /-- …distributes the key to its next target (checked at submission). -/
  | distribute (k : Nat)
  /-- …submits: content (or the update) to its targets with our key, and the update to the
  outside one by one (checked at submission). -/
  | submit (k : Nat)
  deriving DecidableEq, Repr

def setIn (xs : List Nat) (x : Nat) (b : Bool) : List Nat := if b then x :: xs.erase x else xs.erase x
def upd {α : Type} (f : Nat → α) (i : Nat) (v : α) : Nat → α := fun x => if x = i then v else f x

def unplan (s : S) (k : Nat) (j : Job) : S := { s with jobs := s.jobs.set k { j with plan := none } }

/-- A send plans: the membership now, its targets (members with devices), the rotation, and who
needs the key. -/
def planJob (s : S) (k : Nat) (j : Job) : S :=
  let p := planOf s.members j.rs j.update
  let targets := p.1.filter fun a => !(s.devices a).isEmpty
  let current := devs s targets
  let r := rotation s.distributed current targets
  let reset := r.1 || s.stale
  let give := if reset then current else current.filter (!s.delivered.contains ·)
  let base := if reset then { s with epoch := s.epoch + 1, stale := false, distributed := [], delivered := [] } else s
  { base with distributed := base.distributed ++ current.filter (!base.distributed.contains ·), jobs := base.jobs.set k { j with plan := some (targets, p.2, (give.map (·.1)).eraseDups), generation := base.epoch, reserved := current } }

def stepCore (s : S) : Ev → S
  | .add a => { s with members := setIn s.members a true }
  | .remove a => { s with members := setIn s.members a false }
  | .refresh a ds => { s with devices := upd s.devices a ds }
  | .expire => { s with stale := true }
  | .queue rs u => { s with jobs := s.jobs ++ [⟨rs, u, none, 0, []⟩] }
  | .plan k => match s.jobs[k]? with
    | some j => planJob s k j
    | none => s
  | .distribute k => match s.jobs[k]? with
    | some j => match j.plan with
      | some (targets, outside, a :: rest) =>
        if s.members.contains a then
          let ds := j.reserved.filter (·.1 == a)
          { s with holders := s.holders ++ ds.map (fun d => (d.1, d.2, j.generation)),
                   out := s.out ++ [(a, "key")],
                   delivered := if j.generation == s.epoch then s.delivered ++ ds.filter (!s.delivered.contains ·) else s.delivered,
                   jobs := s.jobs.set k { j with plan := some (targets, outside, rest) } }
        else unplan s k j
      | _ => s
    | none => s
  | .submit k => match s.jobs[k]? with
    | some j => match j.plan with
      | some (targets, outside, []) =>
        if targets.all s.members.contains && j.generation == s.epoch && !s.stale &&
            s.distributed.all (fun d => s.members.contains d.1) then
          { s with jobs := s.jobs.eraseIdx k,
                   out := s.out ++ targets.map (·, if j.update then "update" else "content") ++ outside.map (·, "update") }
        else unplan s k j
      | _ => s
    | none => s

def step (s : S) (e : Ev) : S := stepCore s e

def S.init (members : List Nat) (devices : Nat → List Nat) : S := ⟨members, devices, 0, false, [], [], [], [], []⟩

inductive Reach : S → Prop where
  | init (m : List Nat) (d : Nat → List Nat) : Reach (S.init m d)
  | step {s : S} (e : Ev) : Reach s → Reach (step s e)

end Group
