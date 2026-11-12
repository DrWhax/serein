import CallBoundary.Model

/-! # The properties

Each as a `Prop` (proved in `Proofs.lean`) and, for the explorer, as a `Bool` evaluated after
every step of random runs. -/

namespace CallBoundary

/-- **What the app may do for the service**, judged in the state the request arrived in. -/
def Allowed (s : St) : Out → Prop
  | .signal p c => (∃ k, s.call = some k ∧ k.peer = p ∧ k.id = c) ∨ lookup s.offers c = some p
  | .incoming p c => lookup s.offers c = some p
  | .message u => (s.selfKnown = true ∧ u = selfId) ∨
      ∃ g ∈ s.groups, (g.link = false ∧ u ∈ g.members) ∨ (g.link = true ∧ u ∈ g.participants)
  | .groupMessage gid us => ((∃ g ∈ s.groups, g.link = false ∧ g.group = gid) ∨ gid ∈ s.cancelled) ∧
      ∀ u ∈ us, (s.selfKnown = true ∧ u = selfId) ∨
        ∃ g ∈ s.groups, (g.link = false ∧ u ∈ g.members) ∨ (g.link = true ∧ u ∈ g.participants)
  | .ring u _ => u ∈ s.senders
  | .groupEnded c => ∃ g ∈ s.groups, g.client = c

/-- The invariant every reachable state keeps. -/
structure Inv (s : St) : Prop where
  epGenLen : s.epGen.length = s.eps
  epLive : ∀ e, s.ep = some e → s.epGen[e]? = some s.gen
  reportedLe : s.reported ≤ s.gen
  /-- **A command reaches only the endpoint of the generation it was made on.** -/
  cmdsGen : ∀ c ∈ s.cmds, s.epGen[c.ep]? = some c.gen
  /-- **A reported loss ended everything made before it**: the current call, if not ended, and
  every group call client were made on a generation not yet lost. -/
  callGen : ∀ k, s.call = some k → k.gen ≤ s.gen ∧ (k.ended = false → s.reported ≤ k.gen)
  groupGen : ∀ g ∈ s.groups, g.gen ≤ s.gen ∧ s.reported ≤ g.gen
  /-- **Once `setSelfUuid` is known, the live endpoint has it.** -/
  configured : s.config = true → ∀ e, s.ep = some e → e ∈ s.configOn

/-! ## For the explorer -/

def allowedB (s : St) : Out → Bool
  | .signal p c => maySignal s p c
  | .incoming p c => lookup s.offers c == some p
  | .message u => mayMessage s u
  | .groupMessage gid us => mayGroupMessage s gid us
  | .ring u _ => s.senders.contains u
  | .groupEnded c => s.groups.any (·.client == c)

/-- What a step added to `out` was allowed in the state before it. -/
def outAllowedB (s : St) (e : Ev) : Bool :=
  ((step s e).out.drop s.out.length).all (allowedB s)

def cmdsGenB (s : St) : Bool := s.cmds.all fun c => s.epGen[c.ep]? == some c.gen

def endedB (s : St) : Bool :=
  (match s.call with
   | some k => k.gen ≤ s.gen && (k.ended || s.reported ≤ k.gen)
   | none => true) && s.groups.all (fun g => g.gen ≤ s.gen && s.reported ≤ g.gen)

def configuredB (s : St) : Bool :=
  !s.config || match s.ep with
    | some e => s.configOn.contains e
    | none => true

/-- A command from a call or group call made on a lost generation reaches nothing. -/
def staleRefusedB (s : St) (e : Ev) : Bool :=
  match e with
  | .callCmd => match s.call with
    | some k => k.gen == s.gen || (step s e).cmds.length == s.cmds.length
    | none => true
  | .groupCmd c => match findHeld s c with
    | some g => g.gen == s.gen || (step s e).cmds.length == s.cmds.length
    | none => true
  | _ => true

/-- **Fails** (`message_from_service`): a call message goes only to ourselves or to a member the
app gave. In a call-link call the participants are the service's word: ringrtc learns them from
the SFU and decrypts them with the link's key, and the app has no list of its own. -/
def messageAppKnownB (s : St) (e : Ev) : Bool :=
  ((step s e).out.drop s.out.length).all fun
    | .message u => (s.selfKnown && u == selfId) || s.groups.any (fun g => !g.link && g.members.contains u)
    | _ => true

end CallBoundary
