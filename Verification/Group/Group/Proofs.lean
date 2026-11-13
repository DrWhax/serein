import Group.Model
import Group.Props

/-! # Proofs -/

namespace Group

variable {s : S}

/-- What a step adds to the output: nothing, one key distribution to a member, or a submission
to targets that are all members (and, for an update, the outside). -/
theorem out_step (s : S) (e : Ev) :
    (step s e).out = s.out ∨
    (∃ a, s.members.contains a = true ∧ (step s e).out = s.out ++ [(a, "key")]) ∨
    (∃ (targets outside : List Nat) (u : Bool), targets.all s.members.contains = true ∧
      (step s e).out = s.out ++ targets.map (·, if u then "update" else "content") ++ outside.map (·, "update")) := by
  cases e with
  | distribute k =>
    simp only [step, stepCore]
    split
    · rename_i j _
      split
      · rename_i targets outside a rest _
        split
        · rename_i hm; exact Or.inr (Or.inl ⟨a, hm, rfl⟩)
        · exact Or.inl rfl
      · exact Or.inl rfl
    · exact Or.inl rfl
  | submit k =>
    simp only [step, stepCore]
    split
    · rename_i j _
      split
      · rename_i targets outside _
        split
        · rename_i hm; exact Or.inr (Or.inr ⟨targets, outside, j.update, (by simp only [Bool.and_eq_true] at hm; exact hm.1.1.1), by simp⟩)
        · exact Or.inl rfl
      · exact Or.inl rfl
    · exact Or.inl rfl
  | plan k =>
    left; simp only [step, stepCore]; split
    · simp only [Group.planJob]; split <;> rfl
    · rfl
  | _ => exact Or.inl rfl

theorem keysToMembers_holds (s : S) (e : Ev) : keysToMembers s e (step s e) = true := by
  rcases out_step s e with h | ⟨a, hm, h⟩ | ⟨targets, outside, u, hm, h⟩
  · simp [keysToMembers, newOut, h]
  · simp [keysToMembers, newOut, h]; simpa using hm
  · simp only [keysToMembers, newOut, h, List.append_assoc, List.drop_left, List.all_append, List.all_map, Bool.and_eq_true,
      List.all_eq_true, Function.comp]
    simp only [List.all_eq_true] at hm
    refine ⟨fun a ha => ?_, fun a _ => by simp⟩
    have := hm a ha
    cases u <;> simp <;> simpa using this

theorem contentToMembers_holds (s : S) (e : Ev) : contentToMembers s e (step s e) = true := by
  rcases out_step s e with h | ⟨a, hm, h⟩ | ⟨targets, outside, u, hm, h⟩
  · simp [contentToMembers, newOut, h]
  · simp [contentToMembers, newOut, h]
  · simp only [contentToMembers, newOut, h, List.append_assoc, List.drop_left, List.all_append, List.all_map, Bool.and_eq_true,
      List.all_eq_true, Function.comp]
    simp only [List.all_eq_true] at hm
    refine ⟨fun a ha => ?_, fun a _ => by simp⟩
    have := hm a ha
    cases u <;> simp <;> simpa using this

-- ## The rotation invariant

def JobOK (s : S) (j : Job) : Prop :=
  j.generation ≤ s.epoch ∧ (j.generation = s.epoch → ∀ d ∈ j.reserved, d ∈ s.distributed)

structure Inv (s : S) : Prop where
  recorded : ∀ h ∈ s.holders, h.2.2 = s.epoch → (h.1, h.2.1) ∈ s.distributed
  past : ∀ h ∈ s.holders, h.2.2 ≤ s.epoch
  jobs : ∀ j ∈ s.jobs, JobOK s j

theorem Inv.init : Inv (S.init m d) := by
  constructor <;> simp [S.init]

theorem Inv.setJob (h : Inv s) (hj : JobOK s j) : Inv { s with jobs := s.jobs.set k j } := by
  refine ⟨h.recorded, h.past, ?_⟩
  intro x hx
  rcases List.mem_or_eq_of_mem_set hx with hx | rfl
  · exact h.jobs x hx
  · exact hj

theorem Inv.unplan (h : Inv s) (hj : j ∈ s.jobs) : Inv (unplan s k j) :=
  h.setJob (h.jobs j hj)

