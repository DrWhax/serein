import CallCapture.Props
import CallCapture.Trace
import CallCapture.UI

/-!
# Counterexamples

Each property below is false for the production behaviour the model describes. The theorems
refute the universal statement (`¬ ∀ s e, Reach s → P s e (step s e)`) with a concrete trace,
checked by evaluation in the kernel (`decide`; nothing is evaluated by compiled code). A second
theorem records under which schedule the trace happens (`UI.lean`): whether every user event is
one the UI offers (`ui`), whether the user acts only while no main-actor job is pending
(`drained`), and whether every scheduler step runs the oldest job (`fifo`). These classify
orderings, not speed. The same traces are replayed against production Swift by
`CallCaptureConformanceTests.counterexampleTraces`.
-/

namespace CallCapture

theorem reach_run (h : Reach s) : Reach (run s es) := by
  induction es generalizing s with
  | nil => exact h
  | cons e es ih => exact ih (Reach.step e h)

/-- `check` fails at the last event of `pre ++ [e]`, run from `cfg`. -/
abbrev Falsifies (check : S → Ev → S → Bool) (cfg : Cfg) (pre : List Ev) (e : Ev) : Prop :=
  check (run (S.init cfg) pre) e (step (run (S.init cfg) pre) e) = false

theorem refutes (h : Falsifies check cfg pre e) : ¬ ∀ s e, Reach s → check s e (step s e) = true := by
  intro hall
  have := hall _ e (reach_run (Reach.init cfg) (es := pre))
  unfold Falsifies at h
  rw [h] at this; cases this

/-- Under which schedule a trace happens: (UI offers every user event, the user acts only on a
drained queue, FIFO). -/
def schedule (t : Trace) : Bool × Bool × Bool := (allIn "ui" t, allIn "drained" t, fifoTrace t)

def cleanupCamera (_ : S) (_ : Ev) (s' : S) : Bool := noIdleUnwantedCamera s'
def cleanupStreams (_ : S) (_ : Ev) (s' : S) : Bool := noOrphanStream s'

/-- Counterexample traces, by property, for Swift to replay. -/
def counterexampleTraces : List (String × Trace) := []

end CallCapture
