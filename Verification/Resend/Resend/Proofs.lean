import Resend.Model
import Resend.Props

/-!
# The proofs

1. The decision: a resend is of a payload logged at that timestamp as delivered to that very
   device, not older than a day; a story only while the requester is in a list it went to;
   nothing past the limit.
2. Every reachable state: the log records deliveries; every answer went to its requester and
   carried only what that device was delivered; at most `retryLimit` answers per request key.
-/

namespace Resend

/-! ## 1. The decision -/

theorem answer_logged (w : World) (s : S) (a d t n : Nat) (p : Payload) (h : answer w s a d t n = .resend p) :
    p ∈ s.payloads ∧ p.ts = t ∧ s.now ≤ p.ts + maxAge ∧ ⟨p.id, a, d⟩ ∈ s.rows := by
  unfold answer at h
  split at h
  · simp at h
  · split at h
    · simp at h
    · rename_i q hq
      split at h
      · simp at h
      · simp at h
        subst h
        have hm := List.mem_of_find?_eq_some hq
        have hp := List.find?_some hq
        simp at hp
        exact ⟨hm, hp.1.1, hp.1.2, hp.2⟩

theorem answer_story (w : World) (s : S) (a d t n : Nat) (p : Payload) (h : answer w s a d t n = .resend p)
    (hs : w.story.contains p.content = true) : listed s a t = true := by
  unfold answer at h
  split at h
  · simp at h
  · split at h
    · simp at h
    · rename_i q hq
      split at h
      · simp at h
      · rename_i hc
        simp at h
        subst h
        simp_all

theorem answer_limit (w : World) (s : S) (a d t n : Nat) (h : retryLimit ≤ n) : answer w s a d t n = .nothing := by
  simp [answer, h]

/-! ## 2. Reachable states -/

structure Inv (s : S) : Prop where
  nodup : (s.payloads.map (·.id)).Nodup
  lt : ∀ p ∈ s.payloads, p.id < s.next
  logged : Logged s
  out : ResentDelivered s
  bound : ∀ k, outCount s k ≤ countOf s k ∧ outCount s k ≤ retryLimit

theorem same_id : ∀ {ps : List Payload}, (ps.map (·.id)).Nodup → ∀ {p q : Payload}, p ∈ ps → q ∈ ps → p.id = q.id → p = q
  | [], _, _, _, hp, _, _ => absurd hp List.not_mem_nil
  | x :: xs, hnd, p, q, hp, hq, hg => by
    simp only [List.map_cons, List.nodup_cons] at hnd
    obtain ⟨hx, hxs⟩ := hnd
    rcases List.mem_cons.mp hp with h1 | h1 <;> rcases List.mem_cons.mp hq with h2 | h2
    · rw [h1, h2]
    · have : q.id ∈ xs.map (·.id) := List.mem_map_of_mem h2
      rw [← hg, h1] at this
      exact absurd this hx
    · have : p.id ∈ xs.map (·.id) := List.mem_map_of_mem h1
      rw [hg, h2] at this
      exact absurd this hx
    · exact same_id hxs h1 h2 hg

theorem prune_inv (s : S) (now : Nat) (hnd : (s.payloads.map (·.id)).Nodup) (hlt : ∀ p ∈ s.payloads, p.id < s.next)
    (hl : Logged s) : (((prune s now).payloads.map (·.id)).Nodup) ∧ (∀ p ∈ (prune s now).payloads, p.id < (prune s now).next) ∧
      Logged (prune s now) := by
  refine ⟨hnd.sublist (List.filter_sublist.map _), fun p hp => hlt p (List.mem_filter.mp hp).1, ?_⟩
  intro r hr
  simp only [prune, List.mem_filter] at hr
  obtain ⟨hr, hany⟩ := hr
  obtain ⟨p, hp, hid, hd⟩ := hl r hr
  refine ⟨p, ?_, hid, hd⟩
  simp only [List.any_eq_true, beq_iff_eq] at hany
  obtain ⟨q, hq, hqid⟩ := hany
  have hq' := (List.mem_filter.mp hq).1
  have : q = p := same_id hnd hq' hp (hqid.trans hid.symm)
  rw [← this]
  exact hq

