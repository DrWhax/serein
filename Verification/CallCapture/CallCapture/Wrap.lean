import CallCapture.Counterexamples
import CallCapture.Proofs

/-!
# Token wrap-around: the `capNext ≤ 2^64` bound is needed

`lastScreenShareToken` is a `UInt64` bumped with `&+=` for every share. After 2^64 shares the
token sequence repeats, and nothing else tells two shares apart: `isCurrentScreenShare` and
`screenFrame` compare tokens. This file builds the reachable state: in a call, share 0's sources
have loaded and a source was picked, but the pick's task has not started; the share button is
then pressed 2^64 times (each press drops the share before it, cancelling its capture, and makes
a new one, as nothing is presenting). Now the newest share, number 2^64, has share 0's token.
Share 0's pick task runs: the token check passes, so it starts a stream of share 0's capture;
the stream starts and is presented (T4 for obsolete shares fails); a frame of it is sent (T2
fails). The construction is symbolic: the 2^64 steps are never evaluated.
-/

namespace CallCapture

/-- In a call, share 0's sources loaded and a source picked; the pick's task not started
(`open.0.0 run.0 start run.0 setup.0.1 run.0 run.0 toggle run.0 src.0.1 run.0 pick`). -/
def wrapPre : List Ev :=
  [.openLobby 0 false, .run 0, .startCall, .run 0, .setupDone 0 true, .run 0, .run 0, .toggleShare, .run 0,
   .srcDone 0 true, .run 0, .pickSource]

def S7 : S := run (S.init {}) wrapPre

def A0 : ACall := ⟨0, .inCall, some .prering, true, 0, true, some 0⟩
def pt0 : PT := ⟨1, 0, 0⟩

theorem S7_active : S7.active = some A0 := by decide
theorem S7_presenting : S7.presenting = false := by decide
theorem S7_gen : S7.gen = 0 := by decide
theorem S7_capNext : S7.capNext = 1 := by decide
theorem S7_lastTok : S7.lastTok = 1 := by decide
theorem S7_share : S7.share = some (0, 1) := by decide
theorem S7_jobs : S7.jobs = [.present 0 pt0] := by decide
theorem S7_cap0 : S7.caps 0 = ⟨1, 0, none, true, 0⟩ := by decide
theorem S7_ncall : S7.ncall = some ⟨0, 0, .prering, false, false, false⟩ := by decide
theorem S7_ops : S7.ops = [] := by decide
theorem S7_streamNext : S7.streamNext = 0 := by decide
theorem S7_outOff : S7.outOff 0 = false := by decide

-- ## One press of the share button, while nothing is presented

theorem step_toggle (ha : s.active = some a) (hp : s.presenting = false) (hs : s.share = some (m, tk)) :
    (step s .toggleShare).active = s.active ∧ (step s .toggleShare).presenting = false ∧
    (step s .toggleShare).gen = s.gen ∧ (step s .toggleShare).ncall = s.ncall ∧
    (step s .toggleShare).capNext = s.capNext + 1 ∧ (step s .toggleShare).lastTok = s.lastTok + 1 ∧
    (step s .toggleShare).share = some (s.capNext, s.lastTok + 1) ∧
    (∀ x, x ≠ s.capNext → ((step s .toggleShare).caps x).tok = (s.caps x).tok ∧
        ((step s .toggleShare).caps x).content = (s.caps x).content ∧ ((step s .toggleShare).caps x).stream = (s.caps x).stream) ∧
    (step s .toggleShare).jobs = s.jobs ++ [.capStop m, .sources s.capNext (s.lastTok + 1) s.gen a.conv] ∧
    (step s .toggleShare).ops = s.ops ∧ (step s .toggleShare).streamNext = s.streamNext ∧
    (step s .toggleShare).streams = s.streams ∧ (step s .toggleShare).outOff = s.outOff := by
  simp only [step, stepCore, noteEnded, handle, toggleShare, ha, hp, Bool.false_eq_true, ite_false, clearShare, hs]
  refine ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, fun x hx => ?_, by simp [spawn, capBegin, setCap], rfl, rfl, rfl, rfl⟩
  simp only [spawn, capBegin, setCap, upd_apply]
  split
  · omega
  · split <;> simp_all

