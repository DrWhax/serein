import CallBoundary.Model
import CallBoundary.Props

/-! # The proofs

`send_cases` pins down the four things a command can do: be refused (another generation), find
the endpoint gone (the generation moves on), run on the live endpoint, or run on a new one. The
invariant (`Inv`) and the configured endpoint are then kept by every step (`inv_step`,
`configured_step`), so they hold in every reachable state (`inv_reach`); `step_out` shows that
everything the app does for the service was allowed in the state the request arrived in. -/

namespace CallBoundary

/-! ## `send` -/

/-- A command on the live endpoint, or a new one: the state after it. -/
def St.ran (s : St) (e : Nat) (o : Origin) : St := { s with cmds := s.cmds ++ [⟨e, o, s.gen⟩] }

def St.fresh (s : St) (o : Origin) : St :=
  { s with ep := some s.eps, eps := s.eps + 1, epGen := s.epGen ++ [s.gen],
           configOn := if s.config then s.configOn ++ [s.eps] else s.configOn,
           cmds := s.cmds ++ (if s.config then [⟨s.eps, .rtc, s.gen⟩] else []) ++ [⟨s.eps, o, s.gen⟩] }

theorem sendLive_cases (s : St) (o : Origin) :
    (∃ e, s.ep = some e ∧ e ∈ s.gone ∧ send.sendLive s o = ({ s with ep := none, gen := s.gen + 1 }, false)) ∨
    (∃ e, s.ep = some e ∧ e ∉ s.gone ∧ send.sendLive s o = (s.ran e o, true)) ∨
    (s.ep = none ∧ send.sendLive s o = (s.fresh o, true)) := by
  unfold send.sendLive
  cases hep : s.ep with
  | some e =>
    by_cases hg : e ∈ s.gone
    · exact Or.inl ⟨e, rfl, hg, by simp [hg]⟩
    · exact Or.inr (Or.inl ⟨e, rfl, hg, by simp [hg, St.ran, hep]⟩)
  | none => exact Or.inr (Or.inr ⟨rfl, by simp [St.fresh]⟩)

theorem send_cases (s : St) (o : Origin) (g : Option Nat) :
    send s o g = (s, false) ∨
    (∃ e, s.ep = some e ∧ e ∈ s.gone ∧ send s o g = ({ s with ep := none, gen := s.gen + 1 }, false)) ∨
    (∃ e, s.ep = some e ∧ e ∉ s.gone ∧ send s o g = (s.ran e o, true)) ∨
    (s.ep = none ∧ send s o g = (s.fresh o, true)) := by
  have h : send s o g = (s, false) ∨ send s o g = send.sendLive s o := by
    unfold send
    cases g with
    | none => exact Or.inr rfl
    | some g' =>
      by_cases h : g' = s.gen
      · exact Or.inr (by simp [h])
      · exact Or.inl (by simp [h])
  rcases h with h | h
  · exact Or.inl h
  · rw [h]; exact Or.inr (sendLive_cases s o)

/-- Without a generation a command is never refused: it runs, or finds the endpoint gone. -/
theorem send_none_cases (s : St) (o : Origin) :
    (∃ e, s.ep = some e ∧ e ∈ s.gone ∧ send s o none = ({ s with ep := none, gen := s.gen + 1 }, false)) ∨
    (∃ e, s.ep = some e ∧ e ∉ s.gone ∧ send s o none = (s.ran e o, true)) ∨
    (s.ep = none ∧ send s o none = (s.fresh o, true)) := sendLive_cases s o

/-- **A command made on a passed generation reaches nothing.** -/
theorem stale_refused (s : St) (o : Origin) (g : Nat) (h : g ≠ s.gen) : send s o (some g) = (s, false) := by
  simp [send, h]

/-- What a command leaves alone. -/
theorem send_keeps (s : St) (o : Origin) (g : Option Nat) :
    (send s o g).1.call = s.call ∧ (send s o g).1.offers = s.offers ∧ (send s o g).1.groups = s.groups ∧
    (send s o g).1.senders = s.senders ∧ (send s o g).1.cancelled = s.cancelled ∧ (send s o g).1.out = s.out ∧
    (send s o g).1.reported = s.reported ∧ (send s o g).1.config = s.config ∧ (send s o g).1.selfKnown = s.selfKnown ∧
    (send s o g).1.gone = s.gone ∧ s.gen ≤ (send s o g).1.gen := by
  rcases send_cases s o g with h | ⟨e, _, _, h⟩ | ⟨e, _, _, h⟩ | ⟨_, h⟩ <;> rw [h] <;> simp [St.ran, St.fresh]

