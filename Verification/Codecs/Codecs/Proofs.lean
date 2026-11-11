import Codecs.Model
import Codecs.Props

/-!
# The proofs

1. Every primitive read from a good cursor stays in its region and hands out only what it consumed.
2. Every grammar run does (`run_within`): regions confine their sub-grammars to the declared bytes
   and are consumed exactly (`region_exact`); what repetitions allocate is bounded by the
   grammar's limits (`run_budget`).
3. The box walker keeps every box inside its container, in order, after its header; it counts
   every box, and never exceeds the budget (`children_within`, `children_budget`).
4. The bit reader's values have `n` bits and its position never passes the input.
-/

namespace Codecs

/-! ## 1. Primitives -/

theorem need_spec {c : Cursor} {n : Int} (hg : Good c) (h : need c n = true) : 0 ≤ n ∧ c.pos + n.toNat ≤ c.stop := by
  simp only [need, Bool.and_eq_true, decide_eq_true_eq] at h
  have := hg.2
  omega

theorem fixedRead_within {bs : List Nat} {c : Cursor} {k : Nat} {big : Bool} {v : Val} {c' : Cursor} (hg : Good c)
    (h : fixedRead bs c k big = .ok (v, c')) : c'.start = c.start ∧ c'.stop = c.stop ∧ c.pos ≤ c'.pos ∧ c'.pos ≤ c.stop ∧ (∃ x, v = .num x) := by
  unfold fixedRead at h
  split at h
  · rename_i hn
    simp at h
    obtain ⟨rfl, rfl⟩ := h
    have := need_spec hg hn
    simp [advance]
    omega
  · simp at h

theorem prim_within {bs : List Nat} {c : Cursor} {p : Prim} {v : Val} {c' : Cursor} (hg : Good c) (h : prim bs c p = .ok (v, c')) :
    c'.start = c.start ∧ c'.stop = c.stop ∧ c.pos ≤ c'.pos ∧ c'.pos ≤ c.stop ∧ (∀ lo hi, v = .slice lo hi → c.pos ≤ lo ∧ lo ≤ hi ∧ hi ≤ c'.pos) := by
  have noSlice : ∀ x, v = .num x → ∀ lo hi, v = .slice lo hi → c.pos ≤ lo ∧ lo ≤ hi ∧ hi ≤ c'.pos := by
    intro x hx lo hi hs; rw [hx] at hs; simp at hs
  cases p with
  | u8 | u16be | u16le | u24be | u24le | u32be | u32le =>
    have ⟨a, b, d, e, x, hx⟩ := fixedRead_within hg h
    exact ⟨a, b, d, e, noSlice x hx⟩
  | u64be =>
    simp only [prim] at h
    split at h
    · rename_i x c1 h1
      have ⟨a1, b1, d1, e1, _⟩ := fixedRead_within hg h1
      split at h
      · rename_i y c2 h2
        have hg1 : Good c1 := ⟨by have := hg.1; omega, by omega⟩
        have ⟨a2, b2, d2, e2, _⟩ := fixedRead_within hg1 h2
        simp at h
        obtain ⟨rfl, rfl⟩ := h
        exact ⟨a2.trans a1, b2.trans b1, by omega, by omega, fun lo hi hs => by simp at hs⟩
      · simp at h
      · simp at h
    · simp at h
    · simp at h
  | bytes n =>
    simp only [prim] at h
    split at h
    · rename_i hn
      simp at h
      obtain ⟨rfl, rfl⟩ := h
      have := need_spec hg hn
      refine ⟨rfl, rfl, by simp [advance], by simp [advance]; omega, fun lo hi hs => ?_⟩
      simp at hs
      obtain ⟨rfl, rfl⟩ := hs
      simp [advance]
    · simp at h
  | skip n =>
    simp only [prim] at h
    split at h
    · rename_i hn
      simp at h
      obtain ⟨rfl, rfl⟩ := h
      have := need_spec hg hn
      exact ⟨rfl, rfl, by simp [advance], by simp [advance]; omega, fun lo hi hs => by simp at hs⟩
    · simp at h
  | expect lit =>
    simp only [prim] at h
    split at h
    · simp at h
    · rename_i hn
      split at h
      · simp at h
        obtain ⟨rfl, rfl⟩ := h
        have := need_spec hg (by simpa using hn)
        exact ⟨rfl, rfl, by simp [advance], by simp [advance]; omega, fun lo hi hs => by simp at hs⟩
      · simp at h
  | rest =>
    simp only [prim] at h
    simp at h
    obtain ⟨rfl, rfl⟩ := h
    exact ⟨rfl, rfl, hg.2, Nat.le_refl _, fun lo hi hs => by simp at hs; obtain ⟨rfl, rfl⟩ := hs; exact ⟨Nat.le_refl _, hg.2, Nat.le_refl _⟩⟩

/-! ## 2. Grammars -/

/-- An accumulated run from `c0` (for the loops). -/
def Acc (c0 : Cursor) (r : R) : Prop := Within c0 r

theorem within_refl (c : Cursor) (hg : Good c) : Within c ⟨c, [], 0⟩ := ⟨rfl, rfl, Nat.le_refl _, hg.2, by simp⟩

theorem within_extend {c0 : Cursor} {acc r' : R} (ha : Within c0 acc) (hr : Within acc.c r') :
    Within c0 ⟨r'.c, acc.reads ++ r'.reads, acc.items + r'.items + 1⟩ := by
  simp only [Within] at *
  obtain ⟨a1, b1, c1, d1, e1⟩ := ha
  obtain ⟨a2, b2, c2, d2, e2⟩ := hr
  refine ⟨a2.trans a1, b2.trans b1, by omega, by rw [← b1]; omega, fun x hx => ?_⟩
  simp only [List.mem_append] at hx
  rcases hx with hx | hx
  · have := e1 x hx; omega
  · have := e2 x hx; omega

theorem good_of_within {c0 : Cursor} {r : R} (hg : Good c0) (h : Within c0 r) : Good r.c := by
  obtain ⟨a, b, c, d, _⟩ := h
  exact ⟨by rw [a]; have := hg.1; omega, by rw [b]; exact d⟩

theorem iterate_within (f : Cursor → Except Fail R) (hf : ∀ c, Good c → ∀ r, f c = .ok r → Within c r) (c0 : Cursor) (hg0 : Good c0) :
    ∀ (k : Nat) (acc r : R), Within c0 acc → iterate f k acc = .ok r → Within c0 r
  | 0, acc, r, ha, h => by simp [iterate] at h; subst h; exact ha
  | k + 1, acc, r, ha, h => by
    simp only [iterate] at h
    split at h
    · rename_i r' hr
      exact iterate_within f hf c0 hg0 k _ r (within_extend ha (hf acc.c (good_of_within hg0 ha) r' hr)) h
    · simp at h

theorem toEnd_within (f : Cursor → Except Fail R) (hf : ∀ c, Good c → ∀ r, f c = .ok r → Within c r) (max : Nat) (c0 : Cursor) (hg0 : Good c0) :
    ∀ (fuel n : Nat) (acc r : R), Within c0 acc → toEndLoop f max fuel n acc = .ok r → Within c0 r
  | 0, n, acc, r, ha, h => by
    simp only [toEndLoop] at h
    split at h
    · simp at h
    · simp at h; subst h; exact ha
  | fuel + 1, n, acc, r, ha, h => by
    simp only [toEndLoop] at h
    split at h
    · simp at h; subst h; exact ha
    · split at h
      · simp at h
      · split at h
        · rename_i r' hr
          split at h
          · simp at h
          · exact toEnd_within f hf max c0 hg0 fuel (n + 1) _ r (within_extend ha (hf acc.c (good_of_within hg0 ha) r' hr)) h
        · simp at h

theorem complete_within (f : Cursor → Except Fail R) (hf : ∀ c, Good c → ∀ r, f c = .ok r → Within c r) (lo hi : Nat) (hlh : lo ≤ hi)
    (r : R) (h : complete f lo hi = .ok r) : r.c.pos = hi ∧ ∀ x ∈ r.reads, lo ≤ x.1 ∧ x.1 ≤ x.2 ∧ x.2 ≤ hi := by
  unfold complete at h
  split at h
  · rename_i r0 h0
    split at h
    · rename_i heq
      simp at h
      subst h
      have hp : r0.c.pos = hi := by simpa using heq
      have ⟨_, _, _, _, hr⟩ := hf ⟨lo, lo, hi⟩ ⟨Nat.le_refl _, hlh⟩ r0 h0
      exact ⟨hp, fun x hx => by have := hr x hx; simp only at this; omega⟩
    · simp at h
  · simp at h

/-- **Reads stay in their region.** -/
theorem run_within (bs : List Nat) : ∀ (g : G) (c : Cursor), Good c → ∀ r, run bs g c = .ok r → Within c r
  | .prim p, c, hg, r, h => by
    simp only [run] at h
    split at h
    · rename_i v c' hp
      simp at h
      subst h
      have ⟨a, b, d, e, f⟩ := prim_within hg hp
      refine ⟨a, b, d, e, fun x hx => ?_⟩
      unfold readRange at hx
      split at hx
      · rename_i lo hi
        simp at hx
        rcases hx with rfl | rfl
        · exact ⟨Nat.le_refl _, d, Nat.le_refl _⟩
        · exact f lo hi rfl
      · simp at hx; subst hx; exact ⟨Nat.le_refl _, d, Nat.le_refl _⟩
    · simp at h
  | .seq a b, c, hg, r, h => by
    simp only [run] at h
    split at h
    · rename_i ra ha
      split at h
      · rename_i rb hb
        simp at h
        subst h
        have wa := run_within bs a c hg ra ha
        have wb := run_within bs b ra.c (good_of_within hg wa) rb hb
        simp only [Within] at wa wb ⊢
        obtain ⟨a1, b1, c1, d1, e1⟩ := wa
        obtain ⟨a2, b2, c2, d2, e2⟩ := wb
        refine ⟨a2.trans a1, b2.trans b1, by omega, by rw [← b1]; omega, fun x hx => ?_⟩
        simp only [List.mem_append] at hx
        rcases hx with hx | hx
        · have := e1 x hx; omega
        · have := e2 x hx; omega
      · simp at h
    · simp at h
  | .region n g, c, hg, r, h => by
    simp only [run] at h
    split at h
    · rename_i hn
      have ⟨h0, hle⟩ := need_spec hg hn
      split at h
      · rename_i r0 h0'
        simp at h
        subst h
        have ⟨_, hr⟩ := complete_within (run bs g) (fun c hc r h => run_within bs g c hc r h) _ _ (by omega) r0 h0'
        refine ⟨rfl, rfl, by simp [advance], by simp [advance]; omega, fun x hx => ?_⟩
        simp only [List.mem_cons] at hx
        rcases hx with rfl | hx
        · simp [advance]
        · have := hr x hx; simp [advance]; omega
      · simp at h
    · simp at h
  | .lenPrefixed w max g, c, hg, r, h => by
    simp only [run] at h
    split at h
    · rename_i len c1 hp
      have ⟨a1, b1, d1, e1, _⟩ := prim_within hg hp
      have hg1 : Good c1 := ⟨by rw [a1]; have := hg.1; omega, by rw [b1]; exact e1⟩
      split at h
      · simp at h
      · split at h
        · rename_i hn
          have ⟨_, hle⟩ := need_spec hg1 hn
          simp only [Int.toNat_natCast] at hle
          split at h
          · rename_i r0 h0'
            simp at h
            subst h
            have ⟨_, hr⟩ := complete_within (run bs g) (fun c hc r h => run_within bs g c hc r h) _ _ (by omega) r0 h0'
            refine ⟨by simp [advance, a1], by simp [advance, b1], by simp [advance]; omega, by simp [advance]; rw [← b1]; omega, fun x hx => ?_⟩
            simp only [List.mem_cons] at hx
            rcases hx with rfl | hx
            · simp [advance]; omega
            · have := hr x hx; simp [advance]; omega
          · simp at h
        · simp at h
    · simp at h
    · simp at h
  | .repeated count max g, c, hg, r, h => by
    simp only [run] at h
    split at h
    · simp at h
    · split at h
      · simp at h
      · exact iterate_within (run bs g) (fun c hc r h => run_within bs g c hc r h) c hg _ _ r (within_refl c hg) h
  | .toEnd max g, c, hg, r, h => by
    simp only [run] at h
    exact toEnd_within (run bs g) (fun c hc r h => run_within bs g c hc r h) max c hg _ _ _ r (within_refl c hg) h
  | .oneOf a b, c, hg, r, h => by
    simp only [run] at h
    split at h
    · rename_i ra ha
      simp at h; subst h
      exact run_within bs a c hg _ ha
    · split at h
      · rename_i rb hb
        simp at h; subst h
        exact run_within bs b c hg _ hb
      · simp at h

/-- **A region is consumed exactly**: the run continues just after the declared bytes. -/
theorem region_exact (bs : List Nat) (n : Int) (g : G) (c : Cursor) (hg : Good c) (r : R) (h : run bs (.region n g) c = .ok r) :
    0 ≤ n ∧ r.c.pos = c.pos + n.toNat := by
  simp only [run] at h
  split at h
  · rename_i hn
    have ⟨h0, _⟩ := need_spec hg hn
    split at h
    · simp at h; subst h; exact ⟨h0, rfl⟩
    · simp at h
  · simp at h

theorem iterate_budget (f : Cursor → Except Fail R) (b : Nat) (hf : ∀ c r, f c = .ok r → r.items ≤ b) :
    ∀ (k : Nat) (acc r : R), iterate f k acc = .ok r → r.items ≤ acc.items + k * (1 + b)
  | 0, acc, r, h => by simp [iterate] at h; subst h; simp
  | k + 1, acc, r, h => by
    simp only [iterate] at h
    split at h
    · rename_i r' hr
      have := iterate_budget f b hf k _ r h
      have := hf _ r' hr
      simp only at *
      rw [Nat.succ_mul]
      omega
    · simp at h

theorem toEnd_budget (f : Cursor → Except Fail R) (b max : Nat) (hf : ∀ c r, f c = .ok r → r.items ≤ b) :
    ∀ (fuel n : Nat) (acc r : R), n ≤ max → acc.items ≤ n * (1 + b) → toEndLoop f max fuel n acc = .ok r → r.items ≤ max * (1 + b)
  | 0, n, acc, r, hn, ha, h => by
    simp only [toEndLoop] at h
    split at h
    · simp at h
    · simp at h; subst h; exact Nat.le_trans ha (Nat.mul_le_mul_right _ hn)
  | fuel + 1, n, acc, r, hn, ha, h => by
    simp only [toEndLoop] at h
    split at h
    · simp at h; subst h; exact Nat.le_trans ha (Nat.mul_le_mul_right _ hn)
    · split at h
      · simp at h
      · rename_i hlt
        split at h
        · rename_i r' hr
          split at h
          · simp at h
          · have := hf _ r' hr
            refine toEnd_budget f b max hf fuel (n + 1) _ r (by omega) ?_ h
            simp only
            rw [Nat.succ_mul]
            omega
        · simp at h

/-- **Budget preservation**: what a grammar's repetitions allocate is bounded by its limits. -/
theorem run_budget (bs : List Nat) : ∀ (g : G) (c : Cursor) (r : R), run bs g c = .ok r → r.items ≤ budget g
  | .prim p, c, r, h => by
    simp only [run] at h
    split at h
    · simp at h; subst h; simp
    · simp at h
  | .seq a b, c, r, h => by
    simp only [run] at h
    split at h
    · rename_i ra ha
      split at h
      · rename_i rb hb
        simp at h; subst h
        have := run_budget bs a c ra ha
        have := run_budget bs b ra.c rb hb
        simp only [budget]
        omega
      · simp at h
    · simp at h
  | .region n g, c, r, h => by
    simp only [run] at h
    split at h
    · split at h
      · rename_i r0 h0
        simp at h; subst h
        simp only [budget]
        unfold complete at h0
        split at h0
        · rename_i r1 h1
          split at h0
          · simp at h0; subst h0; exact run_budget bs g _ _ h1
          · simp at h0
        · simp at h0
      · simp at h
    · simp at h
  | .lenPrefixed w max g, c, r, h => by
    simp only [run] at h
    split at h
    · split at h
      · simp at h
      · split at h
        · split at h
          · rename_i r0 h0
            simp at h; subst h
            simp only [budget]
            unfold complete at h0
            split at h0
            · rename_i r1 h1
              split at h0
              · simp at h0; subst h0; exact run_budget bs g _ _ h1
              · simp at h0
            · simp at h0
          · simp at h
        · simp at h
    · simp at h
    · simp at h
  | .repeated count max g, c, r, h => by
    simp only [run] at h
    split at h
    · simp at h
    · split at h
      · simp at h
      · rename_i hneg hle
        have := iterate_budget (run bs g) (budget g) (fun c r h => run_budget bs g c r h) _ _ r h
        simp only [budget]
        have hk : count.toNat ≤ max := by omega
        simp only at this
        exact Nat.le_trans this (by rw [Nat.zero_add]; exact Nat.mul_le_mul_right _ hk)
  | .toEnd max g, c, r, h => by
    simp only [run] at h
    simp only [budget]
    exact toEnd_budget (run bs g) (budget g) max (fun c r h => run_budget bs g c r h) _ 0 _ r (Nat.zero_le _) (by simp) h
  | .oneOf a b, c, r, h => by
    simp only [run] at h
    simp only [budget]
    split at h
    · simp at h; subst h
      exact Nat.le_trans (run_budget bs a c _ (by assumption)) (Nat.le_max_left _ _)
    · split at h
      · simp at h; subst h
        exact Nat.le_trans (run_budget bs b c _ (by assumption)) (Nat.le_max_right _ _)
      · simp at h

/-! ## 3. Boxes -/

theorem header_spec {bs : List Nat} {pos hi : Nat} {top : Bool} {t p size : Nat} (h : header bs pos hi top = .ok (t, p, size)) (hp : pos + 8 ≤ hi) :
    pos + 8 ≤ p ∧ p ≤ hi := by
  unfold header at h
  simp only at h
  split at h
  · simp at h
  · rename_i p0 sz hs
    have hp0 : pos + 8 ≤ p0 ∧ p0 ≤ hi := by
      split at hs
      · split at hs
        · simp at hs
        · split at hs
          · simp at hs
          · simp at hs; omega
      · split at hs
        · split at hs
          · simp at hs; omega
          · simp at hs
        · simp at hs; omega
    split at h
    · split at h
      · simp at h
      · simp at h; omega
    · simp at h; omega

theorem boxes_spec (bs : List Nat) (hi : Nat) (top : Bool) (maxBoxes : Nat) :
    ∀ (fuel pos : Nat) (out : List Box) (count : Nat) (res : List Box × Nat), pos ≤ hi →
      boxes bs hi top maxBoxes fuel pos out count = .ok res →
      ∃ more, res.1 = out ++ more ∧ res.2 = count + more.length ∧ (more ≠ [] → res.2 ≤ maxBoxes) ∧
        (∀ b ∈ more, pos ≤ b.offset ∧ b.offset + 8 ≤ b.lo ∧ b.lo ≤ b.hi ∧ b.hi ≤ hi) ∧ more.Pairwise (fun a b => a.hi ≤ b.offset)
  | 0, pos, out, count, res, _, h => by simp [boxes] at h; subst h; exact ⟨[], by simp, by simp, by simp, by simp, by simp⟩
  | fuel + 1, pos, out, count, res, hp, h => by
    simp only [boxes] at h
    split at h
    · simp at h; subst h; exact ⟨[], by simp, by simp, by simp, by simp, by simp⟩
    · split at h
      · split at h
        · simp at h; subst h; exact ⟨[], by simp, by simp, by simp, by simp, by simp⟩
        · simp at h
      · rename_i hlt h8
        split at h
        · simp at h
        · rename_i t p size hh
          have ⟨hp8, hph⟩ := header_spec hh (by omega)
          split at h
          · simp at h
          · split at h
            · split at h
              · split at h
                · simp at h
                · simp at h; subst h
                  refine ⟨[⟨t, pos, p, hi⟩], by simp, by simp, by simp; omega, ?_, by simp⟩
                  intro b hb; simp at hb; subst hb; simp; omega
              · simp at h
            · split at h
              · simp at h
              · rename_i hbody hcount
                obtain ⟨more, h1, h2, h3, h4, h5⟩ := boxes_spec bs hi top maxBoxes fuel _ _ _ res (by omega) h
                refine ⟨⟨t, pos, p, p + (size - (p - pos))⟩ :: more, by rw [h1]; simp, by rw [h2]; simp; omega, fun _ => ?_, ?_, ?_⟩
                · by_cases hm : more = []
                  · subst hm; simp at h2; omega
                  · exact h3 hm
                · intro b hb
                  simp only [List.mem_cons] at hb
                  rcases hb with rfl | hb
                  · simp; omega
                  · have := h4 b hb; omega
                · refine List.pairwise_cons.mpr ⟨fun b hb => ?_, h5⟩
                  have := h4 b hb
                  simp only
                  omega

/-- **Container boundaries**: every box lies in its container, after its header, in order. -/
theorem children_within (bs : List Nat) (lo hi : Nat) (top : Bool) (count maxBoxes : Nat) (hlh : lo ≤ hi) (bxs : List Box) (n : Nat)
    (h : children bs lo hi top count maxBoxes = .ok (bxs, n)) : BoxesWithin lo hi bxs := by
  obtain ⟨more, h1, _, _, h4, h5⟩ := boxes_spec bs hi top maxBoxes _ lo [] count (bxs, n) hlh h
  simp at h1
  subst h1
  exact ⟨h4, h5⟩

/-- **The box budget**: every box counts, and a successful walk never passes the limit. -/
theorem children_budget (bs : List Nat) (lo hi : Nat) (top : Bool) (count maxBoxes : Nat) (hlh : lo ≤ hi) (bxs : List Box) (n : Nat)
    (h : children bs lo hi top count maxBoxes = .ok (bxs, n)) : n = count + bxs.length ∧ (bxs ≠ [] → n ≤ maxBoxes) := by
  obtain ⟨more, h1, h2, h3, _, _⟩ := boxes_spec bs hi top maxBoxes _ lo [] count (bxs, n) hlh h
  simp at h1 h2
  subst h1
  exact ⟨h2, h3⟩

/-! ## 4. The bit reader -/

theorem bitAt_le (bs : List Nat) (i : Nat) : bitAt bs i ≤ 1 := by
  unfold bitAt; split <;> omega

theorem bitsVal_lt (bs : List Nat) (p : Nat) : ∀ n, bitsVal bs p n < 2 ^ n := by
  intro n
  induction n with
  | zero => simp [bitsVal]
  | succ k ih =>
    simp only [bitsVal, List.range_succ, List.foldl_append, List.foldl_cons, List.foldl_nil] at ih ⊢
    have := bitAt_le bs (p + k)
    rw [Nat.pow_succ]
    omega

/-- **Bits**: an `n`-bit value; the position never passes the input. -/
theorem readBits_spec (bs : List Nat) (zeroFill : Bool) (r : Bits) (n v : Nat) (r' : Bits) (hr : r.pos ≤ 8 * bs.length)
    (h : readBits bs zeroFill r n = .ok (v, r')) : v < 2 ^ n ∧ r'.pos ≤ 8 * bs.length ∧ r.pos ≤ r'.pos ∧
      (r'.pos = r.pos + n ∨ (zeroFill = true ∧ r'.exhausted = true ∧ r'.pos = 8 * bs.length)) := by
  unfold readBits at h
  split at h
  · rename_i hn
    simp at h; obtain ⟨rfl, rfl⟩ := h
    simp at hn; subst hn
    exact ⟨by simp, hr, Nat.le_refl _, .inl rfl⟩
  · split at h
    · rename_i hle
      simp at h; obtain ⟨rfl, rfl⟩ := h
      exact ⟨bitsVal_lt bs _ n, by simpa using hle, by simp, .inl rfl⟩
    · split at h
      · rename_i hz
        simp at h; obtain ⟨rfl, rfl⟩ := h
        exact ⟨bitsVal_lt bs _ n, Nat.le_refl _, hr, .inr ⟨hz, rfl, rfl⟩⟩
      · simp at h

end Codecs