/-- What `k` presses keep and change. -/
structure Pressed (s0 : S) (k : Nat) (t : S) : Prop where
  active : t.active = s0.active
  presenting : t.presenting = false
  gen : t.gen = s0.gen
  ncall : t.ncall = s0.ncall
  capNext : t.capNext = s0.capNext + k
  lastTok : t.lastTok = s0.lastTok + UInt64.ofNat k
  share : ∃ m, t.share = some (m, t.lastTok) ∧ (0 < k → m = s0.capNext + k - 1)
  cap0 : (t.caps 0).tok = (s0.caps 0).tok ∧ (t.caps 0).content = (s0.caps 0).content ∧ (t.caps 0).stream = (s0.caps 0).stream
  jobs : ∃ extra, t.jobs = s0.jobs ++ extra ∧ extra.length = 2 * k
  ops : t.ops = s0.ops
  streamNext : t.streamNext = s0.streamNext
  streams : t.streams = s0.streams
  outOff : t.outOff = s0.outOff

theorem run_replicate_succ : run s (List.replicate (k + 1) e) = step (run s (List.replicate k e)) e := by
  induction k generalizing s with
  | zero => rfl
  | succ k ih => simp only [List.replicate_succ, run] at ih ⊢; exact ih

theorem pressed (ha : s0.active = some a) (hp : s0.presenting = false) (hc : 0 < s0.capNext)
    (hs : s0.share = some (m0, s0.lastTok)) : ∀ k, Pressed s0 k (run s0 (List.replicate k .toggleShare)) := by
  intro k
  induction k with
  | zero =>
    exact ⟨rfl, hp, rfl, rfl, rfl, by simp [run], ⟨m0, by simpa [run] using hs, fun h => absurd h (by omega)⟩,
           ⟨rfl, rfl, rfl⟩, ⟨[], by simp [run]⟩, rfl, rfl, rfl, rfl⟩
  | succ k ih =>
    rw [run_replicate_succ]
    generalize hr : run s0 (List.replicate k .toggleShare) = r at ih
    have ha' : r.active = some a := by rw [ih.active, ha]
    obtain ⟨m, hm, -⟩ := ih.share
    obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, h11, h12, h13⟩ := step_toggle ha' ih.presenting hm
    obtain ⟨extra, hjobs, hlen⟩ := ih.jobs
    have h0 : 0 ≠ r.capNext := by rw [ih.capNext]; omega
    obtain ⟨c1, c2, c3⟩ := h8 0 h0
    refine ⟨by rw [h1, ih.active], h2, by rw [h3, ih.gen], by rw [h4, ih.ncall], by rw [h5, ih.capNext]; omega, ?_,
      ⟨r.capNext, by rw [h7, h6], fun _ => by rw [ih.capNext]; omega⟩,
      ⟨by rw [c1, ih.cap0.1], by rw [c2, ih.cap0.2.1], by rw [c3, ih.cap0.2.2]⟩,
      ⟨extra ++ [.capStop m, .sources r.capNext (r.lastTok + 1) r.gen a.conv], by rw [h9, hjobs, List.append_assoc],
       by simp [hlen]; omega⟩,
      by rw [h10, ih.ops], by rw [h11, ih.streamNext], by rw [h12, ih.streams], by rw [h13, ih.outOff]⟩
    rw [h6, ih.lastTok, UInt64.ofNat_add, UInt64.ofNat_one, UInt64.add_assoc]

-- ## 2^64 presses later

/-- Irreducible: nothing may evaluate the 2^64 steps; `T_pressed` is all that is known of it. -/
@[irreducible] noncomputable def T : S := run S7 (List.replicate (2 ^ 64) .toggleShare)

theorem T_pressed : Pressed S7 (2 ^ 64) T := by
  unfold T
  exact pressed S7_active S7_presenting (by rw [S7_capNext]; decide) (by rw [S7_share, S7_lastTok]) (2 ^ 64)