theorem run_keeps (s : St) (o : Origin) (g : Option Nat) :
    (run s o g).call = s.call ∧ (run s o g).offers = s.offers ∧ (run s o g).groups = s.groups ∧
    (run s o g).senders = s.senders ∧ (run s o g).cancelled = s.cancelled ∧ (run s o g).out = s.out ∧
    (run s o g).reported = s.reported ∧ (run s o g).config = s.config ∧ (run s o g).selfKnown = s.selfKnown ∧
    (run s o g).gone = s.gone ∧ s.gen ≤ (run s o g).gen := send_keeps s o g

/-! ## The invariant -/

/-- The part of `Inv` about endpoints and commands, which `send` keeps. -/
structure Core (s : St) : Prop where
  epGenLen : s.epGen.length = s.eps
  epLive : ∀ e, s.ep = some e → s.epGen[e]? = some s.gen
  cmdsGen : ∀ c ∈ s.cmds, s.epGen[c.ep]? = some c.gen

theorem core_send {s : St} (o : Origin) (g : Option Nat) (h : Core s) : Core (send s o g).1 := by
  rcases send_cases s o g with h1 | ⟨e, he, _, h1⟩ | ⟨e, he, _, h1⟩ | ⟨he, h1⟩ <;> rw [h1]
  · exact h
  · exact ⟨h.epGenLen, by simp, h.cmdsGen⟩
  · refine ⟨h.epGenLen, h.epLive, ?_⟩
    intro c hc
    simp only [St.ran, List.mem_append, List.mem_singleton] at hc
    rcases hc with hc | rfl
    · exact h.cmdsGen c hc
    · exact h.epLive e he
  · have hlt : ∀ c ∈ s.cmds, c.ep < s.epGen.length := by
      intro c hc
      have := h.cmdsGen c hc
      exact (List.getElem?_eq_some_iff.mp this).1
    have hnew : (s.epGen ++ [s.gen])[s.eps]? = some s.gen := by
      rw [← h.epGenLen]; simp
    refine ⟨by simp [St.fresh, h.epGenLen], ?_, ?_⟩
    · intro e' he'
      simp [St.fresh] at he'
      subst he'; exact hnew
    · intro c hc
      simp only [St.fresh, List.mem_append, List.mem_singleton] at hc
      rcases hc with (hc | hc) | rfl
      · show (s.epGen ++ [s.gen])[c.ep]? = some c.gen
        rw [List.getElem?_append_left (hlt c hc)]; exact h.cmdsGen c hc
      · split at hc
        · simp at hc; subst hc; exact hnew
        · simp at hc
      · exact hnew

theorem core_run {s : St} (o : Origin) (g : Option Nat) (h : Core s) : Core (run s o g) := core_send o g h

/-- The part of `Inv` about calls and groups. -/
structure Gens (s : St) : Prop where
  reportedLe : s.reported ≤ s.gen
  callGen : ∀ k, s.call = some k → k.gen ≤ s.gen ∧ (k.ended = false → s.reported ≤ k.gen)
  groupGen : ∀ g ∈ s.groups, g.gen ≤ s.gen ∧ s.reported ≤ g.gen

/-- `send` keeps `Gens`: the generation only grows. -/
theorem gens_send {s : St} (o : Origin) (g : Option Nat) (h : Gens s) : Gens (send s o g).1 := by
  obtain ⟨hc, -, hg, -, -, -, hr, -, -, -, hle⟩ := send_keeps s o g
  refine ⟨by rw [hr]; exact Nat.le_trans h.reportedLe hle, ?_, ?_⟩
  · intro k hk
    rw [hc] at hk
    obtain ⟨a, b⟩ := h.callGen k hk
    exact ⟨Nat.le_trans a hle, by rw [hr]; exact b⟩
  · intro g' hg'
    rw [hg] at hg'
    obtain ⟨a, b⟩ := h.groupGen g' hg'
    exact ⟨Nat.le_trans a hle, by rw [hr]; exact b⟩

theorem gens_run {s : St} (o : Origin) (g : Option Nat) (h : Gens s) : Gens (run s o g) := gens_send o g h

