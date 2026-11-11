import CallCapture.Effects

/-!
# Frame lemmas: what the non-screen code leaves alone

`S.scr` is everything only the screen-share code may change (captures, streams, the share
token counter, screen-share awaits and the tasks that carry share data). Every other function
keeps it, and keeps or clears `share`; these lemmas say so function by function, so the share
invariant only has to be re-proved for the screen-share functions.
-/

namespace CallCapture

def Op.isScreen : Op → Bool
  | .setup .. => false
  | _ => true

/-- Jobs that carry a share (and must name it by its own token). -/
def Job.isData : Job → Bool
  | .sources .. | .present .. | .sourcesRet .. | .installRet .. | .teardownRet .. | .scFrame .. | .scStopped .. => true
  | _ => false

/-- What only the screen-share code may change. Of each capture only its token and stream:
the share invariant never reads a capture's generation (which `clearShare` bumps). -/
structure Scr where
  capNext : Nat
  capTok : Nat → UInt64
  capStream : Nat → Option Nat
  streams : Nat → Option (Nat × SPh)
  streamNext : Nat
  lastTok : UInt64
  tok0 : UInt64
  sops : List Op
  djobs : List Job

def S.scr (s : S) : Scr :=
  ⟨s.capNext, fun x => (s.caps x).tok, fun x => (s.caps x).stream, s.streams, s.streamNext, s.lastTok, s.tok0,
   s.ops.filter Op.isScreen, s.jobs.filter Job.isData⟩

/-- `scr` of a structure literal (what `{ t with … }` elaborates to). -/
@[simp] theorem scr_mk : S.scr (S.mk a_active a_ringing a_localVideo a_camSends a_gen a_setupTask a_share a_lastTok a_sources a_pc a_running a_again a_caps a_capNext a_streams a_streamNext a_outOff a_ops a_jobs a_ncall a_presenting a_camEnabled a_setupGen a_nativeNext a_setupNext a_camDev a_camNext a_instNext a_genN a_nativeInst a_userVideo a_ended a_capGen0 a_tok0 a_out) =
    ⟨a_capNext, fun x => (a_caps x).tok, fun x => (a_caps x).stream, a_streams, a_streamNext, a_lastTok, a_tok0,
     a_ops.filter Op.isScreen, a_jobs.filter Job.isData⟩ := rfl

/-- …and back to `t.scr` once every field is `t`'s. -/
@[simp] theorem scr_fold {t : S} : (⟨t.capNext, fun x => (t.caps x).tok, fun x => (t.caps x).stream, t.streams, t.streamNext,
    t.lastTok, t.tok0, t.ops.filter Op.isScreen, t.jobs.filter Job.isData⟩ : Scr) = t.scr := rfl

/-- A generation bump keeps a capture's token and stream. -/
@[simp] theorem tok_upd_gen {f : Nat → Cap} : (upd f i { f i with gen := g, bumps := n } x).tok = (f x).tok := by
  simp only [upd]; split <;> simp_all
@[simp] theorem stream_upd_gen {f : Nat → Cap} : (upd f i { f i with gen := g, bumps := n } x).stream = (f x).stream := by
  simp only [upd]; split <;> simp_all

@[simp] theorem scr_capBegin : (capBegin i s).scr = s.scr := by simp [capBegin, setCap]

-- ## Primitives

@[simp] theorem scr_emit : (emit x s).scr = s.scr := rfl
@[simp] theorem scr_enqueue : (enqueue m s).scr = s.scr := by simp [enqueue, List.filter_append, Job.isData]
@[simp] theorem scr_devStop : (devStop s).scr = s.scr := rfl
@[simp] theorem share_emit : (emit x s).share = s.share := rfl
@[simp] theorem share_enqueue : (enqueue m s).share = s.share := rfl
@[simp] theorem share_spawn : (spawn l s).share = s.share := rfl
@[simp] theorem share_addOp : (addOp o s).share = s.share := rfl
@[simp] theorem share_dropOp : (dropOp o s).share = s.share := rfl
@[simp] theorem share_devStop : (devStop s).share = s.share := rfl
@[simp] theorem share_setCap : (setCap i c s).share = s.share := rfl
@[simp] theorem share_setStream : (setStream j v s).share = s.share := rfl
@[simp] theorem share_capBegin : (capBegin i s).share = s.share := rfl