theorem record_inv (s : S) (ts c r : Nat) (ds : List Nat) (h : Inv s) : Inv (record s ts c r ds) := by
  -- The payload the rows are added for.
  have hpay : ∃ (s1 : S) (id : Nat), (record s ts c r ds) =
      prune { s1 with rows := ds.foldl (addRow id r) s1.rows, delivered := s1.delivered ++ ds.map (ts, c, r, ·) } s1.now ∧
      s1.rows = s.rows ∧ s1.delivered = s.delivered ∧ s1.out = s.out ∧ s1.counts = s.counts ∧ s1.now = s.now ∧
      (s1.payloads.map (·.id)).Nodup ∧ (∀ p ∈ s1.payloads, p.id < s1.next) ∧ (∀ p ∈ s.payloads, p ∈ s1.payloads) ∧
      (∃ p ∈ s1.payloads, p.id = id ∧ p.ts = ts ∧ p.content = c) := by
    refine ⟨(payloadFor s ts c).1, (payloadFor s ts c).2, rfl, ?_⟩
    unfold payloadFor
    cases hf : s.payloads.find? (fun p => p.ts == ts && p.content == c) with
    | some p =>
      have hm := List.mem_of_find?_eq_some hf
      have hp := List.find?_some hf
      simp at hp
      exact ⟨rfl, rfl, rfl, rfl, rfl, h.nodup, h.lt, fun _ h => h, p, hm, rfl, hp.1, hp.2⟩
    | none =>
      refine ⟨rfl, rfl, rfl, rfl, rfl, ?_, ?_, fun p hp => List.mem_append_left _ hp, ⟨s.next, ts, c⟩,
        List.mem_append_right _ (List.mem_singleton_self _), rfl, rfl, rfl⟩
      · simp only [List.map_append, List.map_cons, List.map_nil]
        rw [List.nodup_append]
        refine ⟨h.nodup, by simp, ?_⟩
        intro a ha b hb
        simp at hb
        subst hb
        obtain ⟨x, hx, rfl⟩ := List.mem_map.mp ha
        have := h.lt x hx
        omega
      · intro p hp
        simp only [List.mem_append, List.mem_singleton] at hp
        rcases hp with hp | rfl
        · have := h.lt p hp; simp only; omega
        · simp
  obtain ⟨s1, id, he, hrows, hdel, hout, hcnt, _, hnd, hlt, hsub, ⟨p0, hp0, hid0, hts0, hc0⟩⟩ := hpay
  rw [he]
  -- The rows after the fold: old ones, or this payload's for one of the devices.
  have hfold : ∀ (l : List Nat) (rows : List Row), ∀ x ∈ l.foldl (addRow id r) rows,
      x ∈ rows ∨ (x.id = id ∧ x.recipient = r ∧ x.device ∈ l) := by
    intro l
    induction l with
    | nil => intro rows x hx; exact .inl hx
    | cons d ds ih =>
      intro rows x hx
      simp only [List.foldl_cons] at hx
      rcases ih _ x hx with hx | ⟨h1, h2, h3⟩
      · unfold addRow at hx
        split at hx
        · exact .inl hx
        · simp only [List.mem_append, List.mem_singleton] at hx
          rcases hx with hx | rfl
          · exact .inl hx
          · exact .inr ⟨rfl, rfl, List.mem_cons_self ..⟩
      · exact .inr ⟨h1, h2, List.mem_cons_of_mem _ h3⟩
  let s2 : S := { s1 with rows := ds.foldl (addRow id r) s1.rows, delivered := s1.delivered ++ ds.map (ts, c, r, ·) }
  have hl2 : Logged s2 := by
    intro x hx
    rcases hfold ds s1.rows x hx with hx | ⟨h1, h2, h3⟩
    · rw [hrows] at hx
      obtain ⟨p, hp, hid, hd⟩ := h.logged x hx
      exact ⟨p, hsub p hp, hid, List.mem_append_left _ (hdel ▸ hd)⟩
    · refine ⟨p0, hp0, hid0.trans h1.symm, ?_⟩
      rw [hts0, hc0, h2]
      exact List.mem_append_right _ (List.mem_map_of_mem h3)
  have ⟨n1, n2, n3⟩ := prune_inv s2 s1.now hnd hlt hl2
  refine ⟨n1, n2, n3, ?_, ?_⟩
  · intro o ho
    simp only [prune, s2] at ho ⊢
    rw [hout] at ho
    have ⟨a1, a2⟩ := h.out o ho
    refine ⟨a1, fun c hc => ⟨(a2 c hc).1, ?_⟩⟩
    rw [hdel]
    exact List.mem_append_left _ (a2 c hc).2
  · intro k
    have := h.bound k
    simp only [outCount, countOf, prune, s2] at this ⊢
    rw [hout, hcnt]
    exact this

