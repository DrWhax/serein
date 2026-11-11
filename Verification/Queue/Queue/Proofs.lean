import Queue.Model
import Queue.Props

/-! # Proofs: the invariant, shutdown's postcondition, and termination of a drain -/

namespace Queue

variable {s : S}

structure Inv (s : S) : Prop where
  draining : s.draining = s.stopWaiters.length + s.returns.length
  waitersLoop : s.stopWaiters ≠ [] → s.loop ≠ none
  returnNoLoop : s.returns ≠ [] → s.loop = none
  drainingStopped : s.draining ≠ 0 → s.wantsRunning = false
  drainingCancelled : s.draining ≠ 0 → s.loop ≠ none → s.cancelled = true
  waitingWoken : s.loop = some .waiting → s.cancelled = true → s.wakes ≠ 0

theorem Inv.init (db : List Nat) : Inv (S.init db) :=
  ⟨rfl, fun h => absurd rfl h, fun h => absurd rfl h, fun h => absurd rfl h, fun h => absurd rfl h, fun h => by cases h⟩

theorem Inv.start (h : Inv s) : Inv (Queue.start s) := by
  unfold Queue.start
  split
  · exact h
  · rename_i hd
    have hd0 : s.draining = 0 := by simpa using hd
    split
    · exact ⟨h.draining, h.waitersLoop, h.returnNoLoop, fun h' => absurd hd0 h', fun h' => absurd hd0 h', h.waitingWoken⟩
    · have hr : s.returns = [] := by have := h.draining; exact List.eq_nil_of_length_eq_zero (by omega)
      exact ⟨h.draining, fun _ => by simp, fun h' => absurd hr h', fun h' => absurd hd0 h', fun h' => absurd hd0 h', fun h' => by cases h'⟩

theorem Inv.stop (h : Inv s) : Inv (Queue.stop s) :=
  ⟨h.draining, h.waitersLoop, h.returnNoLoop, fun _ => rfl,
   fun _ hl => by simp only [Queue.stop] at hl ⊢; cases hh : s.loop <;> simp_all,
   fun _ _ => by simp [Queue.stop]⟩

theorem Inv.stopAndWait (h : Inv s) : Inv (Queue.stopAndWait s) := by
  unfold Queue.stopAndWait
  simp only [Queue.stop]
  by_cases hl : s.loop.isSome = true
  · simp only [hl, ite_true]
    have hl' : s.loop ≠ none := by cases hh : s.loop <;> simp_all
    have hr : s.returns = [] := by
      cases hh : s.returns
      · rfl
      · exact absurd (h.returnNoLoop (by simp [hh])) hl'
    refine ⟨?_, fun _ => hl', fun h' => absurd hr h', fun _ => rfl, fun _ _ => by simp [hl'], fun _ _ => by simp⟩
    have := h.draining; simp only [List.length_append, List.length_singleton]; omega
  · have hl2 : s.loop.isSome = false := by simpa using hl
    simp only [hl2, Bool.false_eq_true, ite_false]
    have hnone : s.loop = none := by cases hh : s.loop <;> simp_all
    have hw : s.stopWaiters = [] := by
      cases hh : s.stopWaiters
      · rfl
      · exact absurd hnone (h.waitersLoop (by simp [hh]))
    refine ⟨?_, fun h' => by simp [hw] at h', fun _ => hnone, fun _ => rfl, fun _ h' => absurd hnone h', fun h' => by rw [hnone] at h'; cases h'⟩
    have := h.draining; simp only [List.length_append, List.length_singleton]; omega

/-- The loop ends: its waiters become pending returns; it restarts only if nothing drains. -/
theorem Inv.loopEnds (h : Inv s) : Inv (loopEnds s) := by
  unfold Queue.loopEnds
  have ht : Inv { s with loop := none, cancelled := false, returns := s.returns ++ s.stopWaiters, stopWaiters := [] } := by
    refine ⟨?_, fun h' => absurd rfl h', fun _ => rfl, h.drainingStopped, fun _ h' => absurd rfl h', fun h' => by cases h'⟩
    have := h.draining; simp only [List.length_append, List.length_nil]; omega
  split
  · exact ht.start
  · exact ht

