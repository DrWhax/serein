import Codecs.TIFF

/-! # Proofs about the TIFF model -/

namespace Codecs.TIFF

theorem bind_ok {α β : Type} {x : Except Fail α} {f : α → Except Fail β} {b : β}
    (h : (x >>= f) = Except.ok b) : ∃ a, x = .ok a ∧ f a = .ok b := by
  cases x with
  | error e => cases h
  | ok a => exact ⟨a, rfl, h⟩

theorem check_ok {b : Bool} {e : Fail} {u : Unit} (h : check b e = .ok u) : b = true := by
  unfold check at h; split at h <;> simp_all

theorem need_nat {c : Cursor} {k : Nat} (h : need c k = true) : k ≤ c.stop - c.pos := by
  simp [need] at h; omega

theorem rd_ok {bs : List Nat} {big : Bool} {k : Nat} {c : Cursor} {v : Nat} {c' : Cursor}
    (h : rd bs big k c = .ok (v, c')) : k ≤ c.stop - c.pos ∧ c' = advance c k := by
  unfold rd at h
  split at h
  · rename_i hn; simp at h; exact ⟨need_nat hn, h.2.symm⟩
  · cases h

/-- Every known field's values lie in the input. -/
def FieldsWithin (len : Nat) (fs : Fields) : Prop := ∀ t f, fs t = some f → f.lo + f.count * f.width ≤ len

theorem set_within {len : Nat} {fs : Fields} {t : Tag} {f : Field} (hw : FieldsWithin len fs)
    (hf : f.lo + f.count * f.width ≤ len) : FieldsWithin len (fs.set t f) := by
  intro u g hg
  unfold Fields.set at hg
  split at hg
  · cases hg; exact hf
  · exact hw u g hg

theorem entry_within {bs : List Nat} {big : Bool} {fs fs' : Fields} {c c' : Cursor}
    (hs : c.stop = bs.length) (hw : FieldsWithin bs.length fs) (h : entry bs big fs c = .ok (fs', c')) :
    FieldsWithin bs.length fs' ∧ c'.stop = bs.length := by
  unfold entry at h
  obtain ⟨⟨code, c1⟩, h1, h⟩ := bind_ok h
  obtain ⟨⟨type, c2⟩, h2, h⟩ := bind_ok h
  obtain ⟨⟨count, c3⟩, h3, h⟩ := bind_ok h
  obtain ⟨_, h4, h⟩ := bind_ok h
  obtain ⟨_, rfl⟩ := rd_ok h1
  obtain ⟨_, rfl⟩ := rd_ok h2
  obtain ⟨_, rfl⟩ := rd_ok h3
  have n4 := need_nat (check_ok h4)
  simp only [advance] at n4 hs h ⊢
  split at h
  · cases h; exact ⟨hw, hs⟩
  · rename_i t _
    obtain ⟨_, _, h⟩ := bind_ok h
    have hw' : ∀ lo, lo + (count * if (type == 3) = true then 2 else 4) ≤ bs.length →
        FieldsWithin bs.length (fs.set t ⟨type == 3, count, lo⟩) := fun lo hl => set_within hw (by simpa [Field.width] using hl)
    by_cases hsz : (count * if (type == 3) = true then 2 else 4) ≤ 4
    · rw [ite_eq_left hsz] at h
      cases h; exact ⟨hw' _ (by omega), hs⟩
    · rw [ite_eq_right hsz] at h
      obtain ⟨_, ha, h⟩ := bind_ok h
      obtain ⟨_, hb, h⟩ := bind_ok h
      have ha := of_decide_eq_true (check_ok ha); have hb := of_decide_eq_true (check_ok hb)
      cases h
      exact ⟨hw' _ (by omega), hs⟩

theorem entries_within (bs : List Nat) (big : Bool) : ∀ (k : Nat) (fs : Fields) (c : Cursor) (fs' : Fields) (c' : Cursor),
    c.stop = bs.length → FieldsWithin bs.length fs → entries bs big k fs c = .ok (fs', c') →
    FieldsWithin bs.length fs' ∧ c'.stop = bs.length
  | 0, fs, c, fs', c', hs, hw, h => by
    simp only [entries] at h; cases h; exact ⟨hw, hs⟩
  | k + 1, fs, c, fs', c', hs, hw, h => by
    simp only [entries] at h
    obtain ⟨⟨fs1, c1⟩, h1, h⟩ := bind_ok h
    have ⟨w1, s1⟩ := entry_within hs hw h1
    exact entries_within bs big k fs1 c1 fs' c' s1 w1 h

/-- **The directory's values lie in the input**: every field a directory keeps has all its
values inside the input, wherever its entry said they are. -/
theorem directory_within {bs : List Nat} {d : Dir} (h : directory bs = .ok d) : FieldsWithin bs.length d.fields := by
  unfold directory at h
  obtain ⟨⟨_, _⟩, _, h⟩ := bind_ok h
  obtain ⟨big, _, h⟩ := bind_ok h
  obtain ⟨⟨_, _⟩, _, h⟩ := bind_ok h
  obtain ⟨_, _, h⟩ := bind_ok h
  obtain ⟨⟨_, _⟩, _, h⟩ := bind_ok h
  obtain ⟨_, _, h⟩ := bind_ok h
  obtain ⟨⟨count, e⟩, h7, h⟩ := bind_ok h
  obtain ⟨⟨fs, e'⟩, h8, h⟩ := bind_ok h
  obtain ⟨_, _, h⟩ := bind_ok h
  cases h
  obtain ⟨_, rfl⟩ := rd_ok h7
  exact (entries_within bs big count _ _ fs e' rfl (fun _ _ hf => by cases hf) h8).1

theorem values_length {bs : List Nat} {d : Dir} {t : Tag} {n : Nat} {vs : List Nat} (h : values bs d t n = .ok vs) :
    vs.length = n := by
  unfold values at h
  split at h
  · split at h
    · cases h; simp
    · cases h
  · cases h

/-- The rows strips `i`, `i + 1`, … (`n` of them) cover. -/
def rowsFrom (height rows : Nat) : Nat → Nat → Nat
  | _, 0 => 0
  | i, n + 1 => min rows (height - i * rows) + rowsFrom height rows (i + 1) n

theorem rowsFrom_eq (h r : Nat) : ∀ n i, rowsFrom h r i n = min h ((i + n) * r) - min h (i * r)
  | 0, i => by simp [rowsFrom]
  | n + 1, i => by
    simp only [rowsFrom]
    rw [rowsFrom_eq h r n (i + 1)]
    have e1 : (i + 1) * r = i * r + r := by rw [Nat.add_mul, Nat.one_mul]
    have e2 : (i + 1 + n) * r = i * r + n * r + r := by
      rw [show i + 1 + n = i + n + 1 by omega, Nat.add_mul, Nat.add_mul, Nat.one_mul]
    have e3 : (i + (n + 1)) * r = i * r + n * r + r := by rw [← Nat.add_assoc, Nat.add_mul, Nat.add_mul, Nat.one_mul]
    rw [e1, e2, e3]
    generalize i * r = x
    generalize n * r = y
    simp only [Nat.min_def]
    split <;> split <;> split <;> split <;> omega

/-- `1 + (height − 1) / rows` strips cover every row. -/
theorem rowsFrom_all (h r : Nat) (hr : 0 < r) (hh : 0 < h) : rowsFrom h r 0 (1 + (h - 1) / r) = h := by
  rw [rowsFrom_eq]
  have hd := Nat.div_add_mod (h - 1) r
  have hm := Nat.mod_lt (h - 1) hr
  have e : (0 + (1 + (h - 1) / r)) * r = r + r * ((h - 1) / r) := by
    rw [Nat.zero_add, Nat.add_mul, Nat.one_mul, Nat.mul_comm]
  rw [e, Nat.zero_mul]
  generalize r * ((h - 1) / r) = x at hd ⊢
  generalize (h - 1) % r = m at hd hm
  simp only [Nat.min_def]
  split <;> split <;> omega

/-- Pixels of `q` bytes in the strips. -/
def pxCount (q : Nat) (ss : List (Nat × Nat)) : Nat := ss.foldr (fun s acc => s.2 / q + acc) 0

theorem strips_spec (len height rows w q : Nat) (hq : 0 < q) :
    ∀ (ps : List (Nat × Nat)) (i : Nat) (ss : List (Nat × Nat)), strips len height rows (w * q) i ps = .ok ss →
      ss = ps ∧ (∀ s ∈ ss, s.1 + s.2 ≤ len) ∧ pxCount q ss = w * rowsFrom height rows i ss.length
  | [], i, ss, h => by
    simp only [strips] at h; cases h; simp [pxCount, rowsFrom]
  | (o, n) :: rest, i, ss, h => by
    simp only [strips] at h
    split at h
    · cases h
    · rename_i hn
      split at h
      · cases h
      · rename_i ho
        split at h
        · cases h
        · rename_i hl
          split at h
          · rename_i s hs
            cases h
            have ⟨e, hw, hp⟩ := strips_spec len height rows w q hq rest (i + 1) s hs
            subst e
            simp only [bne_iff_ne, ne_eq, Decidable.not_not] at hn
            refine ⟨rfl, ?_, ?_⟩
            · intro x hx
              simp only [List.mem_cons] at hx
              rcases hx with rfl | hx
              · simp only; omega
              · exact hw x hx
            · simp only [pxCount, List.foldr_cons, List.length_cons, rowsFrom] at hp ⊢
              rw [hp, hn]
              have : w * q * min rows (height - i * rows) / q = w * min rows (height - i * rows) := by
                rw [Nat.mul_comm w q, Nat.mul_assoc]
                exact Nat.mul_div_cancel_left _ hq
              rw [this, Nat.mul_add]
          · cases h

theorem checkDims_ok {lim : Limits} {w h : Nat} {u : Unit} (hc : checkDims lim w h = .ok u) :
    0 < w ∧ 0 < h ∧ w ≤ lim.maxDimension ∧ h ≤ lim.maxDimension ∧ w * h ≤ lim.maxPixels := by
  unfold checkDims at hc
  split at hc
  · cases hc
  · rename_i h0
    split at hc
    · cases hc
    · rename_i h1
      simp only [Bool.or_eq_true, beq_iff_eq, decide_eq_true_eq, not_or, Nat.not_lt] at h0 h1
      omega

/-- What an accepted layout was checked to be. -/
theorem layout_spec {bs : List Nat} {lim : Limits} {L : Layout} (h : layout bs lim = .ok L) :
    ∃ rows ps, (∃ u, checkDims lim L.width L.height = .ok u) ∧ 0 < rows ∧
      (L.samples = L.colors ∨ L.samples = L.colors + 1) ∧ (L.bits = 8 ∨ L.bits = 16) ∧
      ps.length = 1 + (L.height - 1) / rows ∧
      strips bs.length L.height rows (L.width * L.samples * (L.bits / 8)) 0 ps = .ok L.strips := by
  unfold layout at h
  obtain ⟨_, _, h⟩ := bind_ok h
  obtain ⟨d, _, h⟩ := bind_ok h
  obtain ⟨width, _, h⟩ := bind_ok h
  obtain ⟨height, _, h⟩ := bind_ok h
  obtain ⟨u, hdims, h⟩ := bind_ok h
  obtain ⟨photo, _, h⟩ := bind_ok h
  obtain ⟨samples, _, h⟩ := bind_ok h
  obtain ⟨_, hs, h⟩ := bind_ok h
  obtain ⟨_, _, h⟩ := bind_ok h
  obtain ⟨bits, _, h⟩ := bind_ok h
  obtain ⟨_, hb, h⟩ := bind_ok h
  obtain ⟨_, _, h⟩ := bind_ok h
  obtain ⟨extra, _, h⟩ := bind_ok h
  obtain ⟨_, _, h⟩ := bind_ok h
  obtain ⟨rows, _, h⟩ := bind_ok h
  obtain ⟨_, hr, h⟩ := bind_ok h
  obtain ⟨offsets, ho, h⟩ := bind_ok h
  obtain ⟨sizes, hz, h⟩ := bind_ok h
  obtain ⟨ss, hss, h⟩ := bind_ok h
  cases h
  have hs := check_ok hs; have hb := check_ok hb; have hr := check_ok hr
  simp only [Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq, decide_eq_true_eq] at hs hb hr
  refine ⟨rows, offsets.zip sizes, ⟨u, hdims⟩, hr, ?_, hb.1, ?_, hss⟩
  · simp only [Layout.colors, beq_iff_eq]; omega
  · rw [List.length_zip, values_length ho, values_length hz, Nat.min_self]

theorem stripPixels_length (bs : List Nat) (L : Layout) : ∀ k p, (stripPixels bs L k p).length = 4 * k
  | 0, _ => rfl
  | k + 1, p => by
    simp only [stripPixels, List.length_append, stripPixels_length bs L k, pixel, List.length_cons, List.length_nil]
    omega

theorem pixels_length (bs : List Nat) (L : Layout) : (pixels bs L).length = 4 * pxCount L.bpp L.strips := by
  unfold pixels pxCount
  induction L.strips with
  | nil => rfl
  | cons s rest ih => simp only [List.foldr_cons, List.length_append, stripPixels_length, ih]; omega

/-! ## The properties -/

/-- **Within the limits.** An accepted bitmap's dimensions are positive and within the limits. -/
theorem tiff_dims {bs : List Nat} {lim : Limits} {L : Layout} (h : layout bs lim = .ok L) :
    0 < L.width ∧ 0 < L.height ∧ L.width ≤ lim.maxDimension ∧ L.height ≤ lim.maxDimension ∧ L.width * L.height ≤ lim.maxPixels := by
  obtain ⟨_, _, ⟨_, hd⟩, _⟩ := layout_spec h
  exact checkDims_ok hd

/-- **Strips lie in the input.** Every strip of an accepted bitmap is inside the input. -/
theorem tiff_strips_within {bs : List Nat} {lim : Limits} {L : Layout} (h : layout bs lim = .ok L) :
    ∀ s ∈ L.strips, s.1 + s.2 ≤ bs.length := by
  obtain ⟨rows, ps, _, _, hs, hb, _, hss⟩ := layout_spec h
  have hq : 0 < L.bpp := by simp only [Layout.bpp, Layout.colors] at hs ⊢; rcases hb with hb | hb <;> rw [hb] <;> split at hs <;> omega
  rw [show L.width * L.samples * (L.bits / 8) = L.width * L.bpp by simp only [Layout.bpp, Nat.mul_assoc]] at hss
  exact (strips_spec _ _ _ _ _ hq ps 0 _ hss).2.1

/-- **Exactly width × height pixels.** An accepted bitmap's strips hold exactly the pixels its
dimensions say, so the decoder's RGBA output has `4 · width · height` values (`PixelBuffer`'s
precondition). -/
theorem tiff_pixels_exact {bs : List Nat} {lim : Limits} {L : Layout} (h : layout bs lim = .ok L) :
    (pixels bs L).length = 4 * (L.width * L.height) := by
  obtain ⟨rows, ps, ⟨_, hd⟩, hr, hs, hb, hlen, hss⟩ := layout_spec h
  have ⟨_, hh, _⟩ := checkDims_ok hd
  have hq : 0 < L.bpp := by simp only [Layout.bpp, Layout.colors] at hs ⊢; rcases hb with hb | hb <;> rw [hb] <;> split at hs <;> omega
  rw [show L.width * L.samples * (L.bits / 8) = L.width * L.bpp by simp only [Layout.bpp, Nat.mul_assoc]] at hss
  have ⟨e, _, hp⟩ := strips_spec _ _ _ _ _ hq ps 0 _ hss
  rw [pixels_length, hp, e, hlen, rowsFrom_all _ _ hr hh]

/-- **Budget.** What an accepted layout holds besides the pixels is bounded by the limits, not
by counts in the input: at most four samples per pixel, and one strip (offset, byte count) per
row at most, so at most `maxDimension` of them. -/
theorem tiff_budget {bs : List Nat} {lim : Limits} {L : Layout} (h : layout bs lim = .ok L) :
    L.samples ≤ 4 ∧ L.strips.length ≤ lim.maxDimension := by
  obtain ⟨rows, ps, ⟨_, hd⟩, hr, hs, hb, hlen, hss⟩ := layout_spec h
  have ⟨_, hh, _, hmax, _⟩ := checkDims_ok hd
  have hq : 0 < L.bpp := by simp only [Layout.bpp, Layout.colors] at hs ⊢; rcases hb with hb | hb <;> rw [hb] <;> split at hs <;> omega
  rw [show L.width * L.samples * (L.bits / 8) = L.width * L.bpp by simp only [Layout.bpp, Nat.mul_assoc]] at hss
  have ⟨e, _, _⟩ := strips_spec _ _ _ _ _ hq ps 0 _ hss
  refine ⟨by simp only [Layout.colors] at hs; split at hs <;> omega, ?_⟩
  rw [e, hlen]
  have := Nat.div_le_self (L.height - 1) rows
  omega

end Codecs.TIFF
