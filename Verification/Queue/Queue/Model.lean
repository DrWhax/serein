/-!
# The job queue: ownership and shutdown

A model of SignalCore's `JobQueue` actor: its run loop (`run`), `start`, `stop`,
`stopAndWait`, `poke`, the handler of the job it executes, and the persisted `jobs` table. As in
the call model, every piece of actor work is pending until a scheduler event runs it, in any
order: the loop task's next segment, a `poke`'s wake-up, a `stopAndWait`'s continuation once the
loop it waited for has ended. The handler runs outside the actor; the environment decides when
it returns and how. The loop is one task (`loop`): a second can only come from `start()` while
none exists.
-/

namespace Queue

/-- How a handler ended. -/
inductive Outcome | ok | permanent | retry | cancelled
  deriving DecidableEq, Repr

/-- Where the loop task is. -/
inductive Phase where
  /-- About to check cancellation and select the next job (a task is pending for it). -/
  | select
  /-- Suspended in `withCheckedContinuation { waiter = $0 }`. -/
  | waiting
  /-- Awaiting the handler of job `j` (`busy`). -/
  | executing (j : Nat)
  /-- The handler returned; its continuation (finish, events, failure handler) is pending. -/
  | after (j : Nat) (o : Outcome)
  deriving DecidableEq, Repr

structure S where
  /-- The `jobs` table (job ids, in order). -/
  db : List Nat
  wantsRunning : Bool
  /-- The loop task, if any (one task: its next segment is pending exactly in `select` and
  `after`); `cancelled`: `loop?.cancel()` was called. -/
  loop : Option Phase
  cancelled : Bool
  draining : Nat
  /-- Pending `poke` wake-ups. -/
  wakes : Nat
  /-- `stopAndWait` calls waiting for the current loop to end, and those whose continuation is
  pending (the loop they waited for has ended). -/
  stopWaiters : List Nat
  returns : List Nat
  stopNext : Nat
  /-- Outputs: jobs whose handler ran to the end (success or final failure), and `stopAndWait`
  calls that returned. -/
  done : List Nat
  returned : List Nat
  deriving DecidableEq, Repr

def S.init (db : List Nat) : S := ⟨db, false, none, false, 0, 0, [], [], 0, [], []⟩

/-- `start()`. -/
def start (s : S) : S :=
  if s.draining != 0 then s
  else if s.loop.isSome then { s with wantsRunning := true }
  else { s with wantsRunning := true, loop := some .select, cancelled := false }

/-- `stop()`: no more running; the loop is cancelled and woken. -/
def stop (s : S) : S :=
  { s with wantsRunning := false, cancelled := s.cancelled || s.loop.isSome, wakes := s.wakes + 1 }

/-- `stopAndWait()`: `draining += 1`, stop, then wait for the loop (if any) to end. -/
def stopAndWait (s : S) : S :=
  let n := s.stopNext
  let s := stop { s with draining := s.draining + 1, stopNext := n + 1 }
  if s.loop.isSome then { s with stopWaiters := s.stopWaiters ++ [n] }
  else { s with returns := s.returns ++ [n] }

/-- The loop task ends: `defer { loop = nil; if wantsRunning { start() } }`, and whoever awaited
it resumes. -/
def loopEnds (s : S) : S :=
  let t := { s with loop := none, cancelled := false, returns := s.returns ++ s.stopWaiters, stopWaiters := [] }
  if s.wantsRunning then start t else t

/-- The loop's next segment: check cancellation, select the first persisted job, execute it or
wait; or, after a handler returned, `execute`'s rest. -/
def loopStep (s : S) : S :=
  match s.loop with
  | some .select =>
    if s.cancelled then loopEnds s
    else match s.db.head? with
      | some j => { s with loop := some (.executing j) }
      | none => { s with loop := some .waiting }
  | some (.after j o) =>
    -- a finished or finally failed job is deleted; a retried one stays where it is (its
    -- `notBefore` only delays it; the rig retries without delay); a cancelled one stays for the
    -- next run. A failure while the loop is cancelled counts as the cancellation (`execute`
    -- checks `Task.isCancelled` first): the job stays, no failure handler runs.
    let o := if s.cancelled && o != .ok then .cancelled else o
    let db := match o with
      | .ok | .permanent => s.db.erase j
      | .retry | .cancelled => s.db
    let done := match o with
      | .ok | .permanent => s.done ++ [j]
      | _ => s.done
    { s with db := db, done := done, loop := some .select }
  | _ => s

inductive Ev where
  /-- The scheduler runs the loop's pending segment. -/
  | runLoop
  /-- …a pending wake-up (`wake()`: resumes the loop if it waits). -/
  | runWake
  /-- …the `k`-th pending `stopAndWait` continuation: `draining -= 1`, return. -/
  | runReturn (k : Nat)
  | start
  | stop
  | stopAndWait
  /-- `enqueue`: a job committed, then `poke()`. -/
  | enqueue (j : Nat)
  /-- The executing handler returns (or throws). A cancelled loop's handler may still succeed. -/
  | handlerReturns (o : Outcome)
  deriving DecidableEq, Repr

def step (s : S) : Ev → S
  | .runLoop => match s.loop with
    | some .select | some (.after _ _) => loopStep s
    | _ => s
  | .runWake => if s.wakes = 0 then s else
    let s := { s with wakes := s.wakes - 1 }
    match s.loop with
    | some .waiting => { s with loop := some .select }
    | _ => s
  | .runReturn k => match s.returns[k]? with
    | some n => { s with returns := s.returns.eraseIdx k, draining := s.draining - 1, returned := s.returned ++ [n] }
    | none => s
  | .start => start s
  | .stop => stop s
  | .stopAndWait => stopAndWait s
  | .enqueue j => { s with db := s.db ++ [j], wakes := s.wakes + 1 }
  | .handlerReturns o => match s.loop with
    | some (.executing j) => { s with loop := some (.after j o) }
    | _ => s

def run (s : S) : List Ev → S
  | [] => s
  | e :: es => run (step s e) es

inductive Reach : S → Prop where
  | init (db : List Nat) : Reach (S.init db)
  | step {s : S} (e : Ev) : Reach s → Reach (step s e)

end Queue