theorem Inv.step (h : Inv s) (e : Ev) : Inv (step s e) := by
  cases e with
  | runLoop =>
    simp only [Queue.step]
    split
    · -- select
      rename_i hl
      simp only [loopStep, hl]
      split
      · exact h.loopEnds
      · rename_i hc
        have hc' : s.cancelled = false := by simpa using hc
        have hd : s.draining = 0 := by
          cases hdd : s.draining with
          | zero => rfl
          | succ n => have := h.drainingCancelled (by omega) (by simp [hl]); simp [hc'] at this
        split
        · exact ⟨h.draining, fun _ => by simp, fun h' => absurd (h.returnNoLoop h') (by simp [hl]),
            h.drainingStopped, fun h' => absurd hd h', fun h' => by cases h'⟩
        · exact ⟨h.draining, fun _ => by simp, fun h' => absurd (h.returnNoLoop h') (by simp [hl]),
            h.drainingStopped, fun h' => absurd hd h', fun _ h' => by simp [hc'] at h'⟩
    · -- after
      rename_i j o hl
      simp only [loopStep, hl]
      exact ⟨h.draining, fun _ => by simp, fun h' => absurd (h.returnNoLoop h') (by simp [hl]),
        h.drainingStopped, fun hd _ => h.drainingCancelled hd (by simp [hl]), fun h' => by cases h'⟩
    · exact h
  | runWake =>
    simp only [Queue.step]
    split
    · exact h
    · rename_i hw
      split
      · rename_i hl
        exact ⟨h.draining, fun _ => by simp, fun h' => absurd (h.returnNoLoop h') (by simp [hl]),
          h.drainingStopped, fun hd _ => h.drainingCancelled hd (by simp [hl]), fun h' => by cases h'⟩
      · rename_i hl
        refine ⟨h.draining, h.waitersLoop, h.returnNoLoop, h.drainingStopped, h.drainingCancelled, fun h1 h2 => ?_⟩
        exact absurd h1 (hl)
  | runReturn k =>
    simp only [Queue.step]
    split
    · rename_i n hk
      have hne : s.returns ≠ [] := by intro h'; simp [h'] at hk
      have hlt := (List.getElem?_eq_some_iff.mp hk).1
      have hlen : (s.returns.eraseIdx k).length + 1 = s.returns.length := by simp [List.length_eraseIdx, hlt]; omega
      have hnone := h.returnNoLoop hne
      have hd0 := h.draining
      refine ⟨?_, h.waitersLoop, fun _ => hnone, fun hd => h.drainingStopped (by simp only at hd; omega), fun _ h' => absurd hnone h',
        fun h' => by rw [hnone] at h'; cases h'⟩
      show s.draining - 1 = s.stopWaiters.length + (s.returns.eraseIdx k).length
      omega
    · exact h
  | start => exact h.start
  | stop => exact h.stop
  | stopAndWait => exact h.stopAndWait
  | enqueue j => exact ⟨h.draining, h.waitersLoop, h.returnNoLoop, h.drainingStopped, h.drainingCancelled, fun _ _ => by simp [Queue.step]⟩
  | handlerReturns o =>
    simp only [Queue.step]
    split
    · rename_i j hl
      exact ⟨h.draining, fun _ => by simp, fun h' => absurd (h.returnNoLoop h') (by simp [hl]),
        h.drainingStopped, fun hd _ => h.drainingCancelled hd (by simp [hl]), fun h' => by cases h'⟩
    · exact h

theorem Inv.reach (h : Reach s) : Inv s := by
  induction h with
  | init db => exact Inv.init db
  | step e _ ih => exact ih.step e

-- ## Frame lemmas

@[simp] theorem returned_start : (Queue.start s).returned = s.returned := by
  unfold Queue.start; split <;> (try split) <;> rfl
