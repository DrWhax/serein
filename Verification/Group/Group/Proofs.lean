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
        · rename_i hm; exact Or.inr (Or.inr ⟨targets, outside, j.update, hm, by simp⟩)
        · exact Or.inl rfl
      · exact Or.inl rfl
    · exact Or.inl rfl
  | plan k =>
    left; simp only [step, stepCore]; split
    · simp only [planJob]; split <;> rfl
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

structure Inv (s : S) : Prop where
  recorded : ∀ h ∈ s.holders, h.2.2 = s.epoch → (h.1, h.2.1) ∈ s.distributed
  past : ∀ h ∈ s.holders, h.2.2 ≤ s.epoch

theorem Inv.init : Inv (S.init m d) := ⟨fun _ h => by simp [S.init] at h, fun _ h => by simp [S.init] at h⟩

/-- `distributed` only grows (between resets), `holders` and `epoch` unchanged. -/
theorem Inv.grow (h : Inv s) (hd : ∀ x ∈ s.distributed, x ∈ s'.distributed) (hh : s'.holders = s.holders) (he : s'.epoch = s.epoch) :
    Inv s' :=
  ⟨fun x hx hg => hd _ (h.recorded x (hh ▸ hx) (he ▸ hg)), fun x hx => he ▸ h.past x (hh ▸ hx)⟩

/-- A plan keeps the record of holders, and either keeps the key and its record or starts a new
key that nobody has. -/
theorem planJob_effect (s : S) (k : Nat) (j : Job) :
    (planJob s k j).holders = s.holders ∧
    (((planJob s k j).epoch = s.epoch ∧ (planJob s k j).distributed = s.distributed) ∨
     ((planJob s k j).epoch = s.epoch + 1 ∧ (planJob s k j).distributed = [])) := by
  simp only [planJob]
  split
  · exact ⟨rfl, Or.inr ⟨rfl, rfl⟩⟩
  · exact ⟨rfl, Or.inl ⟨rfl, rfl⟩⟩

theorem Inv.step (h : Inv s) (e : Ev) : Inv (step s e) := by
  cases e with
  | plan k =>
    simp only [Group.step, stepCore]
    split
    · rename_i j _
      obtain ⟨hh, he⟩ := planJob_effect s k j
      rcases he with ⟨he, hd⟩ | ⟨he, hd⟩
      · exact h.grow (fun x hx => hd ▸ hx) hh he
      · refine ⟨fun x hx hg => ?_, fun x hx => ?_⟩
        · rw [hh] at hx; have := h.past x hx; rw [he] at hg; omega
        · rw [hh] at hx; have := h.past x hx; rw [he]; omega
    · exact h
  | distribute k =>
    simp only [Group.step, stepCore]
    split
    · split
      · split
        · rename_i a rest _ _
          refine ⟨fun x hx hg => ?_, fun x hx => ?_⟩
          · simp only [List.mem_append, List.mem_map] at hx
            rcases hx with hx | ⟨d, hd, rfl⟩
            · exact List.mem_append_left _ (h.recorded x hx hg)
            · show d ∈ s.distributed ++ ((s.devices a).map (a, ·)).filter (!s.distributed.contains ·)
              by_cases hin : d ∈ s.distributed
              · exact List.mem_append_left _ hin
              · exact List.mem_append_right _ (List.mem_filter.mpr ⟨List.mem_map.mpr hd, by simpa using hin⟩)
          · simp only [List.mem_append, List.mem_map] at hx
            rcases hx with hx | ⟨d, -, rfl⟩
            · exact h.past x hx
            · exact Nat.le_refl _
        · exact ⟨h.recorded, h.past⟩
      · exact h
    · exact h
  | submit k =>
    simp only [Group.step, stepCore]
    split
    · split
      · split
        · exact h.grow (fun _ hx => List.mem_append_left _ hx) rfl rfl
        · exact h.grow (fun _ hx => List.mem_append_left _ hx) rfl rfl
      · exact h
    · exact h
  | add a => exact ⟨h.recorded, h.past⟩
  | remove a => exact ⟨h.recorded, h.past⟩
  | refresh a ds => exact ⟨h.recorded, h.past⟩
  | expire => exact ⟨h.recorded, h.past⟩
  | queue rs u => exact ⟨h.recorded, h.past⟩

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

/-- Where a plan leaves the job and the record. -/
theorem planJob_at (s : S) (k : Nat) (j : Job) (hlen : k < s.jobs.length) :
    ∃ outside pend, (planJob s k j).jobs[k]? =
        some { j with plan := some ((planOf s.members j.rs j.update).1.filter (fun a => !(s.devices a).isEmpty), outside, pend) } ∧
      ((planJob s k j).distributed = [] ∨
       ((rotation s.distributed (devs s ((planOf s.members j.rs j.update).1.filter (fun a => !(s.devices a).isEmpty)))
          ((planOf s.members j.rs j.update).1.filter (fun a => !(s.devices a).isEmpty))).1 = false ∧
        (planJob s k j).distributed = s.distributed)) := by
  simp only [planJob]
  split
  · exact ⟨_, _, by rw [List.getElem?_set_self hlen], Or.inl rfl⟩
  · rename_i hreset
    simp only [Bool.or_eq_true, not_or, Bool.not_eq_true] at hreset
    exact ⟨_, _, by rw [List.getElem?_set_self hlen], Or.inr ⟨hreset.1, rfl⟩⟩

theorem rotated_holds (s : S) (e : Ev) : rotated s e (step s e) = true := by
  cases e <;> simp only [rotated]
  case plan k =>
    cases hj : s.jobs[k]? with
    | none => rfl
    | some j =>
      have hlen : k < s.jobs.length := (List.getElem?_eq_some_iff.mp hj).1
      have hst : step s (.plan k) = planJob s k j := by simp [step, stepCore, hj]
      rw [hst]
      have htm : ∀ a ∈ (planOf s.members j.rs j.update).1.filter (fun a => !(s.devices a).isEmpty), s.members.contains a = true := by
        intro a ha
        simp only [planOf, List.mem_filter] at ha
        exact ha.1.2
      have hcur : ∀ d ∈ devs s ((planOf s.members j.rs j.update).1.filter (fun a => !(s.devices a).isEmpty)),
          ((planOf s.members j.rs j.update).1.filter (fun a => !(s.devices a).isEmpty)).contains d.1 = true := by
        intro d hd; simp only [devs, List.mem_flatMap, List.mem_map] at hd
        obtain ⟨a, ha, x, -, rfl⟩ := hd; simpa using ha
      obtain ⟨outside, pend, hjob, hd⟩ := planJob_at s k j hlen
      simp only [hjob]
      rcases hd with hd | ⟨hrot, hd⟩
      · simp [hd]
      · have := rotation_targets s.distributed _ _ hcur hrot
        simp only [hd, List.all_eq_true, Bool.and_eq_true]
        intro d hdd
        exact ⟨this d hdd, htm d.1 (by simpa using this d hdd)⟩

end Group
