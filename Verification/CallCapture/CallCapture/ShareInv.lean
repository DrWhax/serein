import CallCapture.Frames
import CallCapture.Props

/-!
# The share invariant

What makes a share token mean "this share": tokens are handed out as `tok0 + (index + 1)`
(wrapping), the current share is a created capture under its own token, and every screen-share
await, and every pending job that carries a share (its tasks, the continuations of its awaits,
its frame and stop callbacks), names a created capture by that capture's token and a stream it
owns.
`ShareInv` is a function of `S.scr` and `share` only, so the frame lemmas carry it through every
function outside the screen-share code; the screen-share functions are proved one by one.
-/

namespace CallCapture

variable {s s' : S}

def owner (s : S) (j : Nat) : Option Nat := (s.streams j).map (·.1)

def OpOk (s : S) : Op → Prop
  | .sources i tok _ _ => i < s.capNext ∧ tok = (s.caps i).tok
  | .install i _ j pt => i < s.capNext ∧ pt.tok = (s.caps i).tok ∧ owner s j = some i
  | .tdStart i _ j pt => i < s.capNext ∧ pt.tok = (s.caps i).tok ∧ owner s j = some i
  | .stopping j => (owner s j).isSome
  | .setup .. => True

def JobOk (s : S) : Job → Prop
  | .sources i tok _ _ => i < s.capNext ∧ tok = (s.caps i).tok
  | .present i pt => i < s.capNext ∧ pt.tok = (s.caps i).tok
  | .sourcesRet i tok _ _ _ => i < s.capNext ∧ tok = (s.caps i).tok
  | .installRet i _ j pt _ => i < s.capNext ∧ pt.tok = (s.caps i).tok ∧ owner s j = some i
  | .teardownRet i _ _ pt => i < s.capNext ∧ pt.tok = (s.caps i).tok
  | .scFrame i tok => i < s.capNext ∧ tok = (s.caps i).tok
  | .scStopped i tok => i < s.capNext ∧ tok = (s.caps i).tok
  | _ => True

structure ShareInv (s : S) : Prop where
  last : s.lastTok = s.tok0 + UInt64.ofNat s.capNext
  tok : ∀ x, x < s.capNext → (s.caps x).tok = s.tok0 + UInt64.ofNat (x + 1)
  share : ∀ m t, s.share = some (m, t) → m < s.capNext ∧ t = (s.caps m).tok
  ops : ∀ o ∈ s.ops, o.isScreen = true → OpOk s o
  jobs : ∀ l ∈ s.jobs, l.isData = true → JobOk s l
  capStream : ∀ i j, (s.caps i).stream = some j → owner s j = some i
  ownerLt : ∀ j i, owner s j = some i → i < s.capNext
  fresh : ∀ j, s.streamNext ≤ j → s.streams j = none

-- ## Transfer along the frame lemmas

theorem scr_eq (h : s'.scr = s.scr) :
    s'.capNext = s.capNext ∧ (∀ x, (s'.caps x).tok = (s.caps x).tok) ∧ s'.streams = s.streams ∧ s'.streamNext = s.streamNext ∧
    s'.lastTok = s.lastTok ∧ s'.tok0 = s.tok0 ∧ s'.ops.filter Op.isScreen = s.ops.filter Op.isScreen ∧
    s'.jobs.filter Job.isData = s.jobs.filter Job.isData ∧ (∀ x, (s'.caps x).stream = (s.caps x).stream) := by
  simp only [S.scr, Scr.mk.injEq] at h
  obtain ⟨h1, h2, h9, h3, h4, h5, h6, h7, h8⟩ := h
  exact ⟨h1, fun x => congrFun h2 x, h3, h4, h5, h6, h7, h8, fun x => congrFun h9 x⟩

theorem mem_filter_iff {α : Type} {p : α → Bool} {l : List α} {x : α} : x ∈ l.filter p ↔ x ∈ l ∧ p x = true :=
  List.mem_filter

