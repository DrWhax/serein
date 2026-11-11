import Send.Model
import Send.Props

/-! # Proofs -/

namespace Send

/-- **The exemption needs no content**: a payload that qualifies as retraction-only carries no
message content. So adding a body, attachments or anything else to a delete disqualifies it. -/
theorem onlyRetracts_carries (c : Content) (h : c.onlyRetracts = true) : c.carries = false := by
  cases c with
  | data d => simp only [Content.onlyRetracts, Data.onlyDeletes, Bool.and_eq_true, Bool.not_eq_true'] at h; simp [Content.carries, h.2]
  | sent m u st ed =>
    cases m with
    | none => simp only [Content.onlyRetracts, Bool.and_eq_true, Bool.not_eq_true'] at h; simp [Content.carries, h.1.2, h.2]
    | some d =>
      simp only [Content.onlyRetracts, Data.onlyDeletes, Bool.and_eq_true, Bool.not_eq_true'] at h
      simp [Content.carries, h.1.1.2, h.1.2, h.2]
  | content => simp [Content.onlyRetracts] at h
  | other => simp [Content.onlyRetracts] at h

theorem onlyRetracts_extra (d : Data) : (Content.data { d with extra := true }).onlyRetracts = false := by
  simp [Content.onlyRetracts, Data.onlyDeletes]

/-- **Direct and group blocking are separate**: a group payload's authorization reads the
group's block, never a contact's; a direct payload's reads the contact's (id and number), never
a group's. -/
theorem group_ignores_contacts (s : S) (ids nums : List Nat) :
    authorized { s with blockedIds := ids, blockedNums := nums } (.group g) c xs = authorized s (.group g) c xs := rfl

theorem direct_ignores_groups (s : S) (gs : List Nat) :
    authorized { s with blockedGroups := gs } (.direct q) c xs = authorized s (.direct q) c xs := rfl

theorem blocked_contact_refused (s : S) (h : s.blocked q = true) : authorized s (.direct q) c xs = false := by
  simp [authorized, h]

theorem blocked_group_refused (s : S) (h : s.blockedGroups.contains g = true) : authorized s (.group g) c xs = false := by
  simp only [authorized, h, Bool.not_true, Bool.false_and]

/-- A retraction's authorization does not read the messages it names. -/
theorem retraction_ignores_messages (s : S) (h : c.onlyRetracts = true) (m : Nat → Msg) :
    authorized { s with msgs := m } t c xs = authorized s t c xs := by
  cases t <;> simp [authorized, h, S.blocked]

theorem content_needs_live (s : S) (h : authorized s t c xs = true) (hc : c.carries = true) :
    xs.all (fun m => s.msgs m == .live) = true := by
  have hr : c.onlyRetracts = false := by
    cases hh : c.onlyRetracts
    · rfl
    · rw [onlyRetracts_carries c hh] at hc; cases hc
  simp only [authorized, hr, Bool.false_or, Bool.and_eq_true] at h
  exact h.2

-- ## The pipeline

theorem submitted_of (h : submitted p p' = some o) :
    p'.out.length = p.out.length + 1 ∧ p'.out.getLast? = some o := by
  unfold submitted at h; split at h
  · exact ⟨by assumption, h⟩
  · cases h

/-- Only a submit step submits, and only what it checked. -/
theorem step_out (p : P) (e : Ev) :
    (step p e).out = p.out ∨ ∃ j t c ids to, e = .submit j ∧ p.jobs[j]? = some ⟨t, c, ids, .started to⟩ ∧
      authorized p.s t c ids = true ∧ (step p e).out = p.out ++ [⟨t, c, ids, to⟩] := by
  cases e with
  | submit j =>
    simp only [step, stepCore]
    split
    · rename_i t c ids to hj
      split
      · rename_i ha; exact Or.inr ⟨j, t, c, ids, to, rfl, hj, ha, rfl⟩
      · exact Or.inl rfl
    · exact Or.inl rfl
  | start j =>
    left; simp only [step, stepCore]; split
    · split
      · rfl
      · split <;> rfl
    · rfl
  | _ => left; rfl

theorem submitAuthorized_holds (p : P) (e : Ev) : submitAuthorized p e (step p e) = true := by
  rcases step_out p e with h | ⟨j, t, c, ids, to, -, -, ha, h⟩
  · simp [submitAuthorized, submitted, h]
  · simp [submitAuthorized, submitted, h, ha]

theorem contentNeedsSource_holds (p : P) (e : Ev) : contentNeedsSource p e (step p e) = true := by
  rcases step_out p e with h | ⟨j, t, c, ids, to, -, -, ha, h⟩
  · simp [contentNeedsSource, submitted, h]
  · simp only [contentNeedsSource, submitted, h, List.length_append, List.length_singleton, ite_true, List.getLast?_append,
      List.getLast?_singleton, Option.some_or]
    cases hc : c.carries
    · rfl
    · simp only [Bool.not_true, Bool.false_or]; exact content_needs_live p.s ha hc

theorem retractionGoes_holds (p : P) (e : Ev) : retractionGoes p e (step p e) = true := by
  cases e <;> simp only [retractionGoes]
  case submit j =>
    split
    · rename_i t c ids to hj
      cases hr : c.onlyRetracts
      · rfl
      · cases ha : authorized { p.s with msgs := fun _ => .live } t c ids
        · simp
        · have : authorized p.s t c ids = true := by rw [← retraction_ignores_messages p.s hr (fun _ => .live)]; exact ha
          simp [stepCore, hj, this]
    · rfl

theorem recipients_mem (s : S) : q ∈ recipients s g ↔ q ∈ s.members g ∧ s.blocked q = false := by
  simp [recipients]

theorem groupRecipients_holds (p : P) (e : Ev) : groupRecipients p e (step p e) = true := by
  cases e <;> simp only [groupRecipients]
  case start j =>
    split
    · rename_i g c ids hj
      cases ha : authorized p.s (.group g) c ids
      · rfl
      · have hlen : j < p.jobs.length := (List.getElem?_eq_some_iff.mp hj).1
        simp [step, stepCore, hj, ha, List.getElem?_set_self hlen]
    · rfl

end Send
