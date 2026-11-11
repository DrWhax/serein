import CallCapture.Model

/-!
# Which effects each function can request

For every function of the model, the kinds of effect it can add to the log. These are
flow-insensitive over-approximations (`mem_f : x ∈ (f s).out → x ∈ s.out ∨ x.kind ∈ ks`), proved
function by function from its callees; `mem_step` then bounds what one step can request by
what its event's handler, or the job it runs, can request. Environment and device events request
nothing: their continuations and hops are jobs.
-/

namespace CallCapture

inductive EK where
  | camAccessReq | camStartReq | camStopReq | camPreview | sendCam | sendScreen
  | scSourcesReq | scStartReq | scStopReq
  | svcStart | svcAccept | svcDecline | svcHangup | svcEndCall | svcSetVideo | presentOn | presentOff
  deriving DecidableEq, Repr

def Eff.kind : Eff → EK
  | .camAccessReq => .camAccessReq
  | .camStartReq _ => .camStartReq
  | .camStopReq => .camStopReq
  | .camPreview _ => .camPreview
  | .sendFrame (.camera _) => .sendCam
  | .sendFrame (.screen _) => .sendScreen
  | .scSourcesReq _ => .scSourcesReq
  | .scStartReq _ _ => .scStartReq
  | .scStopReq _ => .scStopReq
  | .svcStart _ _ => .svcStart
  | .svcAccept _ _ => .svcAccept
  | .svcDecline _ => .svcDecline
  | .svcHangup _ => .svcHangup
  | .svcEndCall _ _ => .svcEndCall
  | .svcSetVideo _ _ => .svcSetVideo
  | .svcSetPresenting _ true => .presentOn
  | .svcSetPresenting _ false => .presentOff

-- ## Functions that leave the log alone

@[simp] theorem out_spawn : (spawn l s).out = s.out := rfl
@[simp] theorem out_enqueue : (enqueue m s).out = s.out := rfl
@[simp] theorem out_addOp : (addOp o s).out = s.out := rfl
@[simp] theorem out_dropOp : (dropOp o s).out = s.out := rfl
@[simp] theorem out_setCap : (setCap i c s).out = s.out := rfl
@[simp] theorem out_setStream : (setStream j v s).out = s.out := rfl
@[simp] theorem out_clearShare : (clearShare s).out = s.out := by simp only [clearShare]; split <;> rfl
@[simp] theorem out_devStop : (devStop s).out = s.out := rfl
@[simp] theorem out_capBegin : (capBegin i s).out = s.out := rfl
@[simp] theorem out_emit : (emit x s).out = x :: s.out := rfl

@[simp] theorem out_markHungUp : (markHungUp c s).out = s.out := by
  unfold markHungUp; split <;> (try split) <;> rfl

@[simp] theorem out_updateCamera : (updateCamera s).out = s.out := by
  unfold updateCamera; split <;> rfl

@[simp] theorem out_setCameraSending : (setCameraSending b s).out = s.out := by
  simp [setCameraSending]

-- ## The environment's side of CallingService (each adds exactly its own call)

@[simp] theorem out_svcHangup : (svcHangup e s).out = .svcHangup e :: s.out := by
  simp only [svcHangup]; split <;> (try split) <;> simp

@[simp] theorem out_svcEndCall : (svcEndCall c k s).out = .svcEndCall c k :: s.out := by
  simp only [svcEndCall]; split <;> (try split) <;> simp
@[simp] theorem out_svcDecline : (svcDecline c k s).out = .svcDecline c :: s.out := by
  simp only [svcDecline]; split <;> (try split) <;> simp

@[simp] theorem out_svcAccept : (svcAccept c v k s).out = .svcAccept c v :: s.out := by
  simp only [svcAccept]; split <;> (try split) <;> simp

@[simp] theorem out_svcSetVideo : (svcSetVideo c on s).out = .svcSetVideo c on :: s.out := by simp [svcSetVideo]

