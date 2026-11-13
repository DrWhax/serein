# The job queue: ownership and shutdown

The fifth verification slice: SignalCore's `JobQueue` actor. It contains:

- a Lean 4 model of the actor (`start`, `stop`, `stopAndWait`, `poke`, its run loop and `execute`)
  with an explicit scheduler, as in the call model: the loop's next segment, a wake-up, a
  `stopAndWait`'s continuation are pending work that a scheduler event runs, in any order; the
  handler runs outside the actor and returns when the environment says, however it says;
- machine-checked proofs of shutdown's postcondition and of the other properties below, and an
  existence theorem constructing one terminating drain schedule;
- a Swift test that runs the real `JobQueue` on a real database with handlers held at gates, and
  mutants.

**The app is not formally verified.** The proofs are about the model.

```
Tools/verify-queue.sh                 # everything
SKIP_MUTANTS=1 Tools/verify-queue.sh
SKIP_SWIFT=1 Tools/verify-queue.sh    # the Lean side only
```

## 1. What is proved

| Theorem | Statement | For |
|---|---|---|
| `Inv.reach` | The invariant: `draining` counts exactly the `stopAndWait` calls not yet returned; one still waiting for the loop implies a loop exists; one whose continuation is pending implies none does; while draining, nothing wants to run and a live loop is cancelled; a cancelled waiting loop has a wake-up pending. | reachable states, any schedule |
| `shutdownClean_holds` | **Shutdown's postcondition**: when a `stopAndWait` returns, no loop exists — no handler running, no selection or finishing pending. | reachable states |
| `noRestartWhileDraining_holds` | `start()` changes nothing while a `stopAndWait` is pending. | every state |
| `oneAtATime_holds` | A step finishes at most one job, and only the one whose handler returned. | every state |
| `drain_can_terminate` | **Existence of a terminating drain**: from any reachable state, there exists a finite schedule of scheduler events and handler returns (no user action, no new job) that returns every pending `stopAndWait`. | reachable states |

This is an existential reachability theorem, not eventual termination on every fair schedule.
The model permits arbitrary stuttering events, so a scheduler can leave a continuation pending
forever. No fairness predicate or universal liveness theorem is currently proved. The safety
proofs hold for every schedule; the Swift rig tests only its documented settled schedule.

Ownership within one queue holds by construction: the loop is one task, and `start()` creates
one only when none exists.

## 2. Production changes made for this slice

**Q1: a session's workers are drained before another session's start**
(`SignalClient.start`). It created a new `JobQueue` (and maintenance, downloads, pre-key task)
without stopping the running session's: two queues over one database would both select and run
the same job. The app does not start a second session in a running process today (it links only
when no account is stored); the guard makes that a property of `SignalClient` instead of the app.

**Q2: quitting shuts the client down** (`applicationShouldTerminate` → `.terminateLater`,
`SignalClient.shutdown()`, at most 3 seconds), as upstream does before quitting. The app returned
`.terminateNow` and never called `shutdown()`. Now the job queue's handler is cancelled and has
ended (with its database work) before the process exits, downloads and timers have stopped, and
the connection is closed. A send cancelled this way keeps its job and may go out again at the next
start, as before (recipients drop a repeated timestamp); this does not change that.

## 3. What the rig showed about production

A **failure while stopping counts as the cancellation**: `execute` checks `Task.isCancelled` before
anything else, so a handler that fails — even permanently — after `stop()` cancelled the loop
leaves its job in place, uses no attempt, and runs no failure handler; the job runs again at the
next start. The first model deleted it; the rig disagreed; the model now does what production
does. This is the conservative choice (an error surfacing during a cancellation may be caused by
it), noted here because a permanent failure's handler (e.g. marking a message failed) waits for
the next run.

## 4. What is only tested against Swift

`QueueConformanceTests` (SignalCore): the real `JobQueue` with a zero retry delay, its handlers held
at a gate until the trace says how they end (return, permanent failure, retry, cancellation). After
each user or environment event (`start`, `stop`, `stopAndWait`, `enqueue`, a handler's return) the rig
waits until the actor is quiet (no loop, the loop waiting, or a handler held; every `stopAndWait`
returned or still waiting for a live loop) and compares: the loop's state, `wantsRunning`,
`draining`, the persisted jobs, the jobs finished, and how many `stopAndWait` calls returned; and that
no two handlers ever ran at once. The conformance is for this settled schedule; the safety proofs cover any schedule.
Traces: `traces/regressions.txt` (11) and 300 random traces of 16 events.

Mutants (step 6): `start` ignores a pending drain; `stopAndWait` does not wait for the loop; the loop
restarts after a stop; a cancelled handler's job is discarded; a permanent failure is retried.

## 5. Assumptions and limitations

- Retry delays (`notBefore`) are not modelled; the rig uses a zero delay. Attempts are not counted
  (the rig allows a million).
- The deadline wake-up task (a `Task` that sleeps until a retry's `notBefore`) only wakes the loop; it
  is not awaited by `stopAndWait` and changes nothing else.
- Two queues over one database are excluded by `SignalClient` (Q1), not by the queue; that is
  argued from the code, not tested (it needs a full client). The quit drain (Q2) runs inside
  AppKit's termination and is not tested either.
- The handler's own unstructured tasks, if it started any, are outside the queue's reach.