@[simp] theorem done_start : (Queue.start s).done = s.done := by
  unfold Queue.start; split <;> (try split) <;> rfl
@[simp] theorem returned_stopAndWait : (Queue.stopAndWait s).returned = s.returned := by
  unfold Queue.stopAndWait; simp only [Queue.stop]; by_cases hl : s.loop.isSome = true <;> simp [hl]
@[simp] theorem done_stopAndWait : (Queue.stopAndWait s).done = s.done := by
  unfold Queue.stopAndWait; simp only [Queue.stop]; by_cases hl : s.loop.isSome = true <;> simp [hl]
@[simp] theorem returned_loopEnds : (Queue.loopEnds s).returned = s.returned := by
  unfold Queue.loopEnds; split <;> simp
@[simp] theorem done_loopEnds : (Queue.loopEnds s).done = s.done := by
  unfold Queue.loopEnds; split <;> simp
@[simp] theorem returned_loopStep : (loopStep s).returned = s.returned := by
  unfold loopStep; split
  · split
    · simp
    · split <;> rfl
  · rfl
  · rfl

theorem done_loopStep (s : S) :
    (loopStep s).done = s.done ∨ ∃ j o, s.loop = some (.after j o) ∧ (loopStep s).done = s.done ++ [j] := by
  unfold loopStep
  split
  · split
    · left; simp
    · split <;> exact Or.inl rfl
  · rename_i j o hl
    simp only
    split <;> rename_i o' ho <;> (try exact Or.inr ⟨j, o, hl, rfl⟩) <;> exact Or.inl rfl
  · exact Or.inl rfl

theorem returned_step (h : ∀ k, e ≠ .runReturn k) : (step s e).returned = s.returned := by
  cases e with
  | runReturn k => exact absurd rfl (h k)
  | runLoop => simp only [Queue.step]; split <;> simp
  | runWake => simp only [Queue.step]; split <;> (try split) <;> rfl
  | handlerReturns o => simp only [Queue.step]; split <;> rfl
  | start => simp [Queue.step]
  | stopAndWait => simp [Queue.step]
  | stop => rfl
  | enqueue j => rfl

theorem done_step (s : S) (e : Ev) :
    (step s e).done = s.done ∨ ∃ j o, e = .runLoop ∧ s.loop = some (.after j o) ∧ (step s e).done = s.done ++ [j] := by
  cases e with
  | runLoop =>
    simp only [Queue.step]
    split
    · exact (done_loopStep s).imp id fun ⟨j, o, hl, hd⟩ => ⟨j, o, by simp, hl, hd⟩
    · exact (done_loopStep s).imp id fun ⟨j, o, hl, hd⟩ => ⟨j, o, by simp, hl, hd⟩
    · exact Or.inl rfl
  | runWake => left; simp only [Queue.step]; split <;> (try split) <;> rfl
  | runReturn k => left; simp only [Queue.step]; split <;> rfl
  | handlerReturns o => left; simp only [Queue.step]; split <;> rfl
  | start => left; simp [Queue.step]
  | stopAndWait => left; simp [Queue.step]
  | stop => left; rfl
  | enqueue j => left; rfl

-- ## The properties

theorem shutdownClean_holds (hr : Reach s) (e : Ev) : shutdownClean s e (step s e) = true := by
  have h := Inv.reach hr
  simp only [shutdownClean, Bool.or_eq_true, beq_iff_eq]
  by_cases he : ∃ k, e = .runReturn k
  · obtain ⟨k, rfl⟩ := he
    simp only [Queue.step]
    split
    · rename_i n hk
      right
      exact h.returnNoLoop (by intro h'; simp [h'] at hk)
    · left; rfl
  · left
    rw [returned_step (fun k hk => he ⟨k, hk⟩)]

theorem noRestartWhileDraining_holds (s : S) (e : Ev) : noRestartWhileDraining s e (step s e) = true := by
  cases e <;> simp only [noRestartWhileDraining]
  case start =>
    cases hd : s.draining with
    | zero => rfl
    | succ n => simp [Queue.step, Queue.start, hd]