theorem scr_spawn (h : l.isData = false) : (spawn l s).scr = s.scr := by
  simp [spawn, List.filter_append, h]

@[simp] theorem scr_spawn_recPass : (spawn .recPass s).scr = s.scr := scr_spawn rfl
@[simp] theorem scr_spawn_capStop : (spawn (.capStop i) s).scr = s.scr := scr_spawn rfl
@[simp] theorem scr_spawn_setupStart : (spawn (.setupStart g c v n x) s).scr = s.scr := scr_spawn rfl

/-- Cancelling setup tasks changes no job that carries a share. -/
@[simp] theorem filter_map_cancel (l : List Job) : (l.map Job.cancel).filter Job.isData = l.filter Job.isData := by
  induction l with
  | nil => rfl
  | cons a l ih => cases a <;> simp_all [Job.cancel, Job.isData, List.filter_cons]
@[simp] theorem scr_spawn_setupRet : (spawn (.setupRet q g c r p) s).scr = s.scr := scr_spawn rfl
@[simp] theorem scr_spawn_recRet : (spawn .recRet s).scr = s.scr := scr_spawn rfl
@[simp] theorem scr_spawn_stopRet : (spawn (.stopRet j) s).scr = s.scr := scr_spawn rfl
@[simp] theorem scr_spawn_camFrame : (spawn (.camFrame k) s).scr = s.scr := scr_spawn rfl

@[simp] theorem scr_addOp_setup : (addOp (.setup q g sg c v n) s).scr = s.scr := by
  simp [addOp, List.filter_append, Op.isScreen]

theorem filter_erase_of_false {p : α → Bool} [BEq α] [LawfulBEq α] (l : List α) (a : α) (h : p a = false) :
    (l.erase a).filter p = l.filter p := by
  induction l with
  | nil => rfl
  | cons x xs ih =>
    by_cases hx : x = a
    · subst hx; simp [h]
    · simp only [List.erase_cons, beq_iff_eq, hx, if_false, List.filter_cons]; split <;> simp [ih]

@[simp] theorem scr_dropOp_setup : (dropOp (.setup q g sg c v n) s).scr = s.scr := by
  simp [dropOp, filter_erase_of_false _ _ (rfl : Op.isScreen (.setup q g sg c v n) = false)]

-- ## The reconciler's first check (returns a pair)

