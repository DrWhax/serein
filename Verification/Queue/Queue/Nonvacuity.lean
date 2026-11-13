import Queue.Props
namespace Queue.Nonvacuity
def candidate (s : S) (e : Ev) : S := step s e
private def finished : S := run (S.init [7]) [.start, .runLoop, .handlerReturns .ok]
example : (candidate finished .runLoop).done = [7] := by decide
private def draining : S := step (S.init []) .stopAndWait
example : (candidate draining (.runReturn 0)).returned = [0] := by decide
-- Scheduler events alone do not imply progress: this event is disabled forever here.
theorem stuttering_drain (n : Nat) : run draining (List.replicate n Ev.runLoop) = draining := by
  induction n with
  | zero => rfl
  | succ n ih => simpa [List.replicate_succ, run, draining, step, stopAndWait, stop, S.init] using ih
example : draining.returns = [0] := by decide
-- This safety predicate alone accepts a missing successful action. The positive assertions
-- above are intentionally independent and must fail for that mutant.
example : shutdownClean draining (.runReturn 0) draining = true := by decide
end Queue.Nonvacuity