theorem ShareInv.transfer (hi : ShareInv s) (h : s'.scr = s.scr) (hs : Keeps s.share s'.share) : ShareInv s' := by
  obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8, h9⟩ := scr_eq h
  have hop : ∀ o, OpOk s' o ↔ OpOk s o := by
    intro o; cases o <;> simp [OpOk, owner, h1, h2, h3]
  have hjob : ∀ l, JobOk s' l ↔ JobOk s l := by
    intro l; cases l <;> simp [JobOk, owner, h1, h2, h3]
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · rw [h5, h6, h1]; exact hi.last
  · intro x hx; rw [h2, h6]; rw [h1] at hx; exact hi.tok x hx
  · intro m t ht
    rcases hs with hs | hs
    · rw [hs] at ht; rw [h1, h2]; exact hi.share m t ht
    · rw [hs] at ht; cases ht
  · intro o ho hsc
    have : o ∈ s'.ops.filter Op.isScreen := mem_filter_iff.mpr ⟨ho, hsc⟩
    rw [h7] at this
    exact (hop o).mpr (hi.ops o (mem_filter_iff.mp this).1 hsc)
  · intro l hl hd
    have : l ∈ s'.jobs.filter Job.isData := mem_filter_iff.mpr ⟨hl, hd⟩
    rw [h8] at this
    exact (hjob l).mpr (hi.jobs l (mem_filter_iff.mp this).1 hd)
  · intro i j hj; rw [h9] at hj; simp only [owner, h3]; exact hi.capStream i j hj
  · intro j i hj; simp only [owner, h3] at hj; rw [h1]; exact hi.ownerLt j i hj
  · intro j hj; rw [h4] at hj; rw [h3]; exact hi.fresh j hj

theorem ShareInv.of_scr (hi : ShareInv s) (h : s'.scr = s.scr) (hs : s'.share = s.share) : ShareInv s' :=
  hi.transfer h (Or.inl hs)

theorem ShareInv.init (cfg : Cfg) : ShareInv (S.init cfg) := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> simp [S.init, owner, default]

-- ## Tokens identify shares (below 2^64 of them)

