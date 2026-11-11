import CallCapture.Effects
import CallCapture.Props
import CallCapture.ShareInv

/-!
# Proved properties

Every theorem here is about all states reachable from any initial counters (`Reach`), or about
every state outright, under the scheduler of `Model.lean`: any pending job may run next, and
user and device events may come between any two jobs. The transitive axioms they use are
printed by `Audit.lean`.
-/

namespace CallCapture

-- ## The two kinds of step

/-- The state the `k`-th job runs in. -/
abbrev jobState (s : S) (k : Nat) : S := { s with out := [], jobs := s.jobs.eraseIdx k }

theorem step_run (hl : s.jobs[k]? = some l) : step s (.run k) = noteEnded s (runJob l (jobState s k)) := by
  simp [step, stepCore, hl]

theorem ShareInv.jobState (hi : ShareInv s) : ShareInv (jobState s k) :=
  ⟨hi.last, hi.tok, hi.share, hi.ops, fun l hl hd => hi.jobs l (List.mem_of_mem_eraseIdx hl) hd,
   hi.capStream, hi.ownerLt, hi.fresh⟩

theorem jobOk_of (hi : ShareInv s) (hl : s.jobs[k]? = some l) (hd : l.isData = true) : JobOk (jobState s k) l :=
  hi.jobs l (List.mem_of_getElem? hl) hd