theorem mem_insertGroup {g g' : GroupR} {gs : List GroupR} (h : g' ∈ insertGroup g gs) : g' = g ∨ g' ∈ gs := by
  induction gs with
  | nil => simp [insertGroup] at h; exact Or.inl h
  | cons x t ih =>
    simp only [insertGroup] at h
    split at h
    · simp at h; rcases h with h | h | h
      · exact Or.inl h
      · exact Or.inr (by simp [h])
      · exact Or.inr (by simp [h])
    · split at h
      · simp at h; rcases h with h | h
        · exact Or.inl h
        · exact Or.inr (by simp [h])
      · simp at h; rcases h with h | h
        · exact Or.inr (by simp [h])
        · rcases ih h with h' | h'
          · exact Or.inl h'
          · exact Or.inr (by simp [h'])

theorem mem_updGroup {c : Nat} {f : GroupR → GroupR} {gs : List GroupR} {g' : GroupR} (h : g' ∈ updGroup c f gs) :
    ∃ g ∈ gs, g' = g ∨ g' = f g := by
  simp only [updGroup, List.mem_map] at h
  obtain ⟨g, hg, rfl⟩ := h
  refine ⟨g, hg, ?_⟩
  split <;> simp

theorem findGroup_mem {s : St} {c : Nat} {g : GroupR} (h : findGroup s c = some g) : g ∈ s.groups ∧ g.client = c := by
  simp only [findGroup] at h
  exact ⟨List.mem_of_find?_eq_some h, by simpa using List.find?_some h⟩

/-- Groups whose generations are kept. -/
theorem gens_groups {s : St} (gs : List GroupR) (h : Gens s) (hg : ∀ g ∈ gs, g.gen ≤ s.gen ∧ s.reported ≤ g.gen) :
    Gens { s with groups := gs } := ⟨h.reportedLe, h.callGen, hg⟩

theorem gens_upd {s : St} (c : Nat) (f : GroupR → GroupR) (hf : ∀ g, (f g).gen = g.gen) (h : Gens s) :
    Gens { s with groups := updGroup c f s.groups } := by
  refine gens_groups _ h ?_
  intro g' hg'
  obtain ⟨g0, hg0, h1 | h1⟩ := mem_updGroup hg'
  · rw [h1]; exact h.groupGen g0 hg0
  · rw [h1, hf]; exact h.groupGen g0 hg0

theorem core_with {s s' : St} (h : Core s) (e1 : s'.epGen = s.epGen) (e2 : s'.eps = s.eps) (e3 : s'.ep = s.ep)
    (e4 : s'.gen = s.gen) (e5 : s'.cmds = s.cmds) : Core s' := by
  refine ⟨by rw [e1, e2]; exact h.epGenLen, ?_, ?_⟩
  · intro e he; rw [e1, e4]; rw [e3] at he; exact h.epLive e he
  · intro c hc; rw [e1]; rw [e5] at hc; exact h.cmdsGen c hc

theorem core_step {s : St} (e : Ev) (h : Core s) : Core (step s e) := by
  cases e with
  | setSelf =>
    simp only [step]
    have h1 : Core { s with selfKnown := true, config := true } := core_with h rfl rfl rfl rfl rfl
    have h2 := core_send .rtc none h1
    split
    · rename_i s2 heq
      rw [heq] at h2
      split
      · split
        · exact h2
        · exact core_with h2 rfl rfl rfl rfl rfl
      · exact h2
    · rename_i s2 heq
      rw [heq] at h2; exact h2
  | start p c =>
    simp only [step]
    have h2 := core_send .rtc none h
    split
    · rename_i s1 heq; rw [heq] at h2; exact core_with h2 rfl rfl rfl rfl rfl
    · rename_i s1 heq; rw [heq] at h2; exact h2
  | offer p c => exact core_run _ _ (core_with h rfl rfl rfl rfl rfl)
  | callMsg u => exact core_run _ _ (core_with h rfl rfl rfl rfl rfl)
  | group gid c link =>
    simp only [step]
    have h2 := core_send .rtc none h
    split
    · rename_i s1 heq; rw [heq] at h2
      split
      · exact h2
      · exact core_with h2 rfl rfl rfl rfl rfl
    · rename_i s1 heq; rw [heq] at h2; exact h2
  | members c ms =>
    simp only [step]; split
    · exact core_run _ _ (core_with h rfl rfl rfl rfl rfl)
    · exact h
  | callCmd => simp only [step]; split <;> first | exact core_run _ _ h | exact h
  | groupCmd c => simp only [step]; split <;> first | exact core_run _ _ h | exact h
  | cancelRing gid => exact core_run _ _ (core_with h rfl rfl rfl rfl rfl)
  | expireSender u => exact core_with h rfl rfl rfl rfl rfl
  | expireRing gid => exact core_with h rfl rfl rfl rfl rfl
  | incoming p c => simp only [step]; split <;> first | exact h | exact core_with h rfl rfl rfl rfl rfl
  | signal p c =>
    simp only [step]; split
    · exact h
    · split
      · exact core_run _ _ (core_with h rfl rfl rfl rfl rfl)
      · exact core_run _ _ h
  | message u => simp only [step]; split <;> first | exact h | exact core_with h rfl rfl rfl rfl rfl
  | groupMessage gid us => simp only [step]; split <;> first | exact h | exact core_with h rfl rfl rfl rfl rfl
  | ring u gid => simp only [step]; split <;> first | exact h | exact core_with h rfl rfl rfl rfl rfl
  | callEnded c =>
    simp only [step]; split
    · exact h
    · have h1 : Core { s with offers := s.offers.filter (·.1 ≠ c) } := core_with h rfl rfl rfl rfl rfl
      split
      · split
        · exact core_run _ _ (core_run _ _ (core_run _ _ (core_with h1 rfl rfl rfl rfl rfl)))
        · exact h1
      · exact h1
  | devices c us => simp only [step]; split <;> first | exact h | exact core_with h rfl rfl rfl rfl rfl
  | groupEnded c =>
    simp only [step]; split
    · exact h
    · split
      · rename_i g _
        have := core_run .group (some g.gen) (core_with (s' := { s with groups := s.groups.filter (·.client ≠ c) }) h rfl rfl rfl rfl rfl)
        exact core_with this rfl rfl rfl rfl rfl
      · exact h
  | crash =>
    simp only [step]; split
    · split
      · exact h
      · exact core_with h rfl rfl rfl rfl rfl
    · exact h
  | wait =>
    simp only [step]; split
    · exact core_with h rfl rfl rfl rfl rfl
    · split
      · split
        · exact ⟨h.epGenLen, by simp, h.cmdsGen⟩
        · exact h
      · exact h

/-- **A reported loss ends everything made before it.** -/
theorem gens_report {s : St} (h : Gens s) : Gens (report s) := by
  refine ⟨Nat.le_refl _, ?_, ?_⟩
  · intro k hk
    cases hc : s.call with
    | none => simp [report, hc] at hk
    | some k0 =>
      simp only [report, hc, Option.map_some, Option.some.injEq] at hk
      subst hk
      obtain ⟨a, _⟩ := h.callGen k0 hc
      by_cases hlt : k0.gen < s.gen
      · simp only [hlt, ite_true]; exact ⟨a, by simp⟩
      · simp only [hlt, ite_false]; exact ⟨a, fun _ => by simp only [report]; omega⟩
  · intro g hg
    simp only [report, List.mem_filter, decide_eq_true_eq] at hg
    exact ⟨(h.groupGen g hg.1).1, hg.2⟩

theorem gens_step {s : St} (e : Ev) (h : Gens s) : Gens (step s e) := by
  cases e with
  | setSelf =>
    simp only [step]
    have h1 : Gens { s with selfKnown := true, config := true } := ⟨h.reportedLe, h.callGen, h.groupGen⟩
    have h2 := gens_send .rtc none h1
    split
    · rename_i s2 heq
      rw [heq] at h2
      split
      · split
        · exact h2
        · exact ⟨h2.reportedLe, h2.callGen, h2.groupGen⟩
      · exact h2
    · rename_i s2 heq; rw [heq] at h2; exact h2
  | start p c =>
    simp only [step]
    have h2 := gens_send .rtc none h
    split
    · rename_i s1 heq; rw [heq] at h2
      refine ⟨h2.reportedLe, ?_, h2.groupGen⟩
      intro k hk
      simp at hk; subst hk
      exact ⟨Nat.le_refl _, fun _ => h2.reportedLe⟩
    · rename_i s1 heq; rw [heq] at h2; exact h2
  | offer p c => exact gens_run _ _ ⟨h.reportedLe, h.callGen, h.groupGen⟩
  | callMsg u => exact gens_run _ _ ⟨h.reportedLe, h.callGen, h.groupGen⟩
  | group gid c link =>
    simp only [step]
    have h2 := gens_send .rtc none h
    split
    · rename_i s1 heq; rw [heq] at h2
      split
      · exact h2
      · refine ⟨h2.reportedLe, h2.callGen, ?_⟩
        intro g' hg'
        rcases mem_insertGroup hg' with rfl | hg'
        · exact ⟨Nat.le_refl _, h2.reportedLe⟩
        · exact h2.groupGen g' hg'
    · rename_i s1 heq; rw [heq] at h2; exact h2
  | members c ms =>
    simp only [step]; split
    · exact gens_run _ _ (gens_upd c _ (fun _ => rfl) h)
    · exact h
  | callCmd => simp only [step]; split <;> first | exact gens_run _ _ h | exact h
  | groupCmd c => simp only [step]; split <;> first | exact gens_run _ _ h | exact h
  | cancelRing gid => exact gens_run _ _ ⟨h.reportedLe, h.callGen, h.groupGen⟩
  | expireSender u => exact ⟨h.reportedLe, h.callGen, h.groupGen⟩
  | expireRing gid => exact ⟨h.reportedLe, h.callGen, h.groupGen⟩
  | incoming p c =>
    simp only [step]; split
    · refine ⟨h.reportedLe, ?_, h.groupGen⟩
      intro k hk; simp at hk; subst hk
      exact ⟨Nat.le_refl _, fun _ => h.reportedLe⟩
    · exact h
  | signal p c =>
    simp only [step]; split
    · exact h
    · split
      · exact gens_run _ _ ⟨h.reportedLe, h.callGen, h.groupGen⟩
      · exact gens_run _ _ h
  | message u => simp only [step]; split <;> first | exact h | exact ⟨h.reportedLe, h.callGen, h.groupGen⟩
  | groupMessage gid us => simp only [step]; split <;> first | exact h | exact ⟨h.reportedLe, h.callGen, h.groupGen⟩
  | ring u gid => simp only [step]; split <;> first | exact h | exact ⟨h.reportedLe, h.callGen, h.groupGen⟩
  | callEnded c =>
    simp only [step]; split
    · exact h
    · have h1 : Gens { s with offers := s.offers.filter (·.1 ≠ c) } := ⟨h.reportedLe, h.callGen, h.groupGen⟩
      split
      · rename_i k hk
        split
        · refine gens_run _ _ (gens_run _ _ (gens_run _ _ ⟨h.reportedLe, ?_, h.groupGen⟩))
          intro k' hk'; simp at hk'; subst hk'
          exact ⟨(h.callGen k hk).1, by simp⟩
        · exact h1
      · exact h1
  | devices c us =>
    simp only [step]; split
    · exact gens_upd c _ (fun _ => rfl) h
    · exact h
  | groupEnded c =>
    simp only [step]; split
    · exact h
    · split
      · rename_i g _
        have h1 : Gens { s with groups := s.groups.filter (·.client ≠ c) } := by
          refine gens_groups _ h ?_
          intro g' hg'; exact h.groupGen g' ((List.mem_filter.mp hg').1)
        have := gens_run .group (some g.gen) h1
        exact ⟨this.reportedLe, this.callGen, this.groupGen⟩
      · exact h
  | crash =>
    simp only [step]; split
    · split
      · exact h
      · exact ⟨h.reportedLe, h.callGen, h.groupGen⟩
    · exact h
  | wait =>
    simp only [step]; split
    · exact gens_report h
    · split
      · split
        · refine ⟨Nat.le_succ_of_le h.reportedLe, ?_, ?_⟩
          · intro k hk; obtain ⟨a, b⟩ := h.callGen k hk; exact ⟨Nat.le_succ_of_le a, b⟩
          · intro g hg; obtain ⟨a, b⟩ := h.groupGen g hg; exact ⟨Nat.le_succ_of_le a, b⟩
        · exact h
      · exact h

/-! ## `setSelfUuid` on the live endpoint -/

def Configured (s : St) : Prop := s.config = true → ∀ e, s.ep = some e → e ∈ s.configOn

theorem configured_send {s : St} (o : Origin) (g : Option Nat) (h : Configured s) : Configured (send s o g).1 := by
  rcases send_cases s o g with h1 | ⟨e, he, _, h1⟩ | ⟨e, he, _, h1⟩ | ⟨he, h1⟩ <;> rw [h1]
  · exact h
  · intro _ e' he'; simp at he'
  · exact h
  · intro hc e' he'
    simp only [St.fresh, Option.some.injEq] at he' hc ⊢
    rw [← he']; simp [hc]

theorem configured_with {s s' : St} (h : Configured s) (e1 : s'.config = s.config) (e2 : s'.ep = s.ep) (e3 : s'.configOn = s.configOn) :
    Configured s' := by
  intro hc e he; rw [e3]; rw [e1] at hc; rw [e2] at he; exact h hc e he

theorem configured_run {s : St} (o : Origin) (g : Option Nat) (h : Configured s) : Configured (run s o g) := configured_send o g h

theorem configured_step {s : St} (e : Ev) (h : Configured s) : Configured (step s e) := by
  cases e with
  | setSelf =>
    simp only [step]
    rcases send_none_cases { s with selfKnown := true, config := true } .rtc with ⟨e, he, _, h1⟩ | ⟨e, he, _, h1⟩ | ⟨he, h1⟩ <;>
      rw [h1]
    · intro _ e' he'; simp at he'
    · simp only [St.ran]
      have : s.ep = some e := he
      simp only [this]
      split
      · intro _ e' he'; simp only [Option.some.injEq] at he'; subst he'; assumption
      · intro _ e' he'; simp only [Option.some.injEq] at he'; subst he'; simp
    · simp only [St.fresh, ite_true]
      split
      · intro _ e' he'; simp only [Option.some.injEq] at he'; subst he'; assumption
      · intro _ e' he'; simp only [Option.some.injEq] at he'; subst he'; simp
  | start p c =>
    simp only [step]
    have h2 := configured_send .rtc none h
    split
    · rename_i s1 heq; rw [heq] at h2; exact configured_with h2 rfl rfl rfl
    · rename_i s1 heq; rw [heq] at h2; exact h2
  | offer p c => exact configured_run _ _ (configured_with h rfl rfl rfl)
  | callMsg u => exact configured_run _ _ (configured_with h rfl rfl rfl)
  | group gid c link =>
    simp only [step]
    have h2 := configured_send .rtc none h
    split
    · rename_i s1 heq; rw [heq] at h2
      split
      · exact h2
      · exact configured_with h2 rfl rfl rfl
    · rename_i s1 heq; rw [heq] at h2; exact h2
  | members c ms => simp only [step]; split <;> first | exact configured_run _ _ (configured_with h rfl rfl rfl) | exact h
  | callCmd => simp only [step]; split <;> first | exact configured_run _ _ h | exact h
  | groupCmd c => simp only [step]; split <;> first | exact configured_run _ _ h | exact h
  | cancelRing gid => exact configured_run _ _ (configured_with h rfl rfl rfl)
  | expireSender u => exact configured_with h rfl rfl rfl
  | expireRing gid => exact configured_with h rfl rfl rfl
  | incoming p c => simp only [step]; split <;> first | exact h | exact configured_with h rfl rfl rfl
  | signal p c =>
    simp only [step]; split
    · exact h
    · split
      · exact configured_run _ _ (configured_with h rfl rfl rfl)
      · exact configured_run _ _ h
  | message u => simp only [step]; split <;> first | exact h | exact configured_with h rfl rfl rfl
  | groupMessage gid us => simp only [step]; split <;> first | exact h | exact configured_with h rfl rfl rfl
  | ring u gid => simp only [step]; split <;> first | exact h | exact configured_with h rfl rfl rfl
  | callEnded c =>
    simp only [step]; split
    · exact h
    · have h1 : Configured { s with offers := s.offers.filter (·.1 ≠ c) } := configured_with h rfl rfl rfl
      split
      · split
        · exact configured_run _ _ (configured_run _ _ (configured_run _ _ (configured_with h1 rfl rfl rfl)))
        · exact h1
      · exact h1
  | devices c us => simp only [step]; split <;> first | exact h | exact configured_with h rfl rfl rfl
  | groupEnded c =>
    simp only [step]; split
    · exact h
    · split
      · rename_i g _
        have := configured_run .group (some g.gen) (configured_with (s' := { s with groups := s.groups.filter (·.client ≠ c) }) h rfl rfl rfl)
        exact configured_with this rfl rfl rfl
      · exact h
  | crash =>
    simp only [step]; split
    · split
      · exact h
      · exact configured_with h rfl rfl rfl
    · exact h
  | wait =>
    simp only [step]; split
    · exact configured_with h rfl rfl rfl
    · split
      · split
        · intro _ e' he'; simp at he'
        · exact h
      · exact h

/-! ## Every reachable state -/

theorem inv_of {s : St} (c : Core s) (g : Gens s) (k : Configured s) : Inv s :=
  ⟨c.epGenLen, c.epLive, g.reportedLe, c.cmdsGen, g.callGen, g.groupGen, k⟩

theorem inv_init : Inv St.init := by
  refine ⟨rfl, ?_, Nat.le_refl _, ?_, ?_, ?_, ?_⟩ <;> simp [St.init]

theorem inv_step {s : St} (e : Ev) (h : Inv s) : Inv (step s e) :=
  inv_of (core_step e ⟨h.epGenLen, h.epLive, h.cmdsGen⟩) (gens_step e ⟨h.reportedLe, h.callGen, h.groupGen⟩)
    (configured_step e h.configured)

theorem inv_run' (s : St) (es : List Ev) (h : Inv s) : Inv (run' s es) := by
  induction es generalizing s with
  | nil => exact h
  | cons e es ih => exact ih (step s e) (inv_step e h)

/-- **Every reachable state keeps the invariant**: commands reach only the endpoint of their
generation, a reported loss has ended everything made before it, and the live endpoint has
`setSelfUuid` once it is known. -/
theorem inv_reach (es : List Ev) : Inv (run' St.init es) := inv_run' _ es inv_init

/-! ## What the app does for the service -/

theorem lookup_eq {offers : List (Nat × Nat)} {c p : Nat} (h : (lookup offers c == some p) = true) : lookup offers c = some p := by
  simpa using h

theorem maySignal_allowed {s : St} {p c : Nat} (h : maySignal s p c = true) : Allowed s (.signal p c) := by
  simp only [maySignal, Bool.or_eq_true] at h
  rcases h with h | h
  · left
    split at h
    · rename_i k hk
      simp only [Bool.and_eq_true, beq_iff_eq] at h
      exact ⟨k, hk, h.1, h.2⟩
    · simp at h
  · right; exact lookup_eq h

theorem mayMessage_allowed {s : St} {u : Nat} (h : mayMessage s u = true) :
    (s.selfKnown = true ∧ u = selfId) ∨ ∃ g ∈ s.groups, (g.link = false ∧ u ∈ g.members) ∨ (g.link = true ∧ u ∈ g.participants) := by
  simp only [mayMessage, Bool.or_eq_true, Bool.and_eq_true, beq_iff_eq, List.any_eq_true] at h
  rcases h with h | ⟨g, hg, h⟩
  · exact Or.inl h
  · refine Or.inr ⟨g, hg, ?_⟩
    simp only [Bool.not_eq_true', List.contains_iff_mem] at h
    rcases h with h | h
    · exact Or.inl h
    · exact Or.inr h

/-- **Everything the app does for the service was allowed in the state the request arrived in**:
signalling to a call's peer or an offer's sender, an incoming call only for an offer, call
messages to ourselves, members or call-link participants, group messages to a group with a call
or a cancelled ring, rings from call-message senders, and `onEnded` only for clients it had. -/
theorem step_out (s : St) (e : Ev) : ∃ n, (step s e).out = s.out ++ n ∧ ∀ o ∈ n, Allowed s o := by
  have nothing : ∀ s' : St, s'.out = s.out → ∃ n, s'.out = s.out ++ n ∧ ∀ o ∈ n, Allowed s o :=
    fun s' h => ⟨[], by simp [h], by simp⟩
  have one : ∀ (s' : St) (o : Out), s'.out = s.out ++ [o] → Allowed s o → ∃ n, s'.out = s.out ++ n ∧ ∀ o ∈ n, Allowed s o :=
    fun s' o h ha => ⟨[o], h, by simpa using ha⟩
  cases e with
  | setSelf =>
    apply nothing; simp only [step]
    have := (send_keeps { s with selfKnown := true, config := true } .rtc none).2.2.2.2.2.1
    split
    · rename_i s2 heq; rw [heq] at this
      split
      · split <;> simpa using this
      · simpa using this
    · rename_i s2 heq; rw [heq] at this; simpa using this
  | start p c =>
    apply nothing; simp only [step]
    have := (send_keeps s .rtc none).2.2.2.2.2.1
    split
    · rename_i s1 heq; rw [heq] at this; simpa using this
    · rename_i s1 heq; rw [heq] at this; simpa using this
  | offer p c => apply nothing; simp only [step]; rw [(run_keeps _ _ _).2.2.2.2.2.1]
  | callMsg u => apply nothing; simp only [step]; rw [(run_keeps _ _ _).2.2.2.2.2.1]
  | group gid c link =>
    apply nothing; simp only [step]
    have := (send_keeps s .rtc none).2.2.2.2.2.1
    split
    · rename_i s1 heq; rw [heq] at this
      split <;> simpa using this
    · rename_i s1 heq; rw [heq] at this; simpa using this
  | members c ms =>
    apply nothing; simp only [step]; split
    · rw [(run_keeps _ _ _).2.2.2.2.2.1]
    · rfl
  | callCmd => apply nothing; simp only [step]; split <;> first | rw [(run_keeps _ _ _).2.2.2.2.2.1] | rfl
  | groupCmd c => apply nothing; simp only [step]; split <;> first | rw [(run_keeps _ _ _).2.2.2.2.2.1] | rfl
  | cancelRing gid => apply nothing; simp only [step]; rw [(run_keeps _ _ _).2.2.2.2.2.1]
  | expireSender u => apply nothing; rfl
  | expireRing gid => apply nothing; rfl
  | incoming p c =>
    simp only [step]; split
    · rename_i h
      simp only [Bool.and_eq_true] at h
      exact one _ _ rfl (lookup_eq h.2)
    · exact nothing _ rfl
  | signal p c =>
    simp only [step]; split
    · exact nothing _ rfl
    · split
      · rename_i _ h
        exact one _ _ (by rw [(run_keeps _ _ _).2.2.2.2.2.1]) (maySignal_allowed h)
      · exact nothing _ (by rw [(run_keeps _ _ _).2.2.2.2.2.1])
  | message u =>
    simp only [step]; split
    · rename_i h
      simp only [Bool.and_eq_true] at h
      exact one _ _ rfl (mayMessage_allowed h.2)
    · exact nothing _ rfl
  | groupMessage gid us =>
    simp only [step]; split
    · rename_i h
      simp only [Bool.and_eq_true, mayGroupMessage, Bool.or_eq_true, List.any_eq_true, List.contains_iff_mem,
        List.all_eq_true] at h
      refine one _ _ rfl ⟨?_, fun u hu => mayMessage_allowed (h.2.2 u hu)⟩
      rcases h.2.1 with ⟨g, hg, hx⟩ | hx
      · simp only [Bool.not_eq_true', beq_iff_eq] at hx
        exact Or.inl ⟨g, hg, hx⟩
      · exact Or.inr hx
    · exact nothing _ rfl
  | ring u gid =>
    simp only [step]; split
    · rename_i h
      simp only [Bool.and_eq_true, List.contains_iff_mem] at h
      exact one _ _ rfl h.2
    · exact nothing _ rfl
  | callEnded c =>
    apply nothing; simp only [step]; split
    · rfl
    · split
      · split
        · rw [(run_keeps _ _ _).2.2.2.2.2.1, (run_keeps _ _ _).2.2.2.2.2.1, (run_keeps _ _ _).2.2.2.2.2.1]
        · rfl
      · rfl
  | devices c us => apply nothing; simp only [step]; split <;> rfl
  | groupEnded c =>
    simp only [step]; split
    · exact nothing _ rfl
    · split
      · rename_i g hg
        refine one _ (.groupEnded c) ?_ ?_
        · show (run _ _ _).out ++ [Out.groupEnded c] = _
          rw [(run_keeps _ _ _).2.2.2.2.2.1]
        obtain ⟨hm, hc⟩ := findGroup_mem hg
        exact ⟨g, hm, hc⟩
      · exact nothing _ rfl
  | crash => apply nothing; simp only [step]; split <;> (try split) <;> rfl
  | wait =>
    simp only [step]; split
    · refine ⟨(s.groups.filter (·.gen < s.gen)).map (Out.groupEnded ·.client), rfl, ?_⟩
      intro o ho
      simp only [List.mem_map, List.mem_filter] at ho
      obtain ⟨g, ⟨hg, _⟩, rfl⟩ := ho
      exact ⟨g, hg, rfl⟩
    · apply nothing; split <;> (try split) <;> rfl

/-! ## The limit -/

/-- **Fails**: a call message can go to someone neither we nor a group's members are. In a
call-link call the participants are the service's word, and the app has no list of its own. -/
theorem message_from_service :
    let s := run' St.init [.group 9 5 true, .devices 5 [7]]
    Ev.message 7 ∈ [Ev.message 7] ∧ (step s (.message 7)).out = s.out ++ [.message 7] ∧
      s.selfKnown = false ∧ ∀ g ∈ s.groups, g.link = true := by
  decide

end CallBoundary