theorem tok_inj {t : UInt64} {a b : Nat} (ha : a < 2 ^ 64) (hb : b < 2 ^ 64)
    (h : t + UInt64.ofNat (a + 1) = t + UInt64.ofNat (b + 1)) : a = b := by
  have := congrArg UInt64.toNat h
  simp only [UInt64.toNat_add, UInt64.toNat_ofNat'] at this
  omega

/-- With at most 2^64 shares made, a share's token is no other share's. -/
theorem ShareInv.tok_eq (hi : ShareInv s) (hb : s.capNext ≤ 2 ^ 64) (hx : x < s.capNext) (hy : y < s.capNext)
    (h : (s.caps x).tok = (s.caps y).tok) : x = y := by
  rw [hi.tok x hx, hi.tok y hy] at h
  exact tok_inj (by omega) (by omega) h

/-- …so a share's token matches the current share only if it is the current share. -/
theorem ShareInv.current (hi : ShareInv s) (hb : s.capNext ≤ 2 ^ 64) (hx : x < s.capNext)
    (h : shareTokIs s (s.caps x).tok = true) : curShare s = some x := by
  simp only [shareTokIs] at h
  split at h
  · rename_i m t hsh
    obtain ⟨hm, rfl⟩ := hi.share m t hsh
    have : m = x := hi.tok_eq hb hm hx (by simpa using h)
    simp [curShare, hsh, this]
  · cases h

-- ## Primitives of the screen-share code

theorem upd_apply {α : Type} (f : Nat → α) (i : Nat) (v : α) (x : Nat) : upd f i v x = if x = i then v else f x := rfl

theorem ShareInv.emit (hi : ShareInv s) : ShareInv (emit x s) := hi.of_scr rfl rfl
theorem ShareInv.enqueue (hi : ShareInv s) : ShareInv (enqueue m s) := hi.of_scr scr_enqueue rfl
theorem ShareInv.clearShare (hi : ShareInv s) : ShareInv (clearShare s) :=
  hi.transfer scr_clearShare (by rw [share_clearShare]; exact Keeps.none)

theorem ShareInv.dropOp (hi : ShareInv s) : ShareInv (dropOp o s) := by
  refine ⟨hi.last, hi.tok, hi.share, ?_, hi.jobs, hi.capStream, hi.ownerLt, hi.fresh⟩
  intro o' ho h; exact hi.ops o' (List.mem_of_mem_erase ho) h

theorem ShareInv.addOp (hi : ShareInv s) (h : o.isScreen = true → OpOk s o) : ShareInv (addOp o s) := by
  refine ⟨hi.last, hi.tok, hi.share, ?_, hi.jobs, hi.capStream, hi.ownerLt, hi.fresh⟩
  intro o' ho hs
  simp only [CallCapture.addOp, List.mem_append, List.mem_singleton] at ho
  rcases ho with ho | rfl
  · exact hi.ops o' ho hs
  · exact h hs

theorem ShareInv.spawn (hi : ShareInv s) (h : l.isData = true → JobOk s l) : ShareInv (spawn l s) := by
  refine ⟨hi.last, hi.tok, hi.share, hi.ops, ?_, hi.capStream, hi.ownerLt, hi.fresh⟩
  intro l' hl hd
  simp only [CallCapture.spawn, List.mem_append, List.mem_singleton] at hl
  rcases hl with hl | rfl
  · exact hi.jobs l' hl hd
  · exact h hd

/-- The output flag is not part of the invariant. -/
theorem ShareInv.outOff (hi : ShareInv s) : ShareInv { s with outOff := f } := hi.of_scr rfl rfl

/-- Changing a capture's generation or `content`, or dropping its stream, keeps the invariant. -/
theorem ShareInv.setCap (hi : ShareInv s) (htok : c.tok = (s.caps i).tok)
    (hstr : ∀ j, c.stream = some j → owner s j = some i) : ShareInv (setCap i c s) := by
  have hcaps : ∀ x, ((CallCapture.setCap i c s).caps x).tok = (s.caps x).tok := by
    intro x; simp only [CallCapture.setCap, upd_apply]; split <;> simp_all
  have hop : ∀ o, OpOk (CallCapture.setCap i c s) o ↔ OpOk s o := by
    intro o; cases o <;> simp only [OpOk, owner, hcaps] <;> rfl
  have hjob : ∀ l, JobOk (CallCapture.setCap i c s) l ↔ JobOk s l := by
    intro l; cases l <;> simp only [JobOk, owner, hcaps] <;> rfl
  refine ⟨hi.last, ?_, ?_, ?_, ?_, ?_, hi.ownerLt, hi.fresh⟩
  · intro x hx; rw [hcaps]; exact hi.tok x hx
  · intro m t ht; rw [hcaps]; exact hi.share m t ht
  · intro o ho h; exact (hop o).mpr (hi.ops o ho h)
  · intro l hl h; exact (hjob l).mpr (hi.jobs l hl h)
  · intro x j hj
    simp only [CallCapture.setCap, upd_apply] at hj
    split at hj
    · subst x; exact hstr j hj
    · exact hi.capStream x j hj

theorem ShareInv.capBegin (hi : ShareInv s) : ShareInv (capBegin i s) :=
  hi.setCap rfl (fun j hj => hi.capStream i j hj)

/-- Changing a stream's phase, keeping its owner. -/
theorem ShareInv.setStream (hi : ShareInv s) (ho : owner s j = some i) : ShareInv (setStream j (some (i, ph)) s) := by
  have hown : ∀ x, owner (CallCapture.setStream j (some (i, ph)) s) x = owner s x := by
    intro x; simp only [owner, CallCapture.setStream, upd_apply]; split
    · subst x; simp only [owner, Option.map_eq_some_iff] at ho
      obtain ⟨⟨o, p⟩, h1, h2⟩ := ho; simp_all
    · rfl
  have hop : ∀ o, OpOk (CallCapture.setStream j (some (i, ph)) s) o ↔ OpOk s o := by
    intro o; cases o <;> simp only [OpOk, hown] <;> rfl
  have hjob : ∀ l, JobOk (CallCapture.setStream j (some (i, ph)) s) l ↔ JobOk s l := by
    intro l; cases l <;> simp only [JobOk, hown] <;> rfl
  refine ⟨hi.last, hi.tok, hi.share, ?_, ?_, ?_, ?_, ?_⟩
  · intro o ho h; exact (hop o).mpr (hi.ops o ho h)
  · intro l hl h; exact (hjob l).mpr (hi.jobs l hl h)
  · intro x y hy; rw [hown]; exact hi.capStream x y hy
  · intro x y hy; rw [hown] at hy; exact hi.ownerLt x y hy
  · intro x hx
    simp only [CallCapture.setStream, upd_apply]
    split
    · subst x
      have := hi.fresh j hx
      simp [owner, this] at ho
    · exact hi.fresh x hx

theorem owner_lt (hi : ShareInv s) (h : (owner s j).isSome = true) : j < s.streamNext := by
  rcases Nat.lt_or_ge j s.streamNext with h' | h'
  · exact h'
  · have := hi.fresh j h'; simp [owner, this] at h

theorem ShareInv.stopStream (hi : ShareInv s) (ho : (owner s j).isSome = true) : ShareInv (stopStream j s) := by
  simp only [CallCapture.stopStream]
  apply ShareInv.emit
  split
  · rename_i o ph hj
    exact hi.outOff.setStream (by simp [owner, hj])
  · rename_i hj; simp [owner, hj] at ho

/-- A new stream, owned by a created capture. -/
theorem ShareInv.newStream (hi : ShareInv s) (hc : i < s.capNext) :
    ShareInv (CallCapture.setStream s.streamNext (some (i, ph)) { s with streamNext := s.streamNext + 1 }) := by
  have hold : ∀ x, (owner s x).isSome = true → owner (CallCapture.setStream s.streamNext (some (i, ph)) { s with streamNext := s.streamNext + 1 }) x = owner s x := by
    intro x hx
    have := owner_lt hi hx
    simp only [owner, CallCapture.setStream, upd_apply]
    split
    · omega
    · rfl
  have hjob : ∀ l, JobOk s l → JobOk (CallCapture.setStream s.streamNext (some (i, ph)) { s with streamNext := s.streamNext + 1 }) l := by
    intro l hl
    cases l <;> try trivial
    all_goals first
      | exact hl
      | (obtain ⟨a, b, c⟩ := hl; exact ⟨a, b, by rw [hold _ (by simp [c])]; exact c⟩)
  refine ⟨hi.last, hi.tok, hi.share, ?_, fun l hl h => hjob l (hi.jobs l hl h), ?_, ?_, ?_⟩
  · intro o ho h
    have h' := hi.ops o ho h
    cases o with
    | setup => trivial
    | sources => exact h'
    | install i' cg j' pt =>
      obtain ⟨a, b, c⟩ := h'; exact ⟨a, b, by rw [hold j' (by simp [c])]; exact c⟩
    | tdStart i' cg j' pt =>
      obtain ⟨a, b, c⟩ := h'; exact ⟨a, b, by rw [hold j' (by simp [c])]; exact c⟩
    | stopping j' =>
      simp only [OpOk] at h' ⊢; rw [hold j' h']; exact h'
  · intro x y hy
    have := hi.capStream x y hy
    rw [hold _ (by simp [this])]; exact this
  · intro x y hy
    simp only [owner, CallCapture.setStream, upd_apply] at hy
    split at hy
    · simp at hy; subst hy; exact hc
    · exact hi.ownerLt x y hy
  · intro x hx
    have hx' : s.streamNext + 1 ≤ x := hx
    simp only [CallCapture.setStream, upd_apply]
    split
    · omega
    · exact hi.fresh x (by omega)

