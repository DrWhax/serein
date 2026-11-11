import Queue.Model

/-! # The properties -/

namespace Queue

/-- **Shutdown's postcondition**: when a `stopAndWait` returns, no loop exists: no handler is
running, and nothing of the loop (selecting the next job, finishing one) is pending. -/
def shutdownClean (s : S) (_e : Ev) (s' : S) : Bool :=
  s'.returned.length == s.returned.length || s'.loop == none

/-- **No restart while draining**: `start()` changes nothing while a `stopAndWait` is pending. -/
def noRestartWhileDraining (s : S) (e : Ev) (s' : S) : Bool :=
  match e with
  | .start => s.draining == 0 || s' == s
  | _ => true

/-- **Only the loop finishes jobs, one at a time**: a step finishes at most one job, and only the
one whose handler returned. -/
def oneAtATime (s : S) (e : Ev) (s' : S) : Bool :=
  s'.done.length ≤ s.done.length + 1 &&
  (s'.done.length == s.done.length || match e, s.loop with
    | .runLoop, some (.after j _) => s'.done == s.done ++ [j]
    | _, _ => false)

def stepChecks : List (String × (S → Ev → S → Bool)) :=
  [("shutdown-clean", shutdownClean), ("no-restart-while-draining", noRestartWhileDraining), ("one-at-a-time", oneAtATime)]

end Queue