@[simp] theorem out_svcSetPresenting : (svcSetPresenting c p s).out = .svcSetPresenting c p :: s.out := by
  simp only [svcSetPresenting]; split <;> (repeat' split) <;> simp

@[simp] theorem out_stopStream : (stopStream j s).out = .scStopReq j :: s.out := by simp [stopStream]

/-- Widen the kinds a lemma allows (`decide` checks the inclusion). -/
theorem sub_or {x : Eff} {l : List Eff} {ks ks' : List EK} (h : x ∈ l ∨ x.kind ∈ ks) (hs : ks ⊆ ks' := by decide) :
    x ∈ l ∨ x.kind ∈ ks' := h.imp_right (fun h => hs h)

/-- `emit y` then something that adds only `ks`. -/
theorem emit_or {x y : Eff} {l : List Eff} {ks : List EK} (h : x ∈ y :: l) (hy : y.kind ∈ ks := by simp [Eff.kind]) :
    x ∈ l ∨ x.kind ∈ ks := by
  rcases List.mem_cons.mp h with rfl | h
  · exact Or.inr hy
  · exact Or.inl h

-- Proof helpers. Hygiene is off so that `h` (the membership hypothesis) and `hm` are the
-- caller's names.
set_option hygiene false in
/-- Apply a callee's lemma to `h` (matched at reducible transparency, so a wrong callee fails at
once), widening its kinds if needed. -/
macro "mem " t:term : tactic =>
  `(tactic| (have hm := by with_reducible exact $t
             first | exact hm | exact sub_or hm))

set_option hygiene false in
/-- A branch that adds nothing. -/
macro "keep" : tactic =>
  `(tactic| ((try simp only [out_spawn, out_enqueue, out_addOp, out_dropOp, out_setCap, out_setStream, out_clearShare,
               out_devStop, out_capBegin, out_markHungUp, out_updateCamera, out_setCameraSending] at h)
             exact Or.inl h))