theorem receipt_inv (s : S) (r d ts : Nat) (h : Inv s) : Inv (receipt s r d ts) := by
  refine ⟨h.nodup.sublist (List.filter_sublist.map _), fun p hp => h.lt p (List.mem_filter.mp hp).1, ?_, h.out, h.bound⟩
  intro x hx
  simp only [receipt] at hx ⊢
  have hx0 := (List.mem_filter.mp hx).1
  obtain ⟨p, hp, hid, hd⟩ := h.logged x hx0
  refine ⟨p, List.mem_filter.mpr ⟨hp, ?_⟩, hid, hd⟩
  simp only [Bool.not_eq_true', Bool.and_eq_false_iff, Bool.not_eq_false', List.any_eq_true, beq_iff_eq]
  exact .inr ⟨x, hx, hid.symm⟩

theorem find_rows_delivered (s : S) (h : Inv s) {a d : Nat} {p : Payload} (hl : p ∈ s.payloads) (hr : ⟨p.id, a, d⟩ ∈ s.rows) :
    (p.ts, p.content, a, d) ∈ s.delivered := by
  obtain ⟨q, hq, hid, hd⟩ := h.logged _ hr
  have : q = p := same_id h.nodup hq hl hid
  subst this
  exact hd

theorem countOf_bump_eq (c : List ((Nat × Nat × Nat) × Nat)) (k : Nat × Nat × Nat) (n : Nat) (s : S) :
    countOf { s with counts := bump c k n } k = n + 1 := by
  simp [countOf, bump]

theorem find_filter_ne (c : List ((Nat × Nat × Nat) × Nat)) (k k' : Nat × Nat × Nat) (hne : k' ≠ k) :
    (c.filter (·.1 != k)).find? (·.1 == k') = c.find? (·.1 == k') := by
  induction c with
  | nil => rfl
  | cons x xs ih =>
    by_cases hx : x.1 = k
    · have : x.1 ≠ k' := by rw [hx]; exact Ne.symm hne
      simp [List.filter_cons, hx, List.find?_cons, ih, this, Ne.symm hne]
    · simp [List.filter_cons, hx, List.find?_cons, ih]

