/-!
# The asynchronous publication boundary

This supplements the byte-authentication model. A validated download result is held across
CDN/decoder awaits; the writer compares its job lease and original attachment snapshot with the
current row. `version` abstracts equality of the full pointer snapshot, not just its digest.
Cryptographic validation remains the contract proved by `Attachments.Proofs`.
-/
namespace Attachments.Publication
structure S where
  lease : Nat := 0
  version : Nat := 0
  live : Bool := true
  pending : Bool := true
  cancelled : Bool := false
  work : Option (Nat × Nat) := none
  published : List Nat := []
  deriving DecidableEq, Repr
inductive Ev
  | begin | finish | cancel | requeue | replace | revoke
  deriving DecidableEq, Repr

def step (s : S) : Ev → S
  | .begin => { s with work := some (s.lease, s.version) }
  | .cancel => { s with cancelled := true, pending := false }
  | .requeue => { s with lease := s.lease + 1, pending := true }
  | .replace => { s with version := s.version + 1 }
  | .revoke => { s with live := false }
  | .finish => match s.work with
    | some (lease, version) =>
      if lease == s.lease && version == s.version && s.live && s.pending && !s.cancelled then
        { s with pending := false, published := s.published ++ [version], work := none }
      else s
    | none => s

/-- Publication authorizes the current full snapshot, in its current live job, at commit. -/
def safe (s s' : S) : Bool := s'.published == s.published ||
  (s.live && s.pending && !s.cancelled && s.work == some (s.lease, s.version) &&
    s'.published == s.published ++ [s.version])

theorem publish_current (s : S) (e : Ev) : safe s (step s e) = true := by
  cases e <;> simp only [step, safe]
  all_goals try { simp; done }
  split
  · split
    · rename_i lease version hw h
      simp only [Bool.and_eq_true, beq_iff_eq, Bool.not_eq_true'] at h
      rcases h with ⟨⟨⟨⟨rfl, rfl⟩, hl⟩, hp⟩, hc⟩
      simp [hl, hp, hc, hw]
    · simp
  · simp

private def waiting : S := step {} .begin
example : (step waiting .finish).published = [0] := by decide
example : (step (step waiting .replace) .finish).published = [] := by decide
example : (step (step waiting .requeue) .finish).published = [] := by decide
example : (step (step waiting .cancel) .finish).published = [] := by decide
example : (step (step waiting .revoke) .finish).published = [] := by decide
end Attachments.Publication