-- ## ScreenShareCapture

theorem ShareInv.capTeardown (hi : ShareInv s) : ShareInv (capTeardown i s).1 ∧
    (∀ j, (capTeardown i s).2 = some j → owner (capTeardown i s).1 j = some i) ∧
    (capTeardown i s).1.capNext = s.capNext ∧ (∀ x, ((capTeardown i s).1.caps x).tok = (s.caps x).tok) ∧
    (∀ x, owner (capTeardown i s).1 x = owner s x) ∧ (capTeardown i s).1.streamNext = s.streamNext := by
  simp only [CallCapture.capTeardown]
  split
  · rename_i j hj
    have ho := hi.capStream i j hj
    have h1 : ShareInv (CallCapture.setCap i { s.caps i with stream := none } s) :=
      hi.setCap rfl (fun j hj => by simp at hj)
    have h2 := h1.stopStream (j := j) (by
      have : owner (CallCapture.setCap i { s.caps i with stream := none } s) j = owner s j := rfl
      rw [this, ho]; rfl)
    refine ⟨h2, ?_, rfl, ?_, ?_, rfl⟩
    · intro j' hj'; cases hj'
      simp only [CallCapture.stopStream, owner, CallCapture.emit, CallCapture.setStream, upd_apply, CallCapture.setCap]
      simp only [owner, Option.map_eq_some_iff] at ho
      obtain ⟨⟨o, ph⟩, h3, h4⟩ := ho
      simp only at h4; simp [h3, h4]
    · intro x; simp only [CallCapture.stopStream, CallCapture.emit, CallCapture.setStream, CallCapture.setCap, upd_apply]
      split <;> simp_all
    · intro x
      simp only [owner, CallCapture.stopStream, CallCapture.emit, CallCapture.setStream, CallCapture.setCap, upd_apply]
      split
      · subst x; simp only [owner, Option.map_eq_some_iff] at ho
        obtain ⟨⟨o, ph⟩, h3, h4⟩ := ho
        simp only at h4; simp [h3, h4]
      · rfl
  · exact ⟨hi, by simp, rfl, by simp, by simp, rfl⟩

theorem ShareInv.capStop (hi : ShareInv s) : ShareInv (capStop i s) := by
  simp only [CallCapture.capStop]
  have hb := hi.capBegin (i := i)
  obtain ⟨h1, h2, -, -, -, -⟩ := hb.capTeardown (i := i)
  split
  · rename_i s' j heq
    rw [heq] at h1 h2
    exact h1.addOp (fun _ => by simp [OpOk, h2 j rfl])
  · rename_i s' heq
    rw [heq] at h1; exact h1

-- ## Finding awaits