set_option hygiene false in
/-- A branch that adds one effect of an allowed kind. -/
macro "one" : tactic =>
  `(tactic| ((try simp only [out_emit, out_spawn, out_enqueue, out_addOp, out_dropOp, out_setCap, out_setStream,
               out_clearShare, out_devStop, out_capBegin, out_markHungUp, out_updateCamera, out_setCameraSending,
               out_svcHangup, out_svcEndCall, out_svcDecline, out_svcAccept, out_svcSetVideo, out_svcSetPresenting,
               out_stopStream] at h)
             first | exact emit_or h | exact sub_or (emit_or h)))

-- ## CaptureReconciler

theorem mem_recR1 (h : x ∈ (recR1 s).1.out) : x ∈ s.out ∨ x.kind ∈ [.camStopReq, .camAccessReq] := by
  simp only [recR1] at h
  repeat' split at h
  all_goals first | one | keep

theorem mem_recEnd (h : x ∈ (recEnd s).out) : x ∈ s.out ∨ x.kind ∈ [.camStopReq, .camAccessReq] := by
  simp only [recEnd] at h
  split at h
  · split at h <;> rename_i heq <;> exact mem_recR1 (s := { s with again := false }) (by rw [heq]; exact h)
  · exact Or.inl h

theorem mem_recPass (h : x ∈ (recPass s).out) : x ∈ s.out ∨ x.kind ∈ [.camStopReq, .camAccessReq] := by
  simp only [recPass] at h
  split at h <;> rename_i heq
  · exact mem_recR1 (s := { s with again := false }) (by rw [heq]; exact h)
  · rcases mem_recEnd h with h | h
    · exact mem_recR1 (s := { s with again := false }) (by rw [heq]; exact h)
    · exact Or.inr h

theorem mem_camAccessDone (h : x ∈ (camAccessDone g s).out) :
    x ∈ s.out ∨ x.kind ∈ [.camStopReq, .camAccessReq, .camStartReq] := by
  simp only [camAccessDone] at h
  repeat' split at h
  all_goals first | mem mem_recEnd h | one | keep

theorem mem_camStartDone (h : x ∈ (camStartDone ok s).out) : x ∈ s.out ∨ x.kind ∈ [.camStopReq, .camAccessReq] := by
  simp only [camStartDone] at h
  repeat' split at h
  all_goals first | mem mem_recEnd h | one | keep

theorem mem_recResume (h : x ∈ (recResume s).out) : x ∈ s.out ∨ x.kind ∈ [.camStopReq, .camAccessReq, .camStartReq] := by
  simp only [recResume] at h
  split at h
  all_goals first | mem mem_camAccessDone h | mem mem_camStartDone h | mem mem_recEnd h | keep

@[simp] theorem out_camAccessEnv : (camAccessEnv g s).out = s.out := by simp only [camAccessEnv]; split <;> rfl
@[simp] theorem out_camStartEnv : (camStartEnv ok s).out = s.out := by simp only [camStartEnv]; split <;> rfl
@[simp] theorem out_camStopEnv : (camStopEnv s).out = s.out := by simp only [camStopEnv]; split <;> rfl
@[simp] theorem out_camFrameEnv : (camFrameEnv k s).out = s.out := by simp only [camFrameEnv]; split <;> rfl

theorem mem_camFrame (h : x ∈ (camFrame k s).out) : x ∈ s.out ∨ x.kind ∈ [.camPreview, .sendCam] := by
  simp only [camFrame] at h
  repeat' split at h
  all_goals first
    | keep
    | one
    | (simp only [out_emit] at h
       rcases List.mem_cons.mp h with rfl | h
       · exact Or.inr (by simp [Eff.kind])
       · exact emit_or h)

-- ## ScreenShareCapture

theorem mem_capTeardown (h : x ∈ (capTeardown i s).1.out) : x ∈ s.out ∨ x.kind ∈ [.scStopReq] := by
  simp only [capTeardown] at h
  split at h
  all_goals first | one | keep

theorem mem_capStop (h : x ∈ (capStop i s).out) : x ∈ s.out ∨ x.kind ∈ [.scStopReq] := by
  simp only [capStop] at h
  split at h <;> rename_i heq <;> exact mem_capTeardown (i := i) (s := capBegin i s) (by rw [heq]; exact h)

theorem mem_capStartAfterTeardown (h : x ∈ (capStartAfterTeardown i cg pt s).out) :
    x ∈ s.out ∨ x.kind ∈ [.scStartReq] := by
  simp only [capStartAfterTeardown] at h
  split at h
  all_goals first | one | keep

theorem mem_capStart (h : x ∈ (capStart i pt s).out) : x ∈ s.out ∨ x.kind ∈ [.scStopReq, .scStartReq] := by
  simp only [capStart] at h
  split at h <;> rename_i heq
  · exact sub_or (mem_capTeardown (i := i) (s := capBegin i s) (by rw [heq]; exact h))
  · rcases mem_capStartAfterTeardown h with h | h
    · exact sub_or (mem_capTeardown (i := i) (s := capBegin i s) (by rw [heq]; exact h))
    · exact sub_or (Or.inr h)

-- ## SignalSession: presenting

theorem mem_stopPresenting (h : x ∈ (stopPresenting c s).out) : x ∈ s.out ∨ x.kind ∈ [.presentOff] := by
  simp only [stopPresenting] at h
  repeat' split at h
  all_goals first | one | keep

theorem mem_toggleShare (h : x ∈ (toggleShare s).out) : x ∈ s.out ∨ x.kind ∈ [.presentOff] := by
  simp only [toggleShare] at h
  repeat' split at h
  all_goals first | mem mem_stopPresenting h | keep

theorem mem_sourcesLeaf (h : x ∈ (sourcesLeaf i tok gen c s).out) : x ∈ s.out ∨ x.kind ∈ [.scSourcesReq] := by
  simp only [sourcesLeaf] at h
  split at h
  · exact Or.inl h
  · exact emit_or h

@[simp] theorem out_srcDone : (srcDone i tok gen c ok s).out = s.out := by
  simp only [srcDone]; (repeat' split) <;> simp

@[simp] theorem out_srcEnv : (srcEnv i ok s).out = s.out := by simp only [srcEnv]; split <;> rfl

@[simp] theorem out_pickSource : (pickSource s).out = s.out := by
  simp only [pickSource]; split <;> (repeat' split) <;> rfl

theorem mem_presentLeaf (h : x ∈ (presentLeaf i pt s).out) : x ∈ s.out ∨ x.kind ∈ [.scStopReq, .scStartReq] := by
  simp only [presentLeaf] at h
  repeat' split at h
  all_goals first | mem mem_capStart h | keep

theorem mem_installDone (h : x ∈ (installDone i cg j pt ok s).out) : x ∈ s.out ∨ x.kind ∈ [.scStopReq, .presentOn] := by
  simp only [installDone] at h
  repeat' split at h
  all_goals first | mem mem_capStop h | one | keep

@[simp] theorem out_scStartEnv : (scStartEnv j ok s).out = s.out := by simp only [scStartEnv]; split <;> rfl
@[simp] theorem out_scStopEnv : (scStopEnv j ok s).out = s.out := by
  simp only [scStopEnv]; split
  · rfl
  · split <;> rfl
@[simp] theorem out_scFrameEnv : (scFrameEnv j s).out = s.out := by simp only [scFrameEnv]; (repeat' split) <;> rfl
@[simp] theorem out_scStoppedEnv : (scStoppedEnv j s).out = s.out := by simp only [scStoppedEnv]; (repeat' split) <;> rfl

theorem mem_scFrame (h : x ∈ (scFrame i tok s).out) : x ∈ s.out ∨ x.kind ∈ [.sendScreen] := by
  simp only [scFrame] at h
  repeat' split at h
  all_goals first | one | keep

theorem mem_scStopped (h : x ∈ (scStopped tok s).out) : x ∈ s.out ∨ x.kind ∈ [.presentOff] := by
  simp only [scStopped] at h
  repeat' split at h
  all_goals first | mem mem_stopPresenting h | keep

-- ## SignalSession: calls

theorem mem_releaseCallMedia (h : x ∈ (releaseCallMedia c s).out) :
    x ∈ s.out ∨ x.kind ∈ [.presentOff, .svcHangup] := by
  simp only [releaseCallMedia, out_updateCamera, out_svcHangup] at h
  rcases List.mem_cons.mp h with rfl | h
  · exact Or.inr (by simp [Eff.kind])
  · mem mem_stopPresenting h

theorem mem_endCallUI (h : x ∈ (endCallUI s).out) : x ∈ s.out ∨ x.kind ∈ [.presentOff, .svcHangup] := by
  simp only [endCallUI] at h; mem mem_releaseCallMedia h

theorem mem_endStrayCall (h : x ∈ (endStrayCall c k s).out) : x ∈ s.out ∨ x.kind ∈ [.svcEndCall] := by
  simp only [endStrayCall] at h
  repeat' split at h
  all_goals first | one | keep

theorem mem_handleEv (h : x ∈ (handleEv o e s).out) : x ∈ s.out ∨ x.kind ∈ [.svcEndCall, .presentOff, .svcHangup, .svcSetVideo] := by
  cases e <;> simp only [handleEv] at h
  all_goals repeat' split at h
  all_goals first | mem mem_endStrayCall h | mem mem_releaseCallMedia h | mem mem_endCallUI h | one | keep

@[simp] theorem out_openLobby : (openLobby c v s).out = s.out := by
  simp only [openLobby]; split <;> simp

@[simp] theorem out_startCall : (startCall s).out = s.out := by
  simp only [startCall]; split <;> (repeat' split) <;> simp

theorem mem_setupDone (h : x ∈ (setupDone gen c r p s).out) : x ∈ s.out ∨ x.kind ∈ [.svcEndCall, .presentOff, .svcHangup] := by
  simp only [setupDone] at h
  repeat' split at h
  all_goals first | mem mem_endCallUI h | one | keep

theorem mem_setupLeaf (h : x ∈ (setupLeaf g c v inst k s).out) :
    x ∈ s.out ∨ x.kind ∈ [.svcStart, .svcEndCall, .presentOff, .svcHangup] := by
  simp only [setupLeaf] at h
  split at h
  · exact Or.inl h
  split at h
  · rcases mem_setupDone h with h | h
    · simp only [out_emit] at h
      rcases List.mem_cons.mp h with rfl | h
      · exact Or.inr (by simp [Eff.kind])
      · exact Or.inl h
    · exact Or.inr (List.mem_cons_of_mem _ h)
  · simp only [out_addOp, out_emit] at h
    rcases List.mem_cons.mp h with rfl | h
    · exact Or.inr (by simp [Eff.kind])
    · exact Or.inl h

@[simp] theorem out_setupEnv : (setupEnv q ok s).out = s.out := by
  simp only [setupEnv]; split
  · rfl
  · (repeat' split) <;> rfl

theorem mem_acceptCall (h : x ∈ (acceptCall c v s).out) : x ∈ s.out ∨ x.kind ∈ [.svcAccept, .presentOff, .svcHangup] := by
  simp only [acceptCall, out_updateCamera, out_svcAccept] at h
  rcases List.mem_cons.mp h with rfl | h
  · exact Or.inr (by simp [Eff.kind])
  · repeat' split at h
    all_goals first | keep | mem mem_endCallUI h

theorem mem_declineCall (h : x ∈ (declineCall c s).out) : x ∈ s.out ∨ x.kind ∈ [.svcDecline] := by
  simp only [declineCall, out_svcDecline] at h; exact emit_or h

theorem mem_hangUp (h : x ∈ (hangUp s).out) : x ∈ s.out ∨ x.kind ∈ [.svcHangup, .presentOff] := by
  simp only [hangUp] at h
  have hm := mem_endCallUI h
  rcases hm with h | h
  · simp only [out_svcHangup] at h; exact emit_or h
  · exact sub_or (Or.inr h)

theorem mem_setVideo (h : x ∈ (setVideo on s).out) : x ∈ s.out ∨ x.kind ∈ [.svcSetVideo] := by
  simp only [setVideo] at h
  repeat' split at h
  all_goals first | one | keep

@[simp] theorem out_nIncoming : (nIncoming c v s).out = s.out := by simp only [nIncoming]; split <;> rfl
@[simp] theorem out_nState : (nState st s).out = s.out := by
  simp only [nState]; split <;> (repeat' split) <;> rfl
@[simp] theorem out_nEnd : (nEnd r s).out = s.out := by simp only [nEnd]; split <;> rfl
@[simp] theorem out_nRejected : (nRejected c s).out = s.out := rfl

theorem mem_runMsg (h : x ∈ (runMsg m s).out) : x ∈ s.out ∨ x.kind ∈ [.svcEndCall, .presentOff, .svcHangup, .svcSetVideo] := by
  simp only [runMsg] at h
  split at h
  all_goals first | mem mem_handleEv h | keep

-- ## Steps

/-- The kinds of effect the handler of each event can request (none for the environment's). -/
def handleKinds : Ev → List EK
  | .accept .. => [.svcAccept, .presentOff, .svcHangup]
  | .decline _ => [.svcDecline]
  | .hangUp | .closeCall => [.svcEndCall, .presentOff, .svcHangup]
  | .setVideo _ => [.svcSetVideo]
  | .toggleShare => [.presentOff]
  | _ => []

/-- What each job can request. -/
def jobKinds : Job → List EK
  | .recPass => [.camStopReq, .camAccessReq]
  | .capStop _ => [.scStopReq]
  | .setupStart .. => [.svcStart, .svcEndCall, .presentOff, .svcHangup]
  | .sources .. => [.scSourcesReq]
  | .present .. => [.scStopReq, .scStartReq]
  | .setupRet .. => [.svcEndCall, .presentOff, .svcHangup]
  | .msg _ => [.svcEndCall, .presentOff, .svcHangup, .svcSetVideo]
  | .recRet => [.camStopReq, .camAccessReq, .camStartReq]
  | .sourcesRet .. | .stopRet _ => []
  | .installRet .. => [.scStopReq, .presentOn]
  | .teardownRet .. => [.scStartReq]
  | .camFrame _ => [.camPreview, .sendCam]
  | .scFrame .. => [.sendScreen]
  | .scStopped .. => [.presentOff]

/-- What one step can request: its handler's kinds, or its job's. -/
def stepKinds (s : S) : Ev → List EK
  | .run k => match s.jobs[k]? with | some l => jobKinds l | none => []
  | e => handleKinds e

theorem mem_handle (h : x ∈ (handle e s).out) : x ∈ s.out ∨ x.kind ∈ handleKinds e := by
  cases e <;> simp only [handle, handleKinds] at h ⊢
  case accept => mem mem_acceptCall h
  case decline => mem mem_declineCall h
  case hangUp => mem mem_hangUp h
  case closeCall => mem mem_endCallUI h
  case setVideo => mem mem_setVideo h
  case toggleShare => mem mem_toggleShare h
  all_goals first
    | exact Or.inl h
    | (simp only [out_openLobby, out_startCall, out_pickSource, out_nIncoming, out_nState, out_nEnd, out_nRejected, out_clearShare,
         out_setupEnv, out_camAccessEnv, out_camStartEnv, out_camStopEnv, out_camFrameEnv, out_srcEnv, out_scStartEnv,
         out_scStopEnv, out_scFrameEnv, out_scStoppedEnv] at h
       exact Or.inl h)

theorem mem_runJob (h : x ∈ (runJob l s).out) : x ∈ s.out ∨ x.kind ∈ jobKinds l := by
  cases l <;> simp only [runJob, jobKinds] at h ⊢
  case recPass => mem mem_recPass h
  case capStop => mem mem_capStop h
  case setupStart => mem mem_setupLeaf h
  case sources => mem mem_sourcesLeaf h
  case present => mem mem_presentLeaf h
  case setupRet => mem mem_setupDone h
  case recRet => mem mem_recResume h
  case sourcesRet => simp only [out_srcDone] at h; exact Or.inl h
  case installRet => mem mem_installDone h
  case teardownRet => mem mem_capStartAfterTeardown h
  case stopRet => exact Or.inl h
  case msg => mem mem_runMsg h
  case camFrame => mem mem_camFrame h
  case scFrame => mem mem_scFrame h
  case scStopped => mem mem_scStopped h

@[simp] theorem out_noteEnded : (noteEnded s s').out = s'.out := rfl

/-- Everything one step requests comes from its handler or from the job it runs. -/
theorem mem_step (h : x ∈ (step s e).out) : x.kind ∈ stepKinds s e := by
  simp only [step, out_noteEnded, stepCore] at h
  cases e
  case run k =>
    simp only [stepKinds]
    cases hl : s.jobs[k]? with
    | none => simp [hl] at h
    | some l =>
      simp only [hl] at h
      rcases mem_runJob h with h | h
      · simp at h
      · exact h
  all_goals
    simp only [stepKinds]
    rcases mem_handle h with h | h
    · simp at h
    · exact h

end CallCapture
