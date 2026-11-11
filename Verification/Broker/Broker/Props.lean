import Broker.Model

/-! # The properties

Each as a `Prop` (proved in `Proofs.lean` for every reachable state) and as a `Bool` the
explorer evaluates after every step of random runs (`checks`). -/

namespace Broker

/-- Every request's session exists and is on the request's channel. -/
def Shaped (s : St) : Prop :=
  ∀ q ∈ s.reqs, ∀ id, q.sess = some id → ∃ x, s.sess[id]? = some x ∧ x.ch = q.kind.ch

/-- A channel's live session is on it and has not ended. -/
def LiveOpen (s : St) : Prop := ∀ (c : Ch) (id : Nat), s.live c = some id → s.sess[id]? = some ⟨c, false⟩

/-- A session that has not ended is its channel's live one. -/
def OneOpen (s : St) : Prop := ∀ (id : Nat) (x : Sess), s.sess[id]? = some x → x.ended = false → s.live x.ch = some id

/-- **Nothing waits on a session that has ended**: an outstanding request is on a session that
is up, and its handler has not run. -/
def PendingLive (s : St) : Prop :=
  ∀ q ∈ s.reqs, q.status = .pending → q.answered = false ∧ ∃ id, q.sess = some id ∧ ended s id = false

/-- A lost request was on a session that ended. -/
def LostEnded (s : St) : Prop :=
  ∀ q ∈ s.reqs, q.status = .failed .lost → ∃ id x, q.sess = some id ∧ s.sess[id]? = some x ∧ x.ended = true

/-- A delivered reply's request was answered. -/
def Answered (s : St) : Prop := ∀ (m : Nat) (r : Reply), (m, r) ∈ s.delivered → ∃ q, s.reqs[m]? = some q ∧ q.answered = true

/-- **A request succeeds only with a reply to its own message, decoded and validated as its own.** -/
def OkOwn (s : St) : Prop :=
  ∀ (m : Nat) (q : Req) (v : Val), s.reqs[m]? = some q → q.status = .ok v → ∃ r, (m, r) ∈ s.delivered ∧ (accept q.kind r).1 = .ok v

/-- **No helper session is left behind**: a session a delivered reply named for its request is
the caller's, or the client released it. -/
def NoLeak (s : St) : Prop :=
  ∀ (m : Nat) (r : Reply) (q : Req) (u : Nat), (m, r) ∈ s.delivered → s.reqs[m]? = some q → late q.kind r = some u →
    q.status = .ok (.session u) ∨ Kind.release q.kind.ch u ∈ s.reqs.map Req.kind

/-- **A release goes to the helper that named the session**, and names only what it named. -/
def ReleaseNamed (s : St) : Prop :=
  ∀ (j : Nat) (q : Req) (c : Ch) (u : Nat), s.reqs[j]? = some q → q.kind = Kind.release c u →
    ∃ m r p, (m, r) ∈ s.delivered ∧ s.reqs[m]? = some p ∧ p.kind.ch = c ∧ late p.kind r = some u

def timedOutCount (s : St) (i : Nat) : Nat :=
  s.reqs.countP fun q => decide (q.kind.input = some i ∧ q.status = .failed .timedOut)

/-- Whether a request with input `i` was lost when session `id` ended. -/
def lostOn (s : St) (i id : Nat) : Bool :=
  s.reqs.any fun q => decide (q.sess = some id ∧ q.kind.input = some i ∧ q.status = .failed .lost)

def lostSessions (s : St) (i : Nat) : Nat := (List.range s.sess.length).countP (lostOn s i)

/-- **Strikes**: two per timeout of a request with the input, one per ended session a request with
it was in flight on (however many were). -/
def StrikesExact (s : St) : Prop := ∀ i, s.strikes i = quarantineAt * timedOutCount s i + lostSessions s i

/-- Everything, inductively. -/
def Inv (s : St) : Prop :=
  Shaped s ∧ LiveOpen s ∧ OneOpen s ∧ PendingLive s ∧ LostEnded s ∧ Answered s ∧ OkOwn s ∧ NoLeak s ∧
    ReleaseNamed s ∧ StrikesExact s

/-! ## As checks -/

def indexed (s : St) : List (Nat × Req) := (List.range s.reqs.length).filterMap fun m => (s.reqs[m]?).map (m, ·)

def checkPendingLive (s : St) : Bool :=
  s.reqs.all fun q => q.status != .pending || (!q.answered && match q.sess with | some id => !ended s id | none => false)

def checkOkOwn (s : St) : Bool :=
  (indexed s).all fun (m, q) => match q.status with
    | .ok v => s.delivered.any fun (m', r) => m' == m && (accept q.kind r).1 == .ok v
    | _ => true

def checkNoLeak (s : St) : Bool :=
  s.delivered.all fun (m, r) => match s.reqs[m]? with
    | some q => match late q.kind r with
      | some u => q.status == .ok (.session u) || (s.reqs.map Req.kind).contains (Kind.release q.kind.ch u)
      | none => true
    | none => true

def checkReleaseNamed (s : St) : Bool :=
  s.reqs.all fun q => match q.kind with
    | .release c u => s.delivered.any fun (m, r) => match s.reqs[m]? with
      | some p => p.kind.ch == c && late p.kind r == some u
      | none => false
    | _ => true

def checkStrikes (s : St) (inputs : Nat) : Bool :=
  (List.range inputs).all fun i => s.strikes i == quarantineAt * timedOutCount s i + lostSessions s i

/-- A false one, kept to show the explorer finds violations: a request is never refused. -/
def checkNeverRefused (s : St) : Bool := s.reqs.all fun q => q.status != .failed .refused

def checks (s : St) : List (String × Bool) :=
  [("pending-live", checkPendingLive s), ("ok-own", checkOkOwn s), ("no-leak", checkNoLeak s),
   ("release-named", checkReleaseNamed s), ("strikes", checkStrikes s 4), ("never-refused", checkNeverRefused s)]

end Broker