theorem findSources_mem : findSources i ops = some (tok, gen, c) → .sources i tok gen c ∈ ops := by
  induction ops with
  | nil => simp [findSources]
  | cons o os ih =>
    cases o <;> simp only [findSources] <;> (try split) <;> intro h <;> simp_all

theorem findInstall_mem : findInstall j ops = some (i, cg, pt) → .install i cg j pt ∈ ops := by
  induction ops with
  | nil => simp [findInstall]
  | cons o os ih =>
    cases o <;> simp only [findInstall] <;> (try split) <;> intro h <;> simp_all

theorem findStop_mem : findStop j ops = some o → o ∈ ops := by
  induction ops with
  | nil => simp [findStop]
  | cons x xs ih =>
    cases x <;> simp only [findStop] <;> (try split) <;> intro h <;> simp_all

theorem findStop_shape : findStop j ops = some o → (∃ i cg pt, o = .tdStart i cg j pt) ∨ o = .stopping j := by
  induction ops with
  | nil => simp [findStop]
  | cons x xs ih =>
    cases x <;> simp only [findStop] <;> (try split) <;> intro h <;> (try exact ih h)
    all_goals (simp only [Option.some.injEq] at h; subst h; simp_all)

theorem tok_capBegin : ((capBegin i s).caps x).tok = (s.caps x).tok := by
  simp only [CallCapture.capBegin, CallCapture.setCap, upd_apply]; split <;> simp_all

-- ## The start path

theorem ShareInv.capStartAfterTeardown (hi : ShareInv s) (hc : i < s.capNext) (ht : pt.tok = (s.caps i).tok) :
    ShareInv (capStartAfterTeardown i cg pt s) := by
  simp only [CallCapture.capStartAfterTeardown]
  split
  · exact hi
  · have h1 := hi.newStream (i := i) (ph := .starting) hc
    apply ShareInv.addOp _ (fun _ => ?_)
    · exact h1.emit
    · simp only [OpOk]
      refine ⟨hc, ht, ?_⟩
      simp [owner, CallCapture.emit, CallCapture.setStream, upd_apply]

theorem ShareInv.capStart (hi : ShareInv s) (hc : i < s.capNext) (ht : pt.tok = (s.caps i).tok) :
    ShareInv (capStart i pt s) := by
  simp only [CallCapture.capStart]
  have hb := hi.capBegin (i := i)
  obtain ⟨h1, h2, h3, h4, -, -⟩ := hb.capTeardown (i := i)
  split <;> rename_i s' x heq <;> rw [heq] at h1 h2 h3 h4
  · rename_i j
    exact h1.addOp (fun _ => by
      simp only [OpOk]
      refine ⟨by rw [h3]; exact hc, by rw [h4, tok_capBegin]; exact ht, h2 _ rfl⟩)
  · exact h1.capStartAfterTeardown (by rw [h3]; exact hc) (by rw [h4, tok_capBegin]; exact ht)

theorem ShareInv.presentLeaf (hi : ShareInv s) (hl : JobOk s (.present i pt)) : ShareInv (presentLeaf i pt s) := by
  obtain ⟨hc, ht⟩ := hl
  simp only [CallCapture.presentLeaf]
  split
  · exact hi
  · split
    · exact hi.capStart hc ht
    · split
      · exact hi.clearShare
      · exact hi

theorem ShareInv.sourcesLeaf (hi : ShareInv s) (hl : JobOk s (.sources i t g c)) :
    ShareInv (sourcesLeaf i t g c s) := by
  simp only [CallCapture.sourcesLeaf]
  split
  · exact hi
  · exact hi.emit.addOp (fun _ => hl)

-- ## Making a share

