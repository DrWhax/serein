import CallCapture.Video

/-!
# T3 for obsolete shares: no stream is started for a share that was stopped or replaced

A stream start (`scStartReq`) comes from one of two places:

- the pick's task (`presentLeaf`), after `isCurrentScreenShare`: the share's token identifies
  it (`ShareInv.current`, with at most 2^64 shares);
- `start(_:)` continuing after the teardown of the capture's previous stream
  (`capStartAfterTeardown`), which checks only the capture's own generation.

Every revocation bumps that generation (`clearScreenShare` calls `cancelStart`). So a pending
continuation whose generation still matches was made since the last bump, while its share was
current, and the share is still current: `Td.Inv` below. The generation is a wrapping `UInt64`,
so the invariant writes it as a count of bumps (`Cap.bumps`, ghost); with fewer than 2^64 bumps
of one capture, equal generations mean equal counts. `Td.Inv` itself needs no bound: where the
share token does not identify the share, it allows "more than 2^64 shares" instead.
-/

namespace CallCapture

variable {s s' : S}

/-- A suspended teardown-then-start of capture `i` under capture generation `cg`. -/
@[simp] def Op.td : Op → Option (Nat × UInt64)
  | .setup .. => none
  | .sources .. => none
  | .tdStart i cg _ _ => some (i, cg)
  | .install .. => none
  | .stopping _ => none

/-- Its continuation, once the teardown has completed. -/
@[simp] def Job.td : Job → Option (Nat × UInt64)
  | .teardownRet i cg _ _ => some (i, cg)
  | .recPass => none
  | .capStop _ => none
  | .setupStart .. => none
  | .sources .. => none
  | .present .. => none
  | .setupRet .. => none
  | .recRet => none
  | .sourcesRet .. => none
  | .installRet .. => none
  | .stopRet _ => none
  | .msg _ => none
  | .camFrame _ => none
  | .scFrame .. => none
  | .scStopped .. => none

/-- What the invariant reads, besides the share: the capture counter, each capture's generation
and bump count, and the pending teardown-then-starts. (The share has its own frame lemmas,
`share_*`, in Frames.lean.) -/
structure Td where
  capNext : Nat
  capGB : Nat → UInt64 × Nat
  capGen0 : UInt64
  tops : List (Nat × UInt64)
  tjobs : List (Nat × UInt64)

def S.td (s : S) : Td :=
  ⟨s.capNext, fun x => ((s.caps x).gen, (s.caps x).bumps), s.capGen0, s.ops.filterMap Op.td,
   s.jobs.filterMap Job.td⟩

@[simp] theorem td_mk : S.td (S.mk a_active a_ringing a_localVideo a_camSends a_gen a_setupTask a_share a_lastTok a_sources a_pc a_running a_again a_caps a_capNext a_streams a_streamNext a_outOff a_ops a_jobs a_ncall a_presenting a_camEnabled a_setupGen a_nativeNext a_setupNext a_camDev a_camNext a_instNext a_genN a_nativeInst a_userVideo a_ended a_capGen0 a_tok0 a_out) =
    ⟨a_capNext, fun x => ((a_caps x).gen, (a_caps x).bumps), a_capGen0, a_ops.filterMap Op.td, a_jobs.filterMap Job.td⟩ := rfl

@[simp] theorem td_fold {t : S} : (⟨t.capNext, fun x => ((t.caps x).gen, (t.caps x).bumps), t.capGen0,
    t.ops.filterMap Op.td, t.jobs.filterMap Job.td⟩ : Td) = t.td := rfl

-- ## Primitives

theorem filterMap_erase {l : List Op} (h : o.td = none) : (l.erase o).filterMap Op.td = l.filterMap Op.td := by
  induction l with
  | nil => rfl
  | cons b l ih =>
    rw [List.erase_cons]
    split
    · rename_i hb
      have : b = o := by simpa using hb
      subst this; simp only [List.filterMap_cons, h]
    · cases hbt : b.td <;> simp only [List.filterMap_cons, hbt, ih]

@[simp] theorem filterMap_map_cancel {l : List Job} : (l.map Job.cancel).filterMap Job.td = l.filterMap Job.td := by
  have : Job.td ∘ Job.cancel = Job.td := by funext b; cases b <;> rfl
  rw [List.filterMap_map, this]

@[simp] theorem td_emit : (emit x s).td = s.td := rfl
/-- Not a teardown continuation (a Bool, so that `simp` discharges it by evaluation). -/
def Job.noTd (l : Job) : Bool := l.td.isNone
def Op.noTd (o : Op) : Bool := o.td.isNone

theorem Job.td_of_noTd {l : Job} (h : l.noTd = true) : l.td = none := by simpa [Job.noTd] using h
theorem Op.td_of_noTd {o : Op} (h : o.noTd = true) : o.td = none := by simpa [Op.noTd] using h

theorem td_spawn (h : l.noTd = true) : (spawn l s).td = s.td := by
  simp only [spawn, S.td, List.filterMap_append, List.filterMap_cons, List.filterMap_nil, Job.td_of_noTd h, List.append_nil]
@[simp] theorem td_enqueue : (enqueue m s).td = s.td := by
  simp only [enqueue, S.td, List.filterMap_append, List.filterMap_cons, List.filterMap_nil, Job.td, List.append_nil]
theorem td_addOp (h : o.noTd = true) : (addOp o s).td = s.td := by
  simp only [addOp, S.td, List.filterMap_append, List.filterMap_cons, List.filterMap_nil, Op.td_of_noTd h, List.append_nil]
theorem td_dropOp (h : o.noTd = true) : (dropOp o s).td = s.td := by
  simp only [dropOp, S.td, filterMap_erase (Op.td_of_noTd h)]
theorem td_setCap (h1 : c.gen = (s.caps i).gen) (h2 : c.bumps = (s.caps i).bumps) : (setCap i c s).td = s.td := by
  simp only [setCap, S.td, Td.mk.injEq, true_and, and_true]
  funext x; simp only [upd]; split
  · subst_vars; rw [h1, h2]
  · rfl
@[simp] theorem td_spawn_recPass : (spawn .recPass s).td = s.td := td_spawn rfl
@[simp] theorem td_spawn_capStop : (spawn (.capStop i) s).td = s.td := td_spawn rfl
@[simp] theorem td_spawn_setupStart : (spawn (.setupStart g c v n x) s).td = s.td := td_spawn rfl
@[simp] theorem td_spawn_sources : (spawn (.sources i t g c) s).td = s.td := td_spawn rfl
@[simp] theorem td_spawn_present : (spawn (.present i pt) s).td = s.td := td_spawn rfl
@[simp] theorem td_spawn_setupRet : (spawn (.setupRet q g c r p) s).td = s.td := td_spawn rfl
@[simp] theorem td_spawn_recRet : (spawn .recRet s).td = s.td := td_spawn rfl
@[simp] theorem td_spawn_sourcesRet : (spawn (.sourcesRet i t g c ok) s).td = s.td := td_spawn rfl
@[simp] theorem td_spawn_installRet : (spawn (.installRet i cg j pt ok) s).td = s.td := td_spawn rfl
@[simp] theorem td_spawn_stopRet : (spawn (.stopRet j) s).td = s.td := td_spawn rfl
@[simp] theorem td_spawn_msg : (spawn (.msg m) s).td = s.td := td_spawn rfl
@[simp] theorem td_spawn_camFrame : (spawn (.camFrame k) s).td = s.td := td_spawn rfl
@[simp] theorem td_spawn_scFrame : (spawn (.scFrame i t) s).td = s.td := td_spawn rfl
@[simp] theorem td_spawn_scStopped : (spawn (.scStopped i t) s).td = s.td := td_spawn rfl
@[simp] theorem td_addOp_setup : (addOp (.setup q g sg c v n) s).td = s.td := td_addOp rfl
@[simp] theorem td_dropOp_setup : (dropOp (.setup q g sg c v n) s).td = s.td := td_dropOp rfl
@[simp] theorem td_addOp_sources : (addOp (.sources i t g c) s).td = s.td := td_addOp rfl
@[simp] theorem td_dropOp_sources : (dropOp (.sources i t g c) s).td = s.td := td_dropOp rfl
@[simp] theorem td_addOp_install : (addOp (.install i cg j pt) s).td = s.td := td_addOp rfl
@[simp] theorem td_dropOp_install : (dropOp (.install i cg j pt) s).td = s.td := td_dropOp rfl
@[simp] theorem td_addOp_stopping : (addOp (.stopping j) s).td = s.td := td_addOp rfl
@[simp] theorem td_dropOp_stopping : (dropOp (.stopping j) s).td = s.td := td_dropOp rfl
@[simp] theorem td_setCap_stream : (setCap i { s.caps i with stream := v } s).td = s.td := td_setCap rfl rfl
@[simp] theorem td_setCap_content : (setCap i { s.caps i with content := b } s).td = s.td := td_setCap rfl rfl
@[simp] theorem td_setStream : (setStream j v s).td = s.td := rfl
@[simp] theorem td_devStop : (devStop s).td = s.td := rfl

set_option hygiene false in
/-- `td` through a function whose branches are structure updates and callees with `td` lemmas. -/
macro "td_by " f:ident : tactic =>
  `(tactic| (simp only [$f:ident]; (repeat' split) <;> (try simp_all) <;> (try (simp only [S.td, Td.mk.injEq] at *; simp_all))))

-- ## Functions that leave it alone

@[simp] theorem td_markHungUp : (markHungUp c s).td = s.td := by td_by markHungUp
@[simp] theorem td_svcHangup : (svcHangup e s).td = s.td := by td_by svcHangup
@[simp] theorem td_svcEndCall : (svcEndCall c k s).td = s.td := by td_by svcEndCall
@[simp] theorem td_svcAccept : (svcAccept c v k s).td = s.td := by td_by svcAccept
@[simp] theorem td_svcDecline : (svcDecline c k s).td = s.td := by td_by svcDecline
@[simp] theorem td_svcSetVideo : (svcSetVideo c on s).td = s.td := by td_by svcSetVideo
@[simp] theorem td_svcSetPresenting : (svcSetPresenting c p s).td = s.td := by td_by svcSetPresenting
@[simp] theorem td_recR1 : (recR1 s).1.td = s.td := by td_by recR1

@[simp] theorem td_recEnd : (recEnd s).td = s.td := by
  simp only [recEnd]
  (repeat' split) <;> rename_i heq <;>
    first
    | (have h1 := @td_recR1 { s with again := false }; rw [heq] at h1; simp_all)
    | simp_all

@[simp] theorem td_recPass : (recPass s).td = s.td := by
  simp only [recPass]
  (repeat' split) <;> rename_i heq <;>
    first
    | (have h1 := @td_recR1 { s with again := false }; rw [heq] at h1; simp_all)
    | simp_all

@[simp] theorem td_updateCamera : (updateCamera s).td = s.td := by td_by updateCamera
@[simp] theorem td_camAccessEnv : (camAccessEnv g s).td = s.td := by td_by camAccessEnv
@[simp] theorem td_camStartEnv : (camStartEnv ok s).td = s.td := by td_by camStartEnv
@[simp] theorem td_camStopEnv : (camStopEnv s).td = s.td := by td_by camStopEnv
@[simp] theorem td_camAccessDone : (camAccessDone g s).td = s.td := by td_by camAccessDone
@[simp] theorem td_camStartDone : (camStartDone ok s).td = s.td := by td_by camStartDone
@[simp] theorem td_recResume : (recResume s).td = s.td := by td_by recResume
@[simp] theorem td_camFrameEnv : (camFrameEnv k s).td = s.td := by td_by camFrameEnv
@[simp] theorem td_camFrame : (camFrame k s).td = s.td := by td_by camFrame
@[simp] theorem td_setCameraSending : (setCameraSending b s).td = s.td := by td_by setCameraSending
@[simp] theorem td_stopStream : (stopStream j s).td = s.td := by td_by stopStream
@[simp] theorem td_capTeardown : (capTeardown i s).1.td = s.td := by td_by capTeardown
@[simp] theorem td_capStartAfterTeardown : (capStartAfterTeardown i cg pt s).td = s.td := by td_by capStartAfterTeardown
@[simp] theorem td_sourcesLeaf : (sourcesLeaf i t g c s).td = s.td := by td_by sourcesLeaf
@[simp] theorem td_srcEnv : (srcEnv i ok s).td = s.td := by td_by srcEnv
@[simp] theorem td_pickSource : (pickSource s).td = s.td := by td_by pickSource
@[simp] theorem td_scStartEnv : (scStartEnv j ok s).td = s.td := by td_by scStartEnv
@[simp] theorem td_scFrameEnv : (scFrameEnv j s).td = s.td := by td_by scFrameEnv
@[simp] theorem td_scFrame : (scFrame i t s).td = s.td := by td_by scFrame
@[simp] theorem td_scStoppedEnv : (scStoppedEnv j s).td = s.td := by td_by scStoppedEnv
@[simp] theorem td_endStrayCall : (endStrayCall c k s).td = s.td := by td_by endStrayCall
@[simp] theorem td_startCall : (startCall s).td = s.td := by td_by startCall
@[simp] theorem td_setupEnv : (setupEnv q ok s).td = s.td := by td_by setupEnv
@[simp] theorem td_declineCall : (declineCall c s).td = s.td := by td_by declineCall
@[simp] theorem td_nIncoming : (nIncoming c v s).td = s.td := by td_by nIncoming
@[simp] theorem td_nState : (nState st s).td = s.td := by td_by nState
@[simp] theorem td_nEnd : (nEnd r s).td = s.td := by td_by nEnd
@[simp] theorem td_nRejected : (nRejected c s).td = s.td := by td_by nRejected
@[simp] theorem td_openLobby : (openLobby c v s).td = s.td := by td_by openLobby
@[simp] theorem td_setVideo : (setVideo on s).td = s.td := by td_by setVideo


-- `share` frame lemmas Frames.lean does not have
theorem share_stopStream : (stopStream j s).share = s.share := rfl
theorem share_sourcesLeaf : (sourcesLeaf i t g c s).share = s.share := by
  simp only [sourcesLeaf]; split <;> rfl
theorem share_pickSource : (pickSource s).share = s.share := by
  simp only [pickSource]; split <;> (try split) <;> rfl
theorem share_scFrame : (scFrame i t s).share = s.share := by
  simp only [scFrame]; split <;> rfl

-- ## The invariant

/-- A pending teardown-then-start `(i, cg)`: of a created capture; `cg` is that capture's
generation after `b` bumps; and if there has been no bump since (`b` is the count now), its share
is the current one, or more than 2^64 shares exist. -/
def TdOk (s : S) (p : Nat × UInt64) : Prop :=
  p.1 < s.capNext ∧ ∃ b, b ≤ (s.caps p.1).bumps ∧ p.2 = s.capGen0 + UInt64.ofNat b ∧
    (b = (s.caps p.1).bumps → curShare s = some p.1 ∨ 2 ^ 64 < s.capNext)

/-- Each created capture's generation is its count of bumps (from `capGen0`), and every pending
teardown-then-start is `TdOk`. A definition, not a structure, so that a structure update of
other fields keeps it by definition. -/
def TdInv (s : S) : Prop :=
  (∀ x, x < s.capNext → (s.caps x).gen = s.capGen0 + UInt64.ofNat (s.caps x).bumps) ∧
  (∀ p ∈ s.ops.filterMap Op.td, TdOk s p) ∧
  (∀ p ∈ s.jobs.filterMap Job.td, TdOk s p)

theorem td_eq (h : s'.td = s.td) :
    s'.capNext = s.capNext ∧ (∀ x, (s'.caps x).gen = (s.caps x).gen ∧ (s'.caps x).bumps = (s.caps x).bumps) ∧
    s'.capGen0 = s.capGen0 ∧ s'.ops.filterMap Op.td = s.ops.filterMap Op.td ∧
    s'.jobs.filterMap Job.td = s.jobs.filterMap Job.td := by
  simp only [S.td, Td.mk.injEq] at h
  obtain ⟨h1, h2, h3, h4, h5⟩ := h
  refine ⟨h1, fun x => ?_, h3, h4, h5⟩
  have := congrFun h2 x
  simp only [Prod.mk.injEq] at this
  exact this

theorem TdOk.of (hn : s'.capNext = s.capNext) (hc : ∀ x, (s'.caps x).bumps = (s.caps x).bumps)
    (h0 : s'.capGen0 = s.capGen0) (hsh : s'.share = s.share) (h : TdOk s p) : TdOk s' p := by
  obtain ⟨hx, b, hb, hcg, hcur⟩ := h
  refine ⟨by rw [hn]; exact hx, b, by rw [hc]; exact hb, by rw [h0]; exact hcg, fun hbb => ?_⟩
  have := hcur (by rw [← hc]; exact hbb)
  simp only [curShare, hsh, hn]; exact this

/-- The same share, counter, generations and counts, and no new pending teardown-then-start. -/
theorem TdInv.of (hi : TdInv s) (hn : s'.capNext = s.capNext)
    (hc : ∀ x, (s'.caps x).gen = (s.caps x).gen ∧ (s'.caps x).bumps = (s.caps x).bumps)
    (h0 : s'.capGen0 = s.capGen0) (hsh : s'.share = s.share)
    (ho : ∀ p ∈ s'.ops.filterMap Op.td, p ∈ s.ops.filterMap Op.td)
    (hj : ∀ p ∈ s'.jobs.filterMap Job.td, p ∈ s.jobs.filterMap Job.td) : TdInv s' :=
  ⟨fun x hx => by rw [(hc x).1, (hc x).2, h0]; exact hi.1 x (hn ▸ hx),
   fun p hp => TdOk.of hn (fun x => (hc x).2) h0 hsh (hi.2.1 p (ho p hp)),
   fun p hp => TdOk.of hn (fun x => (hc x).2) h0 hsh (hi.2.2 p (hj p hp))⟩

theorem TdInv.keep (h : s'.td = s.td) (hsh : s'.share = s.share) (hi : TdInv s) : TdInv s' := by
  obtain ⟨h1, h2, h3, h4, h5⟩ := td_eq h
  exact hi.of h1 h2 h3 hsh (fun p hp => h4 ▸ hp) (fun p hp => h5 ▸ hp)

theorem TdInv.init (cfg : Cfg) : TdInv (S.init cfg) :=
  ⟨fun x hx => by simp [S.init] at hx, fun p hp => by simp [S.init] at hp, fun p hp => by simp [S.init] at hp⟩

theorem TdInv.eraseIdx (hi : TdInv s) : TdInv (jobState s k) :=
  hi.of rfl (fun _ => ⟨rfl, rfl⟩) rfl rfl (fun _ hp => hp) (fun p hp => by
    rw [List.mem_filterMap] at hp ⊢
    obtain ⟨a, ha, hf⟩ := hp
    exact ⟨a, List.mem_of_mem_eraseIdx ha, hf⟩)

theorem TdInv.dropOp (hi : TdInv s) : TdInv (CallCapture.dropOp o s) :=
  hi.of rfl (fun _ => ⟨rfl, rfl⟩) rfl rfl (fun p hp => by
    rw [List.mem_filterMap] at hp ⊢
    obtain ⟨a, ha, hf⟩ := hp
    exact ⟨a, List.mem_of_mem_erase ha, hf⟩) (fun _ hp => hp)

-- ## The screen-share functions

theorem caps_capBegin : (CallCapture.capBegin i s).caps x =
    if x = i then { s.caps i with gen := (s.caps i).gen + 1, bumps := (s.caps i).bumps + 1 } else s.caps x := rfl

theorem TdOk.capBegin (h : TdOk s p) : TdOk (CallCapture.capBegin i s) p := by
  obtain ⟨hx, b, hb, hcg, hcur⟩ := h
  refine ⟨hx, b, ?_, hcg, fun hbb => ?_⟩
  · rw [caps_capBegin]; split
    · rename_i h; subst h; show b ≤ (s.caps p.1).bumps + 1; omega
    · exact hb
  · rw [caps_capBegin] at hbb; split at hbb
    · rename_i h; subst h; simp only at hbb; omega
    · exact hcur hbb

theorem TdInv.capBegin (hi : TdInv s) : TdInv (CallCapture.capBegin i s) := by
  refine ⟨fun x hx => ?_, fun p hp => (hi.2.1 p hp).capBegin, fun p hp => (hi.2.2 p hp).capBegin⟩
  rw [caps_capBegin]; split
  · rename_i h; subst h
    show (s.caps x).gen + 1 = s.capGen0 + UInt64.ofNat ((s.caps x).bumps + 1)
    rw [hi.1 x hx, UInt64.ofNat_add, UInt64.ofNat_one, UInt64.add_assoc]
  · exact hi.1 x hx

/-- `CallCapture.clearShare`: the share goes, and its capture is bumped at once (`cancelStart`), so its
continuations are no longer current; the others were not current before either. -/
theorem TdOk.clear (hsh : s.share = some (i, t)) (h : TdOk s p) : TdOk (CallCapture.capBegin i { s with share := none }) p := by
  obtain ⟨hx, b, hb, hcg, hcur⟩ := h
  refine ⟨hx, b, ?_, hcg, fun hbb => ?_⟩
  · rw [caps_capBegin]; split
    · rename_i h; subst h; show b ≤ (s.caps p.1).bumps + 1; omega
    · exact hb
  · rw [caps_capBegin] at hbb; split at hbb
    · rename_i h; subst h; simp only at hbb; omega
    · rename_i hne
      right
      rcases hcur hbb with h | h
      · simp only [curShare, hsh, Option.map_some, Option.some.injEq] at h; exact absurd h.symm hne
      · exact h

theorem TdInv.clearShare (hi : TdInv s) : TdInv (CallCapture.clearShare s) := by
  unfold CallCapture.clearShare
  split
  · rename_i i t hsh
    refine TdInv.keep td_spawn_capStop share_spawn ?_
    exact ⟨(hi.capBegin (i := i)).1, fun p hp => (hi.2.1 p hp).clear hsh, fun p hp => (hi.2.2 p hp).clear hsh⟩
  · exact hi

theorem TdInv.capStop (hi : TdInv s) : TdInv (CallCapture.capStop i s) := by
  have h1 := TdInv.keep (td_capTeardown (i := i)) share_capTeardown (hi.capBegin (i := i))
  unfold CallCapture.capStop
  split <;> rename_i heq <;> simp only [heq] at h1
  · exact TdInv.keep td_addOp_stopping share_addOp h1
  · exact h1

theorem TdInv.addTd (hi : TdInv s) (hok : TdOk s (i, cg)) : TdInv (addOp (.tdStart i cg j pt) s) :=
  ⟨hi.1, fun p hp => by
     simp only [addOp, List.filterMap_append, List.filterMap_cons, Op.td, List.filterMap_nil, List.mem_append,
       List.mem_singleton] at hp
     rcases hp with hp | hp
     · exact hi.2.1 p hp
     · subst hp; exact hok,
   hi.2.2⟩

theorem TdInv.addTdJob (hi : TdInv s) (hok : TdOk s (i, cg)) : TdInv (spawn (.teardownRet i cg j pt) s) :=
  ⟨hi.1, hi.2.1, fun p hp => by
     simp only [spawn, List.filterMap_append, List.filterMap_cons, Job.td, List.filterMap_nil, List.mem_append,
       List.mem_singleton] at hp
     rcases hp with hp | hp
     · exact hi.2.2 p hp
     · subst hp; exact hok⟩

/-- `start(_:)`: the capture is bumped, and a teardown-then-start it leaves pending carries the
new generation, while the share is current (the caller's check). -/
theorem TdInv.capStart (hi : TdInv s) (hlt : i < s.capNext) (hcur : curShare s = some i ∨ 2 ^ 64 < s.capNext) :
    TdInv (CallCapture.capStart i pt s) := by
  have h0 := hi.capBegin (i := i)
  have h1 := TdInv.keep (td_capTeardown (i := i)) share_capTeardown h0
  obtain ⟨t1, t2, t3, -, -⟩ := td_eq (td_capTeardown (i := i) (s := CallCapture.capBegin i s))
  have hsh1 := share_capTeardown (i := i) (s := CallCapture.capBegin i s)
  rcases h : capTeardown i (CallCapture.capBegin i s) with ⟨s', _ | j⟩
  all_goals simp only [h] at h1 t1 t2 t3 hsh1
  · have : CallCapture.capStart i pt s = capStartAfterTeardown i ((CallCapture.capBegin i s).caps i).gen pt s' := by
      simp only [CallCapture.capStart, h]
    rw [this]; exact TdInv.keep td_capStartAfterTeardown share_capStartAfterTeardown h1
  · have : CallCapture.capStart i pt s = addOp (.tdStart i ((CallCapture.capBegin i s).caps i).gen j pt) s' := by
      simp only [CallCapture.capStart, h]
    rw [this]
    refine h1.addTd ⟨by rw [t1]; exact hlt, (s'.caps i).bumps, Nat.le_refl _, ?_, fun _ => ?_⟩
    · show ((CallCapture.capBegin i s).caps i).gen = s'.capGen0 + UInt64.ofNat (s'.caps i).bumps
      rw [t3, (t2 i).2]; exact h0.1 i hlt
    · show curShare s' = some i ∨ 2 ^ 64 < s'.capNext
      rw [t1]; simp only [curShare, hsh1, share_capBegin]; exact hcur

theorem TdInv.stopPresenting (hi : TdInv s) : TdInv (CallCapture.stopPresenting c s) := by
  have h1 : TdInv (CallCapture.clearShare { s with sources := false }) := TdInv.clearShare hi
  unfold CallCapture.stopPresenting
  try dsimp only
  split
  · exact TdInv.keep td_svcSetPresenting share_svcSetPresenting h1
  · exact h1

theorem TdOk.addShare (hsh : s.share = none) (h : TdOk s p) :
    TdOk { s with lastTok := tok, capNext := s.capNext + 1, share := some (s.capNext, tok),
                  caps := upd s.caps s.capNext c } p := by
  obtain ⟨x, cg⟩ := p
  obtain ⟨hx, b, hb, hcg, hcur⟩ := h
  simp only at hx hb hcg hcur
  have hne : x ≠ s.capNext := by omega
  have hcx : upd s.caps s.capNext c x = s.caps x := by simp [upd, hne]
  refine ⟨by show x < s.capNext + 1; omega, b, by show b ≤ (upd s.caps s.capNext c x).bumps; rw [hcx]; exact hb,
    hcg, fun hbb => ?_⟩
  right
  have : b = (s.caps x).bumps := by rw [← hcx]; exact hbb
  rcases hcur this with h | h
  · simp [curShare, hsh] at h
  · show 2 ^ 64 < s.capNext + 1; omega

/-- A new share: capture `capNext`, fresh (generation `capGen0`, no bumps). There was no share
(it was just cleared), so no continuation was current. -/
theorem TdInv.addShare (hi : TdInv s) (hsh : s.share = none) (hc1 : c.gen = s.capGen0) (hc2 : c.bumps = 0) :
    TdInv { s with lastTok := tok, capNext := s.capNext + 1, share := some (s.capNext, tok),
                   caps := upd s.caps s.capNext c } := by
  refine ⟨fun x hx => ?_, fun p hp => (hi.2.1 p hp).addShare hsh, fun p hp => (hi.2.2 p hp).addShare hsh⟩
  show (upd s.caps s.capNext c x).gen = s.capGen0 + UInt64.ofNat (upd s.caps s.capNext c x).bumps
  simp only [upd]; split
  · rw [hc1, hc2]; simp
  · rename_i hne; exact hi.1 x (by change x < s.capNext + 1 at hx; omega)

theorem TdInv.toggleShare (hi : TdInv s) : TdInv (CallCapture.toggleShare s) := by
  unfold CallCapture.toggleShare
  try dsimp only
  split
  · exact hi
  · split
    · exact hi.stopPresenting
    · exact TdInv.keep td_spawn_sources share_spawn (hi.clearShare.addShare share_clearShare rfl rfl)

theorem TdInv.srcDone (hi : TdInv s) : TdInv (CallCapture.srcDone i t g c ok s) := by
  have h1 : TdInv (setCap i { s.caps i with content := true } s) := TdInv.keep td_setCap_content share_setCap hi
  unfold CallCapture.srcDone
  try dsimp only
  split
  · split
    · exact h1
    · exact h1
  · split
    · exact hi.clearShare
    · exact hi

theorem TdInv.presentLeaf (hi : TdInv s) (hs : ShareInv s) (hlt : i < s.capNext) (hpt : pt.tok = (s.caps i).tok) :
    TdInv (CallCapture.presentLeaf i pt s) := by
  unfold CallCapture.presentLeaf
  try dsimp only
  split
  · exact hi
  · rename_i hc
    split
    · apply hi.capStart hlt
      have hc' : isCurrent s pt = true := by simpa using hc
      have ht : shareTokIs s (s.caps i).tok = true := by
        simp only [isCurrent, Bool.and_eq_true] at hc'; rw [← hpt]; exact hc'.1.1
      by_cases hb : s.capNext ≤ 2 ^ 64
      · exact Or.inl (hs.current hb hlt ht)
      · exact Or.inr (by omega)
    · split
      · exact hi.clearShare
      · exact hi

theorem TdInv.installDone (hi : TdInv s) : TdInv (CallCapture.installDone i cg j pt ok s) := by
  have h1 : TdInv (setCap i { s.caps i with stream := some j } s) := TdInv.keep td_setCap_stream share_setCap hi
  unfold CallCapture.installDone
  try dsimp only
  split
  · split
    · exact hi.clearShare
    · exact hi
  · split
    · exact TdInv.keep td_addOp_stopping share_addOp (TdInv.keep td_stopStream share_stopStream hi)
    · split
      · exact h1.capStop
      · exact TdInv.keep td_svcSetPresenting share_svcSetPresenting h1

/-- A stop completes: a teardown-then-start's continuation is spawned with the same data. -/
theorem TdInv.scStopEnv (hi : TdInv s) : TdInv (CallCapture.scStopEnv j ok s) := by
  unfold CallCapture.scStopEnv
  try dsimp only
  split
  · exact hi
  · rename_i o ho
    have h1 := hi.dropOp (o := o)
    cases o with
    | tdStart i cg j' pt =>
      have hm : (i, cg) ∈ s.ops.filterMap Op.td := List.mem_filterMap.mpr ⟨_, findStop_mem ho, rfl⟩
      exact TdInv.addTdJob h1 (hi.2.1 _ hm)
    | _ => exact TdInv.keep td_spawn_stopRet share_spawn h1

theorem TdInv.scStopped (hi : TdInv s) : TdInv (CallCapture.scStopped t s) := by
  unfold CallCapture.scStopped; split
  · exact hi.stopPresenting
  · exact hi

-- ## The call code: teardown

theorem TdInv.releaseCallMedia (hi : TdInv s) : TdInv (CallCapture.releaseCallMedia c s) := by
  have h1 : TdInv { s with gen := s.gen + 1, genN := s.genN + 1, setupTask := false, jobs := s.jobs.map Job.cancel } :=
    hi.of rfl (fun _ => ⟨rfl, rfl⟩) rfl rfl (fun _ hp => hp) (fun p hp => by rw [filterMap_map_cancel] at hp; exact hp)
  unfold CallCapture.releaseCallMedia
  try dsimp only
  exact TdInv.keep td_updateCamera share_updateCamera (TdInv.keep td_svcHangup share_svcHangup h1.stopPresenting)

theorem TdInv.endCallUI (hi : TdInv s) : TdInv (CallCapture.endCallUI s) := by
  unfold CallCapture.endCallUI; exact TdInv.releaseCallMedia hi

theorem TdInv.hangUp (hi : TdInv s) : TdInv (CallCapture.hangUp s) := by
  unfold CallCapture.hangUp; exact (TdInv.keep td_svcHangup share_svcHangup hi).endCallUI

theorem TdInv.handleEv (hi : TdInv s) : TdInv (CallCapture.handleEv o e s) := by
  unfold CallCapture.handleEv
  cases e with
  | outgoing c v n setup =>
    simp only
    split
    · split
      · split
        · exact TdInv.keep td_svcSetVideo share_svcSetVideo hi
        · exact hi
      · exact TdInv.keep td_endStrayCall share_endStrayCall hi
    · exact TdInv.keep td_endStrayCall share_endStrayCall hi
  | incoming c v n =>
    simp only; split
    · exact hi
    · exact hi
  | state c st n =>
    simp only; split
    · split
      · exact hi
      · split
        · exact TdInv.keep td_endStrayCall share_endStrayCall hi
        · exact hi
    · split
      · exact TdInv.keep td_endStrayCall share_endStrayCall hi
      · exact hi
  | ended c r n =>
    simp only
    have h1 : TdInv (if (s.ringing.map (·.2)) == some n then { s with ringing := none } else s) := by
      split
      · exact hi
      · exact hi
    generalize (if (s.ringing.map (·.2)) == some n then { s with ringing := none } else s) = t at h1 ⊢
    split
    · split
      · split
        · exact TdInv.releaseCallMedia h1
        · exact h1.endCallUI
      · exact h1
    · exact h1

theorem TdInv.runMsg (hi : TdInv s) : TdInv (CallCapture.runMsg m s) := by
  unfold CallCapture.runMsg
  split
  · exact hi.handleEv
  · exact TdInv.keep td_setCameraSending share_setCameraSending hi

theorem TdInv.setupDone (hi : TdInv s) : TdInv (CallCapture.setupDone g c r p s) := by
  unfold CallCapture.setupDone
  try dsimp only
  (repeat' split) <;>
    first
    | exact hi
    | exact TdInv.keep td_svcEndCall share_svcEndCall hi
    | exact hi.endCallUI

theorem TdInv.setupLeaf (hi : TdInv s) : TdInv (CallCapture.setupLeaf g c v n x s) := by
  unfold CallCapture.setupLeaf
  try dsimp only
  split
  · exact hi
  · split
    · exact TdInv.setupDone hi
    · exact TdInv.keep td_addOp_setup share_addOp hi

theorem TdInv.acceptCall (hi : TdInv s) : TdInv (CallCapture.acceptCall c v s) := by
  unfold CallCapture.acceptCall
  try dsimp only
  (repeat' split) <;>
    first
    | exact TdInv.keep td_updateCamera share_updateCamera (TdInv.keep td_svcAccept share_svcAccept hi.endCallUI)
    | exact TdInv.keep td_updateCamera share_updateCamera (TdInv.keep td_svcAccept share_svcAccept hi)

-- ## Every step

theorem TdInv.step (hs : ShareInv s) (hi : TdInv s) (e : Ev) : TdInv (step s e) := by
  show TdInv (stepCore s e)
  cases e
  case run k =>
    simp only [stepCore]
    split
    · rename_i l hl
      have hj : TdInv (jobState s k) := hi.eraseIdx
      cases l with
      | recPass => exact TdInv.keep td_recPass share_recPass hj
      | capStop i => exact hj.capStop
      | setupStart => exact hj.setupLeaf
      | sources => exact TdInv.keep td_sourcesLeaf share_sourcesLeaf hj
      | present i pt =>
        obtain ⟨hic, hpt⟩ := jobOk_of hs hl rfl
        exact hj.presentLeaf hs.jobState hic hpt
      | setupRet => exact hj.setupDone
      | recRet => exact TdInv.keep td_recResume share_recResume hj
      | sourcesRet => exact hj.srcDone
      | installRet => exact hj.installDone
      | teardownRet => exact TdInv.keep td_capStartAfterTeardown share_capStartAfterTeardown hj
      | stopRet => exact hj
      | msg => exact hj.runMsg
      | camFrame => exact TdInv.keep td_camFrame share_camFrame hj
      | scFrame => exact TdInv.keep td_scFrame share_scFrame hj
      | scStopped => exact hj.scStopped
    · exact hi
  all_goals simp only [stepCore, handle]
  case openLobby => exact TdInv.keep td_openLobby share_openLobby hi
  case startCall => exact TdInv.keep td_startCall share_startCall hi
  case accept => exact TdInv.acceptCall hi
  case decline => exact TdInv.keep td_declineCall share_declineCall hi
  case hangUp => exact TdInv.hangUp hi
  case closeCall => exact TdInv.endCallUI hi
  case setVideo => exact TdInv.keep td_setVideo share_setVideo hi
  case toggleShare => exact TdInv.toggleShare hi
  case pickSource => exact TdInv.keep td_pickSource share_pickSource hi
  case cancelPick => exact TdInv.clearShare hi
  case nIncoming => exact TdInv.keep td_nIncoming share_nIncoming hi
  case nState => exact TdInv.keep td_nState share_nState hi
  case nEnd => exact TdInv.keep td_nEnd share_nEnd hi
  case nRejected => exact TdInv.keep td_nRejected share_nRejected hi
  case setupDone => exact TdInv.keep td_setupEnv share_setupEnv hi
  case camAccess => exact TdInv.keep td_camAccessEnv share_camAccessEnv hi
  case camStart => exact TdInv.keep td_camStartEnv share_camStartEnv hi
  case camStopDone => exact TdInv.keep td_camStopEnv share_camStopEnv hi
  case camFrame => exact TdInv.keep td_camFrameEnv share_camFrameEnv hi
  case srcDone => exact TdInv.keep td_srcEnv share_srcEnv hi
  case scStartDone => exact TdInv.keep td_scStartEnv share_scStartEnv hi
  case scStopDone => exact TdInv.scStopEnv hi
  case scFrame => exact TdInv.keep td_scFrameEnv share_scFrameEnv hi
  case scStopped => exact TdInv.keep td_scStoppedEnv share_scStoppedEnv hi

theorem TdInv.reach (h : Reach s) : TdInv s := by
  induction h with
  | init cfg => exact TdInv.init cfg
  | step e hr ih => exact ih.step (ShareInv.reach hr) e

-- ## T3 for obsolete shares

theorem gen_inj {t : UInt64} {a b : Nat} (ha : a < 2 ^ 64) (hb : b < 2 ^ 64)
    (h : t + UInt64.ofNat a = t + UInt64.ofNat b) : a = b := by
  have := congrArg UInt64.toNat h
  simp only [UInt64.toNat_add, UInt64.toNat_ofNat'] at this
  omega

theorem share_capStart : (capStart i pt s).share = s.share := by
  simp only [capStart]
  have h := share_capTeardown (i := i) (s := capBegin i s)
  split <;> rename_i heq <;> rw [heq] at h <;> simp_all [share_capStartAfterTeardown]

/-- `start(_:)` starts only a stream of its own capture. -/
theorem capStart_start (h : .scStartReq i' j ∈ (capStart i pt t).out) (ht : t.out = []) : i' = i := by
  have hst : ((capBegin i t).caps i).stream = (t.caps i).stream := by simp [capBegin, setCap, upd]
  cases hs : (t.caps i).stream with
  | none =>
    have : capStart i pt t = capStartAfterTeardown i ((capBegin i t).caps i).gen pt (capBegin i t) := by
      simp only [capStart, capTeardown, hst, hs]
    rw [this] at h
    simp only [capStartAfterTeardown] at h
    split at h
    · simp [ht] at h
    · simp [addOp, emit, setStream, ht] at h; exact h.1
  | some j' =>
    have : capStart i pt t = addOp (.tdStart i ((capBegin i t).caps i).gen j' pt)
        (stopStream j' (setCap i { (capBegin i t).caps i with stream := none } (capBegin i t))) := by
      simp only [capStart, capTeardown, hst, hs]
    rw [this] at h
    simp [addOp, stopStream, emit, setStream, setCap, ht] at h

/-- The pick's task starts a stream only of its own share, after its check passed, and leaves
the share as it is. -/
theorem present_start (hx : .scStartReq i j ∈ (presentLeaf i' pt t).out) (ht : t.out = []) :
    i = i' ∧ isCurrent t pt = true ∧ (presentLeaf i' pt t).share = t.share := by
  by_cases hc : isCurrent t pt = true
  · by_cases hcont : (t.caps i').content = true
    · have he : presentLeaf i' pt t = capStart i' pt t := by simp [presentLeaf, hc, hcont]
      rw [he] at hx ⊢
      exact ⟨capStart_start hx ht, hc, share_capStart⟩
    · have : (presentLeaf i' pt t).out = t.out := by
        simp only [presentLeaf, hc, hcont]; (repeat' split) <;> first | contradiction | simp | rfl
      rw [this, ht] at hx; simp at hx
  · have : presentLeaf i' pt t = t := by simp [presentLeaf, hc]
    rw [this, ht] at hx; simp at hx

/-- **T3 (obsolete share)**: a screen stream is started only for the current share. With at most
2^64 shares made (`capNext ≤ 2^64`, as for T2), and fewer than 2^64 generation bumps of each
capture (`bumps`: each stop and each restart of that share bumps it, and it wraps). -/
theorem t3ScreenObsolete_holds (hr : Reach s) (hb : s.capNext ≤ 2 ^ 64) (hg : ∀ i, (s.caps i).bumps < 2 ^ 64)
    (e : Ev) : t3ScreenObsolete s e (step s e) = true := by
  have hi := ShareInv.reach hr
  have ht := TdInv.reach hr
  simp only [t3ScreenObsolete, List.all_eq_true]
  intro x hx
  split
  · rename_i i j
    have hm := mem_step (List.mem_reverse.mp hx)
    cases e <;> simp [Eff.kind, stepKinds, handleKinds] at hm
    rename_i k
    cases hl : s.jobs[k]? with
    | none => simp [hl] at hm
    | some l =>
      rw [hl] at hm
      cases l <;> simp [jobKinds] at hm
      case present i' pt =>
        -- the pick's task: its token check passed, and the token names the share
        obtain ⟨hic, hpt⟩ := jobOk_of hi hl rfl
        rw [step_run hl] at hx ⊢
        simp only [effects, runJob] at hx
        obtain ⟨rfl, hc, hsh⟩ := present_start (List.mem_reverse.mp hx) rfl
        have hcur : curShare (jobState s k) = some i := by
          apply hi.jobState.current hb hic
          simp only [isCurrent, Bool.and_eq_true] at hc; rw [← hpt]; exact hc.1.1
        show (curShare (presentLeaf i pt (jobState s k)) == some i) = true
        simp only [curShare] at hcur ⊢
        rw [hsh, hcur]; simp
      case teardownRet i' cg j' pt =>
        -- the start after a teardown: its generation check passed, so no bump since it was made
        obtain ⟨hic, -⟩ := jobOk_of hi hl rfl
        rw [step_run hl] at hx ⊢
        simp only [effects, runJob] at hx
        have hx' := List.mem_reverse.mp hx
        show (curShare (capStartAfterTeardown i' cg pt (jobState s k)) == some i) = true
        simp only [curShare, share_capStartAfterTeardown]
        simp only [capStartAfterTeardown] at hx'
        split at hx'
        · simp at hx'
        · rename_i hcg
          simp [addOp, emit, setStream] at hx'
          obtain ⟨rfl, -⟩ := hx'
          have hm : (i, cg) ∈ s.jobs.filterMap Job.td := List.mem_filterMap.mpr ⟨_, List.mem_of_getElem? hl, rfl⟩
          obtain ⟨-, b, hb', hcgb, hcur⟩ := ht.2.2 _ hm
          have heq : cg = (s.caps i).gen := by simpa using hcg
          rw [ht.1 i hic] at heq
          simp only at hcgb hb' hcur
          rw [hcgb] at heq
          have hbb := gen_inj (by have := hg i; omega) (hg i) heq
          rcases hcur hbb with h | h
          · simp only [curShare] at h; simp [h]
          · omega
  · rfl

end CallCapture
