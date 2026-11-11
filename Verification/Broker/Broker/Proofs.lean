import Broker.Model
import Broker.Props

/-! # The proofs

One inductive invariant (`Inv`, ten parts) preserved by every event, and the theorems that
follow from it. -/

namespace Broker

/-! ## Lists -/

theorem countP_set_same {α} {p : α → Bool} : ∀ {l : List α} {m : Nat} {x y : α},
    l[m]? = some x → p x = p y → (l.set m y).countP p = l.countP p
  | [], _, _, _, h, _ => by simp at h
  | _ :: _, 0, _, _, h, hp => by simp at h; subst h; simp [List.countP_cons, hp]
  | _ :: _, _ + 1, _, _, h, hp => by simp at h; simp [List.countP_cons, countP_set_same h hp]

theorem countP_set_add {α} {p : α → Bool} : ∀ {l : List α} {m : Nat} {x y : α},
    l[m]? = some x → p x = false → (l.set m y).countP p = l.countP p + (if p y then 1 else 0)
  | [], _, _, _, h, _ => by simp at h
  | _ :: _, 0, _, _, h, hp => by simp at h; subst h; simp [List.countP_cons, hp]
  | _ :: _, _ + 1, _, _, h, hp => by
    simp at h
    simp only [List.set_cons_succ, List.countP_cons, countP_set_add h hp]
    omega

theorem any_set_same {α} {p : α → Bool} : ∀ {l : List α} {m : Nat} {x y : α},
    l[m]? = some x → p x = p y → (l.set m y).any p = l.any p
  | [], _, _, _, h, _ => by simp at h
  | _ :: _, 0, _, _, h, hp => by simp at h; subst h; simp [hp]
  | _ :: _, _ + 1, _, _, h, hp => by simp at h; simp [any_set_same h hp]

theorem countP_range_congr {p q : Nat → Bool} {n : Nat} (h : ∀ x, x < n → p x = q x) :
    (List.range n).countP p = (List.range n).countP q :=
  List.countP_congr fun x hx => by rw [h x (List.mem_range.1 hx)]

/-- Counting over `range n` when the predicate changes at `id` only, from false. -/
theorem countP_range_change {p p' : Nat → Bool} {id : Nat} (hp : p id = false) (heq : ∀ x, x ≠ id → p' x = p x) :
    ∀ n, id < n → (List.range n).countP p' = (List.range n).countP p + (if p' id then 1 else 0)
  | 0, h => absurd h (Nat.not_lt_zero _)
  | n + 1, h => by
    rw [List.range_succ, List.countP_append, List.countP_append]
    by_cases hn : n = id
    · subst hn
      rw [countP_range_congr (fun x hx => heq x (by omega))]
      simp [hp]
    · have h1 : [n].countP p' = [n].countP p := by simp [heq n hn]
      rw [countP_range_change hp heq n (by omega), h1]
      omega

/-- Two distinct elements satisfy `p` when it counts at least two in a list without duplicates. -/
theorem two_of_countP {α} {p : α → Bool} : ∀ {l : List α}, l.Nodup → 2 ≤ l.countP p →
    ∃ a b, a ≠ b ∧ a ∈ l ∧ b ∈ l ∧ p a = true ∧ p b = true
  | [], _, h => by simp at h
  | a :: t, hnd, h => by
    rw [List.nodup_cons] at hnd
    rw [List.countP_cons] at h
    by_cases ha : p a = true
    · simp only [ha, ↓reduceIte] at h
      obtain ⟨b, hb, hpb⟩ := List.countP_pos_iff.1 (by omega : 0 < t.countP p)
      exact ⟨a, b, fun e => hnd.1 (e ▸ hb), by simp, by simp [hb], ha, hpb⟩
    · simp only [ha, Bool.false_eq_true, ↓reduceIte, Nat.add_zero] at h
      obtain ⟨x, y, hxy, hx, hy, hpx, hpy⟩ := two_of_countP hnd.2 h
      exact ⟨x, y, hxy, by simp [hx], by simp [hy], hpx, hpy⟩

theorem getElem?_append_of_some {α} {l t : List α} {i : Nat} {x : α} (h : l[i]? = some x) : (l ++ t)[i]? = some x := by
  rw [List.getElem?_append_left (List.getElem?_eq_some_iff.1 h).1]; exact h

theorem lt_of_getElem?_some {α} {l : List α} {i : Nat} {x : α} (h : l[i]? = some x) : i < l.length :=
  (List.getElem?_eq_some_iff.1 h).1

/-! ## The model's pieces -/

theorem accept_not_pending (k : Kind) (r : Reply) : (accept k r).1 ≠ .pending := by
  cases k <;> cases r <;> simp only [accept] <;> (try split) <;> simp_all

theorem accept_not_lost (k : Kind) (r : Reply) : (accept k r).1 ≠ .failed .lost := by
  cases k <;> cases r <;> simp only [accept] <;> (try split) <;> simp_all

theorem accept_not_timedOut (k : Kind) (r : Reply) : (accept k r).1 ≠ .failed .timedOut := by
  cases k <;> cases r <;> simp only [accept] <;> (try split) <;> simp_all

/-- A session `accept` releases is the one the reply names. -/
theorem accept_release_late {k : Kind} {r : Reply} {u : Nat} (h : (accept k r).2 = some u) : late k r = some u := by
  cases k <;> cases r <;> simp only [accept, late] at h ⊢ <;> (try split at h) <;> simp_all

/-- A session a reply names is the caller's, or released. -/
theorem accept_late {k : Kind} {r : Reply} {u : Nat} (h : late k r = some u) :
    (accept k r).1 = .ok (.session u) ∨ (accept k r).2 = some u := by
  cases k <;> cases r <;> simp only [accept, late] at h ⊢ <;> (try split) <;> simp_all

theorem answer_release_late {q : Req} {r : Reply} {u : Nat} (h : (answer q r).2 = some u) : late q.kind r = some u := by
  unfold answer at h
  split at h
  · exact accept_release_late h
  · exact h

theorem answer_not_pending (q : Req) (r : Reply) : (answer q r).1 ≠ .pending := by
  unfold answer; split
  · exact accept_not_pending _ _
  · assumption

theorem answer_lost (q : Req) (r : Reply) : (answer q r).1 = .failed .lost ↔ q.status = .failed .lost := by
  unfold answer; split
  · rename_i h; rw [h]; exact ⟨fun e => absurd e (accept_not_lost _ _), fun e => by cases e⟩
  · exact Iff.rfl

theorem answer_timedOut (q : Req) (r : Reply) : (answer q r).1 = .failed .timedOut ↔ q.status = .failed .timedOut := by
  unfold answer; split
  · rename_i h; rw [h]; exact ⟨fun e => absurd e (accept_not_timedOut _ _), fun e => by cases e⟩
  · exact Iff.rfl

theorem answer_ok {q : Req} {r : Reply} {v : Val} (h : (answer q r).1 = .ok v) :
    (q.status = .pending ∧ (accept q.kind r).1 = .ok v) ∨ q.status = .ok v := by
  unfold answer at h; split at h
  · exact Or.inl ⟨by assumption, h⟩
  · exact Or.inr h

theorem getElem?_concat_cases {α} {l : List α} {a x : α} {i : Nat} (h : (l ++ [a])[i]? = some x) :
    l[i]? = some x ∨ (i = l.length ∧ x = a) := by
  by_cases hi : i < l.length
  · left; rwa [List.getElem?_append_left hi] at h
  · right
    rw [List.getElem?_append_right (by omega)] at h
    have h0 : i - l.length = 0 := by
      cases hh : i - l.length with
      | zero => rfl
      | succ n => rw [hh] at h; simp at h
    rw [h0] at h
    simp at h
    exact ⟨by omega, h.symm⟩

theorem ended_false {s : St} {id : Nat} : ended s id = false ↔ ∃ x, s.sess[id]? = some x ∧ x.ended = false := by
  unfold ended; cases s.sess[id]? <;> simp

/-! ## `opened` and `send` -/

theorem opened_of_live {s : St} {c : Ch} {id : Nat} (h : s.live c = some id) : opened s c = s := by simp [opened, h]

