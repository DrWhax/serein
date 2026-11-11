import Identity.Model
import Identity.Props

/-!
# Proofs

`approve` is one transaction: `fold_rows` gives its effect in closed form (every reviewed peer's
row approved, every other row untouched), and `valid` is evaluated on the state before any
change. `Inv` is the invariant behind the two state properties: trust is granted only for the
key on record, by the user only for a shown key, and syncs carry shown keys.
-/

namespace Identity

variable {s s' : S}

@[simp] theorem upd_same {f : Nat → α} : upd f i v i = v := by simp [upd]
theorem upd_other {f : Nat → α} (h : x ≠ i) : upd f i v x = f x := by simp [upd, h]
theorem upd_self {f : Nat → α} : upd f i (f i) = f := by funext x; simp only [upd]; split <;> simp_all

-- ## approveOne and its fold

/-- What approval does to a row: unverified goes back to default, and the key is approved. -/
def approveRow (r : Row) : Row :=
  { r with verified := if r.verified == .unverified then .dflt else r.verified, approved := true }

theorem approveRow_idem (r : Row) : approveRow (approveRow r) = approveRow r := by
  cases r with
  | mk k f re v a => cases v <;> rfl

@[simp] theorem approveRow_key : (approveRow r).key = r.key := rfl

theorem approveOne_rows (s : S) (x : Snap) : (approveOne s x).rows = upd s.rows x.peer ((s.rows x.peer).map approveRow) := by
  cases h : s.rows x.peer with
  | none =>
    simp only [approveOne, h, Option.map_none]
    funext q; simp only [upd]; split <;> simp_all
  | some r =>
    by_cases hv : r.verified = .unverified
    · simp only [approveOne, h, hv, beq_self_eq_true, ite_true, upd_same]
      funext q; simp only [upd, Option.map_some]; split
      · cases r; simp_all [approveRow]
      · rfl
    · have hb : (r.verified == .unverified) = false := by simpa using hv
      simp only [approveOne, h, hb, Bool.false_eq_true, ite_false, Option.map_some]
      funext q; simp only [upd]; split
      · cases r; simp_all [approveRow]
      · rfl

/-- The fields approval leaves alone. -/
theorem approveOne_keeps (s : S) (x : Snap) :
    (approveOne s x).aci = s.aci ∧ (approveOne s x).ourKey = s.ourKey ∧ (approveOne s x).held = s.held ∧
    (approveOne s x).pending = s.pending ∧ (approveOne s x).sent = s.sent ∧ (approveOne s x).shown = s.shown ∧
    (approveOne s x).keyChanges = s.keyChanges ∧ (approveOne s x).remoteNotices = s.remoteNotices := by
  cases h : s.rows x.peer with
  | none => simp [approveOne, h]
  | some r =>
    by_cases hv : r.verified = .unverified
    · simp [approveOne, h, hv]
    · have hb : (r.verified == .unverified) = false := by simpa using hv
      simp [approveOne, h, hb]

theorem keys_approveOne (s : S) (y : Snap) (q : Nat) :
    ((approveOne s y).rows q).map Row.key = (s.rows q).map Row.key := by
  rw [approveOne_rows]; simp only [upd]; split
  · subst_vars; cases s.rows y.peer <;> rfl
  · rfl

theorem valid_approveOne (s : S) (x y : Snap) : valid (approveOne s y) x = valid s x := by
  obtain ⟨h1, h2, -⟩ := approveOne_keeps s y
  have hk := keys_approveOne s y x.peer
  unfold valid; rw [h1, h2]
  cases ha : (approveOne s y).rows x.peer <;> cases hb : s.rows x.peer <;> simp only [ha, hb] at hk ⊢ <;> simp_all

theorem fold_rows (xs : List Snap) (s : S) (q : Nat) :
    (xs.foldl approveOne s).rows q = if xs.any (·.peer == q) then (s.rows q).map approveRow else s.rows q := by
  induction xs generalizing s with
  | nil => simp
  | cons x xs ih =>
    simp only [List.foldl_cons, ih, approveOne_rows, upd, List.any_cons]
    by_cases hq : q = x.peer
    · subst hq
      simp only [ite_true, beq_self_eq_true, Bool.true_or, Option.map_map]
      split <;> first | rfl | (congr 1; funext r; exact approveRow_idem r)
    · have : (x.peer == q) = false := by simp; omega
      simp [hq, this]

theorem fold_keeps (xs : List Snap) (s : S) :
    (xs.foldl approveOne s).aci = s.aci ∧ (xs.foldl approveOne s).ourKey = s.ourKey ∧
    (xs.foldl approveOne s).held = s.held ∧ (xs.foldl approveOne s).pending = s.pending ∧
    (xs.foldl approveOne s).sent = s.sent ∧ (xs.foldl approveOne s).shown = s.shown ∧
    (xs.foldl approveOne s).keyChanges = s.keyChanges ∧ (xs.foldl approveOne s).remoteNotices = s.remoteNotices := by
  induction xs generalizing s with
  | nil => exact ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl⟩
  | cons x xs ih =>
    obtain ⟨a1, a2, a3, a4, a5, a6, a7, a8⟩ := ih (approveOne s x)
    obtain ⟨b1, b2, b3, b4, b5, b6, b7, b8⟩ := approveOne_keeps s x
    exact ⟨a1.trans b1, a2.trans b2, a3.trans b3, a4.trans b4, a5.trans b5, a6.trans b6, a7.trans b7, a8.trans b8⟩

theorem approveOne_grant (s : S) (x : Snap) :
    (approveOne s x).grant = if (s.rows x.peer).isSome then upd s.grant x.peer (some (x.key, .user)) else s.grant := by
  cases h : s.rows x.peer with
  | none => simp [approveOne, h]
  | some r =>
    by_cases hv : r.verified = .unverified
    · simp [approveOne, h, hv]
    · have hb : (r.verified == .unverified) = false := by simpa using hv
      simp [approveOne, h, hb]

theorem approveOne_jobs (s : S) (x : Snap) :
    ∀ j ∈ (approveOne s x).jobs, j ∈ s.jobs ∨ (j.peer = x.peer ∧ j.key = x.key) := by
  intro j hj
  cases h : s.rows x.peer with
  | none => simp [approveOne, h] at hj; exact Or.inl hj
  | some r =>
    by_cases hv : r.verified = .unverified
    · simp [approveOne, h, hv] at hj
      rcases hj with hj | hj
      · exact Or.inl hj
      · subst hj; exact Or.inr ⟨rfl, rfl⟩
    · have hb : (r.verified == .unverified) = false := by simpa using hv
      simp [approveOne, h, hb] at hj; exact Or.inl hj

-- ## approve

theorem approve_stale (h : xs.all (valid s) = false) : approve xs s = { s with last := .stale } := by
  simp [approve, h]

theorem approve_rows (h : xs.all (valid s) = true) (q : Nat) :
    (approve xs s).rows q = if xs.any (·.peer == q) then (s.rows q).map approveRow else s.rows q := by
  simp only [approve, h, ite_true]; exact fold_rows xs s q

-- ## The invariant

/-- Trust (an approval or a verification) is granted for exactly the key on record; by the user,
only for a key that was shown. -/
def GrantOk (s : S) : Prop :=
  ∀ p r, s.rows p = some r → (r.approved = true ∨ r.verified = .verified) →
    ∃ src, s.grant p = some (r.key, src) ∧ (src = .user → ∃ x ∈ s.shown, x.peer = p ∧ x.key = r.key)

structure Inv (s : S) : Prop where
  grant : GrantOk s
  held : ∀ x ∈ s.held, x ∈ s.shown
  pending : ∀ xs ∈ s.pending, ∀ x ∈ xs, x ∈ s.shown
  sync : ∀ j ∈ s.jobs ++ s.sent, ∃ x ∈ s.shown, x.peer = j.peer ∧ x.key = j.key

theorem GrantOk.upd' (h : GrantOk s) (hr : s'.rows = upd s.rows p v) (hg : s'.grant = upd s.grant p g)
    (hsh : ∀ x ∈ s.shown, x ∈ s'.shown)
    (hp : ∀ r, v = some r → (r.approved = true ∨ r.verified = .verified) →
      ∃ src, g = some (r.key, src) ∧ (src = .user → ∃ x ∈ s'.shown, x.peer = p ∧ x.key = r.key)) : GrantOk s' := by
  intro q r hq ht
  rw [hr] at hq
  by_cases hqp : q = p
  · subst hqp; rw [upd_same] at hq; rw [hg, upd_same]; exact hp r hq ht
  · rw [upd_other hqp] at hq; rw [hg, upd_other hqp]
    obtain ⟨src, h1, h2⟩ := h q r hq ht
    exact ⟨src, h1, fun hu => by obtain ⟨x, hx, h3⟩ := h2 hu; exact ⟨x, hsh x hx, h3⟩⟩

theorem GrantOk.approveOne (h : GrantOk s) (hv : valid s x = true) (hx : x ∈ s.shown) : GrantOk (approveOne s x) := by
  obtain ⟨-, -, -, -, -, hsh, -⟩ := approveOne_keeps s x
  simp only [valid, Bool.and_eq_true, beq_iff_eq] at hv
  obtain ⟨-, hk⟩ := hv
  cases hr : s.rows x.peer with
  | none => rw [hr] at hk; simp at hk
  | some r =>
    rw [hr] at hk; simp only [beq_iff_eq] at hk
    refine GrantOk.upd' h (by rw [approveOne_rows, hr]; try rfl) (by rw [approveOne_grant, hr]; try rfl)
      (fun y hy => by rw [hsh]; exact hy) ?_
    intro r' hr' _
    simp only [Option.map_some, Option.some.injEq] at hr'
    subst hr'
    exact ⟨.user, by rw [approveRow_key, hk], fun _ => ⟨x, by rw [hsh]; exact hx, rfl, by rw [approveRow_key, hk]⟩⟩

theorem GrantOk.fold {xs : List Snap} (h : GrantOk s) (hv : ∀ x ∈ xs, valid s x = true) (hx : ∀ x ∈ xs, x ∈ s.shown) :
    GrantOk (xs.foldl Identity.approveOne s) := by
  induction xs generalizing s with
  | nil => exact h
  | cons x xs ih =>
    obtain ⟨-, -, -, -, -, hsh, -⟩ := approveOne_keeps s x
    refine ih (h.approveOne (hv x (by simp)) (hx x (by simp))) (fun y hy => ?_) (fun y hy => ?_)
    · rw [valid_approveOne]; exact hv y (by simp [hy])
    · rw [hsh]; exact hx y (by simp [hy])

theorem fold_jobs (xs : List Snap) (s : S) :
    ∀ j ∈ (xs.foldl approveOne s).jobs, j ∈ s.jobs ∨ ∃ x ∈ xs, j.peer = x.peer ∧ j.key = x.key := by
  induction xs generalizing s with
  | nil => intro j hj; exact Or.inl hj
  | cons x xs ih =>
    intro j hj
    rcases ih (approveOne s x) j hj with h | ⟨y, hy, h⟩
    · rcases approveOne_jobs s x j h with h | h
      · exact Or.inl h
      · exact Or.inr ⟨x, by simp, h⟩
    · exact Or.inr ⟨y, by simp [hy], h⟩

theorem Inv.approve (h : Inv s) (hx : ∀ x ∈ xs, x ∈ s.shown) : Inv (approve xs s) := by
  unfold Identity.approve
  split
  · rename_i hv
    simp only [List.all_eq_true] at hv
    obtain ⟨-, -, h3, h4, h5, h6, -⟩ := fold_keeps xs s
    refine ⟨GrantOk.fold h.grant hv hx, fun y hy => ?_, fun ys hys y hy => ?_, fun j hj => ?_⟩
    · show y ∈ (xs.foldl approveOne s).shown
      rw [h6]; exact h.held y (by rw [← h3]; exact hy)
    · show y ∈ (xs.foldl approveOne s).shown
      rw [h6]; exact h.pending ys (by rw [← h4]; exact hys) y hy
    · show ∃ x ∈ (xs.foldl approveOne s).shown, x.peer = j.peer ∧ x.key = j.key
      rw [h6]
      simp only [List.mem_append] at hj
      rcases hj with hj | hj
      · rcases fold_jobs xs s j hj with hj | ⟨x, hx', h1, h2⟩
        · exact h.sync j (by simp [hj])
        · exact ⟨x, hx x hx', h1.symm, h2.symm⟩
      · exact h.sync j (by rw [h5] at hj; simp [hj])
  · exact ⟨h.grant, h.held, h.pending, h.sync⟩

/-- Fields the invariant does not read. -/
theorem Inv.of (h : Inv s) (hr : s'.rows = s.rows) (hg : s'.grant = s.grant) (hh : s'.held = s.held)
    (hp : s'.pending = s.pending) (hj : s'.jobs = s.jobs) (hs : s'.sent = s.sent) (hsh : s'.shown = s.shown) : Inv s' := by
  refine ⟨fun q r hq ht => ?_, fun x hx => ?_, fun xs hxs x hx => ?_, fun j hjm => ?_⟩
  · rw [hr] at hq; rw [hg, hsh]; exact h.grant q r hq ht
  · rw [hsh]; rw [hh] at hx; exact h.held x hx
  · rw [hsh]; rw [hp] at hxs; exact h.pending xs hxs x hx
  · rw [hsh]; rw [hj, hs] at hjm; exact h.sync j hjm

theorem Inv.saveKey (h : Inv s) : Inv (saveKey p k s) := by
  unfold Identity.saveKey
  split
  · refine ⟨GrantOk.upd' (g := s.grant p) h.grant rfl upd_self.symm (fun _ hx => hx) ?_,
      h.held, h.pending, h.sync⟩
    intro r hr ht
    simp only [Option.some.injEq] at hr; subst hr; simp at ht
  · split
    · refine ⟨GrantOk.upd' h.grant rfl rfl (fun _ hx => hx) ?_, h.held, h.pending, h.sync⟩
      intro r' hr' ht
      simp only [Option.some.injEq] at hr'; subst hr'
      simp only at ht
      rcases ht with ht | ht
      · simp at ht
      · split at ht <;> simp at ht
    · exact h

theorem Inv.setVer (h : Inv s) (hx : x ∈ s.shown) : Inv (Identity.setVer x b s) := by
  by_cases hv : valid s x = true
  · cases hr : s.rows x.peer with
    | none =>
      simp only [Identity.setVer, hv, hr, Bool.not_true, Bool.false_eq_true, ite_false]
      exact h.of rfl rfl rfl rfl rfl rfl rfl
    | some r =>
      have hk : r.key = x.key := by simp only [valid, hr, Bool.and_eq_true, beq_iff_eq] at hv; exact hv.2
      have hsync : ∀ c, ∀ j ∈ (s.jobs ++ [⟨x.peer, x.key, c⟩]) ++ s.sent, ∃ y ∈ s.shown, y.peer = j.peer ∧ y.key = j.key := by
        intro c j hj
        simp only [List.mem_append, List.mem_singleton] at hj
        rcases hj with (hj | hj) | hj
        · exact h.sync j (by simp [hj])
        · subst hj; exact ⟨x, hx, rfl, rfl⟩
        · exact h.sync j (by simp [hj])
      cases b with
      | false =>
        by_cases hd : r.verified = .dflt
        · simp only [Identity.setVer, hv, hr, hd, Bool.not_true, Bool.false_eq_true, ite_false, beq_self_eq_true, ite_true]
          exact h.of rfl rfl rfl rfl rfl rfl rfl
        · have hb : (r.verified == VS.dflt) = false := by simpa using hd
          simp only [Identity.setVer, hv, hr, hb, Bool.not_true, Bool.false_eq_true, ite_false]
          refine ⟨GrantOk.upd' (g := s.grant x.peer) h.grant rfl upd_self.symm (fun _ hy => hy) ?_, h.held, h.pending, hsync false⟩
          intro r' hr' ht
          simp only [Option.some.injEq] at hr'; subst hr'
          simp only at ht
          rcases ht with ht | ht
          · exact h.grant x.peer r hr (Or.inl ht)
          · simp at ht
      | true =>
        by_cases hd : r.verified = .verified
        · simp only [Identity.setVer, hv, hr, hd, Bool.not_true, Bool.false_eq_true, ite_false, ite_true, beq_self_eq_true]
          exact h.of rfl rfl rfl rfl rfl rfl rfl
        · have hb : (r.verified == VS.verified) = false := by simpa using hd
          simp only [Identity.setVer, hv, hr, hb, Bool.not_true, Bool.false_eq_true, ite_false, ite_true]
          refine ⟨GrantOk.upd' h.grant rfl rfl (fun _ hy => hy) ?_, h.held, h.pending, hsync true⟩
          intro r' hr' _
          simp only [Option.some.injEq] at hr'; subst hr'
          exact ⟨.user, by simp [hk], fun _ => ⟨x, hx, rfl, by simp [hk]⟩⟩
  · have hv' : valid s x = false := by simpa using hv
    simp only [Identity.setVer, hv', Bool.not_false, ite_true]
    exact h.of rfl rfl rfl rfl rfl rfl rfl

/-- A ContactRecord's row, granted by our own devices. -/
theorem Inv.storageRow (h : Inv t) :
    Inv { t with rows := upd t.rows p (some ⟨k, f, true, v, true⟩), grant := upd t.grant p (some (k, .sync)) } := by
  refine ⟨GrantOk.upd' h.grant rfl rfl (fun _ hx => hx) ?_, h.held, h.pending, h.sync⟩
  intro r hr _
  simp only [Option.some.injEq] at hr; subst hr
  exact ⟨.sync, rfl, fun h => by cases h⟩

theorem Inv.storage (h : Inv s) : Inv (storage p k v f s) := by
  unfold Identity.storage
  simp only
  (repeat' split) <;>
    first
    | exact h
    | exact h.of rfl rfl rfl rfl rfl rfl rfl
    | exact (h.of (s' := { s with keyChanges := bump s.keyChanges p }) rfl rfl rfl rfl rfl rfl rfl).storageRow.of rfl rfl rfl rfl rfl rfl rfl
    | exact (h.of (s' := { s with keyChanges := bump s.keyChanges p }) rfl rfl rfl rfl rfl rfl rfl).storageRow
    | exact h.storageRow.of rfl rfl rfl rfl rfl rfl rfl
    | exact h.storageRow

theorem Inv.showSnap (h : Inv s) : Inv (showSnap p s) := by
  unfold Identity.showSnap
  split
  · rename_i r _
    have hsub : ∀ y ∈ s.shown, y ∈ s.shown ++ [⟨s.aci, s.ourKey, p, r.key⟩] := fun y hy => List.mem_append_left _ hy
    refine ⟨fun q r' hq ht => ?_, fun y hy => ?_, fun ys hys y hy => hsub y (h.pending ys hys y hy), fun j hj => ?_⟩
    · obtain ⟨src, h1, h2⟩ := h.grant q r' hq ht
      exact ⟨src, h1, fun hu => by obtain ⟨y, hy, h3⟩ := h2 hu; exact ⟨y, hsub y hy, h3⟩⟩
    · simp only [List.mem_append, List.mem_singleton] at hy
      rcases hy with hy | hy
      · exact hsub y (h.held y hy)
      · subst hy; exact List.mem_append_right _ (by simp)
    · obtain ⟨y, hy, h3⟩ := h.sync j hj; exact ⟨y, hsub y hy, h3⟩
  · exact h

theorem Inv.commitAt (h : Inv s) : Inv (commitAt k s) := by
  unfold Identity.commitAt
  split
  · rename_i xs hk
    have hxs : xs ∈ s.pending := List.mem_of_getElem? hk
    have h' : Inv { s with pending := s.pending.eraseIdx k } :=
      ⟨h.grant, h.held, fun ys hys => h.pending ys (List.mem_of_mem_eraseIdx hys), h.sync⟩
    exact h'.approve (h.pending xs hxs)
  · exact h

theorem Inv.step (h : Inv s) (e : Ev) : Inv (step s e) := by
  have h0 : Inv { s with last := .none } := h.of rfl rfl rfl rfl rfl rfl rfl
  unfold Identity.step
  cases e with
  | view p => exact h0.showSnap
  | confirm is =>
    simp only [stepCore]
    refine ⟨h.grant, h.held, fun xs hxs x hx => ?_, h.sync⟩
    simp only [List.mem_append, List.mem_singleton] at hxs
    rcases hxs with hxs | hxs
    · exact h.pending xs hxs x hx
    · subst hxs
      simp only [List.mem_filterMap] at hx
      obtain ⟨i, -, hi⟩ := hx
      exact h.held x (List.mem_of_getElem? hi)
  | commit k => exact h0.commitAt
  | race k p kk => exact h0.saveKey.commitAt
  | verify i b =>
    simp only [stepCore]
    split
    · rename_i x hx; exact h0.setVer (h.held x (List.mem_of_getElem? hx))
    · exact h0
  | key p k => exact h0.saveKey
  | account a k => exact h.of rfl rfl rfl rfl rfl rfl rfl
  | window p =>
    simp only [stepCore]
    split
    · rename_i r hr
      refine ⟨GrantOk.upd' (g := s.grant p) h.grant rfl upd_self.symm (fun _ hx => hx) ?_,
        h.held, h.pending, h.sync⟩
      intro r' hr' ht
      simp only [Option.some.injEq] at hr'; subst hr'
      exact h.grant p r hr ht
    · exact h0
  | storage p k v f => exact h0.storage
  | sync j =>
    simp only [stepCore]
    split
    · rename_i x hx
      refine ⟨h.grant, h.held, h.pending, fun j' hj' => h.sync j' ?_⟩
      have hj'' : j' ∈ s.jobs.eraseIdx j ++ (s.sent ++ [x]) := hj'
      simp only [List.mem_append, List.mem_singleton] at hj'' ⊢
      rcases hj'' with hj'' | hj'' | hj''
      · exact Or.inl (List.mem_of_mem_eraseIdx hj'')
      · exact Or.inr hj''
      · subst hj''; exact Or.inl (List.mem_of_getElem? hx)
    · exact h0

theorem Inv.init : Inv S.init :=
  ⟨fun _ _ h => by simp [S.init] at h, fun _ h => by simp [S.init] at h, fun _ h => by simp [S.init] at h,
   fun _ h => by simp [S.init] at h⟩

theorem Inv.reach (h : Reach s) : Inv s := by
  induction h with
  | init => exact Inv.init
  | step e _ ih => exact ih.step e

-- ## The properties

theorem sent_saveKey : (saveKey p k s).sent = s.sent := by
  unfold Identity.saveKey; split
  · rfl
  · split <;> rfl

theorem sent_approve : (approve xs s).sent = s.sent := by
  unfold Identity.approve; split
  · exact (fold_keeps xs s).2.2.2.2.1
  · rfl

theorem sent_setVer : (Identity.setVer x b s).sent = s.sent := by
  unfold Identity.setVer; simp only; (repeat' split) <;> rfl

theorem sent_storage : (Identity.storage p k v f s).sent = s.sent := by
  unfold Identity.storage; simp only; (repeat' split) <;> rfl

theorem sent_commitAt : (commitAt k s).sent = s.sent := by
  unfold commitAt; split
  · exact sent_approve
  · rfl

theorem syncExact_holds (s : S) (e : Ev) : syncExact s e (step s e) = true := by
  cases e <;> simp only [syncExact, step, stepCore]
  case view p => unfold showSnap; split <;> simp
  case confirm => simp
  case commit k => simp [sent_commitAt]
  case race k p kk => simp [sent_commitAt, sent_saveKey]
  case verify i b => split <;> simp [sent_setVer]
  case key p k => simp [sent_saveKey]
  case account => simp
  case window p => split <;> simp
  case storage p k v f => simp [sent_storage]
  case sync j => split <;> simp_all

theorem grantShown_holds (hr : Reach s) (ps : List Nat) (e : Ev) : grantShown ps s e (step s e) = true := by
  have hi := Inv.reach (Reach.step e hr)
  simp only [grantShown, List.all_eq_true]
  intro p _
  split
  · rename_i r hr'
    cases ht : (r.approved || r.verified == .verified)
    · simp
    · simp only [Bool.or_eq_true, beq_iff_eq] at ht
      obtain ⟨src, hg, hu⟩ := hi.grant p r hr' ht
      simp only [Bool.not_true, Bool.false_or, hg, beq_self_eq_true, Bool.true_and]
      cases src
      · obtain ⟨x, hx, h1, h2⟩ := hu rfl
        simp only [bne_self_eq_false, Bool.false_or, List.any_eq_true, Bool.and_eq_true, beq_iff_eq]
        exact ⟨x, hx, h1, h2⟩
      · rfl
  · rfl

theorem syncShown_holds (hr : Reach s) (e : Ev) : syncShown s e (step s e) = true := by
  have hi := Inv.reach (Reach.step e hr)
  simp only [syncShown, List.all_eq_true, List.any_eq_true, Bool.and_eq_true, beq_iff_eq]
  intro j hj
  exact hi.sync j hj

theorem storageNoSubstitute_holds (s : S) (e : Ev) : storageNoSubstitute s e (step s e) = true := by
  cases e <;> simp only [storageNoSubstitute]
  case storage p k v f =>
    cases f
    · simp only
      split
      · rename_i r hr
        cases hk : r.key == k
        · simp only [Bool.false_or]
          have : step s (.storage p k v false) = { s with last := .none } := by
            simp [step, stepCore, Identity.storage, hr, hk]
          rw [this]; simp
        · rfl
      · rfl
    · rfl

theorem keyChangeRevokes_holds (s : S) (e : Ev) : keyChangeRevokes s e (step s e) = true := by
  cases e <;> simp only [keyChangeRevokes]
  case key p k =>
    split
    · rename_i r hr
      cases hk : r.key == k
      · have hk' : r.key ≠ k := by simpa using hk
        have hsk : step s (.key p k) = { s with last := .none, rows := upd s.rows p (some ⟨k, false, true, if r.verified == .verified || r.verified == .unverified then .unverified else .dflt, false⟩), keyChanges := bump s.keyChanges p, grant := upd s.grant p none } := by
          simp [step, stepCore, Identity.saveKey, hr, hk']
        rw [hsk]
        simp only [Bool.false_or, upd_same, Bool.not_false, Bool.true_and, Bool.and_eq_true, List.all_eq_true]
        refine ⟨⟨?_, rfl⟩, fun x _ => ?_⟩
        · split <;> simp
        · by_cases hp : x.peer = p
          · by_cases hx : x.key = r.key
            · have hk2 : k ≠ x.key := by rw [hx]; exact Ne.symm hk'
              simp only [valid, hp, hx, upd_same, bne_self_eq_false, Bool.false_or]
              simp only [Bool.not_eq_true', Bool.and_eq_false_iff, beq_eq_false_iff_ne, ne_eq]
              exact Or.inr (Ne.symm hk')
            · simp [hx]
          · simp [hp]
      · simp
    · rfl
  case account a k =>
    cases ha : (a == s.aci && k == s.ourKey)
    · simp only [Bool.false_or, List.all_eq_true]
      intro x _
      simp only [step, stepCore, valid]
      cases hx : (x.aci == s.aci && x.ourKey == s.ourKey)
      · simp
      · simp only [Bool.and_eq_true, beq_iff_eq] at hx
        simp only [Bool.and_eq_false_iff, beq_eq_false_iff_ne, ne_eq] at ha
        simp only [Bool.not_true, Bool.false_or, Bool.not_eq_true', Bool.and_eq_false_iff, beq_eq_false_iff_ne, ne_eq]
        rcases ha with ha | ha
        · left; left; rw [hx.1]; exact fun h => ha h.symm
        · left; right; rw [hx.2]; exact fun h => ha h.symm
    · rfl

theorem staleNoChange_holds (ps : List Nat) (s : S) (e : Ev) : staleNoChange ps s e (step s e) = true := by
  cases e <;> simp only [staleNoChange, commitOf]
  case commit k =>
    cases hk : s.pending[k]? with
    | none => rfl
    | some xs =>
      simp only [Option.map_some]
      cases hv : xs.all (valid { s with last := .none, pending := s.pending.eraseIdx k })
      · have : step s (.commit k) = { s with last := .stale, pending := s.pending.eraseIdx k } := by
          simp only [step, stepCore, commitAt, hk]; rw [approve_stale hv]
        rw [this]; simp [trust]
      · rfl
  case race k p kk =>
    cases hk : (saveKey p kk { s with last := .none }).pending[k]? with
    | none => rfl
    | some xs =>
      simp only [Option.map_some]
      cases hv : xs.all (valid { saveKey p kk { s with last := .none } with pending := (saveKey p kk { s with last := .none }).pending.eraseIdx k })
      · have : step s (.race k p kk) = { saveKey p kk { s with last := .none } with last := .stale, pending := (saveKey p kk { s with last := .none }).pending.eraseIdx k } := by
          simp only [step, stepCore, commitAt, hk]; rw [approve_stale hv]
        rw [this]; simp [trust]
      · rfl
  case verify i b =>
    cases hx : s.held[i]? with
    | none => rfl
    | some x =>
      simp only
      cases hv : valid s x
      · have : step s (.verify i b) = { s with last := .stale } := by
          simp only [step, stepCore, hx, Identity.setVer]
          have : valid { s with last := .none } x = false := hv
          simp [this]
        rw [this]; simp [trust]
      · rfl

/-- `targets` for one commit, from the state its transaction starts in. -/
theorem targets_approve (t : S) (xs : List Snap) (ps : List Nat) :
    ((ps.all fun p => t.rows p == (approve xs t).rows p ||
      (match t.rows p, (approve xs t).rows p with
       | some r, some r' => r.key == r'.key && xs.any (fun x => x.peer == p && x.key == r.key)
       | _, _ => false)) &&
    (!xs.all (valid t) || xs.all fun x => match (approve xs t).rows x.peer with
       | some r' => r'.key == x.key && r'.approved && r'.verified != .unverified
       | none => false)) = true := by
  cases hv : xs.all (valid t)
  · rw [approve_stale hv]; simp
  · have hv' : ∀ x ∈ xs, valid t x = true := by simpa using hv
    have hkey : ∀ x ∈ xs, ∃ r, t.rows x.peer = some r ∧ r.key = x.key := by
      intro x hx
      have := hv' x hx
      simp only [valid, Bool.and_eq_true, beq_iff_eq] at this
      cases hr : t.rows x.peer with
      | none => rw [hr] at this; simp at this
      | some r => rw [hr] at this; exact ⟨r, rfl, by simpa using this.2⟩
    simp only [Bool.and_eq_true, List.all_eq_true, Bool.not_true, Bool.false_or]
    refine ⟨fun p _ => ?_, fun x hx => ?_⟩
    · rw [approve_rows hv]
      split
      · rename_i hany
        cases hr : t.rows p with
        | none => simp
        | some r =>
          simp only [Option.map_some, approveRow_key, beq_self_eq_true, Bool.true_and, Bool.or_eq_true]
          right
          obtain ⟨x, hx, hxp⟩ := List.any_eq_true.mp hany
          simp only [beq_iff_eq] at hxp
          obtain ⟨r', hr', hk⟩ := hkey x hx
          rw [hxp, hr] at hr'
          simp only [Option.some.injEq] at hr'; subst hr'
          exact List.any_eq_true.mpr ⟨x, hx, by simp [hxp, hk]⟩
      · simp
    · rw [approve_rows hv]
      have hany : xs.any (·.peer == x.peer) = true := List.any_eq_true.mpr ⟨x, hx, by simp⟩
      rw [if_pos hany]
      obtain ⟨r, hr, hk⟩ := hkey x hx
      rw [hr]
      simp only [Option.map_some, approveRow_key, hk, beq_self_eq_true, Bool.true_and, approveRow]
      cases r.verified <;> simp

theorem targets_holds (ps : List Nat) (s : S) (e : Ev) : targets ps s e (step s e) = true := by
  cases e <;> simp only [targets, commitOf]
  case commit k =>
    cases hk : s.pending[k]? with
    | none => rfl
    | some xs =>
      simp only [Option.map_some]
      have : step s (.commit k) = approve xs { s with last := .none, pending := s.pending.eraseIdx k } := by
        simp only [step, stepCore, commitAt, hk]
      rw [this]; exact targets_approve _ xs ps
  case race k p kk =>
    cases hk : (saveKey p kk { s with last := .none }).pending[k]? with
    | none => rfl
    | some xs =>
      simp only [Option.map_some]
      have : step s (.race k p kk) = approve xs { saveKey p kk { s with last := .none } with pending := (saveKey p kk { s with last := .none }).pending.eraseIdx k } := by
        simp only [step, stepCore, commitAt, hk]
      rw [this]; exact targets_approve _ xs ps
  case verify i b =>
    cases hx : s.held[i]? with
    | none => rfl
    | some x =>
      simp only [List.all_eq_true]
      intro p _
      have e1 : step s (.verify i b) = Identity.setVer x b { s with last := .none } := by simp [step, stepCore, hx]
      rw [e1]
      by_cases hv : valid s x = true
      · cases hr : s.rows x.peer with
        | none =>
          have hv0 : valid { s with last := .none } x = true := hv
          simp [Identity.setVer, hv0, hr]
        | some r =>
          have hk : r.key = x.key := by simp only [valid, hr, Bool.and_eq_true, beq_iff_eq] at hv; exact hv.2
          have hv0 : valid { s with last := .none } x = true := hv
          cases b with
          | false =>
            by_cases hd : r.verified = .dflt
            · simp [Identity.setVer, hv0, hr, hd]
            · have hb : (r.verified == VS.dflt) = false := by simpa using hd
              simp only [Identity.setVer, hv0, hr, hb, Bool.not_true, Bool.false_eq_true, ite_false]
              by_cases hp : p = x.peer
              · subst hp; simp [hr, hk]
              · simp [upd_other hp]
          | true =>
            by_cases hd : r.verified = .verified
            · simp [Identity.setVer, hv0, hr, hd]
            · have hb : (r.verified == VS.verified) = false := by simpa using hd
              simp only [Identity.setVer, hv0, hr, hb, Bool.not_true, Bool.false_eq_true, ite_false, ite_true]
              by_cases hp : p = x.peer
              · subst hp; simp [hr, hk]
              · simp [upd_other hp]
      · have hv1 : valid s x = false := by simpa using hv
        have hv0 : valid { s with last := .none } x = false := hv1
        simp [Identity.setVer, hv0]

end Identity
