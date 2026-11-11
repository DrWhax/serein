import Modifiers.Model
import Modifiers.Props

/-!
# The proofs

1. The decision: someone else's modifier acts in its target's conversation; deletes, edits and
   terminations are by the author, admin deletes by an administrator; reactions, votes and pins
   by a member not blocked (and, on our message, one it was sent to); a message deleted for
   everyone accepts nothing; an edit is accepted only if newer than what is shown.
2. The waiting list: an eviction removes an entry of the sender with the most waiting, never one
   of a sender with fewer than another; the list only loses entries (and gains the new one).
3. The receiver: an invariant of every reachable state (`Inv`: the properties of `Props.lean`
   and bookkeeping), and `StepOk` for every step.
-/

namespace Modifiers

/-! ## 1. The decision -/

theorem accepts_conversation (w : World) (r : Row) (m : Mod) (h : accepts w r m = true)
    (hs : m.src = .other) (hu : m.sender ≠ w.us) : r.conv = m.conv := by
  have hu' : (m.sender == w.us) = false := by simpa using hu
  unfold accepts at h
  split at h <;> simp_all [inConv, editValid, pinnable]

theorem accepts_edit_conversation (w : World) (r : Row) (m : Mod) (hk : m.kind = .edit)
    (h : accepts w r m = true) : r.conv = m.conv := by
  simp_all [accepts, editValid]

theorem accepts_author (w : World) (r : Row) (m : Mod) (hk : m.kind = .delete ∨ m.kind = .edit ∨ m.kind = .terminate)
    (h : accepts w r m = true) : m.sender = r.author := by
  rcases hk with hk | hk | hk <;> simp_all [accepts, editValid]

theorem accepts_admin (w : World) (r : Row) (m : Mod) (hk : m.kind = .adminDelete)
    (h : accepts w r m = true) : isAdmin w r.conv m.sender = true := by
  simp_all [accepts]

