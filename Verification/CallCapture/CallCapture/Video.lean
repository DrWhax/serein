import CallCapture.Instances
import CallCapture.Proofs

/-!
# The camera follows the user's choice (T3 for the camera)

`callLocalVideo` (`localVideo`) changes only with the user's own choice (`userVideo`): opening a
lobby, accepting a call, or the video button. Every other function keeps both (frame lemmas
below), so the two are equal in every reachable state; the camera, which the app starts and
feeds only while `localVideo` is on (`camStartWanted_holds`, `cameraFrames_gated`), therefore
runs only while the user has video on.
-/

namespace CallCapture

variable {s s' : S}

def S.vid (s : S) : Bool × Bool := (s.localVideo, s.userVideo)

@[simp] theorem vid_mk : S.vid (S.mk a_active a_ringing a_localVideo a_camSends a_gen a_setupTask a_share a_lastTok a_sources a_pc a_running a_again a_caps a_capNext a_streams a_streamNext a_outOff a_ops a_jobs a_ncall a_presenting a_camEnabled a_setupGen a_nativeNext a_setupNext a_camDev a_camNext a_instNext a_genN a_nativeInst a_userVideo a_ended a_capGen0 a_tok0 a_out) =
    (a_localVideo, a_userVideo) := rfl

@[simp] theorem vid_fold {t : S} : ((t.localVideo, t.userVideo) : Bool × Bool) = t.vid := rfl

-- ## Functions that keep the video choice

@[simp] theorem vid_emit : (emit x s).vid = s.vid := rfl
@[simp] theorem vid_spawn : (spawn l s).vid = s.vid := rfl
@[simp] theorem vid_enqueue : (enqueue m s).vid = s.vid := rfl
@[simp] theorem vid_addOp : (addOp o s).vid = s.vid := rfl
@[simp] theorem vid_dropOp : (dropOp o s).vid = s.vid := rfl
@[simp] theorem vid_setCap : (setCap i c s).vid = s.vid := rfl
@[simp] theorem vid_setStream : (setStream j v s).vid = s.vid := rfl
@[simp] theorem vid_devStop : (devStop s).vid = s.vid := rfl
@[simp] theorem vid_capBegin : (capBegin i s).vid = s.vid := rfl
@[simp] theorem vid_clearShare : (clearShare s).vid = s.vid := by simp only [clearShare]; split <;> rfl

set_option hygiene false in
/-- `vid` through a function whose branches are structure updates and callees with `vid` lemmas. -/
macro "vid_by " f:ident : tactic =>
  `(tactic| (simp only [$f:ident]; (repeat' split) <;> (try simp_all) <;> (try (simp only [S.vid, Prod.mk.injEq] at *; simp_all))))

@[simp] theorem vid_markHungUp : (markHungUp c s).vid = s.vid := by vid_by markHungUp
@[simp] theorem vid_svcHangup : (svcHangup e s).vid = s.vid := by vid_by svcHangup
@[simp] theorem vid_svcEndCall : (svcEndCall c k s).vid = s.vid := by vid_by svcEndCall
@[simp] theorem vid_svcAccept : (svcAccept c v k s).vid = s.vid := by vid_by svcAccept
@[simp] theorem vid_svcDecline : (svcDecline c k s).vid = s.vid := by vid_by svcDecline
@[simp] theorem vid_svcSetVideo : (svcSetVideo c on s).vid = s.vid := by vid_by svcSetVideo
@[simp] theorem vid_svcSetPresenting : (svcSetPresenting c p s).vid = s.vid := by vid_by svcSetPresenting
@[simp] theorem vid_recR1 : (recR1 s).1.vid = s.vid := by vid_by recR1

@[simp] theorem vid_recEnd : (recEnd s).vid = s.vid := by
  simp only [recEnd]
  (repeat' split) <;> rename_i heq <;>
    first
    | (have h1 := @vid_recR1 { s with again := false }; rw [heq] at h1; simp_all)
    | simp_all

@[simp] theorem vid_recPass : (recPass s).vid = s.vid := by
  simp only [recPass]
  (repeat' split) <;> rename_i heq <;>
    first
    | (have h1 := @vid_recR1 { s with again := false }; rw [heq] at h1; simp_all)
    | simp_all

@[simp] theorem vid_updateCamera : (updateCamera s).vid = s.vid := by vid_by updateCamera
@[simp] theorem vid_camAccessEnv : (camAccessEnv g s).vid = s.vid := by vid_by camAccessEnv
@[simp] theorem vid_camStartEnv : (camStartEnv ok s).vid = s.vid := by vid_by camStartEnv
@[simp] theorem vid_camStopEnv : (camStopEnv s).vid = s.vid := by vid_by camStopEnv
@[simp] theorem vid_camAccessDone : (camAccessDone g s).vid = s.vid := by vid_by camAccessDone
@[simp] theorem vid_camStartDone : (camStartDone ok s).vid = s.vid := by vid_by camStartDone
@[simp] theorem vid_recResume : (recResume s).vid = s.vid := by vid_by recResume
@[simp] theorem vid_camFrameEnv : (camFrameEnv k s).vid = s.vid := by vid_by camFrameEnv
@[simp] theorem vid_camFrame : (camFrame k s).vid = s.vid := by vid_by camFrame
@[simp] theorem vid_setCameraSending : (setCameraSending b s).vid = s.vid := by vid_by setCameraSending
@[simp] theorem vid_stopStream : (stopStream j s).vid = s.vid := by vid_by stopStream
@[simp] theorem vid_capTeardown : (capTeardown i s).1.vid = s.vid := by vid_by capTeardown

@[simp] theorem vid_capStop : (capStop i s).vid = s.vid := by
  simp only [capStop]
  have h := vid_capTeardown (i := i) (s := capBegin i s)
  split <;> rename_i heq <;> rw [heq] at h <;> simp_all

@[simp] theorem vid_capStartAfterTeardown : (capStartAfterTeardown i cg pt s).vid = s.vid := by vid_by capStartAfterTeardown

@[simp] theorem vid_capStart : (capStart i pt s).vid = s.vid := by
  simp only [capStart]
  have h := vid_capTeardown (i := i) (s := capBegin i s)
  split <;> rename_i heq <;> rw [heq] at h <;> simp_all

@[simp] theorem vid_stopPresenting : (stopPresenting c s).vid = s.vid := by vid_by stopPresenting
@[simp] theorem vid_toggleShare : (toggleShare s).vid = s.vid := by vid_by toggleShare
@[simp] theorem vid_sourcesLeaf : (sourcesLeaf i t g c s).vid = s.vid := by vid_by sourcesLeaf
@[simp] theorem vid_srcEnv : (srcEnv i ok s).vid = s.vid := by vid_by srcEnv
@[simp] theorem vid_srcDone : (srcDone i t g c ok s).vid = s.vid := by vid_by srcDone
@[simp] theorem vid_pickSource : (pickSource s).vid = s.vid := by vid_by pickSource
@[simp] theorem vid_presentLeaf : (presentLeaf i pt s).vid = s.vid := by vid_by presentLeaf
@[simp] theorem vid_scStartEnv : (scStartEnv j ok s).vid = s.vid := by vid_by scStartEnv
@[simp] theorem vid_installDone : (installDone i cg j pt ok s).vid = s.vid := by vid_by installDone
@[simp] theorem vid_scStopEnv : (scStopEnv j ok s).vid = s.vid := by vid_by scStopEnv
@[simp] theorem vid_scFrameEnv : (scFrameEnv j s).vid = s.vid := by vid_by scFrameEnv
@[simp] theorem vid_scFrame : (scFrame i t s).vid = s.vid := by vid_by scFrame
@[simp] theorem vid_scStoppedEnv : (scStoppedEnv j s).vid = s.vid := by vid_by scStoppedEnv
@[simp] theorem vid_scStopped : (scStopped t s).vid = s.vid := by vid_by scStopped
@[simp] theorem vid_releaseCallMedia : (releaseCallMedia c s).vid = s.vid := by vid_by releaseCallMedia
@[simp] theorem vid_endStrayCall : (endStrayCall c k s).vid = s.vid := by vid_by endStrayCall
@[simp] theorem vid_startCall : (startCall s).vid = s.vid := by vid_by startCall
@[simp] theorem vid_setupEnv : (setupEnv q ok s).vid = s.vid := by vid_by setupEnv
@[simp] theorem vid_declineCall : (declineCall c s).vid = s.vid := by vid_by declineCall
@[simp] theorem vid_nIncoming : (nIncoming c v s).vid = s.vid := by vid_by nIncoming
@[simp] theorem vid_nState : (nState st s).vid = s.vid := by vid_by nState
@[simp] theorem vid_nEnd : (nEnd r s).vid = s.vid := by vid_by nEnd
@[simp] theorem vid_nRejected : (nRejected c s).vid = s.vid := by vid_by nRejected


-- The call code, which keeps the choice too (`callLocalVideo` is no longer set by `.outgoingCall`).
@[simp] theorem vid_endCallUI : (endCallUI s).vid = s.vid := by vid_by endCallUI
@[simp] theorem vid_hangUp : (hangUp s).vid = s.vid := by vid_by hangUp
@[simp] theorem vid_handleEv : (handleEv o e s).vid = s.vid := by cases e <;> vid_by handleEv
@[simp] theorem vid_runMsg : (runMsg m s).vid = s.vid := by vid_by runMsg
@[simp] theorem vid_setupDone : (setupDone g c r p s).vid = s.vid := by vid_by setupDone
@[simp] theorem vid_setupLeaf : (setupLeaf g c v n x s).vid = s.vid := by vid_by setupLeaf

-- ## The invariant

/-- The app's video setting is the user's choice. -/
def VidOk (s : S) : Prop := s.localVideo = s.userVideo

theorem VidOk.of_vid (h : s'.vid = s.vid) (hi : VidOk s) : VidOk s' := by
  simp only [S.vid, Prod.mk.injEq] at h; unfold VidOk; rw [h.1, h.2]; exact hi

theorem VidOk.of_set (h : s'.vid = (v, v)) : VidOk s' := by
  simp only [S.vid, Prod.mk.injEq] at h; unfold VidOk; rw [h.1, h.2]

theorem VidOk.openLobby (hi : VidOk s) : VidOk (openLobby c v s) := by
  simp only [CallCapture.openLobby]; split
  · exact hi
  · exact VidOk.of_set (v := v) (by simp)

theorem VidOk.acceptCall : VidOk (acceptCall c v s) := by
  simp only [CallCapture.acceptCall]
  exact VidOk.of_set (v := v) (by simp only [vid_updateCamera, vid_svcAccept]; split <;> simp)

theorem VidOk.setVideo (hi : VidOk s) : VidOk (setVideo on s) := by
  simp only [CallCapture.setVideo]; split
  · exact VidOk.of_set (v := on) rfl
  · exact VidOk.of_set (v := on) (by split <;> simp)

theorem VidOk.step (hi : VidOk s) : VidOk (CallCapture.step s e) := by
  show VidOk (stepCore s e)
  cases e
  case run k =>
    simp only [stepCore]; split
    · rename_i l _
      exact VidOk.of_vid (s := { s with out := [], jobs := s.jobs.eraseIdx k }) (by cases l <;> simp [runJob]) hi
    · exact hi
  case openLobby c v =>
    show VidOk (CallCapture.openLobby c v { s with out := [] })
    exact VidOk.openLobby (s := { s with out := [] }) hi
  case accept => exact VidOk.acceptCall
  case setVideo on =>
    show VidOk (CallCapture.setVideo on { s with out := [] })
    exact VidOk.setVideo (s := { s with out := [] }) hi
  all_goals exact VidOk.of_vid (s := { s with out := [] }) (by simp [stepCore, handle]) hi

theorem VidOk.reach (h : Reach s) : VidOk s := by
  induction h with
  | init cfg => rfl
  | step e _ ih => exact ih.step

theorem camFrame_keeps (t : S) :
    (camFrame k t).active = t.active ∧ (camFrame k t).localVideo = t.localVideo ∧
      (camFrame k t).userVideo = t.userVideo := by
  simp only [camFrame]; split
  · simp
  · split <;> simp [emit]

/-- **T3 (camera)**: a camera start is requested, and camera frames are sent, only while the call
(or lobby) is live and the user has video on. In every reachable state. -/
theorem t3Camera_holds (hr : Reach s) (e : Ev) : t3Camera s e (step s e) = true := by
  have hv : VidOk (step s e) := VidOk.reach (Reach.step e hr)
  unfold VidOk at hv
  simp only [t3Camera, List.all_eq_true]
  intro x hx
  split
  · -- a camera start: the app wants the camera, and its setting is the user's choice
    have hw := camStartWanted_holds s e
    simp only [camStartWanted, Bool.or_eq_true, Bool.not_eq_eq_eq_not, Bool.not_true, List.any_eq_false] at hw
    rcases hw with hw | hw
    · exact absurd rfl (hw _ hx)
    · simp only [wanted, Bool.and_eq_true] at hw ⊢
      exact ⟨hw, hv ▸ hw.2⟩
  · -- a camera frame: only from the frame's hop, which changes neither the call nor the setting
    rename_i k
    obtain ⟨hj, hw, -, -⟩ := cameraFrames_gated s e k hx
    cases e <;> simp [jobOf] at hj
    rename_i k'
    cases hl : s.jobs[k']? with
    | none => simp [hl] at hj
    | some l =>
      simp only [hl, Option.some.injEq] at hj
      subst hj
      have hs := step_run hl
      obtain ⟨ha, hlv, huv⟩ := camFrame_keeps (k := k) (jobState s k')
      have hrj : runJob (.camFrame k) (jobState s k') = camFrame k (jobState s k') := rfl
      rw [hs, hrj] at hv ⊢
      simp only [wanted, activeLive, noteEnded, ha, hlv, huv, Bool.and_eq_true] at hw hv ⊢
      exact ⟨hw, hv ▸ hw.2⟩
  · rfl

end CallCapture