theorem oneAtATime_holds (s : S) (e : Ev) : oneAtATime s e (step s e) = true := by
  rcases done_step s e with h | ⟨j, o, rfl, hl, h⟩
  · simp [oneAtATime, h]
  · simp [oneAtATime, h, hl]

-- ## Termination of a drain, if the workers finish

def weight : Option Phase → Nat
  | none => 0
  | some .select => 1
  | some .waiting => 2
  | some (.after _ _) => 2
  | some (.executing _) => 3

def measure (s : S) : Nat := 4 * weight s.loop + s.wakes + s.returns.length + s.stopWaiters.length

/-- Events the environment and the scheduler produce on their own: running pending actor work,
and a handler returning. No user action, no new job. -/
def Ev.isDrain : Ev → Bool
  | .runLoop | .runWake | .runReturn _ | .handlerReturns _ => true
  | _ => false

theorem drain_step (h : Inv s) (hp : ¬(s.stopWaiters = [] ∧ s.returns = [])) :
    ∃ e, e.isDrain = true ∧ measure (step s e) < measure s := by
  have hdr : s.draining ≠ 0 := by
    have := h.draining
    intro h0
    apply hp
    exact ⟨List.eq_nil_of_length_eq_zero (by omega), List.eq_nil_of_length_eq_zero (by omega)⟩
  have hws := h.drainingStopped hdr
  cases hl : s.loop with
  | none =>
    have hw : s.stopWaiters = [] := by
      cases hh : s.stopWaiters
      · rfl
      · exact absurd hl (h.waitersLoop (by simp [hh]))
    have hr : s.returns ≠ [] := fun hr => hp ⟨hw, hr⟩
    obtain ⟨n, rest, hnr⟩ : ∃ n rest, s.returns = n :: rest := by
      cases hh : s.returns
      · exact absurd hh hr
      · exact ⟨_, _, rfl⟩
    refine ⟨.runReturn 0, rfl, ?_⟩
    simp [Queue.step, hnr, measure, hl]
  | some ph =>
    have hc := h.drainingCancelled hdr (by simp [hl])
    cases ph with
    | select =>
      refine ⟨.runLoop, rfl, ?_⟩
      simp [Queue.step, loopStep, hl, hc, Queue.loopEnds, hws, measure, weight]
      omega
    | waiting =>
      have hwk := h.waitingWoken hl hc
      refine ⟨.runWake, rfl, ?_⟩
      simp [Queue.step, hwk, hl, measure, weight]
      omega
    | after j o =>
      refine ⟨.runLoop, rfl, ?_⟩
      simp [Queue.step, loopStep, hl, measure, weight]
    | executing j =>
      refine ⟨.handlerReturns .cancelled, rfl, ?_⟩
      simp [Queue.step, hl, measure, weight]

/-- **Termination, if the workers finish**: from any reachable state, there is a run of the
scheduler and of handlers returning — no user action, no new job — after which every pending
`stopAndWait` has returned. -/
theorem drain_terminates (hr : Reach s) :
    ∃ es : List Ev, es.all Ev.isDrain = true ∧ (run s es).stopWaiters = [] ∧ (run s es).returns = [] := by
  have h := Inv.reach hr
  suffices ∀ n (s : S), measure s = n → Inv s →
      ∃ es : List Ev, es.all Ev.isDrain = true ∧ (run s es).stopWaiters = [] ∧ (run s es).returns = [] from this _ s rfl h
  intro n
  induction n using Nat.strongRecOn with
  | _ n ih =>
    intro s hm h
    by_cases hd : s.stopWaiters = [] ∧ s.returns = []
    · exact ⟨[], rfl, hd.1, hd.2⟩
    · obtain ⟨e, he, hlt⟩ := drain_step h hd
      obtain ⟨es, h1, h2, h3⟩ := ih _ (hm ▸ hlt) (step s e) rfl (h.step e)
      exact ⟨e :: es, by simp [he, h1], h2, h3⟩

end Queue