@[simp] theorem effects_noteEnded : effects (noteEnded s s') = effects s' := rfl

-- ## The camera

set_option hygiene false in
/-- Case analysis on what `wanted` reads, so every condition in a camera step is decided. -/
macro "wanted_cases" : tactic =>
  `(tactic| (rcases hact : s.active with _ | ⟨_, _, _, live, _, _⟩ <;> (try cases live) <;>
             cases hlv : s.localVideo <;> simp_all [wanted, activeLive, emit, effects, devStop]))

/-- **T4 (camera)**: a camera start whose continuation runs once the camera is no longer wanted
stops the camera in that same job (`stopDevice`). Holds in every state. -/
theorem t4Camera_holds (s : S) (e : Ev) : t4Camera s e (step s e) = true := by
  unfold t4Camera
  cases e
  case run k =>
    simp only [jobOf]
    cases hl : s.jobs[k]? with
    | none => rfl
    | some l =>
      cases l <;> try rfl
      split
      · rename_i hpc
        rw [step_run hl]
        simp only [effects_noteEnded, runJob, recResume, hpc, camStartDone]
        wanted_cases
      · rfl
  all_goals rfl

/-- **T3 (camera, application authorization)**: the camera is asked to start only while the app
wants it: a live call (or lobby) with `callLocalVideo` on, in the state the step ends in. This is
not the user's own choice (`userVideo`); see `Counterexamples.t3Camera_videoOffDuringSetup`. -/
theorem camStartWanted_holds (s : S) (e : Ev) : camStartWanted s e (step s e) = true := by
  simp only [camStartWanted, Bool.or_eq_true, Bool.not_eq_eq_eq_not, Bool.not_true, List.any_eq_false]
  by_cases he : ∃ k, e = .run k ∧ s.jobs[k]? = some .recRet
  · obtain ⟨k, rfl, hl⟩ := he
    rw [step_run hl]
    simp only [effects_noteEnded, runJob, recResume, effects]
    split
    · rename_i g hpc
      simp only [camAccessDone]
      split
      · left; intro x hx
        rcases mem_recEnd (List.mem_reverse.mp hx) with h | h
        · simp at h
        · intro hk; revert h; cases x <;> simp_all [Eff.kind]
      · split
        · left; intro x hx
          rcases mem_recEnd (List.mem_reverse.mp hx) with h | h
          · simp at h
          · intro hk; revert h; cases x <;> simp_all [Eff.kind]
        · right; rename_i h; revert h; simp only [noteEnded]; wanted_cases
    · left; intro x hx
      rcases mem_camStartDone (List.mem_reverse.mp hx) with h | h
      · simp at h
      · intro hk; revert h; cases x <;> simp_all [Eff.kind]
    · left; intro x hx
      rcases mem_recEnd (List.mem_reverse.mp hx) with h | h
      · simp at h
      · intro hk; revert h; cases x <;> simp_all [Eff.kind]
    · left; intro x hx; simp at hx
  · left; intro x hx hk
    have hm := mem_step (List.mem_reverse.mp hx)
    cases e
    case run k =>
      simp only [stepKinds] at hm
      cases hl : s.jobs[k]? with
      | none => simp [hl] at hm
      | some l =>
        rw [hl] at hm
        cases l <;> (try exact he ⟨k, rfl, hl⟩) <;> cases x <;> simp_all [Eff.kind, jobKinds]
    all_goals (cases x <;> simp_all [Eff.kind, stepKinds, handleKinds])

/-- Camera frames reach the call only from the camera's frame callback, while the app wants the
camera, the service asked for frames, and nothing is being presented. Holds in every state. -/
theorem cameraFrames_gated (s : S) (e : Ev) (k : Nat) (h : .sendFrame (.camera k) ∈ effects (step s e)) :
    jobOf s e = some (.camFrame k) ∧ wanted s = true ∧ s.camSends = true ∧ s.presenting = false := by
  have hm := mem_step (List.mem_reverse.mp h)
  cases e <;> simp [Eff.kind, stepKinds, handleKinds] at hm
  rename_i k'
  cases hl : s.jobs[k']? with
  | none => simp [hl] at hm
  | some l =>
    rw [hl] at hm
    cases l <;> simp [jobKinds] at hm
    rename_i k''
    rw [step_run hl] at h
    simp only [effects_noteEnded, effects, runJob, camFrame] at h
    simp only [jobOf, hl]
    revert h
    split
    · simp
    · split <;> wanted_cases

-- ## Screen sharing

theorem stream_capBegin : ((capBegin i s).caps x).stream = (s.caps x).stream := by
  simp only [capBegin, setCap, upd_apply]; split <;> simp_all

/-- **T2 (frames)**: a frame of share `i` is submitted only if `i` is the current share. With at
most 2^64 shares made (`capNext ≤ 2^64`); `Wrap.t2Frames_wrap` shows the bound is needed. -/
theorem t2Frames_holds (hr : Reach s) (hb : s.capNext ≤ 2 ^ 64) (e : Ev) : t2Frames s e (step s e) = true := by
  have hi := ShareInv.reach hr
  simp only [t2Frames, List.all_eq_true]
  intro x hx
  split
  · rename_i i
    have hm := mem_step (List.mem_reverse.mp hx)
    cases e <;> simp [Eff.kind, stepKinds, handleKinds] at hm
    rename_i k
    cases hl : s.jobs[k]? with
    | none => simp [hl] at hm
    | some l =>
      rw [hl] at hm
      cases l <;> simp [jobKinds] at hm
      case scFrame i' t =>
      obtain ⟨hic, ht⟩ := jobOk_of hi hl rfl
      rw [step_run hl] at hx
      simp only [effects_noteEnded, effects, runJob, scFrame] at hx
      split at hx
      · rename_i hc
        simp [emit] at hx; subst hx
        simp only [Bool.and_eq_true] at hc
        rw [ht] at hc
        simpa using hi.current hb hic hc.1.1
      · simp at hx
  · rfl

/-- **T4 (obsolete share)**: a stream start whose continuation runs after its share was stopped
or replaced stops the stream in that same job, and does not switch presenting on. With at most
2^64 shares made. -/
theorem t4ScreenObsolete_holds (hr : Reach s) (hb : s.capNext ≤ 2 ^ 64) (e : Ev) :
    t4ScreenObsolete s e (step s e) = true := by
  have hi := ShareInv.reach hr
  unfold t4ScreenObsolete
  cases e
  all_goals try rfl
  rename_i k
  simp only [jobOf]
  cases hl : s.jobs[k]? with
  | none => rfl
  | some l =>
    cases l
    all_goals try rfl
    rename_i i cg j pt ok
    cases ok
    · rfl
    by_cases hcur : curShare s = some i
    · simp [hcur]
    · obtain ⟨hic, hpt, hoj⟩ := jobOk_of hi hl rfl
      simp only [hcur, beq_iff_eq, decide_false, Bool.false_or]
      rw [step_run hl]
      simp only [effects_noteEnded, effects, runJob, installDone, Bool.not_true, Bool.false_eq_true, ite_false]
      split
      · -- overtaken while starting: the cancel path stops it
        simp [addOp, stopStream, emit, setStream, noPresentOn, effects]
      · -- kept, but the share is obsolete: isCurrent fails on the token, capture.stop() stops it
        have hnc : isCurrent (setCap i { (jobState s k).caps i with stream := some j } (jobState s k)) pt = false := by
          simp only [isCurrent, Bool.and_eq_false_iff]
          left; left
          cases hsh : shareTokIs s pt.tok with
          | false => exact hsh
          | true =>
            rw [hpt] at hsh
            exact absurd (hi.current hb hic hsh) hcur
        simp only [hnc, Bool.not_false, ite_true]
        have hstr : ((capBegin i (setCap i { (jobState s k).caps i with stream := some j } (jobState s k))).caps i).stream = some j := by
          rw [stream_capBegin]; simp [setCap, upd_apply]
        simp only [capStop, capTeardown, hstr]
        simp [addOp, stopStream, emit, setStream, setCap, capBegin, noPresentOn, effects]

/-- An obsolete share's token never matches the share. -/
theorem obsolete_tok (hi : ShareInv s) (hb : s.capNext ≤ 2 ^ 64) (hsh : s.share = some (m, t)) (hic : i < s.capNext)
    (hne : i ≠ m) : shareTokIs s (s.caps i).tok = false := by
  cases h : shareTokIs s (s.caps i).tok with
  | false => rfl
  | true => have := hi.current hb hic h; simp [curShare, hsh] at this; exact absurd this.symm hne

/-- What T2 asks of a step caused by an obsolete share: the share and presenting are as they
were, `setPresenting` is not called, and only streams of other captures than `m` are stopped. -/
def Quiet (s s' : S) (m : Nat) : Prop :=
  s'.share = s.share ∧ s'.presenting = s.presenting ∧
  ∀ x ∈ s'.out, (∀ c p, x ≠ .svcSetPresenting c p) ∧ (∀ j, x = .scStopReq j → streamOwner s j ≠ some m)

theorem Quiet.toT2Stop (hq : Quiet s s' m) (hsh : s.share = some (m, t)) (hev : evShare s e = some i) :
    t2Stop s e s' = true := by
  obtain ⟨h1, h2, h3⟩ := hq
  unfold CallCapture.t2Stop
  rw [hev, hsh]
  simp only
  split
  · rfl
  · rw [h1, h2, hsh]
    simp only [beq_self_eq_true, Bool.true_and, List.all_eq_true, effects, List.mem_reverse]
    intro x hx
    obtain ⟨ha, hb⟩ := h3 x hx
    cases x <;> simp_all

/-- A step that changes neither the share nor presenting and requests nothing. -/
theorem Quiet.of_nothing (h1 : s'.share = s.share) (h2 : s'.presenting = s.presenting) (h3 : s'.out = []) : Quiet s s' m :=
  ⟨h1, h2, by simp [h3]⟩

theorem share_capStartAfterTeardown : (capStartAfterTeardown i cg pt s).share = s.share := by
  simp only [capStartAfterTeardown]; split <;> rfl

theorem presenting_capStartAfterTeardown : (capStartAfterTeardown i cg pt s).presenting = s.presenting := by
  simp only [capStartAfterTeardown]; split <;> rfl

theorem share_capTeardown : (capTeardown i s).1.share = s.share := by
  simp only [capTeardown]; split <;> rfl

theorem presenting_capTeardown : (capTeardown i s).1.presenting = s.presenting := by
  simp only [capTeardown]; split <;> rfl

theorem share_capStop : (capStop i s).share = s.share := by
  simp only [capStop]
  have h := share_capTeardown (i := i) (s := capBegin i s)
  split <;> rename_i heq <;> rw [heq] at h <;> exact h

theorem presenting_capStop : (capStop i s).presenting = s.presenting := by
  simp only [capStop]
  have h := presenting_capTeardown (i := i) (s := capBegin i s)
  split <;> rename_i heq <;> rw [heq] at h <;> exact h

-- ### The jobs of an obsolete share, one by one (in the state a job runs in: `out = []`)

section
variable (hi : ShareInv s) (hb : s.capNext ≤ 2 ^ 64) (hsh : s.share = some (m, t)) (hout : s.out = [])
include hi hb hsh hout

theorem quiet_capStop (hne : i ≠ m) : Quiet s (capStop i s) m := by
  refine ⟨share_capStop, presenting_capStop, ?_⟩
  intro x hx
  have hst := stream_capBegin (i := i) (s := s) (x := i)
  cases hj : (s.caps i).stream with
  | none =>
    rw [hj] at hst
    have : (capStop i s).out = s.out := by simp only [capStop, capTeardown, hst]; rfl
    rw [this, hout] at hx; cases hx
  | some j =>
    rw [hj] at hst
    have hoj := hi.capStream i j hj
    have : (capStop i s).out = [.scStopReq j] := by
      simp only [capStop, capTeardown, hst]; simp [addOp, stopStream, emit, hout, capBegin, setCap, setStream]
    rw [this] at hx
    simp only [List.mem_singleton] at hx; subst hx
    refine ⟨by simp, fun j' hj' => ?_⟩
    cases hj'; simp only [streamOwner]; simp only [owner] at hoj; rw [hoj]; simpa using hne

theorem quiet_sourcesLeaf : Quiet s (sourcesLeaf i t' g c s) m := by
  simp only [sourcesLeaf]
  split
  · exact Quiet.of_nothing rfl rfl hout
  · refine ⟨rfl, rfl, ?_⟩
    intro x hx
    simp [addOp, emit, hout] at hx
    subst hx; exact ⟨by simp, by simp⟩

theorem quiet_presentLeaf (hne : i ≠ m) (hl : JobOk s (.present i pt)) : Quiet s (presentLeaf i pt s) m := by
  obtain ⟨hic, hpt⟩ := hl
  have hnt := obsolete_tok hi hb hsh hic hne
  rw [← hpt] at hnt
  have hnc : isCurrent s pt = false := by simp [isCurrent, hnt]
  simp only [presentLeaf, hnc, Bool.not_false, ite_true]
  exact Quiet.of_nothing rfl rfl hout

theorem quiet_srcDone (hne : i ≠ m) (hl : JobOk s (.sourcesRet i t' g c ok)) : Quiet s (srcDone i t' g c ok s) m := by
  obtain ⟨hic, ht⟩ := hl
  have hnt := obsolete_tok hi hb hsh hic hne
  rw [← ht] at hnt
  simp only [srcDone]
  split
  · have hnc : isCurrent (setCap i { s.caps i with content := true } s) ⟨t', g, c⟩ = false := by
      simp only [isCurrent, shareTokIs, setCap, hsh] at hnt ⊢; simp [hnt]
    simp only [hnc, Bool.false_eq_true, ite_false]
    exact Quiet.of_nothing rfl rfl hout
  · simp only [hnt, Bool.false_eq_true, ite_false]
    exact Quiet.of_nothing rfl rfl hout

theorem quiet_installDone (hne : i ≠ m) (hl : JobOk s (.installRet i cg j pt ok)) : Quiet s (installDone i cg j pt ok s) m := by
  obtain ⟨hic, hpt, hoj⟩ := hl
  have hnt := obsolete_tok hi hb hsh hic hne
  rw [← hpt] at hnt
  have hjm : streamOwner s j ≠ some m := by
    simp only [streamOwner]; simp only [owner] at hoj; rw [hoj]; simpa using hne
  simp only [installDone]
  split
  · simp only [hnt, Bool.false_eq_true, ite_false]
    exact Quiet.of_nothing rfl rfl hout
  · split
    · -- overtaken: the cancel path stops stream j (capture i's)
      refine ⟨by simp [addOp, stopStream, emit, setStream], by simp [addOp, stopStream, emit, setStream], ?_⟩
      intro x hx
      simp [addOp, stopStream, emit, setStream, hout] at hx
      subst hx
      exact ⟨by simp, fun j' hj' => by cases hj'; exact hjm⟩
    · -- kept, but obsolete: isCurrent fails on the token and capture.stop() stops stream j
      have hnc : isCurrent (setCap i { s.caps i with stream := some j } s) pt = false := by
        simp only [isCurrent, shareTokIs, setCap, hsh] at hnt ⊢; simp [hnt]
      simp only [hnc, Bool.not_false, ite_true]
      have hstr : ((capBegin i (setCap i { s.caps i with stream := some j } s)).caps i).stream = some j := by
        rw [stream_capBegin]; simp [setCap, upd_apply]
      simp only [capStop, capTeardown, hstr]
      refine ⟨by simp [addOp, stopStream, emit, setStream, setCap, capBegin],
              by simp [addOp, stopStream, emit, setStream, setCap, capBegin], ?_⟩
      intro x hx
      simp [addOp, stopStream, emit, setStream, setCap, capBegin, hout] at hx
      subst hx
      exact ⟨by simp, fun j' hj' => by cases hj'; exact hjm⟩

theorem quiet_teardownRet : Quiet s (capStartAfterTeardown i cg pt s) m := by
  refine ⟨share_capStartAfterTeardown, presenting_capStartAfterTeardown, ?_⟩
  intro x hx
  rcases mem_capStartAfterTeardown hx with h | h
  · simp [hout] at h
  · refine ⟨fun c p hc => ?_, fun j' hj' => ?_⟩
    · subst hc; cases p <;> simp [Eff.kind] at h
    · subst hj'; simp [Eff.kind] at h

theorem quiet_scFrame (hne : i ≠ m) (hl : JobOk s (.scFrame i t')) : Quiet s (scFrame i t' s) m := by
  obtain ⟨hic, ht⟩ := hl
  have hnt := obsolete_tok hi hb hsh hic hne
  rw [← ht] at hnt
  simp only [scFrame, hnt, Bool.false_and, Bool.false_eq_true, ite_false]
  exact Quiet.of_nothing rfl rfl hout

theorem quiet_scStopped (hne : i ≠ m) (hl : JobOk s (.scStopped i t')) : Quiet s (scStopped t' s) m := by
  obtain ⟨hic, ht⟩ := hl
  have hnt := obsolete_tok hi hb hsh hic hne
  rw [← ht] at hnt
  simp only [scStopped, hnt, Bool.false_eq_true, ite_false]
  exact Quiet.of_nothing rfl rfl hout

end

-- ### The environment's events about a share change neither the share nor presenting

theorem share_srcEnv : (srcEnv i ok s).share = s.share := by simp only [srcEnv]; split <;> rfl
theorem presenting_srcEnv : (srcEnv i ok s).presenting = s.presenting := by simp only [srcEnv]; split <;> rfl
theorem share_scStartEnv : (scStartEnv j ok s).share = s.share := by simp only [scStartEnv]; split <;> rfl
theorem presenting_scStartEnv : (scStartEnv j ok s).presenting = s.presenting := by simp only [scStartEnv]; split <;> rfl
theorem share_scStopEnv : (scStopEnv j ok s).share = s.share := by simp only [scStopEnv]; split <;> (try split) <;> rfl
theorem presenting_scStopEnv : (scStopEnv j ok s).presenting = s.presenting := by
  simp only [scStopEnv]; split <;> (try split) <;> rfl
theorem share_scFrameEnv : (scFrameEnv j s).share = s.share := by simp only [scFrameEnv]; (repeat' split) <;> rfl
theorem presenting_scFrameEnv : (scFrameEnv j s).presenting = s.presenting := by simp only [scFrameEnv]; (repeat' split) <;> rfl
theorem share_scStoppedEnv : (scStoppedEnv j s).share = s.share := by simp only [scStoppedEnv]; (repeat' split) <;> rfl
theorem presenting_scStoppedEnv : (scStoppedEnv j s).presenting = s.presenting := by
  simp only [scStoppedEnv]; (repeat' split) <;> rfl

/-- **T2 (stopping)**: a step that belongs to an obsolete share (a device event of its streams
or sources, or any job carrying it: its tasks, the continuations of its awaits, its frame and
stop callbacks) leaves the current share and presenting as they are, never calls
`setPresenting`, and stops only streams of other captures. With at most 2^64 shares made. -/
theorem t2Stop_holds (hr : Reach s) (hb : s.capNext ≤ 2 ^ 64) (e : Ev) : t2Stop s e (step s e) = true := by
  have hi := ShareInv.reach hr
  cases hev : evShare s e with
  | none => simp [t2Stop, hev]
  | some i =>
    cases hsh : s.share with
    | none => simp [t2Stop, hev, hsh]
    | some p =>
      obtain ⟨m, t⟩ := p
      by_cases hne : i = m
      · unfold t2Stop; rw [hev, hsh]; simp [hne]
      · apply Quiet.toT2Stop (i := i) _ hsh hev
        cases e
        case run k =>
          cases hl : s.jobs[k]? with
          | none => simp [evShare, hl] at hev
          | some l =>
            rw [step_run hl]
            have hj := hi.jobState (k := k)
            have hsh' : (jobState s k).share = some (m, t) := hsh
            have hb' : (jobState s k).capNext ≤ 2 ^ 64 := hb
            show Quiet (jobState s k) (runJob l (jobState s k)) m
            cases l <;> simp only [evShare, hl, Option.some.injEq, reduceCtorEq] at hev
            case capStop i' => subst hev; exact quiet_capStop hj hb' hsh' rfl hne
            case sources i' t' g c => subst hev; exact quiet_sourcesLeaf hj hb' hsh' rfl
            case present i' pt => subst hev; exact quiet_presentLeaf hj hb' hsh' rfl hne (jobOk_of hi hl rfl)
            case sourcesRet i' t' g c ok => subst hev; exact quiet_srcDone hj hb' hsh' rfl hne (jobOk_of hi hl rfl)
            case installRet i' cg j pt ok => subst hev; exact quiet_installDone hj hb' hsh' rfl hne (jobOk_of hi hl rfl)
            case teardownRet i' cg j pt => exact quiet_teardownRet hj hb' hsh' rfl
            case scFrame i' t' => subst hev; exact quiet_scFrame hj hb' hsh' rfl hne (jobOk_of hi hl rfl)
            case scStopped i' t' => subst hev; exact quiet_scStopped hj hb' hsh' rfl hne (jobOk_of hi hl rfl)
            case stopRet j => exact Quiet.of_nothing rfl rfl rfl
        all_goals simp only [evShare, reduceCtorEq] at hev
        all_goals
          simp only [step, stepCore, handle]
          first
            | exact Quiet.of_nothing share_srcEnv presenting_srcEnv out_srcEnv
            | exact Quiet.of_nothing share_scStartEnv presenting_scStartEnv out_scStartEnv
            | exact Quiet.of_nothing share_scStopEnv presenting_scStopEnv out_scStopEnv
            | exact Quiet.of_nothing share_scFrameEnv presenting_scFrameEnv out_scFrameEnv
            | exact Quiet.of_nothing share_scStoppedEnv presenting_scStoppedEnv out_scStoppedEnv

end CallCapture
