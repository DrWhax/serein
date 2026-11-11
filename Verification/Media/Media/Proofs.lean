import Media.Model
import Media.Props

/-! # Proofs -/

namespace Media

/-- **Authorization belongs to the relation, not the file**: another message referencing the
same file changes nothing about whether this message may show it. -/
theorem permits_other_ref (d : Db) (h : m' ≠ m) :
    permits { d with rel := (m', p') :: d.rel } m p = permits d m p := by
  have hne : ((m, p) == (m', p')) = false := by simp [Ne.symm h]
  simp only [permits, List.contains_cons, hne, Bool.false_or]
  rfl

/-- A deleted, erased or expired message permits nothing, whatever else references the file. -/
theorem deleted_permits_nothing (d : Db) (h : d.rows m = none) : permits d m p = false := by
  simp [permits, live, h]

theorem erased_permits_nothing (d : Db) (h : d.rows m = some r) (he : r.erased = true) : permits d m p = false := by
  simp [permits, live, h, he]

theorem expired_permits_nothing (d : Db) (h : d.rows m = some r) (hx : r.expires = some t) (ht : t ≤ d.now) :
    permits d m p = false := by
  simp [permits, live, h, hx]; omega

theorem avail_mem : x ∈ avail d ↔ x ∈ d.rel ∧ live d x.1 = true := by simp [avail]

/-- Only an export after the panel, or a playback, adds to what is handed out, and only what
its message permits at that moment. -/
theorem out_step (s : S) (e : Ev) :
    (step s e).out = s.out ∨ ∃ k m p, (step s e).out = s.out ++ [(k, m, p)] ∧ permits s.d m p = true := by
  cases e
  case playVideo m p =>
    simp only [step, stepCore]; split
    · rename_i h; exact Or.inr ⟨_, m, p, rfl, h⟩
    · exact Or.inl rfl
  case playAudio m p =>
    simp only [step, stepCore]; split
    · rename_i h; exact Or.inr ⟨_, m, p, rfl, h⟩
    · exact Or.inl rfl
  case confirmSave =>
    simp only [step, stepCore]; split
    · rename_i m p _; split
      · rename_i h; exact Or.inr ⟨_, m, p, rfl, h⟩
      · exact Or.inl rfl
    · exact Or.inl rfl
  case openLightbox => simp only [step, stepCore]; split <;> exact Or.inl rfl
  case openSave => simp only [step, stepCore]; split <;> exact Or.inl rfl
  case decoded k =>
    simp only [step, stepCore]; split
    · split <;> exact Or.inl rfl
    · exact Or.inl rfl
  all_goals exact Or.inl rfl

theorem handedOutPermitted_holds (s : S) (e : Ev) : handedOutPermitted s e (step s e) = true := by
  rcases out_step s e with h | ⟨k, m, p, h, hp⟩
  · simp [handedOutPermitted, newOut, h]
  · simp [handedOutPermitted, newOut, h, hp]

theorem decodePermitted_holds (s : S) (e : Ev) : decodePermitted s e (step s e) = true := by
  cases e
  case decoded k =>
    simp only [decodePermitted, step, stepCore]
    cases hk : s.decodes[k]? with
    | none => simp
    | some x =>
      obtain ⟨m, p⟩ := x
      simp only
      split <;> simp_all
  case update =>
    simp only [decodePermitted, step, stepCore, apply, List.all_eq_true, List.contains_iff_mem]
    intro p hp
    exact (List.mem_filter.mp hp).1
  case openLightbox => simp only [decodePermitted, step, stepCore]; split <;> simp
  case playVideo => simp only [decodePermitted, step, stepCore]; split <;> simp
  case playAudio => simp only [decodePermitted, step, stepCore]; split <;> simp
  case openSave => simp only [decodePermitted, step, stepCore]; split <;> simp
  case confirmSave => simp only [decodePermitted, step, stepCore]; split <;> (try split) <;> simp
  all_goals simp [decodePermitted, step, stepCore]

theorem updateRevokes_holds (s : S) (e : Ev) : updateRevokes s e (step s e) = true := by
  cases e <;> simp only [updateRevokes]
  case update =>
    simp only [step, stepCore, apply, Bool.and_eq_true, Option.all_eq_true, List.all_eq_true]
    refine ⟨⟨⟨fun x hx => ?_, fun x hx => ?_⟩, fun x hx => ?_⟩, fun p hp => ?_⟩
    · obtain ⟨m, ps⟩ := x
      simp only [Option.mem_def, Option.filter_eq_some_iff, Bool.and_eq_true, List.any_eq_true, beq_iff_eq,
        List.all_eq_true, List.contains_iff_mem, avail_mem] at hx
      obtain ⟨-, ⟨y, ⟨-, hy⟩, rfl⟩, hall⟩ := hx
      refine ⟨by simpa using hy, fun p hp => ?_⟩
      obtain ⟨hrel, hl⟩ := hall p hp
      simp [permits, hl, List.contains_iff_mem, hrel]
    · obtain ⟨m, p⟩ := x
      simp only [Option.mem_def, Option.filter_eq_some_iff, List.contains_iff_mem, avail_mem] at hx
      obtain ⟨-, hrel, hl⟩ := hx
      simp [permits, hl, List.contains_iff_mem, hrel]
    · obtain ⟨m, p⟩ := x
      simp only [Option.mem_def, Option.filter_eq_some_iff, List.contains_iff_mem, avail_mem] at hx
      obtain ⟨-, hrel, hl⟩ := hx
      simp [permits, hl, List.contains_iff_mem, hrel]
    · simp only [List.mem_filter, List.any_eq_true, beq_iff_eq, avail_mem] at hp
      obtain ⟨-, ⟨y, ⟨hrel, hl⟩, rfl⟩⟩ := hp
      simp only [permitsAny, List.any_eq_true, Bool.and_eq_true, beq_iff_eq]
      exact ⟨y, hrel, rfl, hl⟩

end Media