@[simp] theorem scr_recR1 : (recR1 s).1.scr = s.scr := by
  simp only [recR1]; (repeat' split) <;> simp_all
@[simp] theorem share_recR1 : (recR1 s).1.share = s.share := by
  simp only [recR1]; (repeat' split) <;> simp_all

-- ## Functions that keep the screen state and the share

@[simp] theorem scr_markHungUp : (markHungUp c s).scr = s.scr := by
  simp only [markHungUp]; (repeat' split) <;> simp_all
@[simp] theorem share_markHungUp : (markHungUp c s).share = s.share := by
  simp only [markHungUp]; (repeat' split) <;> simp_all

@[simp] theorem scr_svcHangup : (svcHangup e s).scr = s.scr := by
  simp only [svcHangup]; (repeat' split) <;> simp_all
@[simp] theorem share_svcHangup : (svcHangup e s).share = s.share := by
  simp only [svcHangup]; (repeat' split) <;> simp_all

@[simp] theorem scr_svcEndCall : (svcEndCall c k s).scr = s.scr := by
  simp only [svcEndCall]; (repeat' split) <;> simp_all
@[simp] theorem share_svcEndCall : (svcEndCall c k s).share = s.share := by
  simp only [svcEndCall]; (repeat' split) <;> simp_all

@[simp] theorem scr_svcAccept : (svcAccept c v k s).scr = s.scr := by
  simp only [svcAccept]; (repeat' split) <;> simp_all
@[simp] theorem share_svcAccept : (svcAccept c v k s).share = s.share := by
  simp only [svcAccept]; (repeat' split) <;> simp_all

@[simp] theorem scr_svcDecline : (svcDecline c k s).scr = s.scr := by
  simp only [svcDecline]; (repeat' split) <;> simp_all
@[simp] theorem share_svcDecline : (svcDecline c k s).share = s.share := by
  simp only [svcDecline]; (repeat' split) <;> simp_all

@[simp] theorem scr_svcSetVideo : (svcSetVideo c on s).scr = s.scr := by
  simp only [svcSetVideo]; (repeat' split) <;> simp_all
@[simp] theorem share_svcSetVideo : (svcSetVideo c on s).share = s.share := by
  simp only [svcSetVideo]; (repeat' split) <;> simp_all

@[simp] theorem scr_svcSetPresenting : (svcSetPresenting c p s).scr = s.scr := by
  simp only [svcSetPresenting]; (repeat' split) <;> simp_all
@[simp] theorem share_svcSetPresenting : (svcSetPresenting c p s).share = s.share := by
  simp only [svcSetPresenting]; (repeat' split) <;> simp_all

@[simp] theorem scr_updateCamera : (updateCamera s).scr = s.scr := by
  simp only [updateCamera]; (repeat' split) <;> simp_all
@[simp] theorem share_updateCamera : (updateCamera s).share = s.share := by
  simp only [updateCamera]; (repeat' split) <;> simp_all

@[simp] theorem scr_recEnd : (recEnd s).scr = s.scr := by
  simp only [recEnd]
  (repeat' split) <;> rename_i heq <;>
    first
    | (have h1 := @scr_recR1 { s with again := false }; rw [heq] at h1; simp_all)
    | simp_all
@[simp] theorem share_recEnd : (recEnd s).share = s.share := by
  simp only [recEnd]
  (repeat' split) <;> rename_i heq <;>
    first
    | (have h1 := @share_recR1 { s with again := false }; rw [heq] at h1; simp_all)
    | simp_all

@[simp] theorem scr_recPass : (recPass s).scr = s.scr := by
  simp only [recPass]
  (repeat' split) <;> rename_i heq <;>
    first
    | (have h1 := @scr_recR1 { s with again := false }; rw [heq] at h1; simp_all)
    | simp_all
@[simp] theorem share_recPass : (recPass s).share = s.share := by
  simp only [recPass]
  (repeat' split) <;> rename_i heq <;>
    first
    | (have h1 := @share_recR1 { s with again := false }; rw [heq] at h1; simp_all)
    | simp_all

@[simp] theorem scr_camAccessDone : (camAccessDone g s).scr = s.scr := by
  simp only [camAccessDone]; (repeat' split) <;> simp_all
@[simp] theorem share_camAccessDone : (camAccessDone g s).share = s.share := by
  simp only [camAccessDone]; (repeat' split) <;> simp_all

@[simp] theorem scr_camStartDone : (camStartDone ok s).scr = s.scr := by
  simp only [camStartDone]; (repeat' split) <;> simp_all
@[simp] theorem share_camStartDone : (camStartDone ok s).share = s.share := by
  simp only [camStartDone]; (repeat' split) <;> simp_all

@[simp] theorem scr_recResume : (recResume s).scr = s.scr := by
  simp only [recResume]; (repeat' split) <;> simp_all
@[simp] theorem share_recResume : (recResume s).share = s.share := by
  simp only [recResume]; (repeat' split) <;> simp_all

@[simp] theorem scr_camAccessEnv : (camAccessEnv g s).scr = s.scr := by
  simp only [camAccessEnv]; (repeat' split) <;> simp_all
@[simp] theorem share_camAccessEnv : (camAccessEnv g s).share = s.share := by
  simp only [camAccessEnv]; (repeat' split) <;> simp_all [spawn]
@[simp] theorem scr_camStartEnv : (camStartEnv ok s).scr = s.scr := by
  simp only [camStartEnv]; (repeat' split) <;> simp_all
@[simp] theorem share_camStartEnv : (camStartEnv ok s).share = s.share := by
  simp only [camStartEnv]; (repeat' split) <;> simp_all [spawn]
@[simp] theorem scr_camStopEnv : (camStopEnv s).scr = s.scr := by
  simp only [camStopEnv]; (repeat' split) <;> simp_all
@[simp] theorem share_camStopEnv : (camStopEnv s).share = s.share := by
  simp only [camStopEnv]; (repeat' split) <;> simp_all [spawn]
@[simp] theorem scr_camFrameEnv : (camFrameEnv k s).scr = s.scr := by
  simp only [camFrameEnv]; (repeat' split) <;> simp_all
@[simp] theorem share_camFrameEnv : (camFrameEnv k s).share = s.share := by
  simp only [camFrameEnv]; (repeat' split) <;> simp_all [spawn]

@[simp] theorem scr_camFrame : (camFrame k s).scr = s.scr := by
  simp only [camFrame]; (repeat' split) <;> simp_all
@[simp] theorem share_camFrame : (camFrame k s).share = s.share := by
  simp only [camFrame]; (repeat' split) <;> simp_all

@[simp] theorem scr_setCameraSending : (setCameraSending b s).scr = s.scr := by
  simp only [setCameraSending]; (repeat' split) <;> simp_all
@[simp] theorem share_setCameraSending : (setCameraSending b s).share = s.share := by
  simp only [setCameraSending]; (repeat' split) <;> simp_all

@[simp] theorem scr_endStrayCall : (endStrayCall c k s).scr = s.scr := by
  simp only [endStrayCall]; (repeat' split) <;> simp_all
@[simp] theorem share_endStrayCall : (endStrayCall c k s).share = s.share := by
  simp only [endStrayCall]; (repeat' split) <;> simp_all

@[simp] theorem scr_openLobby : (openLobby c v s).scr = s.scr := by
  simp only [openLobby]; (repeat' split) <;> simp_all
@[simp] theorem share_openLobby : (openLobby c v s).share = s.share := by
  simp only [openLobby]; (repeat' split) <;> simp_all

@[simp] theorem scr_startCall : (startCall s).scr = s.scr := by
  simp only [startCall]; (repeat' split) <;> simp_all
@[simp] theorem share_startCall : (startCall s).share = s.share := by
  simp only [startCall]; (repeat' split) <;> simp_all




@[simp] theorem scr_declineCall : (declineCall c s).scr = s.scr := by
  simp only [declineCall]; (repeat' split) <;> simp_all
@[simp] theorem share_declineCall : (declineCall c s).share = s.share := by
  simp only [declineCall]; (repeat' split) <;> simp_all

@[simp] theorem scr_setVideo : (setVideo on s).scr = s.scr := by
  simp only [setVideo]; (repeat' split) <;> simp_all
@[simp] theorem share_setVideo : (setVideo on s).share = s.share := by
  simp only [setVideo]; (repeat' split) <;> simp_all

@[simp] theorem scr_nIncoming : (nIncoming c v s).scr = s.scr := by
  simp only [nIncoming]; (repeat' split) <;> simp_all
@[simp] theorem share_nIncoming : (nIncoming c v s).share = s.share := by
  simp only [nIncoming]; (repeat' split) <;> simp_all

@[simp] theorem scr_nState : (nState st s).scr = s.scr := by
  simp only [nState]; (repeat' split) <;> simp_all
@[simp] theorem share_nState : (nState st s).share = s.share := by
  simp only [nState]; (repeat' split) <;> simp_all

@[simp] theorem scr_nEnd : (nEnd r s).scr = s.scr := by
  simp only [nEnd]; (repeat' split) <;> simp_all
@[simp] theorem share_nEnd : (nEnd r s).share = s.share := by
  simp only [nEnd]; (repeat' split) <;> simp_all

@[simp] theorem scr_nRejected : (nRejected c s).scr = s.scr := by
  simp only [nRejected]; (repeat' split) <;> simp_all
@[simp] theorem share_nRejected : (nRejected c s).share = s.share := by
  simp only [nRejected]; (repeat' split) <;> simp_all

-- ## Functions that keep the screen state and keep or clear the share

/-- The share is kept, or cleared. -/
def Keeps (a b : Option (Nat × UInt64)) : Prop := b = a ∨ b = none

theorem Keeps.refl : Keeps a a := Or.inl rfl
theorem Keeps.none : Keeps a none := Or.inr rfl
theorem Keeps.trans (h1 : Keeps a b) (h2 : Keeps b c) : Keeps a c := by
  rcases h2 with rfl | rfl
  · exact h1
  · exact Keeps.none

@[simp] theorem scr_clearShare : (clearShare s).scr = s.scr := by
  simp only [clearShare]; split
  · simp only [scr_spawn_capStop, scr_capBegin]; rfl
  · rfl

theorem share_clearShare : (clearShare s).share = none := by
  simp only [clearShare]; split
  · rfl
  · rename_i h; exact h

@[simp] theorem scr_stopPresenting : (stopPresenting c s).scr = s.scr := by
  simp only [stopPresenting]; split <;> simp_all
theorem share_stopPresenting : (stopPresenting c s).share = none := by
  simp only [stopPresenting]; split
  · rw [share_svcSetPresenting, share_clearShare]
  · exact share_clearShare

@[simp] theorem scr_releaseCallMedia : (releaseCallMedia c s).scr = s.scr := by
  simp only [releaseCallMedia]; simp_all
theorem share_releaseCallMedia : (releaseCallMedia c s).share = none := by
  simp only [releaseCallMedia]; simp [share_stopPresenting]

@[simp] theorem scr_endCallUI : (endCallUI s).scr = s.scr := by simp only [endCallUI]; simp_all
theorem share_endCallUI : (endCallUI s).share = none := by simp only [endCallUI]; exact share_releaseCallMedia

@[simp] theorem scr_hangUp : (hangUp s).scr = s.scr := by simp only [hangUp]; simp_all
theorem share_hangUp : (hangUp s).share = none := by simp only [hangUp]; exact share_endCallUI

@[simp] theorem scr_acceptCall : (acceptCall c v s).scr = s.scr := by
  simp only [acceptCall]; (repeat' split) <;> simp_all
theorem share_acceptCall : Keeps s.share (acceptCall c v s).share := by
  simp only [acceptCall]; (repeat' split) <;> simp_all [Keeps, share_endCallUI]

@[simp] theorem scr_handleEv : (handleEv o e s).scr = s.scr := by
  simp only [handleEv]; (repeat' split) <;> simp_all
theorem share_handleEv : Keeps s.share (handleEv o e s).share := by
  simp only [handleEv]; (repeat' split) <;>
    simp_all [Keeps, share_releaseCallMedia, share_endCallUI]

@[simp] theorem scr_setupDone : (setupDone gen c r p s).scr = s.scr := by
  simp only [setupDone]; (repeat' split) <;> simp_all
theorem share_setupDone : Keeps s.share (setupDone gen c r p s).share := by
  simp only [setupDone]; (repeat' split) <;> simp_all [Keeps, share_endCallUI]

@[simp] theorem scr_setupLeaf : (setupLeaf g c v n x s).scr = s.scr := by
  simp only [setupLeaf]; (repeat' split) <;> simp_all
theorem share_setupLeaf : Keeps s.share (setupLeaf g c v n x s).share := by
  simp only [setupLeaf]; split
  · exact Keeps.refl
  · split
    · exact share_setupDone
    · exact Keeps.refl

@[simp] theorem scr_setupEnv : (setupEnv q ok s).scr = s.scr := by
  simp only [setupEnv]; (repeat' split) <;> simp_all
@[simp] theorem share_setupEnv : (setupEnv q ok s).share = s.share := by
  simp only [setupEnv]; (repeat' split) <;> simp_all [spawn, enqueue, dropOp]

@[simp] theorem scr_runMsg : (runMsg m s).scr = s.scr := by
  simp only [runMsg]; (repeat' split) <;> simp_all
theorem share_runMsg : Keeps s.share (runMsg m s).share := by
  simp only [runMsg]; (repeat' split)
  · exact share_handleEv
  · simp [Keeps]

end CallCapture
