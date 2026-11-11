import Modifiers.Model

/-!
# The properties

Each is a `Prop` (what is proved) and a `Bool` check of one step (what the explorer runs).

* **Target** (`ResolvedCorrect`): a modifier acts only on the message it names (author, and the
  message's timestamp or one of its edits'), by the decision on that message.
* **Early modifiers** (`PendingUnresolvable`): nothing waits whose target is there: when a message
  or a revision arrives, everything that named it has been applied or refused.
* **Newest shown** (`NewestShown`): a message shows the newest of the edits that reached it
  (valid ones: by its author, in its conversation, on time), else the original; an older edit
  arriving late does not overwrite a newer one.
* **No resurrection, only the target changes** (`StepOk`): in a step, a stored message keeps its
  author, timestamp and conversation, its revision never goes back, once deleted for everyone it
  never changes again (a duplicate of it is dropped, edits and the rest refused), and it changes
  only through an accepted modifier that named it — or is removed here.
-/

namespace Modifiers

def ResolvedCorrect (w : World) (s : S) : Prop :=
  ∀ x ∈ s.resolved, resolves x.2.1 x.1 = true ∧ x.2.2 = accepts w x.2.1 x.1

def PendingUnresolvable (s : S) : Prop :=
  ∀ e ∈ s.pending, ∀ r ∈ s.rows, resolves r e.mod = false

/-- The edits that reached stored message `g`: valid ones are no newer than what it shows;
what it shows is the original or an accepted edit. -/
def NewestShown (w : World) (s : S) : Prop :=
  ∀ r ∈ s.rows,
    (r.deleted = false → ∀ x ∈ s.resolved, x.2.1.gen = r.gen → x.1.kind = .edit → editValid w x.2.1 x.1 = true → x.1.ts ≤ r.rev) ∧
    (r.rev = r.sentAt ∨ ∃ x ∈ s.resolved, x.2.1.gen = r.gen ∧ x.1.kind = .edit ∧ x.2.2 = true ∧ x.1.ts = r.rev)

def StepOk (s s' : S) : Prop :=
  ∃ new, s'.resolved = new ++ s.resolved ∧
    ∀ g r, s.get g = some r → s'.get g = none ∨
      ∃ r', s'.get g = some r' ∧ r'.author = r.author ∧ r'.sentAt = r.sentAt ∧ r'.conv = r.conv ∧ r.rev ≤ r'.rev ∧
        (r.deleted = true → r' = r) ∧ (r' ≠ r → ∃ x ∈ new, x.2.1.gen = g ∧ x.2.2 = true)

/-! ## Checks of one step (the explorer) -/

def resolvedCorrectB (w : World) (s : S) : Bool := s.resolved.all fun x => resolves x.2.1 x.1 && x.2.2 == accepts w x.2.1 x.1

def pendingUnresolvableB (s : S) : Bool := s.pending.all fun e => s.rows.all fun r => !resolves r e.mod

def newestShownB (w : World) (s : S) : Bool := s.rows.all fun r =>
  (r.deleted || s.resolved.all fun x => !(x.2.1.gen == r.gen && x.1.kind == .edit && editValid w x.2.1 x.1) || x.1.ts ≤ r.rev) &&
  (r.rev == r.sentAt || s.resolved.any fun x => x.2.1.gen == r.gen && x.1.kind == .edit && x.2.2 && x.1.ts == r.rev)

def stepOkB (s s' : S) : Bool :=
  let n := s'.resolved.length - s.resolved.length
  let new := s'.resolved.take n
  s'.resolved.drop n == s.resolved && s.rows.all fun r =>
    match s'.get r.gen with
    | none => true
    | some r' => r'.author == r.author && r'.sentAt == r.sentAt && r'.conv == r.conv && r.rev ≤ r'.rev &&
        (!r.deleted || r' == r) && (r' == r || new.any fun x => x.2.1.gen == r.gen && x.2.2)

def stepChecks (w : World) (s s' : S) : List (String × Bool) :=
  [("resolved-correct", resolvedCorrectB w s'), ("pending-unresolvable", pendingUnresolvableB s'),
   ("newest-shown", newestShownB w s'), ("step-ok", stepOkB s s'), ("fuel", !s'.exhausted)]

end Modifiers