theorem accepts_member (w : World) (r : Row) (m : Mod)
    (hk : m.kind = .reaction ∨ m.kind = .vote ∨ m.kind = .pin ∨ m.kind = .unpin) (hu : m.sender ≠ w.us)
    (h : accepts w r m = true) : belongs w m.sender r.conv = true ∧ blockedIn w r.conv m.sender = false := by
  have hu' : (m.sender == w.us) = false := by simpa using hu
  rcases hk with hk | hk | hk | hk
  · simp only [accepts, hk, hu', Bool.false_or, Bool.and_eq_true, beq_iff_eq] at h
    exact ⟨h.2.1.1.2, by simpa using h.2.1.2⟩
  · simp only [accepts, hk, hu', Bool.false_or, Bool.and_eq_true] at h
    exact ⟨h.1.2, by simpa using h.2.1.2⟩
  · simp only [accepts, pinnable, hk, Bool.and_eq_true] at h
    exact ⟨h.1.2, by simpa using h.1.1.2⟩
  · simp only [accepts, pinnable, hk, Bool.and_eq_true] at h
    exact ⟨h.1.1.2, by simpa using h.1.1.1.2⟩

theorem accepts_sent (w : World) (r : Row) (m : Mod) (hk : m.kind = .reaction ∨ m.kind = .vote)
    (hu : m.sender ≠ w.us) (ho : r.outgoing = true) (h : accepts w r m = true) : r.sentTo.contains m.sender = true := by
  have hu' : (m.sender == w.us) = false := by simpa using hu
  rcases hk with hk | hk <;> simp_all [accepts, sentToSender]

/-- **A message deleted for everyone accepts nothing** (its poll went with its contents). -/
theorem deleted_accepts_nothing (w : World) (r : Row) (m : Mod) (hd : r.deleted = true) (hp : r.poll = false) :
    accepts w r m = false := by
  unfold accepts
  split <;> simp_all [editValid, editable, pinnable]

theorem edit_newer (w : World) (r : Row) (m : Mod) (hk : m.kind = .edit) (h : accepts w r m = true) : r.rev < m.ts := by
  simp_all [accepts]

theorem edit_valid (w : World) (r : Row) (m : Mod) (hk : m.kind = .edit) (h : accepts w r m = true) : editValid w r m = true := by
  simp_all [accepts]

theorem edit_refuses (w : World) (r : Row) (m : Mod) (hk : m.kind = .edit) (h : r.erased = true ∨ r.viewOnce = true ∨ r.voice = true) :
    accepts w r m = false := by
  rcases h with h | h | h <;> simp_all [accepts, editValid, editable]

/-! ## 2. The waiting list -/

theorem heaviestFrom_spec (c : Entry → Nat) : ∀ (es : List Entry) (b b' : Entry),
    heaviestFrom c (some b) es = some b' → c b ≤ c b' ∧ (∀ x ∈ es, c x ≤ c b') ∧ (b' = b ∨ b' ∈ es)
  | [], b, b', h => by simp [heaviestFrom] at h; subst h; simp
  | e :: es, b, b', h => by
    simp only [heaviestFrom] at h
    by_cases hlt : c b < c e
    · simp only [hlt, ite_true] at h
      have ⟨h1, h2, h3⟩ := heaviestFrom_spec c es e b' h
      refine ⟨by omega, ?_, ?_⟩
      · intro x hx
        simp at hx
        rcases hx with rfl | hx
        · exact h1
        · exact h2 x hx
      · rcases h3 with rfl | h3 <;> simp_all
    · simp only [hlt, ite_false] at h
      have ⟨h1, h2, h3⟩ := heaviestFrom_spec c es b b' h
      refine ⟨h1, ?_, ?_⟩
      · intro x hx
        simp at hx
        rcases hx with rfl | hx
        · omega
        · exact h2 x hx
      · rcases h3 with rfl | h3 <;> simp_all

theorem heaviest_spec (l : List Entry) (b : Entry) (h : heaviest l = some b) :
    b ∈ l ∧ ∀ x ∈ l, count l x.mod.sender ≤ count l b.mod.sender := by
  unfold heaviest at h
  cases l with
  | nil => simp [heaviestFrom] at h
  | cons e es =>
    simp only [heaviestFrom] at h
    have ⟨h1, h2, h3⟩ := heaviestFrom_spec _ es e b h
    refine ⟨?_, ?_⟩
    · rcases h3 with rfl | h3 <;> simp_all
    · intro x hx
      simp at hx
      rcases hx with rfl | hx
      · exact h1
      · exact h2 x hx

/-- **An eviction takes from the sender with the most waiting.** -/
theorem evict_heaviest (l : List Entry) (h : l ≠ []) :
    ∃ b ∈ l, evict l = l.erase b ∧ ∀ x ∈ l, count l x.mod.sender ≤ count l b.mod.sender := by
  unfold evict
  cases hb : heaviest l with
  | none =>
    cases l with
    | nil => exact absurd rfl h
    | cons e es =>
      unfold heaviest at hb
      simp only [heaviestFrom] at hb
      have : ∀ (c : Entry → Nat) (es : List Entry) (b : Entry), heaviestFrom c (some b) es ≠ none := by
        intro c es
        induction es with
        | nil => intro b; simp [heaviestFrom]
        | cons e es ih => intro b; simp only [heaviestFrom]; split <;> exact ih _
      exact absurd hb (this _ es e)
  | some b =>
    have ⟨hm, hmax⟩ := heaviest_spec l b hb
    exact ⟨b, hm, rfl, hmax⟩

theorem mem_erase_of_ne' {l : List Entry} {a b : Entry} (hab : a ≠ b) (ha : a ∈ l) : a ∈ l.erase b :=
  (List.mem_erase_of_ne hab).mpr ha

/-- **A flood does not evict a lighter sender**: an entry whose sender has fewer waiting than
some other sender survives an eviction. -/
theorem evict_spares_lighter (l : List Entry) (x y : Entry) (hx : x ∈ l) (hy : y ∈ l)
    (hlt : count l x.mod.sender < count l y.mod.sender) : x ∈ evict l := by
  have hne : l ≠ [] := by intro h; simp [h] at hx
  have ⟨b, _, he, hmax⟩ := evict_heaviest l hne
  rw [he]
  have hyb := hmax y hy
  have hxb : x ≠ b := by
    intro h; subst h; omega
  exact mem_erase_of_ne' hxb hx

theorem evict_sub (l : List Entry) : ∀ x ∈ evict l, x ∈ l := by
  intro x hx
  unfold evict at hx
  split at hx
  · exact List.mem_of_mem_erase hx
  · exact hx

theorem trim_sub (limit : Nat) : ∀ (n : Nat) (l : List Entry), ∀ x ∈ trim limit n l, x ∈ l
  | 0, l, x, hx => by simpa [trim] using hx
  | n + 1, l, x, hx => by
    simp only [trim] at hx
    split at hx
    · exact evict_sub l x (trim_sub limit n (evict l) x hx)
    · exact hx

/-- The list only loses entries, and gains the new one. -/
theorem kept_sub (l : List Entry) (e : Entry) (limit now : Nat) : ∀ x ∈ kept l e limit now, x ∈ l ∨ x = e := by
  intro x hx
  unfold kept at hx
  have := trim_sub limit _ _ x hx
  simp at this
  rcases this with ⟨h, _⟩ | h
  · exact .inl h
  · exact .inr h

/-! ## Rows -/

theorem effect_gen (r : Row) (m : Mod) : (effect r m).gen = r.gen := by unfold effect; split <;> rfl
theorem effect_author (r : Row) (m : Mod) : (effect r m).author = r.author := by unfold effect; split <;> rfl
theorem effect_sentAt (r : Row) (m : Mod) : (effect r m).sentAt = r.sentAt := by unfold effect; split <;> rfl
theorem effect_conv (r : Row) (m : Mod) : (effect r m).conv = r.conv := by unfold effect; split <;> rfl

theorem upd_gen (f : Row → Row) (hf : ∀ x, (f x).gen = x.gen) (g : Nat) (x : Row) :
    (if x.gen == g then f x else x).gen = x.gen := by
  by_cases h : x.gen == g <;> simp [h, hf]

theorem find_update_ne (f : Row → Row) (hf : ∀ x, (f x).gen = x.gen) (g g' : Nat) (hne : g' ≠ g)
    (rows : List Row) : (update rows g f).find? (·.gen == g') = rows.find? (·.gen == g') := by
  unfold update
  rw [List.find?_map]
  have : ((fun x : Row => x.gen == g') ∘ fun x => if x.gen == g then f x else x) = (fun x => x.gen == g') := by
    funext x; simp only [Function.comp, upd_gen f hf]
  rw [this]
  cases h : rows.find? (·.gen == g') with
  | none => rfl
  | some y =>
    have hy := List.find?_some h
    have : y.gen ≠ g := by simp at hy; omega
    simp [this]

theorem find_update_eq (f : Row → Row) (hf : ∀ x, (f x).gen = x.gen) (g : Nat) (rows : List Row) :
    (update rows g f).find? (·.gen == g) = (rows.find? (·.gen == g)).map f := by
  unfold update
  rw [List.find?_map]
  have : ((fun x : Row => x.gen == g) ∘ fun x => if x.gen == g then f x else x) = (fun x => x.gen == g) := by
    funext x; simp only [Function.comp, upd_gen f hf]
  rw [this]
  cases h : rows.find? (·.gen == g) with
  | none => rfl
  | some y =>
    have hy := List.find?_some h
    have : y.gen = g := by simpa using hy
    simp [this]

theorem update_gens (f : Row → Row) (hf : ∀ x, (f x).gen = x.gen) (g : Nat) (rows : List Row) :
    (update rows g f).map (·.gen) = rows.map (·.gen) := by
  unfold update
  rw [List.map_map]
  congr 1
  funext x
  exact upd_gen f hf g x

theorem mem_update (f : Row → Row) (g : Nat) (rows : List Row) (r' : Row) (h : r' ∈ update rows g f) :
    ∃ r ∈ rows, r' = if r.gen == g then f r else r := by
  simp only [update, List.mem_map] at h
  have ⟨r, hr, he⟩ := h
  exact ⟨r, hr, he.symm⟩

theorem lookup_some (rows : List Row) (m : Mod) (r : Row) (h : lookup rows m = some r) : r ∈ rows ∧ resolves r m = true := by
  unfold lookup at h
  cases h1 : rows.find? (fun r => r.author == m.author && r.sentAt == m.target) with
  | some x =>
    rw [h1] at h
    simp at h
    subst h
    have hm := List.mem_of_find?_eq_some h1
    have hp := List.find?_some h1
    simp [resolves] at hp ⊢
    exact ⟨hm, hp.1, .inl hp.2⟩
  | none =>
    rw [h1] at h
    simp at h
    have hm := List.mem_of_find?_eq_some h
    have hp := List.find?_some h
    simp [resolves] at hp ⊢
    exact ⟨hm, hp.1, .inr hp.2⟩

theorem lookup_none (rows : List Row) (m : Mod) (h : lookup rows m = none) : ∀ r ∈ rows, resolves r m = false := by
  unfold lookup at h
  cases h1 : rows.find? (fun r => r.author == m.author && r.sentAt == m.target) with
  | some x => rw [h1] at h; simp at h
  | none =>
    rw [h1] at h
    simp at h
    intro r hr
    simp [List.find?_eq_none] at h1 h
    have a := h1 r hr
    have b := h r hr
    simp [resolves]
    intro ha
    exact ⟨a ha, b ha⟩


/-! ## 3. The receiver -/

structure Inv (w : World) (s : S) : Prop where
  genLt : ∀ r ∈ s.rows, r.gen < s.next
  nodup : (s.rows.map (·.gen)).Nodup
  resLt : ∀ x ∈ s.resolved, x.2.1.gen < s.next
  res : ResolvedCorrect w s
  pend : PendingUnresolvable s
  newest : NewestShown w s
  clean : ∀ r ∈ s.rows, r.deleted = true → r.poll = false

def Evolves (r r' : Row) : Prop :=
  r'.gen = r.gen ∧ r'.author = r.author ∧ r'.sentAt = r.sentAt ∧ r'.conv = r.conv ∧ r.rev ≤ r'.rev ∧ (r.deleted = true → r' = r)

/-- Within a step: no stored message disappears, each evolves, and one changes only through an
accepted modifier that named it. -/
def R (s s' : S) : Prop :=
  ∃ new, s'.resolved = new ++ s.resolved ∧
    ∀ g r, s.get g = some r → ∃ r', s'.get g = some r' ∧ Evolves r r' ∧ (r' ≠ r → ∃ x ∈ new, x.2.1.gen = g ∧ x.2.2 = true)

theorem Evolves.refl (r : Row) : Evolves r r := ⟨rfl, rfl, rfl, rfl, Nat.le_refl _, fun _ => rfl⟩

theorem R.refl (s : S) : R s s := ⟨[], by simp, fun _ r h => ⟨r, h, Evolves.refl r, fun h => absurd rfl h⟩⟩

theorem R.trans {s1 s2 s3 : S} (h1 : R s1 s2) (h2 : R s2 s3) : R s1 s3 := by
  obtain ⟨new1, e1, f1⟩ := h1
  obtain ⟨new2, e2, f2⟩ := h2
  refine ⟨new2 ++ new1, by rw [e2, e1, List.append_assoc], ?_⟩
  intro g r hr
  obtain ⟨r1, hr1, ev1, c1⟩ := f1 g r hr
  obtain ⟨r2, hr2, ev2, c2⟩ := f2 g r1 hr1
  refine ⟨r2, hr2, ?_, ?_⟩
  · obtain ⟨a1, b1, c1', d1, e1', g1⟩ := ev1
    obtain ⟨a2, b2, c2', d2, e2', g2⟩ := ev2
    refine ⟨a2.trans a1, b2.trans b1, c2'.trans c1', d2.trans d1, Nat.le_trans e1' e2', fun hd => ?_⟩
    have := g1 hd
    subst this
    exact g2 hd
  · intro hne
    by_cases h : r1 = r
    · subst h
      obtain ⟨x, hx, hg⟩ := c2 hne
      exact ⟨x, List.mem_append_left _ hx, hg⟩
    · obtain ⟨x, hx, hg⟩ := c1 h
      exact ⟨x, List.mem_append_right _ hx, hg⟩

theorem R_same {s s' : S} (hr : s'.rows = s.rows) (new : List (Mod × Row × Bool)) (hres : s'.resolved = new ++ s.resolved) : R s s' :=
  ⟨new, hres, fun g r h => ⟨r, by unfold S.get at *; rw [hr]; exact h, Evolves.refl r, fun h => absurd rfl h⟩⟩

theorem same_gen : ∀ {rows : List Row}, (rows.map (·.gen)).Nodup → ∀ {r r' : Row}, r ∈ rows → r' ∈ rows →
    r.gen = r'.gen → r = r'
  | [], _, _, _, hr, _, _ => absurd hr List.not_mem_nil
  | x :: xs, hnd, r, r', hr, hr', hg => by
    simp only [List.map_cons, List.nodup_cons] at hnd
    obtain ⟨hx, hxs⟩ := hnd
    rcases List.mem_cons.mp hr with h1 | h1 <;> rcases List.mem_cons.mp hr' with h2 | h2
    · rw [h1, h2]
    · have : r'.gen ∈ xs.map (·.gen) := List.mem_map_of_mem h2
      rw [← hg, h1] at this
      exact absurd this hx
    · have : r.gen ∈ xs.map (·.gen) := List.mem_map_of_mem h1
      rw [hg, h2] at this
      exact absurd this hx
    · exact same_gen hxs h1 h2 hg

theorem get_of_mem {rows : List Row} (hnd : (rows.map (·.gen)).Nodup) {r : Row} (hr : r ∈ rows) :
    rows.find? (·.gen == r.gen) = some r := by
  cases h : rows.find? (·.gen == r.gen) with
  | none =>
    rw [List.find?_eq_none] at h
    exact absurd (by simp) (h r hr)
  | some x =>
    have hx := List.mem_of_find?_eq_some h
    have hg : x.gen = r.gen := by simpa using List.find?_some h
    rw [same_gen hnd hx hr hg]

theorem mem_of_get {s : S} {g : Nat} {r : Row} (h : s.get g = some r) : r ∈ s.rows ∧ r.gen = g := by
  unfold S.get at h
  exact ⟨List.mem_of_find?_eq_some h, by simpa using List.find?_some h⟩

/-! ### Effects -/

theorem effect_rev (r : Row) (m : Mod) (hk : m.kind ≠ .edit) : (effect r m).rev = r.rev := by
  unfold effect; split <;> simp_all

theorem effect_edit (r : Row) (m : Mod) (hk : m.kind = .edit) : effect r m = { r with rev := m.ts, revs := m.ts :: r.revs } := by
  simp [effect, hk]

theorem effect_deleted (r : Row) (m : Mod) (h : (effect r m).deleted = true) :
    r.deleted = true ∨ m.kind = .delete ∨ m.kind = .adminDelete := by
  unfold effect at h; split at h <;> simp_all

theorem effect_deleted_false (r : Row) (m : Mod) (h : (effect r m).deleted = false) : r.deleted = false := by
  unfold effect at h; split at h <;> simp_all

theorem effect_poll (r : Row) (m : Mod) (h : (effect r m).deleted = true) (_hc : r.deleted = true → r.poll = false)
    (hnd : r.deleted = false) : (effect r m).poll = false := by
  unfold effect at h ⊢; split at h <;> simp_all

theorem resolves_effect (r : Row) (m e : Mod) (h : resolves (effect r m) e = true) :
    resolves r e = true ∨ (m.kind = .edit ∧ e.author = r.author ∧ e.target = m.ts) := by
  by_cases hk : m.kind = .edit
  · rw [effect_edit r m hk] at h
    simp only [resolves, Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq, List.contains_cons] at h ⊢
    obtain ⟨ha, hs | ht | hc⟩ := h
    · exact .inl ⟨ha, .inl hs⟩
    · exact .inr ⟨hk, ha.symm, by simpa using ht⟩
    · exact .inl ⟨ha, .inr hc⟩
  · left
    unfold effect at h
    split at h <;> simp_all [resolves]

/-! ### One modifier -/

theorem keep_case (w : World) (s s' : S) (m : Mod) (h : Inv w s) (hno : ∀ r ∈ s.rows, resolves r m = false)
    (hrows : s'.rows = s.rows) (hnext : s'.next = s.next) (hres : s'.resolved = s.resolved)
    (hp : ∀ e ∈ s'.pending, e ∈ s.pending ∨ e.mod = m) : Inv w s' ∧ R s s' := by
  refine ⟨⟨?_, ?_, ?_, ?_, ?_, ?_, ?_⟩, R_same hrows [] (by simp [hres])⟩
  · rw [hrows, hnext]; exact h.genLt
  · rw [hrows]; exact h.nodup
  · rw [hres, hnext]; exact h.resLt
  · intro x hx; rw [hres] at hx; exact h.res x hx
  · intro e he r hr
    rw [hrows] at hr
    rcases hp e he with he | he
    · exact h.pend e he r hr
    · rw [he]; exact hno r hr
  · intro r hr
    rw [hrows] at hr
    rw [hres]
    exact h.newest r hr
  · rw [hrows]; exact h.clean

theorem refused_case (w : World) (s s' : S) (m : Mod) (r : Row) (h : Inv w s) (hr : r ∈ s.rows) (hrs : resolves r m = true)
    (hok : accepts w r m = false) (hrows : s'.rows = s.rows) (hnext : s'.next = s.next)
    (hres : s'.resolved = (m, r, false) :: s.resolved) (hp : s'.pending = s.pending) : Inv w s' ∧ R s s' := by
  refine ⟨⟨?_, ?_, ?_, ?_, ?_, ?_, ?_⟩, R_same hrows [(m, r, false)] (by simp [hres])⟩
  · rw [hrows, hnext]; exact h.genLt
  · rw [hrows]; exact h.nodup
  · intro x hx
    rw [hres] at hx
    rw [hnext]
    rcases List.mem_cons.mp hx with rfl | hx
    · exact h.genLt r hr
    · exact h.resLt x hx
  · intro x hx
    rw [hres] at hx
    rcases List.mem_cons.mp hx with rfl | hx
    · exact ⟨hrs, hok.symm⟩
    · exact h.res x hx
  · intro e he r' hr'
    rw [hp] at he
    rw [hrows] at hr'
    exact h.pend e he r' hr'
  · intro r' hr'
    rw [hrows] at hr'
    have ⟨ha, hb⟩ := h.newest r' hr'
    refine ⟨fun hd x hx hg hk hv => ?_, ?_⟩
    · rw [hres] at hx
      rcases List.mem_cons.mp hx with rfl | hx
      · simp only at hg hk hv ⊢
        have := same_gen h.nodup hr hr' hg
        subst this
        simp [accepts, hk, hv] at hok
        exact hok
      · exact ha hd x hx hg hk hv
    · rcases hb with hb | ⟨x, hx, hx'⟩
      · exact .inl hb
      · rw [hres]; exact .inr ⟨x, List.mem_cons_of_mem _ hx, hx'⟩
  · rw [hrows]; exact h.clean

theorem accepted_case (w : World) (s s' : S) (m : Mod) (r : Row) (h : Inv w s) (hr : r ∈ s.rows) (hrs : resolves r m = true)
    (hok : accepts w r m = true) (hrows : s'.rows = update s.rows r.gen (effect · m)) (hnext : s'.next = s.next)
    (hres : s'.resolved = (m, r, true) :: s.resolved) (hp : ∀ e ∈ s'.pending, e ∈ s.pending)
    (hpe : ∀ e ∈ s'.pending, m.kind = .edit → targets (m.sender, m.ts) e = false) : Inv w s' ∧ R s s' := by
  have hgen : ∀ x, (effect x m).gen = x.gen := fun x => effect_gen x m
  have hnd : r.deleted = false := by
    cases hd : r.deleted
    · rfl
    · have := deleted_accepts_nothing w r m hd (h.clean r hr hd); simp_all
  -- The rows of `s'`: `r` became `effect r m`, the others are the same.
  have hrow : ∀ r' ∈ s'.rows, (r' ∈ s.rows ∧ r'.gen ≠ r.gen) ∨ r' = effect r m := by
    intro r' hr'
    rw [hrows] at hr'
    obtain ⟨r0, hr0, he⟩ := mem_update _ _ _ _ hr'
    by_cases hg : r0.gen = r.gen
    · have := same_gen h.nodup hr0 hr hg
      subst this
      simp at he
      exact .inr he
    · have : (r0.gen == r.gen) = false := by simpa using hg
      rw [this] at he
      subst he
      exact .inl ⟨hr0, hg⟩
  refine ⟨⟨?_, ?_, ?_, ?_, ?_, ?_, ?_⟩, ?_⟩
  · intro r' hr'
    rw [hnext]
    rcases hrow r' hr' with ⟨hr0, _⟩ | rfl
    · exact h.genLt r' hr0
    · rw [hgen]; exact h.genLt r hr
  · rw [hrows, update_gens _ hgen]; exact h.nodup
  · intro x hx
    rw [hres] at hx
    rw [hnext]
    rcases List.mem_cons.mp hx with rfl | hx
    · exact h.genLt r hr
    · exact h.resLt x hx
  · intro x hx
    rw [hres] at hx
    rcases List.mem_cons.mp hx with rfl | hx
    · exact ⟨hrs, hok.symm⟩
    · exact h.res x hx
  · intro e he r' hr'
    have he0 := hp e he
    rcases hrow r' hr' with ⟨hr0, _⟩ | rfl
    · exact h.pend e he0 r' hr0
    · cases hx : resolves (effect r m) e.mod
      · rfl
      · rcases resolves_effect r m e.mod hx with hx' | ⟨hk, ha, ht⟩
        · have := h.pend e he0 r hr; simp_all
        · have hs := accepts_author w r m (.inr (.inl hk)) hok
          have := hpe e he hk
          simp [targets, ha, ht, hs] at this
  · intro r' hr'
    rcases hrow r' hr' with ⟨hr0, hg0⟩ | rfl
    · have ⟨ha, hb⟩ := h.newest r' hr0
      refine ⟨fun hd x hx hg hk hv => ?_, ?_⟩
      · rw [hres] at hx
        rcases List.mem_cons.mp hx with rfl | hx
        · exact absurd hg.symm hg0
        · exact ha hd x hx hg hk hv
      · rcases hb with hb | ⟨x, hx, hx'⟩
        · exact .inl hb
        · rw [hres]; exact .inr ⟨x, List.mem_cons_of_mem _ hx, hx'⟩
    · have ⟨ha, hb⟩ := h.newest r hr
      by_cases hk : m.kind = .edit
      · rw [effect_edit r m hk]
        have hlt := edit_newer w r m hk hok
        refine ⟨fun _ x hx hg hk' hv => ?_, .inr ⟨(m, r, true), by rw [hres]; exact List.mem_cons_self .., rfl, hk, rfl, rfl⟩⟩
        rw [hres] at hx
        rcases List.mem_cons.mp hx with rfl | hx
        · exact Nat.le_refl _
        · have := ha hnd x hx hg hk' hv
          simp only
          omega
      · rw [effect_rev r m hk, effect_gen, effect_sentAt]
        refine ⟨fun hd x hx hg hk' hv => ?_, ?_⟩
        · rw [hres] at hx
          rcases List.mem_cons.mp hx with rfl | hx
          · exact absurd hk' hk
          · exact ha (effect_deleted_false r m hd) x hx hg hk' hv
        · rcases hb with hb | ⟨x, hx, hx'⟩
          · exact .inl hb
          · rw [hres]; exact .inr ⟨x, List.mem_cons_of_mem _ hx, hx'⟩
  · intro r' hr' hd
    rcases hrow r' hr' with ⟨hr0, _⟩ | rfl
    · exact h.clean r' hr0 hd
    · exact effect_poll r m hd (h.clean r hr) hnd
  · refine ⟨[(m, r, true)], by simp [hres], fun g r0 hg => ?_⟩
    have ⟨hr0, hg0⟩ := mem_of_get hg
    by_cases hgr : g = r.gen
    · have := same_gen h.nodup hr0 hr (hg0.trans hgr)
      subst this
      refine ⟨effect r0 m, ?_, ⟨effect_gen r0 m, effect_author r0 m, effect_sentAt r0 m, effect_conv r0 m, ?_, ?_⟩, ?_⟩
      · unfold S.get
        rw [hrows, hgr, find_update_eq _ hgen]
        unfold S.get at hg
        rw [hgr] at hg
        rw [hg]
        rfl
      · by_cases hk : m.kind = .edit
        · rw [effect_edit r0 m hk]; exact Nat.le_of_lt (edit_newer w r0 m hk hok)
        · rw [effect_rev r0 m hk]; exact Nat.le_refl _
      · intro hd; rw [hnd] at hd; exact absurd hd (by decide)
      · intro _; exact ⟨(m, r0, true), List.mem_singleton_self _, hgr.symm, rfl⟩
    · refine ⟨r0, ?_, Evolves.refl r0, fun h => absurd rfl h⟩
      unfold S.get
      rw [hrows, find_update_ne _ hgen _ _ hgr]
      exact hg


theorem fold_inv (w : World) (n : Nat)
    (ih : ∀ s m keep, Inv w s → Inv w (applyMod w n s m keep) ∧ R s (applyMod w n s m keep)) :
    ∀ (l : List Entry) (s : S), Inv w s →
      Inv w (l.foldl (fun s e => applyMod w n s e.mod false) s) ∧ R s (l.foldl (fun s e => applyMod w n s e.mod false) s)
  | [], s, h => ⟨h, R.refl s⟩
  | e :: es, s, h => by
    simp only [List.foldl_cons]
    have ⟨h1, r1⟩ := ih s e.mod false h
    have ⟨h2, r2⟩ := fold_inv w n ih es _ h1
    exact ⟨h2, r1.trans r2⟩

theorem applyMod_inv (w : World) : ∀ (n : Nat) (s : S) (m : Mod) (keep : Bool), Inv w s →
    Inv w (applyMod w n s m keep) ∧ R s (applyMod w n s m keep)
  | 0, s, m, keep, h => by
    simp only [applyMod]
    exact ⟨⟨h.genLt, h.nodup, h.resLt, h.res, h.pend, h.newest, h.clean⟩, R_same rfl [] (by simp)⟩
  | n + 1, s, m, keep, h => by
    cases hl : lookup s.rows m with
    | none =>
      have hno := lookup_none s.rows m hl
      cases keep with
      | true =>
        have e : applyMod w (n + 1) s m true = { s with pending := kept s.pending ⟨m, s.now⟩ pendingLimit s.now } := by
          simp [applyMod, hl]
        rw [e]
        exact keep_case w s _ m h hno rfl rfl rfl fun e he => by
          rcases kept_sub _ _ _ _ e he with he | he
          · exact .inl he
          · exact .inr (by rw [he])
      | false =>
        have e : applyMod w (n + 1) s m false = s := by simp [applyMod, hl]
        rw [e]
        exact ⟨h, R.refl s⟩
    | some r =>
      have ⟨hr, hrs⟩ := lookup_some s.rows m r hl
      cases hok : accepts w r m with
      | false =>
        have e : applyMod w (n + 1) s m keep = { s with resolved := (m, r, false) :: s.resolved } := by
          simp [applyMod, hl, hok]
        rw [e]
        exact refused_case w s _ m r h hr hrs hok rfl rfl rfl rfl
      | true =>
        by_cases hk : m.kind = .edit
        · let k := (m.sender, m.ts)
          let s3 : S := { s with resolved := (m, r, true) :: s.resolved, rows := update s.rows r.gen (effect · m),
                                 pending := s.pending.filter (!targets k ·) }
          have e : applyMod w (n + 1) s m keep =
              (sortTs (s.pending.filter (targets k))).foldl (fun s e => applyMod w n s e.mod false) s3 := by
            simp [applyMod, hl, hok, hk, s3, k]
          rw [e]
          have ⟨h3, r3⟩ := accepted_case w s s3 m r h hr hrs hok rfl rfl rfl
            (fun e he => (List.mem_filter.mp he).1)
            (fun e he _ => by simpa using (List.mem_filter.mp he).2)
          have ⟨h4, r4⟩ := fold_inv w n (applyMod_inv w n) (sortTs (s.pending.filter (targets k))) s3 h3
          exact ⟨h4, r3.trans r4⟩
        · have e : applyMod w (n + 1) s m keep =
              { s with resolved := (m, r, true) :: s.resolved, rows := update s.rows r.gen (effect · m) } := by
            simp [applyMod, hl, hok, hk]
          rw [e]
          exact accepted_case w s _ m r h hr hrs hok rfl rfl rfl (fun e he => he) (fun _ _ hk' => absurd hk' hk)

/-! ### Events -/

theorem recv_inv (w : World) (s : S) (r0 : Row) (h : Inv w s) (hnew : (s.rows.any fun x => x.author == r0.author && x.sentAt == r0.sentAt) = false) :
    Inv w (step w s (.recv r0)) ∧ R s (step w s (.recv r0)) := by
  let fr := fresh s r0
  let k := (fr.author, fr.sentAt)
  let s1 : S := { s with rows := s.rows ++ [fr], next := s.next + 1 }
  let s3 : S := { s1 with pending := s1.pending.filter (!targets k ·) }
  have e : step w s (.recv r0) = (sortTs (s1.pending.filter (targets k))).foldl
      (fun s e => applyMod w (s1.pending.length + 1) s e.mod false) s3 := by
    simp [step, hnew, s3, s1, k, fr]
  rw [e]
  have hfr : fr.gen = s.next := rfl
  have h3 : Inv w s3 := by
    refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
    · intro r hr
      simp only [s3, s1, List.mem_append, List.mem_singleton] at hr ⊢
      rcases hr with hr | rfl
      · have := h.genLt r hr; omega
      · rw [hfr]; omega
    · simp only [s3, s1, List.map_append, List.map_cons, List.map_nil]
      rw [List.nodup_append]
      refine ⟨h.nodup, by simp, ?_⟩
      intro a ha b hb
      simp at hb
      subst hb
      obtain ⟨x, hx, rfl⟩ := List.mem_map.mp ha
      have := h.genLt x hx
      intro he
      rw [he, hfr] at this
      omega
    · intro x hx
      have := h.resLt x hx
      simp only [s3, s1]
      omega
    · exact h.res
    · intro e he r hr
      simp only [s3, s1, List.mem_filter, List.mem_append, List.mem_singleton] at he hr
      rcases hr with hr | rfl
      · exact h.pend e he.1 r hr
      · have := he.2
        simp [targets, resolves, fresh, fr, k] at this ⊢
        intro ha hs
        rcases this with h1 | h1
        · exact h1 ha.symm
        · exact h1 hs.symm
    · intro r hr
      simp only [s3, s1, List.mem_append, List.mem_singleton] at hr ⊢
      rcases hr with hr | rfl
      · exact h.newest r hr
      · refine ⟨fun _ x hx hg => ?_, .inl rfl⟩
        have := h.resLt x hx
        rw [hg, hfr] at this
        omega
    · intro r hr hd
      simp only [s3, s1, List.mem_append, List.mem_singleton] at hr
      rcases hr with hr | rfl
      · exact h.clean r hr hd
      · simp [fr, fresh] at hd
  have r3 : R s s3 := by
    refine ⟨[], by simp [s3, s1], fun g r hg => ⟨r, ?_, Evolves.refl r, fun h => absurd rfl h⟩⟩
    unfold S.get at hg ⊢
    simp only [s3, s1, List.find?_append, hg]
    rfl
  have ⟨h4, r4⟩ := fold_inv w (s1.pending.length + 1) (applyMod_inv w _) (sortTs (s1.pending.filter (targets k))) s3 h3
  exact ⟨h4, r3.trans r4⟩

theorem forget_inv (w : World) (s : S) (a t : Nat) (h : Inv w s) : Inv w (step w s (.forget a t)) := by
  simp only [step]
  have hsub : ∀ r ∈ s.rows.filter (fun x => !(x.author == a && x.sentAt == t)), r ∈ s.rows := fun r hr => (List.mem_filter.mp hr).1
  refine ⟨fun r hr => h.genLt r (hsub r hr), ?_, h.resLt, h.res, fun e he r hr => h.pend e he r (hsub r hr),
    fun r hr => h.newest r (hsub r hr), fun r hr => h.clean r (hsub r hr)⟩
  exact h.nodup.sublist (List.filter_sublist.map _)

theorem step_inv (w : World) (s : S) (e : Ev) (h : Inv w s) : Inv w (step w s e) := by
  cases e with
  | recv r0 =>
    by_cases hd : (s.rows.any fun x => x.author == r0.author && x.sentAt == r0.sentAt) = true
    · simp only [step, hd, ite_true]; exact h
    · exact (recv_inv w s r0 h (by simpa using hd)).1
  | mod m => exact (applyMod_inv w _ s m _ h).1
  | forget a t => exact forget_inv w s a t h
  | tick n => simp only [step]; exact ⟨h.genLt, h.nodup, h.resLt, h.res, h.pend, h.newest, h.clean⟩

theorem init_inv (w : World) : Inv w S.init :=
  ⟨by simp [S.init], by simp [S.init], by simp [S.init], by simp [ResolvedCorrect, S.init], by simp [PendingUnresolvable, S.init],
   by simp [NewestShown, S.init], by simp [S.init]⟩

theorem reach_inv (w : World) {s : S} (h : Reach w s) : Inv w s := by
  induction h with
  | init => exact init_inv w
  | step e _ ih => exact step_inv w _ e ih

theorem R.stepOk {s s' : S} (h : R s s') : StepOk s s' := by
  obtain ⟨new, he, f⟩ := h
  refine ⟨new, he, fun g r hg => .inr ?_⟩
  obtain ⟨r', hr', ⟨_, ha, hs, hc, hrev, hd⟩, hch⟩ := f g r hg
  exact ⟨r', hr', ha, hs, hc, hrev, hd, hch⟩

/-! ## The theorems -/

/-- **A modifier acts only on the message it names, by the decision on that message** — in
every reachable state, for everything that has reached its target. -/
theorem resolvedCorrect_holds (w : World) {s : S} (h : Reach w s) : ResolvedCorrect w s := (reach_inv w h).res

/-- **Modifiers arriving before their target**: nothing waits whose target is there. -/
theorem pendingUnresolvable_holds (w : World) {s : S} (h : Reach w s) : PendingUnresolvable s := (reach_inv w h).pend

/-- **Older edits do not overwrite newer revisions**: a message shows the newest valid edit that
reached it, else its original. -/
theorem newestShown_holds (w : World) {s : S} (h : Reach w s) : NewestShown w s := (reach_inv w h).newest

/-- **No resurrection, only the target changes**: in every step a stored message keeps its
identity, its revision never goes back, once deleted for everyone it never changes again, and it
changes only through an accepted modifier that named it — or it is removed here. -/
theorem stepOk_holds (w : World) {s : S} (hs : Reach w s) (e : Ev) : StepOk s (step w s e) := by
  have h := reach_inv w hs
  cases e with
  | recv r0 =>
    by_cases hd : (s.rows.any fun x => x.author == r0.author && x.sentAt == r0.sentAt) = true
    · simp only [step, hd, ite_true]; exact (R.refl s).stepOk
    · exact (recv_inv w s r0 h (by simpa using hd)).2.stepOk
  | mod m => exact (applyMod_inv w _ s m _ h).2.stepOk
  | tick n => exact (R_same (s' := step w s (.tick n)) rfl [] (by simp [step])).stepOk
  | forget a t =>
    refine ⟨[], by simp [step], fun g r hg => ?_⟩
    have ⟨hr, hgr⟩ := mem_of_get hg
    simp only [step, S.get]
    by_cases hk : (!(r.author == a && r.sentAt == t)) = true
    · refine .inr ⟨r, ?_, rfl, rfl, rfl, Nat.le_refl _, fun _ => rfl, fun h => absurd rfl h⟩
      have hm : r ∈ s.rows.filter (fun x => !(x.author == a && x.sentAt == t)) := List.mem_filter.mpr ⟨hr, hk⟩
      rw [← hgr]
      exact get_of_mem (h.nodup.sublist (List.filter_sublist.map _)) hm
    · left
      rw [List.find?_eq_none]
      intro x hx hxg
      have hx' := (List.mem_filter.mp hx)
      have := same_gen h.nodup hx'.1 hr (by simpa [hgr] using hxg)
      subst this
      exact hk hx'.2

end Modifiers