theorem mem_union (d : Nat × Nat) (ds xs : List (Nat × Nat)) :
    d ∈ ds ++ xs.filter (!ds.contains ·) ↔ d ∈ ds ∨ d ∈ xs := by
  simp only [List.mem_append, List.mem_filter, Bool.not_eq_true']
  by_cases hd : d ∈ ds <;> simp [hd]

theorem Inv.planJob (h : Inv s) (k : Nat) (j : Job) : Inv (Group.planJob s k j) := by
  simp only [Group.planJob]
  split
  · -- A reset retires every old holder and reservation.
    refine ⟨?_, ?_, ?_⟩
    · intro x hx hg; have := h.past x hx; dsimp at hg; omega
    · intro x hx; have := h.past x hx; dsimp; omega
    · intro x hx
      rcases List.mem_or_eq_of_mem_set hx with hx | rfl
      · have hh := h.jobs x hx
        refine ⟨by dsimp [JobOK] at hh ⊢; omega, ?_⟩
        intro he; have := hh.1; dsimp at he; omega
      · exact ⟨Nat.le_refl _, fun _ d hd => by simpa using hd⟩
  · -- Without reset, union with persisted reservations, never a local snapshot.
    refine ⟨?_, h.past, ?_⟩
    · intro x hx hg; exact List.mem_append_left _ (h.recorded x hx hg)
    · intro x hx
      rcases List.mem_or_eq_of_mem_set hx with hx | rfl
      · have hh := h.jobs x hx
        exact ⟨hh.1, fun he d hd => List.mem_append_left _ (hh.2 he d hd)⟩
      · exact ⟨Nat.le_refl _, fun _ d hd => (mem_union d _ _).mpr (Or.inr hd)⟩

theorem Inv.step (h : Inv s) (e : Ev) : Inv (step s e) := by
  cases e with
  | plan k =>
    simp only [Group.step, stepCore]; split
    · exact h.planJob _ _
    · exact h
  | distribute k =>
    simp only [Group.step, stepCore]
    split
    · rename_i j hj
      have hjmem : j ∈ s.jobs := List.mem_of_getElem? hj
      have hjok := h.jobs j hjmem
      split
      · split
        · refine ⟨?_, ?_, ?_⟩
          · intro x hx hg
            simp only [List.mem_append, List.mem_map] at hx
            rcases hx with hx | ⟨d, hd, rfl⟩
            · exact h.recorded x hx hg
            · exact hjok.2 hg d (List.mem_filter.mp hd).1
          · intro x hx
            simp only [List.mem_append, List.mem_map] at hx
            rcases hx with hx | ⟨d, hd, rfl⟩
            · exact h.past x hx
            · exact hjok.1
          · intro x hx
            rcases List.mem_or_eq_of_mem_set hx with hx | rfl
            · exact h.jobs x hx
            · exact hjok
        · exact h.unplan hjmem
      · exact h
    · exact h
  | submit k =>
    simp only [Group.step, stepCore]
    split
    · rename_i j hj
      split
      · split
        · exact ⟨h.recorded, h.past, fun x hx => h.jobs x (List.mem_of_mem_eraseIdx hx)⟩
        · exact h.unplan (List.mem_of_getElem? hj)
      · exact h
    · exact h
  | queue rs u =>
    refine ⟨h.recorded, h.past, ?_⟩
    intro x hx
    simp only [Group.step, stepCore, List.mem_append, List.mem_singleton] at hx
    rcases hx with hx | rfl
    · exact h.jobs x hx
    · exact ⟨Nat.zero_le _, by simp⟩
  | add a => exact ⟨h.recorded, h.past, h.jobs⟩
  | remove a => exact ⟨h.recorded, h.past, h.jobs⟩
  | refresh a ds => exact ⟨h.recorded, h.past, h.jobs⟩
  | expire => exact ⟨h.recorded, h.past, h.jobs⟩

theorem Inv.reach (hr : Reach s) : Inv s := by
  induction hr with
  | init => exact Inv.init
  | step e _ ih => exact ih.step e

theorem holdersRecorded_holds (hr : Reach s) (e : Ev) : holdersRecorded s e (step s e) = true := by
  have h := Inv.reach (Reach.step e hr)
  simp only [holdersRecorded, List.all_eq_true]
  intro x hx
  cases hg : (x.2.2 != (step s e).epoch)
  · simp only [bne_eq_false_iff_eq] at hg
    simp [h.recorded x hx hg]
  · simp

/-- The rotation rule, in the model: without a reset, every recorded device is among the send's
devices or belongs to one of its targets. -/
theorem rotation_targets (dist current : List (Nat × Nat)) (targets : List Nat)
    (hc : ∀ d ∈ current, targets.contains d.1 = true) (hr : (rotation dist current targets).1 = false) :
    ∀ d ∈ dist, targets.contains d.1 = true := by
  intro d hd
  simp only [rotation, List.any_eq_false, Bool.and_eq_true, Bool.not_eq_true'] at hr
  by_cases hcur : current.contains d = true
  · exact hc d (by simpa using hcur)
  · have := hr d hd; simp_all

theorem rotated_holds (s : S) (e : Ev) : rotated s e (step s e) = true := by
  cases e <;> simp only [rotated]
  case plan k =>
    cases hj : s.jobs[k]? with
    | none => rfl
    | some j =>
      have hlen : k < s.jobs.length := (List.getElem?_eq_some_iff.mp hj).1
      have htm : ∀ a ∈ (planOf s.members j.rs j.update).1.filter (fun a => !(s.devices a).isEmpty), s.members.contains a = true := by
        intro a ha; exact (List.mem_filter.mp (List.mem_filter.mp ha).1).2
      have hcur : ∀ d ∈ devs s ((planOf s.members j.rs j.update).1.filter (fun a => !(s.devices a).isEmpty)),
          ((planOf s.members j.rs j.update).1.filter (fun a => !(s.devices a).isEmpty)).contains d.1 = true := by
        intro d hd; simp only [devs, List.mem_flatMap, List.mem_map] at hd
        obtain ⟨a, ha, x, -, rfl⟩ := hd; simpa using ha
      by_cases hr : ((rotation s.distributed (devs s ((planOf s.members j.rs j.update).1.filter (fun a => !(s.devices a).isEmpty)))
          ((planOf s.members j.rs j.update).1.filter (fun a => !(s.devices a).isEmpty))).1 || s.stale) = true
      · simp only [step, stepCore, hj, Group.planJob, hr, ite_true, List.getElem?_set_self hlen]
        simp only [List.nil_append, List.contains_nil, Bool.not_false, List.all_eq_true, Bool.and_eq_true]
        intro d hd; have hd := (List.mem_filter.mp hd).1; exact ⟨hcur d hd, htm _ (by simpa using hcur d hd)⟩
      · have hn := hr
        have hrot : (rotation s.distributed (devs s ((planOf s.members j.rs j.update).1.filter (fun a => !(s.devices a).isEmpty)))
          ((planOf s.members j.rs j.update).1.filter (fun a => !(s.devices a).isEmpty))).1 = false := by
          simp only [Bool.or_eq_true, not_or, Bool.not_eq_true] at hn
          exact hn.1
        have hd := rotation_targets s.distributed _ _ hcur hrot
        simp only [step, stepCore, hj, Group.planJob, hr, Bool.false_eq_true, ite_false, List.getElem?_set_self hlen, List.all_eq_true, Bool.and_eq_true]
        intro d hm
        have ht : ((planOf s.members j.rs j.update).1.filter (fun a => !(s.devices a).isEmpty)).contains d.1 = true := by
          rcases (mem_union d _ _).mp hm with hm | hm
          · exact hd d hm
          · exact hcur d hm
        exact ⟨ht, htm _ (by simpa using ht)⟩

theorem contentKeySafe_holds (hr : Reach s) (e : Ev) : contentKeySafe s e (step s e) = true := by
  have h := Inv.reach hr
  cases e <;> simp only [step, stepCore, contentKeySafe, newOut]
  all_goals try { simp; done }
  case plan k =>
    split
    · simp only [Group.planJob]; split <;> simp
    · simp
  case distribute k =>
    split
    · split
      · split <;> simp [unplan]
      · simp
    · simp
  case submit k =>
    split
    · rename_i j hj
      split
      · split
        · rename_i hm
          simp only [Bool.and_eq_true] at hm
          simp only [Bool.or_eq_true]; right
          simp only [hj, Bool.and_eq_true]
          refine ⟨hm.1.2, ?_⟩
          have he := hm.1.1.2
          simp only [beq_iff_eq] at he
          rw [he]
          have hm := hm.2
          simp only [List.all_eq_true] at hm ⊢
          intro x hx
          by_cases he : x.2.2 = s.epoch
          · simpa [he] using hm (x.1, x.2.1) (h.recorded x hx he)
          · simp [he]
        · simp [unplan]
      · simp
    · simp

end Group