theorem opened_of_none {s : St} {c : Ch} (h : s.live c = none) :
    opened s c = { s with sess := s.sess ++ [⟨c, false⟩], live := fun c' => if c' = c then some s.sess.length else s.live c' } := by
  simp [opened, h]

theorem opened_reqs (s : St) (c : Ch) : (opened s c).reqs = s.reqs := by unfold opened; split <;> rfl
theorem opened_delivered (s : St) (c : Ch) : (opened s c).delivered = s.delivered := by unfold opened; split <;> rfl
theorem opened_strikes (s : St) (c : Ch) : (opened s c).strikes = s.strikes := by unfold opened; split <;> rfl

theorem opened_sess_some {s : St} {c : Ch} {id : Nat} {x : Sess} (h : s.sess[id]? = some x) : (opened s c).sess[id]? = some x := by
  unfold opened; split
  · exact h
  · exact getElem?_append_of_some h

theorem opened_live_ne {s : St} {c c' : Ch} (h : c' ≠ c) : (opened s c).live c' = s.live c' := by
  unfold opened; split
  · rfl
  · simp [h]

theorem opened_live (s : St) (c : Ch) (hl : LiveOpen s) :
    ∃ id, (opened s c).live c = some id ∧ (opened s c).sess[id]? = some ⟨c, false⟩ := by
  cases h : s.live c with
  | some id => exact ⟨id, by rw [opened_of_live h, h], by rw [opened_of_live h]; exact hl c id h⟩
  | none => exact ⟨s.sess.length, by simp [opened_of_none h], by simp [opened_of_none h]⟩

theorem opened_sess_cases {s : St} {c : Ch} {id : Nat} {x : Sess} (h : (opened s c).sess[id]? = some x) :
    s.sess[id]? = some x ∨ (s.live c = none ∧ id = s.sess.length ∧ x = ⟨c, false⟩) := by
  cases hl : s.live c with
  | some j => rw [opened_of_live hl] at h; exact Or.inl h
  | none =>
    rw [opened_of_none hl] at h
    rcases getElem?_concat_cases h with h | ⟨h1, h2⟩
    · exact Or.inl h
    · exact Or.inr ⟨rfl, h1, h2⟩

theorem opened_sess_length (s : St) (c : Ch) :
    (opened s c).sess.length = s.sess.length ∨ (opened s c).sess.length = s.sess.length + 1 := by
  unfold opened; split
  · exact Or.inl rfl
  · exact Or.inr (by simp)

/-- The request `send` appends. -/
def sent (s : St) (k : Kind) : Req := ⟨k, (opened s k.ch).live k.ch, .pending, false⟩

theorem send_reqs (s : St) (k : Kind) : (send s k).reqs = s.reqs ++ [sent s k] := by simp [send, sent, opened_reqs]
theorem send_sess (s : St) (k : Kind) : (send s k).sess = (opened s k.ch).sess := rfl
theorem send_live (s : St) (k : Kind) : (send s k).live = (opened s k.ch).live := rfl
theorem send_delivered (s : St) (k : Kind) : (send s k).delivered = s.delivered := by simp [send, opened_delivered]
theorem send_strikes (s : St) (k : Kind) : (send s k).strikes = s.strikes := by simp [send, opened_strikes]

theorem send_old {s : St} {k : Kind} {m : Nat} {q : Req} (h : s.reqs[m]? = some q) : (send s k).reqs[m]? = some q := by
  rw [send_reqs]; exact getElem?_append_of_some h

theorem send_cases {s : St} {k : Kind} {m : Nat} {q : Req} (h : (send s k).reqs[m]? = some q) :
    s.reqs[m]? = some q ∨ (m = s.reqs.length ∧ q = sent s k) := by
  rw [send_reqs] at h; exact getElem?_concat_cases h

theorem shaped_send {s : St} {k : Kind} (hs : Shaped s) (hl : LiveOpen s) : Shaped (send s k) := by
  intro q hq id hid
  rw [send_reqs, List.mem_append] at hq
  rcases hq with hq | hq
  · obtain ⟨x, hx, hc⟩ := hs q hq id hid
    exact ⟨x, by rw [send_sess]; exact opened_sess_some hx, hc⟩
  · simp at hq; subst hq
    obtain ⟨id', h1, h2⟩ := opened_live s k.ch hl
    simp only [sent] at hid
    rw [h1] at hid; cases hid
    exact ⟨_, by rw [send_sess]; exact h2, rfl⟩

theorem liveOpen_send {s : St} {k : Kind} (hl : LiveOpen s) : LiveOpen (send s k) := by
  intro c id h
  rw [send_live] at h; rw [send_sess]
  by_cases hc : c = k.ch
  · obtain ⟨id', h1, h2⟩ := opened_live s k.ch hl
    rw [hc, h1] at h; cases h; rw [hc]; exact h2
  · rw [opened_live_ne hc] at h; exact opened_sess_some (hl c id h)

theorem oneOpen_send {s : St} {k : Kind} (ho : OneOpen s) : OneOpen (send s k) := by
  intro id x hx hen
  rw [send_sess] at hx; rw [send_live]
  rcases opened_sess_cases hx with hx | ⟨hn, rfl, rfl⟩
  · have h := ho id x hx hen
    by_cases hc : x.ch = k.ch
    · rw [hc] at h ⊢; rw [opened_of_live h, h]
    · rw [opened_live_ne hc]; exact h
  · simp [opened_of_none hn]

theorem pendingLive_send {s : St} {k : Kind} (hp : PendingLive s) (hl : LiveOpen s) : PendingLive (send s k) := by
  intro q hq hpend
  rw [send_reqs, List.mem_append] at hq
  rcases hq with hq | hq
  · obtain ⟨ha, id, hid, hen⟩ := hp q hq hpend
    refine ⟨ha, id, hid, ?_⟩
    obtain ⟨x, hx, hxe⟩ := ended_false.1 hen
    exact ended_false.2 ⟨x, by rw [send_sess]; exact opened_sess_some hx, hxe⟩
  · simp at hq; subst hq
    obtain ⟨id', h1, h2⟩ := opened_live s k.ch hl
    exact ⟨rfl, id', h1, ended_false.2 ⟨_, by rw [send_sess]; exact h2, rfl⟩⟩

theorem lostEnded_send {s : St} {k : Kind} (h : LostEnded s) : LostEnded (send s k) := by
  intro q hq hlost
  rw [send_reqs, List.mem_append] at hq
  rcases hq with hq | hq
  · obtain ⟨id, x, hid, hx, he⟩ := h q hq hlost
    exact ⟨id, x, hid, by rw [send_sess]; exact opened_sess_some hx, he⟩
  · simp at hq; subst hq; simp [sent] at hlost

theorem answered_send {s : St} {k : Kind} (h : Answered s) : Answered (send s k) := by
  intro m r hm
  rw [send_delivered] at hm
  obtain ⟨q, hq, ha⟩ := h m r hm
  exact ⟨q, send_old hq, ha⟩

theorem okOwn_send {s : St} {k : Kind} (h : OkOwn s) : OkOwn (send s k) := by
  intro m q v hq hv
  rw [send_delivered]
  rcases send_cases hq with hq | ⟨_, rfl⟩
  · exact h m q v hq hv
  · simp [sent] at hv

theorem kinds_send (s : St) (k : Kind) : (send s k).reqs.map Req.kind = s.reqs.map Req.kind ++ [k] := by
  simp [send_reqs, sent]

theorem noLeak_send {s : St} {k : Kind} (h : NoLeak s) (ha : Answered s) : NoLeak (send s k) := by
  intro m r q u hm hq hl
  rw [send_delivered] at hm
  obtain ⟨q0, hq0, _⟩ := ha m r hm
  have hq' := send_old (k := k) hq0
  obtain rfl : q0 = q := Option.some.inj (hq'.symm.trans hq)
  rcases h m r q0 u hm hq0 hl with e | e
  · exact Or.inl e
  · exact Or.inr (by rw [kinds_send]; exact List.mem_append_left _ e)

theorem releaseNamed_send {s : St} {k : Kind} (h : ReleaseNamed s)
    (hk : ∀ c u, k = .release c u → ∃ m r p, (m, r) ∈ s.delivered ∧ s.reqs[m]? = some p ∧ p.kind.ch = c ∧ late p.kind r = some u) :
    ReleaseNamed (send s k) := by
  intro j q c u hq hk'
  rw [send_delivered]
  rcases send_cases hq with hq | ⟨_, rfl⟩
  · obtain ⟨m, r, p, hm, hp, hc, hl⟩ := h j q c u hq hk'
    exact ⟨m, r, p, hm, send_old hp, hc, hl⟩
  · obtain ⟨m, r, p, hm, hp, hc, hl⟩ := hk c u hk'
    exact ⟨m, r, p, hm, send_old hp, hc, hl⟩

theorem lostOn_send (s : St) (k : Kind) : lostOn (send s k) = lostOn s := by
  funext i id
  simp [lostOn, send_reqs, sent]

theorem lostOn_none {s : St} {i id : Nat} (hs : Shaped s) (h : s.sess.length ≤ id) : lostOn s i id = false := by
  unfold lostOn
  rw [Bool.eq_false_iff]
  intro ha
  obtain ⟨q, hq, hp⟩ := List.any_eq_true.1 ha
  simp only [decide_eq_true_eq] at hp
  obtain ⟨x, hx, _⟩ := hs q hq id hp.1
  have := lt_of_getElem?_some hx
  omega

theorem strikes_send {s : St} {k : Kind} (h : StrikesExact s) (hs : Shaped s) : StrikesExact (send s k) := by
  intro i
  have ht : timedOutCount (send s k) i = timedOutCount s i := by simp [timedOutCount, send_reqs, sent]
  have hls : lostSessions (send s k) i = lostSessions s i := by
    unfold lostSessions
    rw [lostOn_send, send_sess]
    rcases opened_sess_length s k.ch with e | e
    · rw [e]
    · rw [e, List.range_succ, List.countP_append]
      simp [lostOn_none hs (Nat.le_refl _)]
  rw [send_strikes, ht, hls]; exact h i

/-! ## More lists -/

theorem any_congr_mem {α} {p q : α → Bool} : ∀ {l : List α}, (∀ x ∈ l, p x = q x) → l.any p = l.any q
  | [], _ => rfl
  | a :: t, h => by
    have h1 := h a (List.mem_cons_self ..)
    have h2 : t.any p = t.any q := any_congr_mem fun x hx => h x (List.mem_cons_of_mem a hx)
    simp only [List.any_cons, h1, h2]

theorem set_self_of_getElem? {α} : ∀ {l : List α} {m : Nat} {x : α}, l[m]? = some x → l.set m x = l
  | [], _, _, h => by simp at h
  | _ :: _, 0, _, h => by simp at h; subst h; rfl
  | _ :: _, _ + 1, _, h => by simp at h; simp [set_self_of_getElem? h]

/-- The kinds at each index, and the replies delivered, only grow: releases keep their witness. -/
theorem releaseNamed_mono {s s' : St} (h : ReleaseNamed s) (hd : ∀ x ∈ s.delivered, x ∈ s'.delivered)
    (hback : ∀ (j : Nat) (q : Req), s'.reqs[j]? = some q → ∃ q0 : Req, s.reqs[j]? = some q0 ∧ q0.kind = q.kind)
    (hfwd : ∀ (j : Nat) (q0 : Req), s.reqs[j]? = some q0 → ∃ q : Req, s'.reqs[j]? = some q ∧ q.kind = q0.kind) : ReleaseNamed s' := by
  intro j q c u hq hk
  obtain ⟨q0, hq0, hk0⟩ := hback j q hq
  obtain ⟨m, r, p, hm, hp, hc, hl⟩ := h j q0 c u hq0 (hk0.trans hk)
  obtain ⟨p', hp', hk'⟩ := hfwd m p hp
  exact ⟨m, r, p', hd _ hm, hp', by rw [hk']; exact hc, by rw [hk']; exact hl⟩

/-! ## `crash` -/

theorem endReq_kind (id : Nat) (q : Req) : (endReq id q).kind = q.kind := by unfold endReq; split <;> rfl
theorem endReq_sess (id : Nat) (q : Req) : (endReq id q).sess = q.sess := by unfold endReq; split <;> rfl

theorem endReq_final {id : Nat} {q : Req} (h : q.status ≠ .pending) : (endReq id q).status = q.status := by
  unfold endReq; split <;> simp_all

theorem endReq_answered {id : Nat} {q : Req} (h : q.answered = true) : (endReq id q).answered = true := by
  unfold endReq; split <;> simp [h]

theorem endReq_off {id : Nat} {q : Req} (h : q.sess ≠ some id) : endReq id q = q := by
  unfold endReq; simp [h]

theorem endReq_pending {id : Nat} {q : Req} (h : (endReq id q).status = .pending) :
    q.status = .pending ∧ ¬(q.sess = some id ∧ q.answered = false) := by
  unfold endReq at h
  split at h
  · simp only at h; split at h <;> simp_all
  · exact ⟨h, by assumption⟩

theorem endReq_lost {id : Nat} {q : Req} (h : (endReq id q).status = .failed .lost) :
    q.status = .failed .lost ∨ (q.sess = some id ∧ q.status = .pending) := by
  unfold endReq at h
  split at h
  · simp only at h; split at h
    · rename_i h1 h2; exact Or.inr ⟨h1.1, h2⟩
    · exact Or.inl h
  · exact Or.inl h

theorem endReq_timedOut {id : Nat} {q : Req} : (endReq id q).status = .failed .timedOut ↔ q.status = .failed .timedOut := by
  unfold endReq; split
  · simp only; split <;> simp_all
  · exact Iff.rfl

theorem endReq_ok {id : Nat} {q : Req} {v : Val} (hv : (endReq id q).status = .ok v) : q.status = .ok v := by
  by_cases hp : q.status = .pending
  · unfold endReq at hv; split at hv <;> simp_all
  · rwa [endReq_final hp] at hv

section crash
variable {s : St} {c : Ch} {id : Nat} (h : s.live c = some id)
include h

theorem crash_reqs : (crash s c).reqs = s.reqs.map (endReq id) := by simp [crash, h]
theorem crash_sess : (crash s c).sess = s.sess.set id ⟨c, true⟩ := by simp [crash, h]
theorem crash_live : (crash s c).live = fun c' => if c' = c then none else s.live c' := by simp [crash, h]
theorem crash_delivered : (crash s c).delivered = s.delivered := by simp [crash, h]
theorem crash_strikes : (crash s c).strikes = fun i => s.strikes i + if inFlight s id i then 1 else 0 := by simp [crash, h]

theorem crash_get {m : Nat} {q' : Req} (hq' : (crash s c).reqs[m]? = some q') : ∃ q, s.reqs[m]? = some q ∧ q' = endReq id q := by
  rw [crash_reqs h, List.getElem?_map] at hq'
  cases hq : s.reqs[m]? with
  | none => rw [hq] at hq'; cases hq'
  | some q => rw [hq] at hq'; exact ⟨q, rfl, (Option.some.inj hq').symm⟩

theorem crash_get_old {m : Nat} {q : Req} (hq : s.reqs[m]? = some q) : (crash s c).reqs[m]? = some (endReq id q) := by
  rw [crash_reqs h, List.getElem?_map, hq]; rfl

theorem kinds_crash : (crash s c).reqs.map Req.kind = s.reqs.map Req.kind := by
  rw [crash_reqs h, List.map_map]; congr 1; funext q; exact endReq_kind id q

theorem shaped_crash (hs : Shaped s) (hl : LiveOpen s) : Shaped (crash s c) := by
  intro q' hq' j hj
  rw [crash_reqs h, List.mem_map] at hq'
  obtain ⟨q, hq, rfl⟩ := hq'
  rw [endReq_sess] at hj; rw [endReq_kind]
  obtain ⟨x, hx, hc⟩ := hs q hq j hj
  rw [crash_sess h, List.getElem?_set]
  by_cases hji : id = j
  · subst hji
    have hlx := hl c id h
    rw [hx] at hlx
    obtain rfl := Option.some.inj hlx
    exact ⟨⟨c, true⟩, by simp [lt_of_getElem?_some hx], hc⟩
  · exact ⟨x, by simp [hji, hx], hc⟩

theorem liveOpen_crash (hl : LiveOpen s) : LiveOpen (crash s c) := by
  intro c' j hj
  rw [crash_live h] at hj
  by_cases hc : c' = c
  · simp [hc] at hj
  · simp only [hc, ↓reduceIte] at hj
    have hx := hl c' j hj
    rw [crash_sess h, List.getElem?_set]
    have hne : id ≠ j := by
      intro e; subst e
      have h2 := hl c id h
      rw [hx] at h2
      simp at h2
      exact hc h2
    simp [hne, hx]

theorem oneOpen_crash (ho : OneOpen s) (hl : LiveOpen s) : OneOpen (crash s c) := by
  intro j x hx hen
  rw [crash_sess h, List.getElem?_set] at hx
  rw [crash_live h]
  by_cases hji : id = j
  · subst hji
    simp [lt_of_getElem?_some (hl c id h)] at hx
    subst hx; simp at hen
  · simp only [hji, ↓reduceIte] at hx
    have hlive := ho j x hx hen
    have hc : x.ch ≠ c := by
      intro e; rw [e, h] at hlive; exact hji (Option.some.inj hlive)
    simp [hc, hlive]

theorem pendingLive_crash (hp : PendingLive s) : PendingLive (crash s c) := by
  intro q' hq' hpend
  rw [crash_reqs h, List.mem_map] at hq'
  obtain ⟨q, hq, rfl⟩ := hq'
  obtain ⟨hpq, hoff⟩ := endReq_pending hpend
  obtain ⟨ha, j, hj, hen⟩ := hp q hq hpq
  have hji : j ≠ id := by intro e; subst e; exact hoff ⟨hj, ha⟩
  rw [endReq_off (by rw [hj]; exact fun e => hji (Option.some.inj e))]
  refine ⟨ha, j, hj, ?_⟩
  obtain ⟨x, hx, hxe⟩ := ended_false.1 hen
  exact ended_false.2 ⟨x, by rw [crash_sess h, List.getElem?_set]; simp [Ne.symm hji, hx], hxe⟩

theorem lostEnded_crash (he : LostEnded s) (hl : LiveOpen s) : LostEnded (crash s c) := by
  intro q' hq' hlost
  rw [crash_reqs h, List.mem_map] at hq'
  obtain ⟨q, hq, rfl⟩ := hq'
  rw [endReq_sess]
  rcases endReq_lost hlost with hl' | ⟨hs', _⟩
  · obtain ⟨j, x, hj, hx, hxe⟩ := he q hq hl'
    by_cases hji : id = j
    · subst hji
      exact ⟨id, ⟨c, true⟩, hj, by rw [crash_sess h, List.getElem?_set_self (lt_of_getElem?_some hx)], rfl⟩
    · exact ⟨j, x, hj, by rw [crash_sess h, List.getElem?_set]; simp [hji, hx], hxe⟩
  · exact ⟨id, ⟨c, true⟩, hs', by rw [crash_sess h, List.getElem?_set_self (lt_of_getElem?_some (hl c id h))], rfl⟩

theorem answered_crash (ha : Answered s) : Answered (crash s c) := by
  intro m r hm
  rw [crash_delivered h] at hm
  obtain ⟨q, hq, hqa⟩ := ha m r hm
  exact ⟨endReq id q, crash_get_old h hq, endReq_answered hqa⟩

theorem okOwn_crash (ho : OkOwn s) : OkOwn (crash s c) := by
  intro m q' v hq' hv
  obtain ⟨q, hq, rfl⟩ := crash_get h hq'
  obtain ⟨r, hr, ha⟩ := ho m q v hq (endReq_ok hv)
  exact ⟨r, by rw [crash_delivered h]; exact hr, by rw [endReq_kind]; exact ha⟩

theorem noLeak_crash (hn : NoLeak s) : NoLeak (crash s c) := by
  intro m r q' u hm hq' hlate
  rw [crash_delivered h] at hm
  obtain ⟨q, hq, rfl⟩ := crash_get h hq'
  rw [endReq_kind] at hlate ⊢
  rcases hn m r q u hm hq hlate with e | e
  · left; rw [endReq_final (by rw [e]; simp)]; exact e
  · right; rw [kinds_crash h]; exact e

theorem releaseNamed_crash (hr : ReleaseNamed s) : ReleaseNamed (crash s c) :=
  releaseNamed_mono hr (by rw [crash_delivered h]; exact fun _ hx => hx)
    (fun j q hq => by obtain ⟨q0, hq0, rfl⟩ := crash_get h hq; exact ⟨q0, hq0, (endReq_kind id q0).symm⟩)
    (fun j q0 hq0 => ⟨endReq id q0, crash_get_old h hq0, endReq_kind id q0⟩)

theorem strikes_crash (hst : StrikesExact s) (hl : LiveOpen s) (hp : PendingLive s) (he : LostEnded s) :
    StrikesExact (crash s c) := by
  intro i
  have ht : timedOutCount (crash s c) i = timedOutCount s i := by
    unfold timedOutCount; rw [crash_reqs h, List.countP_map]
    apply List.countP_congr; intro q _
    simp only [Function.comp, endReq_kind, decide_eq_true_eq, endReq_timedOut]
  have hlid : s.sess[id]? = some ⟨c, false⟩ := hl c id h
  have hid : id < s.sess.length := lt_of_getElem?_some hlid
  have hnot : ∀ q ∈ s.reqs, q.sess = some id → q.status ≠ .failed .lost := by
    intro q hq hs hlost
    obtain ⟨j, x, hj, hx, hxe⟩ := he q hq hlost
    rw [hs] at hj; obtain rfl := Option.some.inj hj
    rw [hlid] at hx; obtain rfl := Option.some.inj hx
    simp at hxe
  have hl0 : lostOn s i id = false := by
    unfold lostOn; rw [Bool.eq_false_iff]; intro ha
    obtain ⟨q, hq, hpq⟩ := List.any_eq_true.1 ha
    simp only [decide_eq_true_eq] at hpq
    exact hnot q hq hpq.1 hpq.2.2
  have hl1 : lostOn (crash s c) i id = inFlight s id i := by
    unfold lostOn inFlight; rw [crash_reqs h, List.any_map]
    apply any_congr_mem; intro q hq
    simp only [Function.comp, endReq_kind, endReq_sess]
    by_cases hs : q.sess = some id
    · have hn := hnot q hq hs
      by_cases hpq : q.status = .pending
      · have ha := (hp q hq hpq).1
        unfold endReq; simp [hs, ha, hpq]
      · rw [endReq_final hpq]; simp [hs, hpq, hn]
    · simp [hs]
  have hl2 : ∀ j, j ≠ id → lostOn (crash s c) i j = lostOn s i j := by
    intro j hj
    unfold lostOn; rw [crash_reqs h, List.any_map]
    apply any_congr_mem; intro q _
    simp only [Function.comp, endReq_kind, endReq_sess]
    by_cases hs : q.sess = some j
    · rw [endReq_off (by rw [hs]; exact fun e => hj (Option.some.inj e))]
    · simp [hs]
  have hls : lostSessions (crash s c) i = lostSessions s i + if inFlight s id i then 1 else 0 := by
    unfold lostSessions
    rw [crash_sess h, List.length_set, countP_range_change hl0 hl2 _ hid, hl1]
  have hsi : (crash s c).strikes i = s.strikes i + if inFlight s id i then 1 else 0 := by rw [crash_strikes h]
  rw [hsi, ht, hls, hst i]
  omega

end crash

/-! ## `timeout`, `cancel` -/

/-- One outstanding request ends without a reply (timeout, cancellation). -/
def endsAt (s : St) (m : Nat) (q : Req) (e : Err) (strikes : Nat → Nat) : St :=
  { s with reqs := s.reqs.set m { q with status := .failed e }, strikes := strikes }

theorem timeout_of {s : St} {m : Nat} {q : Req} (hm : s.reqs[m]? = some q) (hp : q.status = .pending) :
    timeout s m = endsAt s m q .timedOut (bump s.strikes q.kind.input quarantineAt) := by
  simp [timeout, hm, hp, endsAt]

theorem cancel_of {s : St} {m : Nat} {q : Req} (hm : s.reqs[m]? = some q) (hp : q.status = .pending) :
    cancel s m = endsAt s m q .cancelled s.strikes := by
  simp [cancel, hm, hp, endsAt]

theorem timeout_idle {s : St} {m : Nat} (h : ∀ q, s.reqs[m]? = some q → q.status ≠ .pending) : timeout s m = s := by
  unfold timeout; split
  · rfl
  · rename_i q hq; simp [h q hq]

theorem cancel_idle {s : St} {m : Nat} (h : ∀ q, s.reqs[m]? = some q → q.status ≠ .pending) : cancel s m = s := by
  unfold cancel; split
  · rfl
  · rename_i q hq; simp [h q hq]

section ends
variable {s : St} {m : Nat} {q : Req} {e : Err} {f : Nat → Nat} (hm : s.reqs[m]? = some q) (hp : q.status = .pending)
include hm hp

omit hp in
theorem endsAt_get {j : Nat} {q' : Req} (hq' : (endsAt s m q e f).reqs[j]? = some q') :
    (j = m ∧ q' = { q with status := .failed e }) ∨ (j ≠ m ∧ s.reqs[j]? = some q') := by
  simp only [endsAt, List.getElem?_set] at hq'
  by_cases hj : m = j
  · subst hj; simp [lt_of_getElem?_some hm] at hq'; exact Or.inl ⟨rfl, hq'.symm⟩
  · simp only [hj, ↓reduceIte] at hq'; exact Or.inr ⟨Ne.symm hj, hq'⟩

omit hm hp in
theorem endsAt_old {j : Nat} {q0 : Req} (hj : j ≠ m) (h0 : s.reqs[j]? = some q0) : (endsAt s m q e f).reqs[j]? = some q0 := by
  simp only [endsAt]; rw [List.getElem?_set_ne (Ne.symm hj)]; exact h0

omit hp in
theorem kinds_endsAt : (endsAt s m q e f).reqs.map Req.kind = s.reqs.map Req.kind := by
  simp only [endsAt, List.map_set]
  exact set_self_of_getElem? (by rw [List.getElem?_map, hm]; rfl)

theorem notDelivered (ha : Answered s) (hpl : PendingLive s) : ∀ r, (m, r) ∉ s.delivered := by
  intro r hr
  obtain ⟨q0, hq0, hans⟩ := ha m r hr
  rw [hm] at hq0; obtain rfl := Option.some.inj hq0
  have := (hpl q (List.mem_of_getElem? hm) hp).1
  simp_all

theorem inv_endsAt (hi : Inv s) (hnot : e ≠ .lost) (hf : ∀ i, f i = s.strikes i + if q.kind.input = some i ∧ e = .timedOut then quarantineAt else 0) :
    Inv (endsAt s m q e f) := by
  obtain ⟨hs, hl, ho, hpl, he, ha, hok, hn, hr, hst⟩ := hi
  have nd := notDelivered hm hp ha hpl
  have mem : ∀ q', q' ∈ (endsAt s m q e f).reqs → q' ∈ s.reqs ∨ q' = { q with status := .failed e } := by
    intro q' hq'; simp only [endsAt] at hq'
    rcases List.mem_or_eq_of_mem_set hq' with h | h
    · exact Or.inl h
    · exact Or.inr h
  have hqmem : q ∈ s.reqs := List.mem_of_getElem? hm
  refine ⟨?_, hl, ho, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · intro q' hq' j hj
    rcases mem q' hq' with h | rfl
    · exact hs q' h j hj
    · exact hs q hqmem j hj
  · intro q' hq' hpend
    rcases mem q' hq' with h | rfl
    · exact hpl q' h hpend
    · simp at hpend
  · intro q' hq' hlost
    rcases mem q' hq' with h | rfl
    · exact he q' h hlost
    · simp at hlost; exact absurd hlost hnot
  · intro j r hj
    obtain ⟨q0, hq0, hans⟩ := ha j r hj
    have hjm : j ≠ m := by rintro rfl; exact nd r hj
    exact ⟨q0, endsAt_old hjm hq0, hans⟩
  · intro j q' v hq' hv
    rcases endsAt_get hm hq' with ⟨_, rfl⟩ | ⟨_, h0⟩
    · simp at hv
    · exact hok j q' v h0 hv
  · intro j r q' u hj hq' hlate
    rcases endsAt_get hm hq' with ⟨rfl, _⟩ | ⟨_, h0⟩
    · exact absurd hj (nd r)
    · rw [kinds_endsAt hm]; exact hn j r q' u hj h0 hlate
  · exact releaseNamed_mono hr (fun _ hx => hx)
      (fun j q' hq' => by
        rcases endsAt_get hm hq' with ⟨rfl, rfl⟩ | ⟨_, h0⟩
        · exact ⟨q, hm, rfl⟩
        · exact ⟨q', h0, rfl⟩)
      (fun j q0 h0 => by
        by_cases hj : j = m
        · subst hj; rw [hm] at h0; obtain rfl := Option.some.inj h0
          exact ⟨{ q with status := .failed e }, by simp [endsAt, lt_of_getElem?_some hm], rfl⟩
        · exact ⟨q0, endsAt_old hj h0, rfl⟩)
  · intro i
    have hlo : lostOn (endsAt s m q e f) i = lostOn s i := by
      funext j; unfold lostOn; simp only [endsAt]
      exact any_set_same hm (by simp [hp, hnot])
    have ht : timedOutCount (endsAt s m q e f) i = timedOutCount s i + if q.kind.input = some i ∧ e = .timedOut then 1 else 0 := by
      unfold timedOutCount; simp only [endsAt]
      rw [countP_set_add hm (by simp [hp])]
      congr 1
      by_cases h1 : q.kind.input = some i <;> by_cases h2 : e = .timedOut <;> simp [h1, h2]
    have hls : lostSessions (endsAt s m q e f) i = lostSessions s i := by unfold lostSessions; rw [hlo]; rfl
    show f i = _
    rw [hls, ht, hf i, hst i]
    rw [Nat.mul_add]
    split <;> simp [quarantineAt] <;> omega

end ends

/-! ## `call` -/

theorem inv_send {s : St} {k : Kind} (hi : Inv s) (hk : ∀ c u, k ≠ .release c u) : Inv (send s k) := by
  obtain ⟨hs, hl, ho, hpl, he, ha, hok, hn, hr, hst⟩ := hi
  exact ⟨shaped_send hs hl, liveOpen_send hl, oneOpen_send ho, pendingLive_send hpl hl, lostEnded_send he, answered_send ha,
    okOwn_send hok, noLeak_send hn ha, releaseNamed_send hr (fun c u e => absurd e (hk c u)), strikes_send hst hs⟩

/-- A request refused before sending. -/
def refusedReq (k : Kind) : Req := ⟨k, none, .failed .quarantined, true⟩

theorem inv_refuse {s : St} {k : Kind} (hi : Inv s) (hk : ∀ c u, k ≠ .release c u) :
    Inv { s with reqs := s.reqs ++ [refusedReq k] } := by
  obtain ⟨hs, hl, ho, hpl, he, ha, hok, hn, hr, hst⟩ := hi
  refine ⟨?_, hl, ho, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · intro q hq id hid; rw [List.mem_append] at hq
    rcases hq with hq | hq
    · exact hs q hq id hid
    · simp at hq; subst hq; simp [refusedReq] at hid
  · intro q hq hp; rw [List.mem_append] at hq
    rcases hq with hq | hq
    · exact hpl q hq hp
    · simp at hq; subst hq; simp [refusedReq] at hp
  · intro q hq hp; rw [List.mem_append] at hq
    rcases hq with hq | hq
    · exact he q hq hp
    · simp at hq; subst hq; simp [refusedReq] at hp
  · intro m r hm; obtain ⟨q, hq, hqa⟩ := ha m r hm; exact ⟨q, getElem?_append_of_some hq, hqa⟩
  · intro m q v hq hv
    rcases getElem?_concat_cases hq with hq | ⟨_, rfl⟩
    · exact hok m q v hq hv
    · simp [refusedReq] at hv
  · intro m r q u hm hq hl'
    obtain ⟨q0, hq0, _⟩ := ha m r hm
    obtain rfl : q0 = q := Option.some.inj ((getElem?_append_of_some hq0).symm.trans hq)
    rcases hn m r q0 u hm hq0 hl' with e | e
    · exact Or.inl e
    · exact Or.inr (by simp only [List.map_append]; exact List.mem_append_left _ e)
  · intro j q c u hq hk'
    rcases getElem?_concat_cases hq with hq | ⟨_, rfl⟩
    · obtain ⟨m, r, p, hm, hp, hc, hl'⟩ := hr j q c u hq hk'
      exact ⟨m, r, p, hm, getElem?_append_of_some hp, hc, hl'⟩
    · exact absurd hk' (hk c u)
  · intro i
    have ht : timedOutCount { s with reqs := s.reqs ++ [refusedReq k] } i = timedOutCount s i := by
      simp [timedOutCount, refusedReq]
    have hlo : lostOn { s with reqs := s.reqs ++ [refusedReq k] } i = lostOn s i := by
      funext j; simp [lostOn, refusedReq]
    have hls : lostSessions { s with reqs := s.reqs ++ [refusedReq k] } i = lostSessions s i := by
      unfold lostSessions; rw [hlo]
    rw [ht, hls]; exact hst i

theorem inv_call {s : St} (k : Kind) (hi : Inv s) : Inv (call s k) := by
  cases k with
  | release c u => exact hi
  | thumb size i =>
    simp only [call]; split
    · exact inv_refuse hi (by simp)
    · exact inv_send hi (by simp)
  | openV i =>
    simp only [call]; split
    · exact inv_refuse hi (by simp)
    · exact inv_send hi (by simp)
  | start =>
    simp only [call]; split
    · exact inv_refuse hi (by simp)
    · exact inv_send hi (by simp)

/-! ## `reply` -/

/-- The request once its reply is delivered. -/
def took1 (q : Req) (r : Reply) : Req := { q with answered := true, status := (answer q r).1 }

/-- `reply`'s state before any release. -/
def took (s : St) (m : Nat) (q : Req) (r : Reply) : St :=
  { s with reqs := s.reqs.set m (took1 q r), delivered := s.delivered ++ [(m, r)] }

theorem reply_cases (s : St) (m : Nat) (r : Reply) :
    reply s m r = s ∨ ∃ q id, s.reqs[m]? = some q ∧ q.sess = some id ∧ q.answered = false ∧ ended s id = false ∧
      (((answer q r).2 = none ∧ reply s m r = took s m q r) ∨
        ∃ u, (answer q r).2 = some u ∧ reply s m r = send (took s m q r) (.release q.kind.ch u)) := by
  cases hm : s.reqs[m]? with
  | none => left; simp [reply, hm]
  | some q =>
    cases hs : q.sess with
    | none => left; simp [reply, hm, hs]
    | some id =>
      by_cases hc : q.answered = true ∨ ended s id = true
      · left; simp [reply, hm, hs, hc]
      · right
        have h1 : q.answered = false := by cases h : q.answered <;> simp_all
        have h2 : ended s id = false := by cases h : ended s id <;> simp_all
        refine ⟨q, id, rfl, hs, h1, h2, ?_⟩
        cases ha : (answer q r).2 with
        | none => exact Or.inl ⟨rfl, by simp [reply, hm, hs, h1, h2, ha, took, took1]⟩
        | some u => exact Or.inr ⟨u, rfl, by simp [reply, hm, hs, h1, h2, ha, took, took1]⟩

section took
variable {s : St} {m : Nat} {q : Req} {r : Reply} (hm : s.reqs[m]? = some q)
include hm

theorem took_get {j : Nat} {q' : Req} (h : (took s m q r).reqs[j]? = some q') :
    (j = m ∧ q' = took1 q r) ∨ (j ≠ m ∧ s.reqs[j]? = some q') := by
  simp only [took, List.getElem?_set] at h
  by_cases hj : m = j
  · subst hj; simp [lt_of_getElem?_some hm] at h; exact Or.inl ⟨rfl, h.symm⟩
  · simp only [hj, ↓reduceIte] at h; exact Or.inr ⟨Ne.symm hj, h⟩

theorem took_at : (took s m q r).reqs[m]? = some (took1 q r) := by
  simp [took, lt_of_getElem?_some hm]

omit hm in
theorem took_old {j : Nat} {q0 : Req} (hj : j ≠ m) (h0 : s.reqs[j]? = some q0) : (took s m q r).reqs[j]? = some q0 := by
  simp only [took]; rw [List.getElem?_set_ne (Ne.symm hj)]; exact h0

theorem kinds_took : (took s m q r).reqs.map Req.kind = s.reqs.map Req.kind := by
  simp only [took, List.map_set]
  exact set_self_of_getElem? (by rw [List.getElem?_map, hm]; rfl)

variable (hans : q.answered = false)
include hans

theorem notDelivered_took (ha : Answered s) : ∀ r', (m, r') ∉ s.delivered := by
  intro r' hr
  obtain ⟨q0, hq0, h⟩ := ha m r' hr
  rw [hm] at hq0; obtain rfl := Option.some.inj hq0
  simp_all

theorem inv_took (hi : Inv s) :
    Shaped (took s m q r) ∧ LiveOpen (took s m q r) ∧ OneOpen (took s m q r) ∧ PendingLive (took s m q r) ∧
      LostEnded (took s m q r) ∧ Answered (took s m q r) ∧ OkOwn (took s m q r) ∧ ReleaseNamed (took s m q r) ∧
      StrikesExact (took s m q r) := by
  obtain ⟨hs, hl, ho, hpl, he, ha, hok, _, hr, hst⟩ := hi
  have nd := notDelivered_took hm hans ha
  have mem : ∀ q', q' ∈ (took s m q r).reqs → q' ∈ s.reqs ∨ q' = took1 q r := by
    intro q' hq'; simp only [took] at hq'
    exact List.mem_or_eq_of_mem_set hq'
  have hqmem : q ∈ s.reqs := List.mem_of_getElem? hm
  refine ⟨?_, hl, ho, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · intro q' hq' j hj
    rcases mem q' hq' with h | rfl
    · exact hs q' h j hj
    · exact hs q hqmem j hj
  · intro q' hq' hpend
    rcases mem q' hq' with h | rfl
    · exact hpl q' h hpend
    · exact absurd hpend (answer_not_pending q r)
  · intro q' hq' hlost
    rcases mem q' hq' with h | rfl
    · exact he q' h hlost
    · exact he q hqmem ((answer_lost q r).1 hlost)
  · intro j r' hj
    simp only [took, List.mem_append, List.mem_singleton] at hj
    rcases hj with hj | hj
    · obtain ⟨q0, hq0, hans0⟩ := ha j r' hj
      have hjm : j ≠ m := by rintro rfl; exact nd r' hj
      exact ⟨q0, took_old hjm hq0, hans0⟩
    · obtain ⟨hjm, hr'⟩ := Prod.mk.inj hj
      subst j; subst r'
      exact ⟨took1 q r, took_at hm, rfl⟩
  · intro j q' v hq' hv
    rcases took_get hm hq' with ⟨rfl, rfl⟩ | ⟨_, h0⟩
    · rcases answer_ok hv with ⟨_, hacc⟩ | hold
      · exact ⟨r, by simp [took], hacc⟩
      · obtain ⟨r0, hr0, hacc⟩ := hok j q v hm hold
        exact ⟨r0, by simp [took, hr0], hacc⟩
    · obtain ⟨r0, hr0, hacc⟩ := hok j q' v h0 hv
      exact ⟨r0, by simp [took, hr0], hacc⟩
  · exact releaseNamed_mono hr (fun x hx => by simp [took, hx])
      (fun j q' hq' => by
        rcases took_get hm hq' with ⟨rfl, rfl⟩ | ⟨_, h0⟩
        · exact ⟨q, hm, rfl⟩
        · exact ⟨q', h0, rfl⟩)
      (fun j q0 h0 => by
        by_cases hj : j = m
        · subst j; rw [hm] at h0; obtain rfl := Option.some.inj h0
          exact ⟨took1 q r, took_at hm, rfl⟩
        · exact ⟨q0, took_old hj h0, rfl⟩)
  · intro i
    have hlo : lostOn (took s m q r) i = lostOn s i := by
      funext j; unfold lostOn; simp only [took]
      exact any_set_same hm (by simp [took1, answer_lost])
    have ht : timedOutCount (took s m q r) i = timedOutCount s i := by
      unfold timedOutCount; simp only [took]
      exact countP_set_same hm (by simp [took1, answer_timedOut])
    have hls : lostSessions (took s m q r) i = lostSessions s i := by unfold lostSessions; rw [hlo]; rfl
    show s.strikes i = _
    rw [hls, ht]; exact hst i

/-- A delivered reply leaves no helper session behind, released or not. -/
theorem noLeak_reply {s' : St} (hi : Inv s)
    (hfwd : ∀ (j : Nat) (q0 : Req), (took s m q r).reqs[j]? = some q0 → s'.reqs[j]? = some q0)
    (hd : s'.delivered = (took s m q r).delivered)
    (hk : ∀ x ∈ s.reqs.map Req.kind, x ∈ s'.reqs.map Req.kind)
    (hrel : ∀ u, (answer q r).2 = some u → Kind.release q.kind.ch u ∈ s'.reqs.map Req.kind) : NoLeak s' := by
  obtain ⟨_, _, _, hpl, _, ha, _, hn, _, _⟩ := hi
  have nd := notDelivered_took hm hans ha
  intro j r' q' u hj hq' hlate
  rw [hd] at hj
  simp only [took, List.mem_append, List.mem_singleton] at hj
  rcases hj with hj | hj
  · obtain ⟨q0, hq0, _⟩ := ha j r' hj
    have hjm : j ≠ m := by rintro rfl; exact nd r' hj
    have := hfwd j q0 (took_old hjm hq0)
    rw [this] at hq'; obtain rfl := Option.some.inj hq'
    rcases hn j r' q0 u hj hq0 hlate with e | e
    · exact Or.inl e
    · exact Or.inr (hk _ e)
  · obtain ⟨hjm, hr'⟩ := Prod.mk.inj hj
    subst j; subst r'
    have := hfwd m (took1 q r) (took_at hm)
    rw [this] at hq'; obtain rfl := Option.some.inj hq'
    simp only [took1] at hlate ⊢
    unfold answer at hrel ⊢
    by_cases hp : q.status = .pending
    · simp only [hp, ↓reduceIte] at hrel ⊢
      rcases accept_late hlate with e | e
      · exact Or.inl e
      · exact Or.inr (hrel u e)
    · simp only [hp, ↓reduceIte] at hrel ⊢
      exact Or.inr (hrel u hlate)

end took

theorem inv_reply {s : St} (m : Nat) (r : Reply) (hi : Inv s) : Inv (reply s m r) := by
  rcases reply_cases s m r with h | ⟨q, id, hm, _, hans, _, ⟨hnone, h⟩ | ⟨u, hu, h⟩⟩
  · rw [h]; exact hi
  · rw [h]
    obtain ⟨hs, hl, ho, hpl, he, ha, hok, hr, hst⟩ := inv_took hm hans hi
    refine ⟨hs, hl, ho, hpl, he, ha, hok, ?_, hr, hst⟩
    exact noLeak_reply hm hans hi (fun _ _ h => h) rfl (by rw [kinds_took hm]; exact fun _ h => h)
      (fun u hu => by rw [hnone] at hu; cases hu)
  · rw [h]
    obtain ⟨hs, hl, ho, hpl, he, ha, hok, hr, hst⟩ := inv_took hm hans hi
    refine ⟨shaped_send hs hl, liveOpen_send hl, oneOpen_send ho, pendingLive_send hpl hl, lostEnded_send he, answered_send ha,
      okOwn_send hok, ?_, releaseNamed_send hr ?_, strikes_send hst hs⟩
    · exact noLeak_reply hm hans hi (fun _ _ h => send_old h) (send_delivered _ _)
        (fun x hx => by rw [kinds_send, kinds_took hm]; exact List.mem_append_left _ hx)
        (fun u' hu' => by
          rw [hu] at hu'; obtain rfl := Option.some.inj hu'
          rw [kinds_send]; simp)
    · intro c u' hk
      simp only [Kind.release.injEq] at hk
      obtain ⟨rfl, rfl⟩ := hk
      exact ⟨m, r, took1 q r, by simp [took], took_at hm, rfl, by simpa [took1] using answer_release_late hu⟩

/-! ## Every reachable state -/

theorem inv_init : Inv St.init := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;>
    simp [St.init, Shaped, LiveOpen, OneOpen, PendingLive, LostEnded, Answered, OkOwn, NoLeak, ReleaseNamed, StrikesExact,
      timedOutCount, lostSessions]

theorem inv_step {s : St} (e : Ev) (hi : Inv s) : Inv (step s e) := by
  cases e with
  | call k => exact inv_call k hi
  | reply m r => exact inv_reply m r hi
  | crash c =>
    show Inv (crash s c)
    cases h : s.live c with
    | none => simp only [crash, h]; exact hi
    | some id =>
      obtain ⟨hs, hl, ho, hpl, he, ha, hok, hn, hr, hst⟩ := hi
      exact ⟨shaped_crash h hs hl, liveOpen_crash h hl, oneOpen_crash h ho hl, pendingLive_crash h hpl, lostEnded_crash h he hl,
        answered_crash h ha, okOwn_crash h hok, noLeak_crash h hn, releaseNamed_crash h hr, strikes_crash h hst hl hpl he⟩
  | unsolicited c => exact hi
  | timeout m =>
    show Inv (timeout s m)
    by_cases hp : ∃ q, s.reqs[m]? = some q ∧ q.status = .pending
    · obtain ⟨q, hq, hp⟩ := hp
      rw [timeout_of hq hp]
      exact inv_endsAt hq hp hi (by simp) (fun i => by unfold bump; by_cases h : q.kind.input = some i <;> simp [h])
    · rw [timeout_idle (fun q hq e => hp ⟨q, hq, e⟩)]; exact hi
  | cancel m =>
    show Inv (cancel s m)
    by_cases hp : ∃ q, s.reqs[m]? = some q ∧ q.status = .pending
    · obtain ⟨q, hq, hp⟩ := hp
      rw [cancel_of hq hp]
      exact inv_endsAt hq hp hi (by simp) (fun i => by simp)
    · rw [cancel_idle (fun q hq e => hp ⟨q, hq, e⟩)]; exact hi

theorem inv_holds {s : St} (h : Reach s) : Inv s := by
  induction h with
  | init => exact inv_init
  | step e _ ih => exact inv_step e ih

/-! ## The theorems -/

/-- **A request ends once.** Whatever happens next (replies, again, late; crashes; timeouts;
cancellation), a request that has ended keeps its ending. In every state, reachable or not. -/
theorem final_stable (s : St) (e : Ev) {m : Nat} {q : Req} (hq : s.reqs[m]? = some q) (hf : q.status ≠ .pending) :
    ∃ q', (step s e).reqs[m]? = some q' ∧ q'.status = q.status ∧ q'.kind = q.kind := by
  cases e with
  | call k =>
    show ∃ q', (call s k).reqs[m]? = some q' ∧ _
    cases k with
    | release c u => exact ⟨q, hq, rfl, rfl⟩
    | thumb size i =>
      simp only [call]; split
      · exact ⟨q, getElem?_append_of_some hq, rfl, rfl⟩
      · exact ⟨q, send_old hq, rfl, rfl⟩
    | openV i =>
      simp only [call]; split
      · exact ⟨q, getElem?_append_of_some hq, rfl, rfl⟩
      · exact ⟨q, send_old hq, rfl, rfl⟩
    | start =>
      simp only [call]; split
      · exact ⟨q, getElem?_append_of_some hq, rfl, rfl⟩
      · exact ⟨q, send_old hq, rfl, rfl⟩
  | reply m' r =>
    show ∃ q', (reply s m' r).reqs[m]? = some q' ∧ _
    have hkeep : ∀ q0, s.reqs[m']? = some q0 → (took s m' q0 r).reqs[m]? = some q ∨
        (m = m' ∧ (took s m' q0 r).reqs[m]? = some (took1 q r)) := by
      intro q0 hq0
      by_cases hmm : m = m'
      · subst hmm; rw [hq] at hq0; obtain rfl := Option.some.inj hq0; exact Or.inr ⟨rfl, took_at hq⟩
      · exact Or.inl (took_old hmm hq)
    have hstat : (took1 q r).status = q.status := by simp [took1, answer, hf]
    rcases reply_cases s m' r with h | ⟨q0, _, hq0, _, _, _, ⟨_, h⟩ | ⟨u, _, h⟩⟩
    · rw [h]; exact ⟨q, hq, rfl, rfl⟩
    · rw [h]
      rcases hkeep q0 hq0 with h1 | ⟨_, h1⟩
      · exact ⟨q, h1, rfl, rfl⟩
      · exact ⟨took1 q r, h1, hstat, rfl⟩
    · rw [h]
      rcases hkeep q0 hq0 with h1 | ⟨_, h1⟩
      · exact ⟨q, send_old h1, rfl, rfl⟩
      · exact ⟨took1 q r, send_old h1, hstat, rfl⟩
  | crash c =>
    show ∃ q', (crash s c).reqs[m]? = some q' ∧ _
    cases h : s.live c with
    | none => simp only [crash, h]; exact ⟨q, hq, rfl, rfl⟩
    | some id => exact ⟨endReq id q, crash_get_old h hq, endReq_final hf, endReq_kind id q⟩
  | unsolicited c => exact ⟨q, hq, rfl, rfl⟩
  | timeout m' =>
    show ∃ q', (timeout s m').reqs[m]? = some q' ∧ _
    by_cases hp : ∃ q0, s.reqs[m']? = some q0 ∧ q0.status = .pending
    · obtain ⟨q0, hq0, hp0⟩ := hp
      have hmm : m ≠ m' := by rintro rfl; rw [hq] at hq0; obtain rfl := Option.some.inj hq0; exact hf hp0
      rw [timeout_of hq0 hp0]; exact ⟨q, endsAt_old hmm hq, rfl, rfl⟩
    · rw [timeout_idle (fun q0 hq0 e => hp ⟨q0, hq0, e⟩)]; exact ⟨q, hq, rfl, rfl⟩
  | cancel m' =>
    show ∃ q', (cancel s m').reqs[m]? = some q' ∧ _
    by_cases hp : ∃ q0, s.reqs[m']? = some q0 ∧ q0.status = .pending
    · obtain ⟨q0, hq0, hp0⟩ := hp
      have hmm : m ≠ m' := by rintro rfl; rw [hq] at hq0; obtain rfl := Option.some.inj hq0; exact hf hp0
      rw [cancel_of hq0 hp0]; exact ⟨q, endsAt_old hmm hq, rfl, rfl⟩
    · rw [cancel_idle (fun q0 hq0 e => hp ⟨q0, hq0, e⟩)]; exact ⟨q, hq, rfl, rfl⟩

/-- **Nothing waits on a session that has ended**: every outstanding request is on a session
that is up, so a crash ends every request on it at once (no watchdog needed). -/
theorem pendingLive_holds {s : St} (h : Reach s) : PendingLive s := (inv_holds h).2.2.2.1

/-- **A request succeeds only with a reply to its own message**, decoded and validated as its
own. -/
theorem okOwn_holds {s : St} (h : Reach s) : OkOwn s := (inv_holds h).2.2.2.2.2.2.1

theorem accept_thumb {size i : Nat} {r : Reply} {v : Val} (h : (accept (.thumb size i) r).1 = .ok v) :
    v = .thumb size size := by
  cases r <;> simp only [accept] at h <;> (try split at h) <;> simp_all

theorem accept_session {k : Kind} {r : Reply} {u : Nat} (h : (accept k r).1 = .ok (.session u)) : late k r = some u := by
  cases k <;> cases r <;> simp only [accept, late] at h ⊢ <;> (try split at h) <;> simp_all

/-- A thumbnail comes back only at the size its own request asked for, from its own reply. -/
theorem thumb_own {s : St} {m size i : Nat} {q : Req} {v : Val} (h : Reach s) (hq : s.reqs[m]? = some q)
    (hk : q.kind = .thumb size i) (hv : q.status = .ok v) : v = .thumb size size ∧ ∃ r, (m, r) ∈ s.delivered := by
  obtain ⟨r, hr, ha⟩ := okOwn_holds h m q v hq hv
  rw [hk] at ha
  exact ⟨accept_thumb ha, r, hr⟩

/-- A session handed to a caller is the one its own reply named. -/
theorem session_own {s : St} {m u : Nat} {q : Req} (h : Reach s) (hq : s.reqs[m]? = some q)
    (hv : q.status = .ok (.session u)) : ∃ r, (m, r) ∈ s.delivered ∧ late q.kind r = some u := by
  obtain ⟨r, hr, ha⟩ := okOwn_holds h m q _ hq hv
  exact ⟨r, hr, accept_session ha⟩

/-- **No helper session is left behind**: one a reply named for its request is the caller's or
released, whether the reply came in time, refused, or after the request ended. -/
theorem noLeak_holds {s : St} (h : Reach s) : NoLeak s := (inv_holds h).2.2.2.2.2.2.2.1

/-- **A release goes to the helper that named the session**, and names only what it named. -/
theorem releaseNamed_holds {s : St} (h : Reach s) : ReleaseNamed s := (inv_holds h).2.2.2.2.2.2.2.2.1

/-- **Strikes**: two per timeout, one per ended session the input was in flight on. -/
theorem strikes_holds {s : St} (h : Reach s) : StrikesExact s := (inv_holds h).2.2.2.2.2.2.2.2.2

/-- **An input is quarantined only if it hung, or it was in flight on two different sessions
that ended**: one crash never quarantines anything, however many requests were in flight. -/
theorem quarantine_cause {s : St} {i : Nat} (h : Reach s) (hq : quarantineAt ≤ s.strikes i) :
    (∃ q ∈ s.reqs, q.kind.input = some i ∧ q.status = .failed .timedOut) ∨
      ∃ a b, a ≠ b ∧ lostOn s i a = true ∧ lostOn s i b = true := by
  have hs := strikes_holds h i
  by_cases ht : 0 < timedOutCount s i
  · left
    obtain ⟨q, hq, hp⟩ := List.countP_pos_iff.1 ht
    simp only [decide_eq_true_eq] at hp
    exact ⟨q, hq, hp⟩
  · right
    have h2 : 2 ≤ lostSessions s i := by unfold quarantineAt at hs hq; omega
    obtain ⟨a, b, hab, _, _, ha, hb⟩ := two_of_countP List.nodup_range h2
    exact ⟨a, b, hab, ha, hb⟩

/-- One crash adds at most one strike to an input. -/
theorem crash_strikes_le (s : St) (c : Ch) (i : Nat) : (crash s c).strikes i ≤ s.strikes i + 1 := by
  unfold crash; split
  · omega
  · simp only; split <;> omega

theorem idle_of_no_live {s : St} {c : Ch} (hi : Inv s) (hlc : s.live c = none) :
    ∀ q ∈ s.reqs, q.kind.ch = c → q.status ≠ .pending := by
  obtain ⟨hs, _, ho, hpl, _⟩ := hi
  intro q hq hc hp
  obtain ⟨_, j, hj, hen⟩ := hpl q hq hp
  obtain ⟨x, hx, hxe⟩ := ended_false.1 hen
  obtain ⟨y, hy, hyc⟩ := hs q hq j hj
  rw [hx] at hy; obtain rfl := Option.some.inj hy
  have h1 := ho j x hx hxe
  rw [hyc, hc, hlc] at h1
  cases h1

theorem crash_live_none (s : St) (c : Ch) : (crash s c).live c = none := by
  unfold crash; split
  · assumption
  · simp

/-- **After a crash**, nothing on that channel is still waiting, and there is no live session:
the next request opens a new one. -/
theorem crash_ends {s : St} {c : Ch} (h : Reach s) :
    (crash s c).live c = none ∧ ∀ q ∈ (crash s c).reqs, q.kind.ch = c → q.status ≠ .pending :=
  ⟨crash_live_none s c, idle_of_no_live (inv_holds (Reach.step (.crash c) h)) (crash_live_none s c)⟩

/-- With no live session, a request goes on a new session that no earlier request used. -/
theorem send_fresh {s : St} {k : Kind} (h : Reach s) (hn : s.live k.ch = none) :
    (sent s k).sess = some s.sess.length ∧ ∀ q ∈ s.reqs, q.sess ≠ some s.sess.length := by
  refine ⟨by simp [sent, opened_of_none hn], fun q hq e => ?_⟩
  obtain ⟨x, hx, _⟩ := (inv_holds h).1 q hq _ e
  have := lt_of_getElem?_some hx
  omega

/-- **Channels are separate**: an event about one helper's channel leaves every request on the
other, and the other's session, as they were. -/
theorem other_channel {s : St} {e : Ev} {c : Ch} (h : Reach s) (hc : chOf s e = some c) :
    (∀ (j : Nat) (q : Req), s.reqs[j]? = some q → q.kind.ch ≠ c → (step s e).reqs[j]? = some q) ∧
      ∀ c', c' ≠ c → (step s e).live c' = s.live c' := by
  have hi := inv_holds h
  obtain ⟨hs, hl, _⟩ := hi
  cases e with
  | call k =>
    simp only [chOf, Option.some.injEq] at hc
    subst hc
    show (∀ (j : Nat) (q : Req), s.reqs[j]? = some q → _ → (call s k).reqs[j]? = some q) ∧ ∀ c', c' ≠ k.ch → (call s k).live c' = s.live c'
    cases k with
    | release c u => exact ⟨fun _ _ hq _ => hq, fun _ _ => rfl⟩
    | thumb size i =>
      simp only [call]; split
      · exact ⟨fun _ _ hq _ => getElem?_append_of_some hq, fun _ _ => rfl⟩
      · exact ⟨fun _ _ hq _ => send_old hq, fun _ h' => by rw [send_live, opened_live_ne h']⟩
    | openV i =>
      simp only [call]; split
      · exact ⟨fun _ _ hq _ => getElem?_append_of_some hq, fun _ _ => rfl⟩
      · exact ⟨fun _ _ hq _ => send_old hq, fun _ h' => by rw [send_live, opened_live_ne h']⟩
    | start =>
      simp only [call]; split
      · exact ⟨fun _ _ hq _ => getElem?_append_of_some hq, fun _ _ => rfl⟩
      · exact ⟨fun _ _ hq _ => send_old hq, fun _ h' => by rw [send_live, opened_live_ne h']⟩
  | reply m r =>
    show (∀ (j : Nat) (q : Req), s.reqs[j]? = some q → _ → (reply s m r).reqs[j]? = some q) ∧ ∀ c', c' ≠ c → (reply s m r).live c' = s.live c'
    rcases reply_cases s m r with h' | ⟨q0, _, hq0, _, _, _, ⟨_, h'⟩ | ⟨u, _, h'⟩⟩
    · rw [h']; exact ⟨fun _ _ hq _ => hq, fun _ _ => rfl⟩
    · simp only [chOf, hq0, Option.map_some, Option.some.injEq] at hc
      rw [h']
      refine ⟨fun j q hq hqc => ?_, fun _ _ => rfl⟩
      have hjm : j ≠ m := by rintro rfl; rw [hq0] at hq; obtain rfl := Option.some.inj hq; exact hqc hc
      exact took_old hjm hq
    · simp only [chOf, hq0, Option.map_some, Option.some.injEq] at hc
      rw [h']
      refine ⟨fun j q hq hqc => ?_, fun c' h'' => ?_⟩
      · have hjm : j ≠ m := by rintro rfl; rw [hq0] at hq; obtain rfl := Option.some.inj hq; exact hqc hc
        exact send_old (took_old hjm hq)
      · rw [send_live, opened_live_ne (by rw [Kind.ch, hc]; exact h'')]; rfl
  | crash c0 =>
    simp only [chOf, Option.some.injEq] at hc
    subst hc
    show (∀ (j : Nat) (q : Req), s.reqs[j]? = some q → _ → (crash s c0).reqs[j]? = some q) ∧ ∀ c', c' ≠ c0 → (crash s c0).live c' = s.live c'
    cases hlc : s.live c0 with
    | none =>
      have hsame : crash s c0 = s := by simp [crash, hlc]
      rw [hsame]; exact ⟨fun _ _ hq _ => hq, fun _ _ => rfl⟩
    | some id =>
      refine ⟨fun j q hq hqc => ?_, fun c' h' => by rw [crash_live hlc]; simp [h']⟩
      rw [crash_get_old hlc hq, endReq_off]
      intro e
      obtain ⟨x, hx, hxc⟩ := hs q (List.mem_of_getElem? hq) id e
      rw [hl c0 id hlc] at hx; obtain rfl := Option.some.inj hx
      exact hqc hxc.symm
  | unsolicited c0 => exact ⟨fun _ _ hq _ => hq, fun _ _ => rfl⟩
  | timeout m =>
    show (∀ (j : Nat) (q : Req), s.reqs[j]? = some q → _ → (timeout s m).reqs[j]? = some q) ∧ ∀ c', c' ≠ c → (timeout s m).live c' = s.live c'
    by_cases hp : ∃ q0, s.reqs[m]? = some q0 ∧ q0.status = .pending
    · obtain ⟨q0, hq0, hp0⟩ := hp
      simp only [chOf, hq0, Option.map_some, Option.some.injEq] at hc
      rw [timeout_of hq0 hp0]
      refine ⟨fun j q hq hqc => ?_, fun _ _ => rfl⟩
      have hjm : j ≠ m := by rintro rfl; rw [hq0] at hq; obtain rfl := Option.some.inj hq; exact hqc hc
      exact endsAt_old hjm hq
    · rw [timeout_idle (fun q0 hq0 e => hp ⟨q0, hq0, e⟩)]; exact ⟨fun _ _ hq _ => hq, fun _ _ => rfl⟩
  | cancel m =>
    show (∀ (j : Nat) (q : Req), s.reqs[j]? = some q → _ → (cancel s m).reqs[j]? = some q) ∧ ∀ c', c' ≠ c → (cancel s m).live c' = s.live c'
    by_cases hp : ∃ q0, s.reqs[m]? = some q0 ∧ q0.status = .pending
    · obtain ⟨q0, hq0, hp0⟩ := hp
      simp only [chOf, hq0, Option.map_some, Option.some.injEq] at hc
      rw [cancel_of hq0 hp0]
      refine ⟨fun j q hq hqc => ?_, fun _ _ => rfl⟩
      have hjm : j ≠ m := by rintro rfl; rw [hq0] at hq; obtain rfl := Option.some.inj hq; exact hqc hc
      exact endsAt_old hjm hq
    · rw [cancel_idle (fun q0 hq0 e => hp ⟨q0, hq0, e⟩)]; exact ⟨fun _ _ hq _ => hq, fun _ _ => rfl⟩

/-- **Replies that change nothing**: to a message already answered (a duplicate), to one whose
session has ended, to a request never sent; and a message nobody asked for. Definitional. -/
theorem inert {s : St} {m : Nat} {q : Req} (r : Reply) (hq : s.reqs[m]? = some q)
    (h : q.answered = true ∨ q.sess = none ∨ ∃ id, q.sess = some id ∧ ended s id = true) : reply s m r = s := by
  rcases h with h | h | ⟨id, hs, he⟩
  · cases hs : q.sess <;> simp [reply, hq, hs, h]
  · simp [reply, hq, h]
  · simp [reply, hq, hs, he]

theorem unsolicited_inert (s : St) (c : Ch) : step s (.unsolicited c) = s := rfl

/-- **A quarantined input is not sent**: no message, no session. Definitional. -/
theorem quarantined_unsent {s : St} {k : Kind} {i : Nat} (hk : k.input = some i) (hq : quarantineAt ≤ s.strikes i) :
    (call s k).sess = s.sess ∧ (call s k).reqs = s.reqs ++ [⟨k, none, .failed .quarantined, true⟩] := by
  cases k <;> simp_all [Kind.input, call, quarantined]

/-! ## From one helper to another (definitional) -/

/-- The GIF service is asked only for CDN URLs: https, a media host, no port, no credentials. -/
theorem fileAsked_cdn {u : Url} (h : fileAsked u = true) : u.https = true ∧ u.host < 5 ∧ u.port = false ∧ u.user = false := by
  simp only [fileAsked, cdn, Bool.and_eq_true, Bool.not_eq_true', decide_eq_true_eq] at h
  exact ⟨h.1.1.1, h.1.1.2, h.1.2, h.2⟩

/-- A page of GIFs is accepted only if every URL in it is a CDN URL. -/
theorem pageAccepted_cdn {us : List Url} (h : pageAccepted us = true) : ∀ u ∈ us, cdn u = true :=
  List.all_eq_true.1 h

/-- The fetcher is handed only the endpoint the parser's own answer carried, with no payload. -/
theorem handed_parser {r : EndpointReply} {e : Nat} (h : handed r = some e) : r.endpoint = some e ∧ r.payload = 0 := by
  unfold handed at h
  split at h
  · exact ⟨h, by assumption⟩
  · cases h

end Broker