theorem T_reach : Reach T := by unfold T; exact reach_run (reach_run (Reach.init {}))

theorem presenting_svcSetPresenting_on (h : hasCall s c = true) : (svcSetPresenting (some c) true s).presenting = true := by
  have h' : hasCall (emit (.svcSetPresenting (some c) true) s) c = true := h
  simp only [svcSetPresenting, h', ite_true]; rfl

theorem active_svcSetPresenting : (svcSetPresenting c p s).active = s.active := by
  simp only [svcSetPresenting]; repeat' split
  all_goals rfl

theorem caps_svcSetPresenting : (svcSetPresenting c p s).caps = s.caps := by
  simp only [svcSetPresenting]; repeat' split
  all_goals rfl

theorem streams_svcSetPresenting : (svcSetPresenting c p s).streams = s.streams := by
  simp only [svcSetPresenting]; repeat' split
  all_goals rfl

theorem outOff_svcSetPresenting : (svcSetPresenting c p s).outOff = s.outOff := by
  simp only [svcSetPresenting]; repeat' split
  all_goals rfl

theorem jobs_svcSetPresenting : ∃ more, (svcSetPresenting c p s).jobs = s.jobs ++ more := by
  simp only [svcSetPresenting]; repeat' split
  all_goals first | exact ⟨[_], rfl⟩ | exact ⟨[], (List.append_nil _).symm⟩

-- ## The last steps, for any state reached that way
--
-- Everything below is stated for an arbitrary `t` with `Pressed S7 (2^64) t`, never for `T`
-- itself: the kernel ignores `@[irreducible]`, and comparing `{ T with … }` against `T` would
-- make it evaluate the 2^64 steps.

section
variable {t : S} (ht : Pressed S7 (2 ^ 64) t)
include ht

theorem w_share : t.share = some (2 ^ 64, 1) := by
  obtain ⟨m, hm, hk⟩ := ht.share
  rw [hm, ht.lastTok, S7_lastTok, hk (by decide), S7_capNext]; decide

theorem w_jobs : ∃ extra, t.jobs = .present 0 pt0 :: extra ∧ extra.length = 2 * 2 ^ 64 := by
  obtain ⟨extra, h, hl⟩ := ht.jobs
  exact ⟨extra, by rw [h, S7_jobs]; rfl, hl⟩

theorem w_cap0 : (t.caps 0).tok = 1 ∧ (t.caps 0).content = true ∧ (t.caps 0).stream = none := by
  obtain ⟨a, b, c⟩ := ht.cap0
  rw [S7_cap0] at a b c
  exact ⟨a, b, c⟩

/-- Share 0's pick task, after the presses: its token matches the current share, so it starts
a stream (number 0) of share 0's capture. -/
theorem w_present : ∃ cg extra,
    (step t (.run 0)).ops = [.install 0 cg 0 pt0] ∧ ((step t (.run 0)).caps 0).gen = cg ∧
    ((step t (.run 0)).caps 0).tok = 1 ∧ (step t (.run 0)).outOff 0 = false ∧
    (step t (.run 0)).share = some (2 ^ 64, 1) ∧ (step t (.run 0)).active = some A0 ∧ (step t (.run 0)).gen = 0 ∧
    (step t (.run 0)).ncall = S7.ncall ∧ (step t (.run 0)).jobs = extra ∧ extra.length = 2 * 2 ^ 64 := by
  obtain ⟨extra, hj, hl⟩ := w_jobs ht
  have hl0 : t.jobs[0]? = some (.present 0 pt0) := by rw [hj]; rfl
  obtain ⟨c1, c2, c3⟩ := w_cap0 ht
  have hsh := w_share ht
  have hcur : isCurrent (jobState t 0) pt0 = true := by
    simp [isCurrent, shareTokIs, hsh, pt0, ht.gen, S7_gen, ht.active, S7_active, A0]
  have hcon : ((jobState t 0).caps 0).content = true := c2
  have hstr : ((capBegin 0 (jobState t 0)).caps 0).stream = none := by rw [stream_capBegin]; exact c3
  have hsn : t.streamNext = 0 := by rw [ht.streamNext, S7_streamNext]
  refine ⟨((t.caps 0).gen + 1), extra, ?_⟩
  rw [step_run hl0]
  simp only [runJob, presentLeaf, hcur, Bool.not_true, Bool.false_eq_true, ite_false, hcon, ite_true, capStart, capTeardown, hstr,
    capStartAfterTeardown]
  simp [noteEnded, addOp, emit, setStream, capBegin, setCap, upd_apply, hsn, ht.ops, S7_ops, c1, c2, ht.outOff, S7_outOff,
        hsh, ht.active, S7_active, ht.gen, S7_gen, ht.ncall, hj, hl]

end

section
variable {p : S} {cg : UInt64} {extra : List Job}
  (hops : p.ops = [.install 0 cg 0 pt0]) (hgen : (p.caps 0).gen = cg) (htok : (p.caps 0).tok = 1)
  (hoff : p.outOff 0 = false) (hsh : p.share = some (2 ^ 64, 1)) (ha : p.active = some A0) (hg : p.gen = 0)
  (hn : p.ncall = S7.ncall) (hjobs : p.jobs = extra) (hlen : extra.length = 2 * 2 ^ 64)
include hops hgen htok hoff hsh ha hg hn hjobs hlen

/-- The stream finishes starting: its continuation is the job after all the presses' jobs. -/
theorem w_started : (step p (.scStartDone 0 true)).jobs = extra ++ [.installRet 0 cg 0 pt0 true] ∧
    (step p (.scStartDone 0 true)).share = some (2 ^ 64, 1) ∧ (step p (.scStartDone 0 true)).active = some A0 ∧
    (step p (.scStartDone 0 true)).gen = 0 ∧ ((step p (.scStartDone 0 true)).caps 0).gen = cg ∧
    ((step p (.scStartDone 0 true)).caps 0).tok = 1 ∧ (step p (.scStartDone 0 true)).ncall = S7.ncall ∧
    (step p (.scStartDone 0 true)).streams 0 = some (0, .running) ∧ (step p (.scStartDone 0 true)).outOff 0 = false := by
  have hf : findInstall 0 p.ops = some (0, cg, pt0) := by simp [hops, findInstall]
  have hd : (dropOp (.install 0 cg 0 pt0) { p with out := [] }).ops = [] := by
    simp only [dropOp, hops, List.erase_cons_head]
  simp only [step, stepCore, noteEnded, handle, scStartEnv]
  rw [show ({ p with out := [] } : S).ops = p.ops from rfl, hf]
  simp only [spawn, setStream, dropOp, upd_apply, if_pos]
  simp [hjobs, hsh, ha, hg, hgen, htok, hn, hoff]

theorem w_index : (step p (.scStartDone 0 true)).jobs[2 * 2 ^ 64]? = some (.installRet 0 cg 0 pt0 true) := by
  rw [(w_started hops hgen htok hoff hsh ha hg hn hjobs hlen).1, List.getElem?_append_right (by omega)]; simp [hlen]

/-- …and its continuation keeps share 0's stream and presents it. -/
theorem w_kept : step (step p (.scStartDone 0 true)) (.run (2 * 2 ^ 64)) =
    noteEnded (step p (.scStartDone 0 true))
      (svcSetPresenting (some 0) true (setCap 0 { ((jobState (step p (.scStartDone 0 true)) (2 * 2 ^ 64)).caps 0) with stream := some 0 }
        (jobState (step p (.scStartDone 0 true)) (2 * 2 ^ 64)))) := by
  obtain ⟨-, hsh2, ha2, hg2, hgen2, -, -, -, -⟩ := w_started hops hgen htok hoff hsh ha hg hn hjobs hlen
  rw [step_run (w_index hops hgen htok hoff hsh ha hg hn hjobs hlen)]
  simp only [runJob, installDone, Bool.not_true, Bool.false_eq_true, ite_false]
  generalize hp1 : step p (.scStartDone 0 true) = p1 at hsh2 ha2 hg2 hgen2 ⊢
  have hcg : (cg != (p1.caps 0).gen) = false := by simp [hgen2]
  simp only [hcg, Bool.false_eq_true, ite_false]
  split
  · rename_i h
    simp [isCurrent, shareTokIs, setCap, jobState, hsh2, hg2, ha2, pt0, A0] at h
  · rfl

/-- **T4 for obsolete shares fails at 2^64 shares**: share 0 is obsolete (the current share is
number 2^64), yet its stream is kept and presented, and nothing is stopped. -/
theorem w_t4 : t4ScreenObsolete (step p (.scStartDone 0 true)) (.run (2 * 2 ^ 64))
    (step (step p (.scStartDone 0 true)) (.run (2 * 2 ^ 64))) = false := by
  obtain ⟨-, hsh2, -, -, -, -, -, -, -⟩ := w_started hops hgen htok hoff hsh ha hg hn hjobs hlen
  rw [w_kept hops hgen htok hoff hsh ha hg hn hjobs hlen]
  simp [t4ScreenObsolete, jobOf, w_index hops hgen htok hoff hsh ha hg hn hjobs hlen, curShare, hsh2, effects, out_svcSetPresenting,
        setCap, noPresentOn, noteEnded]

/-- Then a frame of that stream hops to the main actor and is sent while share 2^64 is current. -/
theorem w_t2 : ∃ k, t2Frames (step (step (step p (.scStartDone 0 true)) (.run (2 * 2 ^ 64))) (.scFrame 0)) (.run k)
    (step (step (step (step p (.scStartDone 0 true)) (.run (2 * 2 ^ 64))) (.scFrame 0)) (.run k)) = false := by
  obtain ⟨hj1, hsh2, ha2, -, -, htok2, hn2, hst2, hoff2⟩ := w_started hops hgen htok hoff hsh ha hg hn hjobs hlen
  have hk := w_kept hops hgen htok hoff hsh ha hg hn hjobs hlen
  generalize hq0 : step (step p (.scStartDone 0 true)) (.run (2 * 2 ^ 64)) = q0 at hk ⊢
  generalize hp1 : step p (.scStartDone 0 true) = p1 at hk hj1 hsh2 ha2 htok2 hn2 hst2 hoff2
  -- the state after presenting
  have hpres : q0.presenting = true := by
    rw [hk]; show (svcSetPresenting (some 0) true _).presenting = true
    apply presenting_svcSetPresenting_on
    simp [hasCall, setCap, jobState, hn2, S7_ncall]
  have hshare : q0.share = some (2 ^ 64, 1) := by
    rw [hk]; show (svcSetPresenting (some 0) true _).share = _
    rw [share_svcSetPresenting]; simp [setCap, jobState, hsh2]
  have hlive : activeLive q0 = true := by
    rw [hk]; show activeLive (svcSetPresenting (some 0) true _) = true
    simp only [activeLive, active_svcSetPresenting]; simp [setCap, jobState, ha2, A0]
  have hst : q0.streams 0 = some (0, .running) := by
    rw [hk]; show (svcSetPresenting (some 0) true _).streams 0 = _
    rw [streams_svcSetPresenting]; simp [setCap, jobState, hst2]
  have hoff3 : q0.outOff 0 = false := by
    rw [hk]; show (svcSetPresenting (some 0) true _).outOff 0 = _
    rw [outOff_svcSetPresenting]; simp [setCap, jobState, hoff2]
  have htok3 : (q0.caps 0).tok = 1 := by
    rw [hk]; show ((svcSetPresenting (some 0) true _).caps 0).tok = _
    rw [caps_svcSetPresenting]; simp [setCap, jobState, upd_apply, htok2]
  obtain ⟨more, hm⟩ := jobs_svcSetPresenting (c := some 0) (p := true)
    (s := setCap 0 { ((jobState p1 (2 * 2 ^ 64)).caps 0) with stream := some 0 } (jobState p1 (2 * 2 ^ 64)))
  have hq0jobs : q0.jobs = extra ++ more := by
    rw [hk]; show (svcSetPresenting (some 0) true _).jobs = _
    rw [hm]; show (p1.jobs.eraseIdx (2 * 2 ^ 64)) ++ more = _
    rw [hj1, List.eraseIdx_append_of_length_le (by omega)]; simp [hlen]
  -- the frame's hop is the last job
  have hq : (step q0 (.scFrame 0)).jobs = extra ++ more ++ [.scFrame 0 1] ∧ (step q0 (.scFrame 0)).share = some (2 ^ 64, 1) ∧
      (step q0 (.scFrame 0)).presenting = true ∧ activeLive (step q0 (.scFrame 0)) = true := by
    simp only [step, stepCore, noteEnded, handle, scFrameEnv, hst, hoff3, SPh.hasRun]
    simp [spawn, hq0jobs, htok3, hshare, hpres]
    simpa [activeLive] using hlive
  generalize hq1 : step q0 (.scFrame 0) = q at hq ⊢
  obtain ⟨hqj, hqs, hqp, hql⟩ := hq
  refine ⟨(extra ++ more).length, ?_⟩
  have hl : q.jobs[(extra ++ more).length]? = some (.scFrame 0 1) := by rw [hqj]; simp
  rw [step_run hl]
  simp only [t2Frames, effects, runJob, scFrame]
  have hc : (shareTokIs (jobState q (extra ++ more).length) 1 && (jobState q (extra ++ more).length).presenting &&
      activeLive (jobState q (extra ++ more).length)) = true := by
    simp only [Bool.and_eq_true]
    exact ⟨⟨by simp [shareTokIs, jobState, hqs], hqp⟩, hql⟩
  simp only [hc, ite_true]
  simp [emit, curShare, hqs, noteEnded]

end

/-- The state after share 0's pick task ran, with what the last steps need. -/
theorem w_after : ∃ cg extra, Reach (step T (.run 0)) ∧ (step T (.run 0)).ops = [.install 0 cg 0 pt0] ∧
    ((step T (.run 0)).caps 0).gen = cg ∧ ((step T (.run 0)).caps 0).tok = 1 ∧ (step T (.run 0)).outOff 0 = false ∧
    (step T (.run 0)).share = some (2 ^ 64, 1) ∧ (step T (.run 0)).active = some A0 ∧ (step T (.run 0)).gen = 0 ∧
    (step T (.run 0)).ncall = S7.ncall ∧ (step T (.run 0)).jobs = extra ∧ extra.length = 2 * 2 ^ 64 := by
  obtain ⟨cg, extra, h⟩ := w_present T_pressed
  exact ⟨cg, extra, Reach.step _ T_reach, h⟩

theorem t4ScreenObsolete_wrap : ¬ ∀ s e, Reach s → t4ScreenObsolete s e (step s e) = true := by
  intro hall
  obtain ⟨cg, extra, hr, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10⟩ := w_after
  have h := hall _ (.run (2 * 2 ^ 64)) (Reach.step (.scStartDone 0 true) hr)
  rw [w_t4 h1 h2 h3 h4 h5 h6 h7 h8 h9 h10] at h; cases h

/-- **T2 fails at 2^64 shares**: a frame of share 0 is sent while share 2^64 is current. -/
theorem t2Frames_wrap : ¬ ∀ s e, Reach s → t2Frames s e (step s e) = true := by
  intro hall
  obtain ⟨cg, extra, hr, h1, h2, h3, h4, h5, h6, h7, h8, h9, h10⟩ := w_after
  obtain ⟨k, hk⟩ := w_t2 h1 h2 h3 h4 h5 h6 h7 h8 h9 h10
  have h := hall _ (.run k) (Reach.step (.scFrame 0) (Reach.step (.run (2 * 2 ^ 64)) (Reach.step (.scStartDone 0 true) hr)))
  rw [hk] at h; cases h

end CallCapture