theorem countOf_bump_ne (c : List ((Nat × Nat × Nat) × Nat)) (k k' : Nat × Nat × Nat) (n : Nat) (s : S) (hne : k' ≠ k) :
    countOf { s with counts := bump c k n } k' = countOf { s with counts := c } k' := by
  simp only [countOf, bump, List.find?_cons]
  have : ((k, n + 1).1 == k') = false := by simp; exact Ne.symm hne
  rw [this]
  simp only
  rw [find_filter_ne c k k' hne]

theorem retry_inv (w : World) (s : S) (a d t : Nat) (h : Inv s) : Inv (step w s (.retry a d t)) := by
  let k := (a, d, t)
  let n := countOf s k
  let s1 : S := { s with counts := bump s.counts k n }
  have hcount : ∀ k', outCount s1 k' ≤ countOf s1 k' ∧ outCount s1 k' ≤ retryLimit := by
    intro k'
    by_cases hk : k' = k
    · subst hk
      have := h.bound k
      rw [countOf_bump_eq]
      exact ⟨by simp only [outCount, s1] at this ⊢; omega, this.2⟩
    · have := h.bound k'
      rw [countOf_bump_ne s.counts k k' n s hk]
      exact this
  -- Appending an answer for `k` when it was answered fewer than `retryLimit` times.
  have hadd : ∀ o : Out, o.requester = a → o.device = d → o.ts = t → n < retryLimit →
      ∀ k', outCount { s1 with out := s1.out ++ [o] } k' ≤ countOf { s1 with out := s1.out ++ [o] } k' ∧
            outCount { s1 with out := s1.out ++ [o] } k' ≤ retryLimit := by
    intro o ha hd ht hn k'
    have hc : countOf { s1 with out := s1.out ++ [o] } k' = countOf s1 k' := rfl
    rw [hc]
    by_cases hk : k' = k
    · subst hk
      have := h.bound k
      have hb := countOf_bump_eq s.counts k n s
      simp only [outCount, List.filter_append, List.length_append] at this ⊢
      simp only [s1] at hb ⊢
      rw [hb]
      have : (List.filter (fun o => o.requester == k.1 && o.device == k.2.1 && o.ts == k.2.2) [o]).length ≤ 1 := by
        simp [List.filter_cons]; split <;> simp
      constructor <;> omega
    · have := hcount k'
      have hne : (o.requester == k'.1 && o.device == k'.2.1 && o.ts == k'.2.2) = false := by
        cases k' with
        | mk a' rest =>
          cases rest with
          | mk d' t' =>
            simp only [ha, hd, ht, Bool.and_eq_false_iff, beq_eq_false_iff_ne]
            by_cases h1 : a = a'
            · by_cases h2 : d = d'
              · right; intro h3; exact hk (by simp [k, h1, h2, h3])
              · left; right; exact h2
            · left; left; exact h1
      simp only [outCount, List.filter_append, List.length_append, List.filter_cons, hne] at this ⊢
      simpa using this
  simp only [step]
  cases ha : answer w s1 a d t n with
  | nothing => exact ⟨h.nodup, h.lt, h.logged, h.out, hcount⟩
  | null =>
    have hn : n < retryLimit := by
      rcases Nat.lt_or_ge n retryLimit with hc | hc
      · exact hc
      · rw [answer_limit w s1 a d t n hc] at ha; simp at ha
    refine ⟨h.nodup, h.lt, h.logged, ?_, hadd _ rfl rfl rfl hn⟩
    intro o ho
    simp only [List.mem_append, List.mem_singleton] at ho
    rcases ho with ho | rfl
    · exact h.out o ho
    · exact ⟨rfl, fun c hc => by simp at hc⟩
  | resend p =>
    have hn : n < retryLimit := by
      rcases Nat.lt_or_ge n retryLimit with hc | hc
      · exact hc
      · rw [answer_limit w s1 a d t n hc] at ha; simp at ha
    have ⟨hp, hts, _, hr⟩ := answer_logged w s1 a d t n p ha
    refine ⟨h.nodup, h.lt, h.logged, ?_, hadd _ rfl rfl rfl hn⟩
    intro o ho
    simp only [List.mem_append, List.mem_singleton] at ho
    rcases ho with ho | rfl
    · exact h.out o ho
    · refine ⟨rfl, fun c hc => ?_⟩
      simp at hc
      subst hc
      exact ⟨hts, find_rows_delivered s h hp hr⟩

theorem step_inv (w : World) (s : S) (e : Ev) (h : Inv s) : Inv (step w s e) := by
  cases e with
  | send ts c r ds => exact record_inv s ts c r ds h
  | receipt r d ts => exact receipt_inv s r d ts h
  | tick n => exact ⟨h.nodup, h.lt, h.logged, h.out, h.bound⟩
  | story ts l => exact ⟨h.nodup, h.lt, h.logged, h.out, h.bound⟩
  | setList l => exact ⟨h.nodup, h.lt, h.logged, h.out, h.bound⟩
  | retry a d t => exact retry_inv w s a d t h

theorem reach_inv (w : World) {s : S} (h : Reach w s) : Inv s := by
  induction h with
  | init => exact ⟨by simp [S.init], by simp [S.init], by simp [Logged, S.init], by simp [ResentDelivered, S.init],
                   fun k => by simp [outCount, countOf, S.init]⟩
  | step e _ ih => exact step_inv w _ e ih

/-- **The log records deliveries.** -/
theorem logged_holds (w : World) {s : S} (h : Reach w s) : Logged s := (reach_inv w h).logged

/-- **A retry gets back only what that very device was delivered, at the timestamp it asked
about, and only the requester gets it.** -/
theorem resentDelivered_holds (w : World) {s : S} (h : Reach w s) : ResentDelivered s := (reach_inv w h).out

/-- **At most `retryLimit` answers per (requester, device, timestamp).** -/
theorem bounded_holds (w : World) {s : S} (h : Reach w s) : Bounded s := fun k => ((reach_inv w h).bound k).2

end Resend
