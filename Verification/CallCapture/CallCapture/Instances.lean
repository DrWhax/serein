import CallCapture.Props

/-!
# Call instances: an ended call never comes back (T5)

`S.ac` is what only the call code may change: the active call and the instance counter. Every
other function keeps it (frame lemmas below); the call functions are shown to satisfy `Act`:
an instance on screen after them was on screen before (with `live` only going from true to
false), or is a new instance numbered from `instNext`. From that, `LiveInv`: an instance the
ghost record calls ended is not live and was numbered before, in every reachable state; so T5.
-/

namespace CallCapture

variable {s s' : S}

def S.ac (s : S) : Option ACall × Nat := (s.active, s.instNext)

@[simp] theorem ac_mk : S.ac (S.mk a_active a_ringing a_localVideo a_camSends a_gen a_setupTask a_share a_lastTok a_sources a_pc a_running a_again a_caps a_capNext a_streams a_streamNext a_outOff a_ops a_jobs a_ncall a_presenting a_camEnabled a_setupGen a_nativeNext a_setupNext a_camDev a_camNext a_instNext a_genN a_nativeInst a_userVideo a_ended a_capGen0 a_tok0 a_out) =
    (a_active, a_instNext) := rfl

@[simp] theorem ac_fold {t : S} : ((t.active, t.instNext) : Option ACall × Nat) = t.ac := rfl

-- ## Functions outside the call code keep `ac`

@[simp] theorem ac_emit : (emit x s).ac = s.ac := rfl
@[simp] theorem ac_spawn : (spawn l s).ac = s.ac := rfl
@[simp] theorem ac_enqueue : (enqueue m s).ac = s.ac := rfl
@[simp] theorem ac_addOp : (addOp o s).ac = s.ac := rfl
@[simp] theorem ac_dropOp : (dropOp o s).ac = s.ac := rfl
@[simp] theorem ac_setCap : (setCap i c s).ac = s.ac := rfl
@[simp] theorem ac_setStream : (setStream j v s).ac = s.ac := rfl
@[simp] theorem ac_devStop : (devStop s).ac = s.ac := rfl
@[simp] theorem ac_capBegin : (capBegin i s).ac = s.ac := rfl
@[simp] theorem ac_clearShare : (clearShare s).ac = s.ac := by simp only [clearShare]; split <;> rfl

set_option hygiene false in
/-- `ac` through a function whose branches are structure updates and callees with `ac` lemmas. -/
macro "ac_by " f:ident : tactic =>
  `(tactic| (simp only [$f:ident]; (repeat' split) <;> (try simp_all) <;> (try (simp only [S.ac, Prod.mk.injEq] at *; simp_all))))

@[simp] theorem ac_markHungUp : (markHungUp c s).ac = s.ac := by ac_by markHungUp
@[simp] theorem ac_svcHangup : (svcHangup e s).ac = s.ac := by ac_by svcHangup
@[simp] theorem ac_svcEndCall : (svcEndCall c k s).ac = s.ac := by ac_by svcEndCall
@[simp] theorem ac_svcAccept : (svcAccept c v k s).ac = s.ac := by ac_by svcAccept
@[simp] theorem ac_svcDecline : (svcDecline c k s).ac = s.ac := by ac_by svcDecline
@[simp] theorem ac_svcSetVideo : (svcSetVideo c on s).ac = s.ac := by ac_by svcSetVideo
@[simp] theorem ac_svcSetPresenting : (svcSetPresenting c p s).ac = s.ac := by ac_by svcSetPresenting
@[simp] theorem ac_recR1 : (recR1 s).1.ac = s.ac := by ac_by recR1

@[simp] theorem ac_recEnd : (recEnd s).ac = s.ac := by
  simp only [recEnd]
  (repeat' split) <;> rename_i heq <;>
    first
    | (have h1 := @ac_recR1 { s with again := false }; rw [heq] at h1; simp_all)
    | simp_all

@[simp] theorem ac_recPass : (recPass s).ac = s.ac := by
  simp only [recPass]
  (repeat' split) <;> rename_i heq <;>
    first
    | (have h1 := @ac_recR1 { s with again := false }; rw [heq] at h1; simp_all)
    | simp_all

@[simp] theorem ac_updateCamera : (updateCamera s).ac = s.ac := by ac_by updateCamera
@[simp] theorem ac_camAccessEnv : (camAccessEnv g s).ac = s.ac := by ac_by camAccessEnv
@[simp] theorem ac_camStartEnv : (camStartEnv ok s).ac = s.ac := by ac_by camStartEnv
@[simp] theorem ac_camStopEnv : (camStopEnv s).ac = s.ac := by ac_by camStopEnv
@[simp] theorem ac_camAccessDone : (camAccessDone g s).ac = s.ac := by ac_by camAccessDone
@[simp] theorem ac_camStartDone : (camStartDone ok s).ac = s.ac := by ac_by camStartDone
@[simp] theorem ac_recResume : (recResume s).ac = s.ac := by ac_by recResume
@[simp] theorem ac_camFrameEnv : (camFrameEnv k s).ac = s.ac := by ac_by camFrameEnv
@[simp] theorem ac_camFrame : (camFrame k s).ac = s.ac := by ac_by camFrame
@[simp] theorem ac_setCameraSending : (setCameraSending b s).ac = s.ac := by ac_by setCameraSending
@[simp] theorem ac_stopStream : (stopStream j s).ac = s.ac := by ac_by stopStream
@[simp] theorem ac_capTeardown : (capTeardown i s).1.ac = s.ac := by ac_by capTeardown

@[simp] theorem ac_capStop : (capStop i s).ac = s.ac := by
  simp only [capStop]
  have h := ac_capTeardown (i := i) (s := capBegin i s)
  split <;> rename_i heq <;> rw [heq] at h <;> simp_all

@[simp] theorem ac_capStartAfterTeardown : (capStartAfterTeardown i cg pt s).ac = s.ac := by ac_by capStartAfterTeardown

@[simp] theorem ac_capStart : (capStart i pt s).ac = s.ac := by
  simp only [capStart]
  have h := ac_capTeardown (i := i) (s := capBegin i s)
  split <;> rename_i heq <;> rw [heq] at h <;> simp_all

@[simp] theorem ac_stopPresenting : (stopPresenting c s).ac = s.ac := by ac_by stopPresenting
@[simp] theorem ac_toggleShare : (toggleShare s).ac = s.ac := by ac_by toggleShare
@[simp] theorem ac_sourcesLeaf : (sourcesLeaf i t g c s).ac = s.ac := by ac_by sourcesLeaf
@[simp] theorem ac_srcEnv : (srcEnv i ok s).ac = s.ac := by ac_by srcEnv
@[simp] theorem ac_srcDone : (srcDone i t g c ok s).ac = s.ac := by ac_by srcDone
@[simp] theorem ac_pickSource : (pickSource s).ac = s.ac := by ac_by pickSource
@[simp] theorem ac_presentLeaf : (presentLeaf i pt s).ac = s.ac := by ac_by presentLeaf
@[simp] theorem ac_scStartEnv : (scStartEnv j ok s).ac = s.ac := by ac_by scStartEnv
@[simp] theorem ac_installDone : (installDone i cg j pt ok s).ac = s.ac := by ac_by installDone
@[simp] theorem ac_scStopEnv : (scStopEnv j ok s).ac = s.ac := by ac_by scStopEnv
@[simp] theorem ac_scFrameEnv : (scFrameEnv j s).ac = s.ac := by ac_by scFrameEnv
@[simp] theorem ac_scFrame : (scFrame i t s).ac = s.ac := by ac_by scFrame
@[simp] theorem ac_scStoppedEnv : (scStoppedEnv j s).ac = s.ac := by ac_by scStoppedEnv
@[simp] theorem ac_scStopped : (scStopped t s).ac = s.ac := by ac_by scStopped
@[simp] theorem ac_releaseCallMedia : (releaseCallMedia c s).ac = s.ac := by ac_by releaseCallMedia
@[simp] theorem ac_endStrayCall : (endStrayCall c k s).ac = s.ac := by ac_by endStrayCall
@[simp] theorem ac_startCall : (startCall s).ac = s.ac := by ac_by startCall
@[simp] theorem ac_setupEnv : (setupEnv q ok s).ac = s.ac := by ac_by setupEnv
@[simp] theorem ac_declineCall : (declineCall c s).ac = s.ac := by ac_by declineCall
@[simp] theorem ac_setVideo : (setVideo on s).ac = s.ac := by ac_by setVideo
@[simp] theorem ac_nIncoming : (nIncoming c v s).ac = s.ac := by ac_by nIncoming
@[simp] theorem ac_nState : (nState st s).ac = s.ac := by ac_by nState
@[simp] theorem ac_nEnd : (nEnd r s).ac = s.ac := by ac_by nEnd
@[simp] theorem ac_nRejected : (nRejected c s).ac = s.ac := by ac_by nRejected

-- ## What the call code may do to instances

/-- From `s` to `s'`, every instance on screen was on screen before (and is live only if it was
live), or is new: numbered from `s.instNext` on, below `s'.instNext`. -/
def Act (s s' : S) : Prop :=
  s.instNext ≤ s'.instNext ∧
  ∀ b', s'.active = some b' →
    (∃ b, s.active = some b ∧ b.inst = b'.inst ∧ (b'.live = true → b.live = true)) ∨
    (s.instNext ≤ b'.inst ∧ b'.inst < s'.instNext)

theorem Act.refl : Act s s := ⟨Nat.le_refl _, fun b h => Or.inl ⟨b, h, rfl, id⟩⟩

theorem Act.trans {s1 s2 s3 : S} (h1 : Act s1 s2) (h2 : Act s2 s3) : Act s1 s3 := by
  refine ⟨Nat.le_trans h1.1 h2.1, fun b3 hb3 => ?_⟩
  rcases h2.2 b3 hb3 with ⟨b2, hb2, hi2, hl2⟩ | ⟨hlo, hhi⟩
  · rcases h1.2 b2 hb2 with ⟨b1, hb1, hi1, hl1⟩ | ⟨hlo, hhi⟩
    · exact Or.inl ⟨b1, hb1, hi1.trans hi2, fun h => hl1 (hl2 h)⟩
    · exact Or.inr ⟨by omega, by have := h2.1; omega⟩
  · exact Or.inr ⟨by have := h1.1; omega, hhi⟩

theorem Act.of_ac (h : s'.ac = s.ac) : Act s s' := by
  simp only [S.ac, Prod.mk.injEq] at h
  obtain ⟨h1, h2⟩ := h
  refine ⟨by omega, fun b hb => Or.inl ⟨b, by rw [← h1]; exact hb, rfl, id⟩⟩

/-- Clearing the active call. -/
theorem Act.clear : Act s { s with active := none } := ⟨Nat.le_refl _, fun b h => by cases h⟩

/-- A new instance numbered `instNext`. -/
theorem Act.fresh {a : ACall} (ha : a.inst = s.instNext) (f : S → S) (hf : ∀ t, (f t).ac = t.ac) :
    Act s (f { s with active := some a, instNext := s.instNext + 1 }) := by
  have := hf { s with active := some a, instNext := s.instNext + 1 }
  simp only [S.ac, Prod.mk.injEq] at this
  obtain ⟨h1, h2⟩ := this
  refine ⟨by rw [h2]; omega, fun b hb => Or.inr ?_⟩
  rw [h1] at hb; cases hb
  rw [h2]; omega

theorem act_endCallUI : Act s (endCallUI s) := by
  simp only [endCallUI]
  exact Act.clear.trans (Act.of_ac ac_releaseCallMedia)

theorem act_hangUp : Act s (hangUp s) := by
  simp only [hangUp]
  exact (Act.of_ac ac_svcHangup).trans act_endCallUI

theorem act_openLobby : Act s (openLobby c v s) := by
  simp only [openLobby]
  split
  · exact Act.refl
  · -- the new lobby is instance `instNext`
    have h := Act.fresh (s := s) (a := ⟨c, .lobby, none, true, s.instNext, false, none⟩) rfl
      (fun t => updateCamera { t with camSends := false, localVideo := v, userVideo := v }) (fun t => by simp)
    exact h

/-- A new instance numbered `instNext` is the active call. -/
theorem Act.of_new {a : ACall} (h : s'.ac = (some a, s.instNext + 1)) (ha : a.inst = s.instNext) : Act s s' := by
  simp only [S.ac, Prod.mk.injEq] at h
  obtain ⟨h1, h2⟩ := h
  refine ⟨by rw [h2]; omega, fun b hb => Or.inr ?_⟩
  rw [h1] at hb; cases hb
  rw [h2, ha]; omega

/-- The active call stays the same instance, live only if it was. -/
theorem Act.keep (ha : s.active = some a) (hb : b.inst = a.inst) (hl : b.live = true → a.live = true) :
    Act s { s with active := some b } :=
  ⟨Nat.le_refl _, fun b' hb' => by
    simp only [Option.some.injEq] at hb'; subst hb'
    exact Or.inl ⟨a, ha, hb.symm, hl⟩⟩

theorem act_acceptCall : Act s (acceptCall c v s) := by
  simp only [acceptCall]
  have h0 : Act s (if s.active.isSome = true then endCallUI s else s) := by
    split
    · exact act_endCallUI
    · exact Act.refl
  generalize (if s.active.isSome = true then endCallUI s else s) = s0 at h0 ⊢
  refine h0.trans (Act.of_new (a := ⟨c, .inCall, some .accepted, true, s0.instNext, true,
      match s.ringing with | some (c', n) => if (c' == c) = true then some n else none | none => none⟩) ?_ rfl)
  simp only [ac_updateCamera, ac_svcAccept]
  split <;> rfl

theorem act_handleEv : Act s (handleEv o e s) := by
  cases e with
  | outgoing c v n setup =>
    simp only [handleEv]
    split
    · rename_i a ha
      split
      · rename_i hc
        simp only [Bool.and_eq_true] at hc
        have hk := Act.keep (s := s) (b := { conv := c, stage := .inCall, direct := some .prering, live := true, inst := a.inst,
                                              authorized := a.authorized || ownedBy o a.inst s, callId := some n })
          ha rfl (fun _ => hc.1.1.2)
        split
        · exact hk.trans (Act.of_ac ac_svcSetVideo)
        · exact hk
      · exact Act.of_ac ac_endStrayCall
    · exact Act.of_ac ac_endStrayCall
  | incoming c v n =>
    simp only [handleEv]; split
    · exact Act.of_ac rfl
    · exact Act.refl
  | state c st n =>
    simp only [handleEv]
    split
    · rename_i a ha
      split
      · exact Act.keep ha rfl id
      · split
        · exact Act.of_ac ac_endStrayCall
        · exact Act.refl
    · split
      · exact Act.of_ac ac_endStrayCall
      · exact Act.refl
  | ended c r n =>
    simp only [handleEv]
    have h0 : Act s (if (s.ringing.map (·.2) == some n) = true then { s with ringing := none } else s) := by
      split
      · exact Act.of_ac rfl
      · exact Act.refl
    generalize (if (s.ringing.map (·.2) == some n) = true then { s with ringing := none } else s) = s1 at h0 ⊢
    split
    · rename_i a ha
      split
      · split
        · -- the ended screen stays: the same instance, no longer live
          have hk : Act s1 { s1 with active := some { a with live := false } } := Act.keep ha rfl (by intro h; exact absurd h (by simp))
          exact h0.trans (hk.trans (Act.of_ac ac_releaseCallMedia))
        · exact h0.trans act_endCallUI
      · exact h0
    · exact h0

theorem act_setupDone : Act s (setupDone g c r p s) := by
  simp only [setupDone]
  split
  · exact Act.of_ac (by (repeat' split) <;> simp_all)
  · by_cases hg : (s.gen == g) = true
    · simp only [hg, ite_true]
      split
      · exact act_endCallUI.trans (Act.of_ac rfl)
      · exact act_endCallUI
    · simp only [hg, Bool.false_eq_true, ite_false]
      exact Act.refl

theorem act_setupLeaf : Act s (setupLeaf g c v n x s) := by
  simp only [setupLeaf]; split
  · exact Act.refl
  · split
    · exact Act.trans (s2 := emit (.svcStart c v) { s with setupNext := s.setupNext + 1 }) (Act.of_ac rfl) act_setupDone
    · exact Act.of_ac rfl

theorem act_runMsg : Act s (runMsg m s) := by
  simp only [runMsg]; split
  · exact act_handleEv
  · exact Act.of_ac ac_setCameraSending

theorem act_handle : Act s (handle e s) := by
  cases e
  case openLobby => exact act_openLobby
  case accept => exact act_acceptCall
  case hangUp => exact act_hangUp
  case closeCall => exact act_endCallUI
  case run => exact Act.refl
  case cancelPick => exact Act.of_ac (by simp [handle])
  all_goals exact Act.of_ac (by simp [handle])

theorem act_runJob : Act s (runJob l s) := by
  cases l
  case setupRet => exact act_setupDone
  case setupStart => exact act_setupLeaf
  case msg => exact act_runMsg
  case stopRet => exact Act.refl
  all_goals exact Act.of_ac (by simp [runJob])

theorem act_stepCore : Act s (stepCore s e) := by
  cases e
  case run k =>
    simp only [stepCore]
    split
    · exact Act.trans (s2 := { s with out := [], jobs := s.jobs.eraseIdx k }) (Act.of_ac rfl) act_runJob
    · exact Act.of_ac rfl
  all_goals (simp only [stepCore]; exact Act.trans (s2 := { s with out := [] }) (Act.of_ac rfl) act_handle)

-- ## Every reachable state

/-- The active instance was numbered before; an ended instance is not live and was numbered before. -/
structure LiveInv (s : S) : Prop where
  activeLt : ∀ b, s.active = some b → b.inst < s.instNext
  ended : ∀ a, s.ended a = true → instLive s a = false ∧ a < s.instNext

theorem instLive_of (h : instLive s a = true) : ∃ b, s.active = some b ∧ b.inst = a ∧ b.live = true := by
  simp only [instLive] at h
  split at h
  · rename_i b hb; simp only [Bool.and_eq_true, beq_iff_eq] at h; exact ⟨b, hb, h.1, h.2⟩
  · cases h

/-- Not live before, numbered before: not live after any step. -/
theorem not_live (hact : Act s s') (hn : instLive s a = false) (hlt : a < s.instNext) : instLive s' a = false := by
  cases h : instLive s' a with
  | false => rfl
  | true =>
    obtain ⟨b', hb', hi', hl'⟩ := instLive_of h
    rcases hact.2 b' hb' with ⟨b, hb, hi, hl⟩ | ⟨hlo, _⟩
    · have : instLive s a = true := by simp [instLive, hb, hi, hi', hl hl']
      rw [hn] at this; cases this
    · omega

theorem LiveInv.init (cfg : Cfg) : LiveInv (S.init cfg) :=
  ⟨fun b h => by simp [S.init] at h, fun a h => by simp [S.init] at h⟩

theorem instLive_noteEnded : instLive (noteEnded s s') a = instLive s' a := rfl

theorem LiveInv.step (hi : LiveInv s) : LiveInv (CallCapture.step s e) := by
  have hact : Act s (stepCore s e) := act_stepCore
  refine ⟨fun b hb => ?_, fun a ha => ?_⟩
  · have hb' : (stepCore s e).active = some b := hb
    show b.inst < (stepCore s e).instNext
    rcases hact.2 b hb' with ⟨b0, hb0, hi0, _⟩ | ⟨_, hhi⟩
    · have := hi.activeLt b0 hb0; have := hact.1; omega
    · exact hhi
  · simp only [CallCapture.step, noteEnded, Bool.or_eq_true, Bool.and_eq_true, Bool.not_eq_eq_eq_not, Bool.not_true] at ha
    show instLive (stepCore s e) a = false ∧ a < (stepCore s e).instNext
    rcases ha with ha | ⟨hl, hn⟩
    · obtain ⟨hn, hlt⟩ := hi.ended a ha
      exact ⟨not_live hact hn hlt, by have := hact.1; omega⟩
    · obtain ⟨b, hb, hbi, _⟩ := instLive_of hl
      have := hi.activeLt b hb
      exact ⟨hn, by have := hact.1; omega⟩

theorem LiveInv.reach (h : Reach s) : LiveInv s := by
  induction h with
  | init cfg => exact LiveInv.init cfg
  | step e _ ih => exact ih.step

/-- An instance that has ended is never live again, in any reachable state. -/
theorem ended_not_live (h : Reach s) (ha : s.ended a = true) : instLive s a = false :=
  ((LiveInv.reach h).ended a ha).1

/-- **T5**: a call instance that has ended is never live and accepted afterwards. A new start is
a new instance; whether that one was authorized is `acceptAuthorized`
(`Counterexamples.acceptAuthorized_staleAccepted`). -/
theorem t5_holds (hr : Reach s) (e : Ev) : t5 s e (step s e) = true := by
  have hi := LiveInv.reach hr
  simp only [t5]
  split
  · rename_i b hb
    cases hend : s.ended b.inst with
    | false => rfl
    | true =>
      obtain ⟨hn, hlt⟩ := hi.ended b.inst hend
      have hnl := not_live (act_stepCore (e := e)) hn hlt
      have hb' : (stepCore s e).active = some b := hb
      simp only [Bool.true_and, Bool.not_eq_eq_eq_not, Bool.not_true]
      simp only [acceptedLive, CallCapture.step, noteEnded, hb', beq_self_eq_true, Bool.true_and]
      have : instLive (stepCore s e) b.inst = b.live := by simp [instLive, hb']
      rw [hnl] at this
      simp [← this]
  · rfl

end CallCapture