theorem OpOk.grow (hcn : s.capNext ≤ s'.capNext) (htok : ∀ x, x < s.capNext → (s'.caps x).tok = (s.caps x).tok)
    (hown : ∀ j, owner s' j = owner s j) : OpOk s o → OpOk s' o := by
  cases o <;> simp only [OpOk, hown]
  · intro h; exact h
  · rintro ⟨h1, h2⟩; exact ⟨by omega, by rw [htok _ h1]; exact h2⟩
  · rintro ⟨h1, h2, h3⟩; exact ⟨by omega, by rw [htok _ h1]; exact h2, h3⟩
  · rintro ⟨h1, h2, h3⟩; exact ⟨by omega, by rw [htok _ h1]; exact h2, h3⟩
  · intro h; exact h

theorem JobOk.grow (hcn : s.capNext ≤ s'.capNext) (htok : ∀ x, x < s.capNext → (s'.caps x).tok = (s.caps x).tok)
    (hown : ∀ j, owner s' j = owner s j) : JobOk s l → JobOk s' l := by
  cases l <;> simp only [JobOk, hown]
  all_goals first
    | (intro h; exact h)
    | (rintro ⟨h1, h2⟩; exact ⟨by omega, by rw [htok _ h1]; exact h2⟩)
    | (rintro ⟨h1, h2, h3⟩; exact ⟨by omega, by rw [htok _ h1]; exact h2, h3⟩)

/-- A new share: capture number `capNext` under token `lastTok + 1`, and its sources task. -/
theorem ShareInv.addShare (hi : ShareInv s) (inst : Nat) (conv : Conv) :
    ShareInv (CallCapture.spawn (Job.sources s.capNext (s.lastTok + 1) s.gen conv)
      { s with lastTok := s.lastTok + 1, capNext := s.capNext + 1, share := some (s.capNext, s.lastTok + 1),
               caps := upd s.caps s.capNext { tok := s.lastTok + 1, gen := s.capGen0, stream := none, content := false, inst := inst, bumps := 0 } }) := by
  have hlast : s.lastTok + 1 = s.tok0 + UInt64.ofNat (s.capNext + 1) := by
    rw [hi.last, UInt64.ofNat_add, UInt64.add_assoc, UInt64.ofNat_one]
  generalize hc : ({ tok := s.lastTok + 1, gen := s.capGen0, stream := none, content := false, inst := inst, bumps := 0 } : Cap) = c
  have hct : c.tok = s.lastTok + 1 := by rw [← hc]
  have hcs : c.stream = none := by rw [← hc]
  let s1 : S := { s with lastTok := s.lastTok + 1, capNext := s.capNext + 1, share := some (s.capNext, s.lastTok + 1),
                         caps := upd s.caps s.capNext c }
  have htok : ∀ x, x < s.capNext → (s1.caps x).tok = (s.caps x).tok := by
    intro x hx; simp only [s1, upd_apply]; split
    · omega
    · rfl
  have hown : ∀ j, owner s1 j = owner s j := fun _ => rfl
  have h1 : ShareInv s1 := by
    refine ⟨by simp only [s1]; exact hlast, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
    · intro x hx; simp only [s1, upd_apply] at hx ⊢; split
      · subst x; rw [hct]; exact hlast
      · exact hi.tok x (by omega)
    · intro m t ht; simp only [s1, Option.some.injEq, Prod.mk.injEq] at ht
      obtain ⟨rfl, rfl⟩ := ht
      simp [s1, upd_apply, hct]
    · intro o ho h
      exact OpOk.grow (by simp [s1]) htok hown (hi.ops o ho h)
    · intro l hl h; exact JobOk.grow (by simp [s1]) htok hown (hi.jobs l hl h)
    · intro x j hj; simp only [s1, upd_apply] at hj; split at hj
      · rw [hcs] at hj; cases hj
      · exact hi.capStream x j hj
    · intro j x hj; have := hi.ownerLt j x hj; simp only [s1]; omega
    · exact hi.fresh
  exact h1.spawn (fun _ => by simp [JobOk, s1, upd_apply, hct])

theorem ShareInv.toggleShare (hi : ShareInv s) : ShareInv (toggleShare s) := by
  simp only [CallCapture.toggleShare]
  split
  · exact hi
  · rename_i a ha
    split
    · exact hi.transfer scr_stopPresenting (Or.inr share_stopPresenting)
    · -- the old share goes (with its capture), then the new one is made
      exact hi.clearShare.addShare a.inst a.conv

-- ## Sources and picking

theorem ShareInv.srcEnv (hi : ShareInv s) : ShareInv (srcEnv i ok s) := by
  simp only [CallCapture.srcEnv]
  split
  · exact hi
  · rename_i tok gen c hf
    have hop := hi.ops _ (findSources_mem hf) rfl
    exact hi.dropOp.spawn (fun _ => hop)

theorem ShareInv.srcDone (hi : ShareInv s) : ShareInv (srcDone i t gen c ok s) := by
  simp only [CallCapture.srcDone]
  split
  · have h2 : ShareInv (CallCapture.setCap i { s.caps i with content := true } s) := hi.setCap rfl (fun j hj => hi.capStream i j hj)
    split
    · exact h2.of_scr rfl rfl
    · exact h2
  · split
    · exact hi.clearShare
    · exact hi

theorem ShareInv.pickSource (hi : ShareInv s) : ShareInv (pickSource s) := by
  simp only [CallCapture.pickSource]
  have h0 : ShareInv { s with sources := false } := hi.of_scr rfl rfl
  split
  · rename_i a i tok ha hsh
    split
    · exact h0.spawn (fun _ => hi.share i tok hsh)
    · exact h0
  · exact h0

-- ## Streams: completions, frames, errors

theorem ShareInv.scStartEnv (hi : ShareInv s) : ShareInv (scStartEnv j ok s) := by
  simp only [CallCapture.scStartEnv]
  split
  · exact hi
  · rename_i i cg pt hf
    have hop := hi.ops _ (findInstall_mem hf) rfl
    simp only [OpOk] at hop
    obtain ⟨hic, hpt, hoj⟩ := hop
    have h1 := hi.dropOp (o := .install i cg j pt)
    have h2 := h1.setStream (ph := if ok then .running else .failed) (show owner (CallCapture.dropOp (.install i cg j pt) s) j = some i from hoj)
    exact h2.spawn (fun _ => ⟨hic, hpt, by simp [owner, CallCapture.setStream, upd_apply]⟩)

theorem ShareInv.installDone (hi : ShareInv s) (hl : JobOk s (.installRet i cg j pt ok)) : ShareInv (installDone i cg j pt ok s) := by
  obtain ⟨hic, hpt, hoj⟩ := hl
  simp only [CallCapture.installDone]
  split
  · split
    · exact hi.clearShare
    · exact hi
  · split
    · have h3 := hi.stopStream (j := j) (by simp [hoj])
      exact h3.addOp (fun _ => by
        simp only [OpOk, owner, CallCapture.stopStream]
        split <;> simp [CallCapture.emit, CallCapture.setStream, upd_apply])
    · have h3 := hi.setCap (i := i) (c := { s.caps i with stream := some j }) rfl (fun j' hj' => by simp at hj'; subst hj'; exact hoj)
      split
      · exact h3.capStop
      · exact h3.of_scr scr_svcSetPresenting share_svcSetPresenting

theorem ShareInv.scStopEnv (hi : ShareInv s) : ShareInv (scStopEnv j ok s) := by
  simp only [CallCapture.scStopEnv]
  split
  · exact hi
  · rename_i o hf
    have hmem := findStop_mem hf
    rcases findStop_shape hf with ⟨i, cg, pt, rfl⟩ | rfl
    · have hop := hi.ops _ hmem rfl
      simp only [OpOk, owner] at hop
      obtain ⟨hic, hpt, hoj⟩ := hop
      obtain ⟨⟨o', ph⟩, hst, ho'⟩ := Option.map_eq_some_iff.mp hoj
      simp only at ho'; subst ho'
      simp only [hst]
      have h1 := hi.dropOp (o := .tdStart o' cg j pt)
      have h2 := h1.setStream (ph := if ok then .stopped else .stopFailed) (j := j) (i := o')
        (by simp [owner, CallCapture.dropOp, hst])
      exact h2.spawn (fun _ => ⟨hic, hpt⟩)
    · have hop := hi.ops _ hmem rfl
      simp only [OpOk, owner] at hop
      obtain ⟨i, hoj⟩ := Option.isSome_iff_exists.mp hop
      obtain ⟨⟨o', ph⟩, hst, ho'⟩ := Option.map_eq_some_iff.mp hoj
      simp only at ho'; subst ho'
      simp only [hst]
      exact ((hi.dropOp).setStream (by simp [owner, CallCapture.dropOp, hst])).spawn (fun h => by simp [Job.isData] at h)

theorem ShareInv.scFrameEnv (hi : ShareInv s) : ShareInv (scFrameEnv j s) := by
  simp only [CallCapture.scFrameEnv]
  split
  · rename_i i ph hst
    split
    · exact hi.spawn (fun _ => (⟨hi.ownerLt j i (by simp [owner, hst]), rfl⟩ : JobOk s (.scFrame i (s.caps i).tok)))
    · exact hi
  · exact hi

theorem ShareInv.scStoppedEnv (hi : ShareInv s) : ShareInv (scStoppedEnv j s) := by
  simp only [CallCapture.scStoppedEnv]
  split
  · rename_i i ph hst
    have hoj : owner s j = some i := by simp [owner, hst]
    have hlt := hi.ownerLt j i hoj
    split
    · have h1 := (hi.setStream (ph := .stopped) hoj).outOff (f := upd s.outOff j true)
      exact h1.spawn (fun _ => ⟨hlt, rfl⟩)
    · exact hi.outOff.spawn (fun _ => ⟨hlt, rfl⟩)
  · exact hi

theorem ShareInv.scFrame (hi : ShareInv s) : ShareInv (scFrame i t s) := by
  simp only [CallCapture.scFrame]; (repeat' split) <;> first | exact hi | exact hi.emit

theorem ShareInv.scStopped (hi : ShareInv s) : ShareInv (scStopped t s) := by
  simp only [CallCapture.scStopped]
  split
  · exact hi.transfer scr_stopPresenting (Or.inr share_stopPresenting)
  · exact hi

-- ## Every event, every job, every step, every reachable state

theorem ShareInv.handle (hi : ShareInv s) : ShareInv (handle e s) := by
  cases e with
  | openLobby c v => exact hi.of_scr scr_openLobby share_openLobby
  | startCall => exact hi.of_scr scr_startCall share_startCall
  | accept c v => exact hi.transfer scr_acceptCall share_acceptCall
  | decline c => exact hi.of_scr scr_declineCall share_declineCall
  | hangUp => exact hi.transfer scr_hangUp (Or.inr share_hangUp)
  | closeCall => exact hi.transfer scr_endCallUI (Or.inr share_endCallUI)
  | setVideo on => exact hi.of_scr scr_setVideo share_setVideo
  | toggleShare => exact hi.toggleShare
  | pickSource => exact hi.pickSource
  | cancelPick => exact (hi.of_scr (s' := { s with sources := false }) rfl rfl).clearShare
  | run k => exact hi
  | nIncoming c v => exact hi.of_scr scr_nIncoming share_nIncoming
  | nState st => exact hi.of_scr scr_nState share_nState
  | nEnd r => exact hi.of_scr scr_nEnd share_nEnd
  | nRejected c => exact hi.of_scr scr_nRejected share_nRejected
  | setupDone q ok => exact hi.of_scr scr_setupEnv share_setupEnv
  | camAccess g => exact hi.of_scr scr_camAccessEnv share_camAccessEnv
  | camStart ok => exact hi.of_scr scr_camStartEnv share_camStartEnv
  | camStopDone => exact hi.of_scr scr_camStopEnv share_camStopEnv
  | camFrame k => exact hi.of_scr scr_camFrameEnv share_camFrameEnv
  | srcDone i ok => exact hi.srcEnv
  | scStartDone j ok => exact hi.scStartEnv
  | scStopDone j ok => exact hi.scStopEnv
  | scFrame j => exact hi.scFrameEnv
  | scStopped j => exact hi.scStoppedEnv

theorem ShareInv.runJob (hi : ShareInv s) (hl : l.isData = true → JobOk s l) : ShareInv (runJob l s) := by
  cases l with
  | recPass => exact hi.of_scr scr_recPass share_recPass
  | capStop i => exact hi.capStop
  | setupStart g c v n x => exact hi.transfer scr_setupLeaf share_setupLeaf
  | sources i t g c => exact hi.sourcesLeaf (hl rfl)
  | present i pt => exact hi.presentLeaf (hl rfl)
  | setupRet q g c r p => exact hi.transfer scr_setupDone share_setupDone
  | recRet => exact hi.of_scr scr_recResume share_recResume
  | sourcesRet i t g c ok => exact hi.srcDone
  | installRet i cg j pt ok => exact hi.installDone (hl rfl)
  | teardownRet i cg j pt => obtain ⟨hc, ht⟩ := hl rfl; exact hi.capStartAfterTeardown hc ht
  | stopRet j => exact hi
  | msg m => exact hi.transfer scr_runMsg share_runMsg
  | camFrame k => exact hi.of_scr scr_camFrame share_camFrame
  | scFrame i t => exact hi.scFrame
  | scStopped i t => exact hi.scStopped

theorem ShareInv.noteEnded (hi : ShareInv s') : ShareInv (noteEnded s s') := hi.of_scr rfl rfl

theorem ShareInv.step (hi : ShareInv s) : ShareInv (CallCapture.step s e) := by
  simp only [CallCapture.step]
  apply ShareInv.noteEnded
  have h0 : ShareInv { s with out := [] } := hi.of_scr rfl rfl
  cases e
  case run k =>
    simp only [stepCore]
    split
    · rename_i l hl
      have hmem := List.mem_of_getElem? hl
      have h1 : ShareInv { s with out := [], jobs := s.jobs.eraseIdx k } :=
        ⟨hi.last, hi.tok, hi.share, hi.ops, fun l' hl' hd => hi.jobs l' (List.mem_of_mem_eraseIdx hl') hd,
         hi.capStream, hi.ownerLt, hi.fresh⟩
      exact h1.runJob (fun hd => hi.jobs l hmem hd)
    · exact h0
  all_goals (simp only [stepCore]; exact h0.handle)

/-- **The share invariant holds in every reachable state**, from any initial counters. -/
theorem ShareInv.reach (h : Reach s) : ShareInv s := by
  induction h with
  | init cfg => exact ShareInv.init cfg
  | step e _ ih => exact ih.step
