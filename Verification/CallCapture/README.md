# Call/capture lifecycle: a Lean model, proofs, and conformance with production Swift

The first verification slice for Serein: the app's call and capture lifecycle (call start,
accept and hang-up, the camera, screen sharing). It contains:

- an executable Lean 4 model with a pure transition function, in which every piece of main-actor
  work (a spawned task, the continuation of an await, a callback's hop) is a pending job that a
  scheduler event runs, in any order;
- machine-checked proofs for the security invariants, and a refutation that shows the one bound
  they need (2^64 screen shares);
- a Swift test that drives production code with fake devices and a controllable scheduler, and
  compares it with the Lean model after every step.

**The app is not formally verified.** What is proved is proved about the model. That the
production Swift behaves like the model is *tested*, on many traces, not proved. Section 5 lists
the five production defects the model found (D1–D5) and how each was fixed. Several invariants
hold now only by test and exploration, not by proof (§6).

```
Tools/verify-calls.sh                 # everything (about 15 minutes: step 6 rebuilds for each mutant)
SKIP_MUTANTS=1 Tools/verify-calls.sh  # about a minute once built
SKIP_SWIFT=1 Tools/verify-calls.sh    # the Lean side only
```

The script runs these checks:

1. It rejects `sorry`, `admit`, `native_decide`, `axiom` and similar escape hatches.
2. `lake build`: the kernel checks every proof.
3. The audit (`Audit.lean`), diffed against `audit-expected.txt`: the property definitions,
   readably; **every definition the theorem statements depend on, transitively** (626 of them:
   the whole model, through definition bodies, not proofs), each with a hash of its type and
   value; and every theorem statement. A changed or weakened statement or definition fails, even
   when it still builds. It accepts only `propext`, `Classical.choice` and `Quot.sound` as axioms.
4. The random explorer (fixed seed), under four schedules, diffed per property and schedule.
5. The Swift conformance tests, and regression tests for D1–D5.
6. Mutants: ten bugs planted in production one at a time (two callbacks wired to the wrong
   token, a dropped start check, a dropped output gate, and each of the D1–D5 fixes undone).
   Each must make step 5 report a disagreement with the model. The file is restored afterwards,
   also on interrupt.

The toolchain is pinned in `lean-toolchain` (`leanprover/lean4:v4.35.0`). The project uses only
Lean core: no Mathlib and no other dependencies.

## 1. The invariants, from the security goal

These were written from what the user is owed, not from upstream. Upstream behaves the same way
on several points (§5), and that agreement is not evidence of correctness.

| | Invariant |
|---|---|
| T1 | An event that belongs to an obsolete call (a native call that is not the active call's own) cannot mutate the active call. |
| T2 | An obsolete share (stopped or replaced) cannot submit frames, and cannot stop its replacement: the current share and presenting stay as they are, and only the obsolete share's own streams are stopped. |
| T3 | Revocation prevents new capture authorization for that session. For the camera, revocation is the user turning video off, or the call ending. For a call, it is the call (or lobby) ending: no call is asked for, or placed. For a share, it is the share being stopped or replaced, or its call ending: no stream is started and no sources (window list and thumbnails) are requested. |
| T4 | A capture that completes after revocation cannot publish frames, and its cleanup is requested in the same job. |
| T5 | An ended call cannot become accepted again without a distinct authorized start. Formally (`t5`): a call instance that has ended (ghost terminal history, `S.ended`, recorded by `step` whenever an instance goes from live to not live) is never live and accepted afterwards. A new start is a new instance. |
| Acceptance requires authorization | The active call is accepted only if it had an authorized start: the user accepted it, or its own setup started the native call that reports it (`acceptAuthorized`, the property earlier drafts called T5). |
| Cleanup | No running capture is left without something that will stop it: no live stream without a current share, a pending await, or a pending job that stops it; no running camera that is unwanted with no reconciler pass. |

**Application authorization is not the same as physical device behaviour.** Every property is about
what the app *requests* and what it *forwards*. A stop request is not a stopped device. The model
records the fake device's state separately (`DEV=`, stream phases), and nothing here claims:

- that the camera or microphone is physically released at any time;
- that a requested stop completes (the app ignores a failed `stopCapture()` and never retries);
- that teardown terminates, or that any job runs at all (no fairness is assumed).

The microphone is RingRTC's: the app only asks the service to start, mute or hang up a call.

## 2. The scheduler

Swift runs the lifecycle code on the main actor, but does not promise in which order the main
actor runs its pending work, and user input can be handled between any two pieces of it. The
model therefore makes every piece of main-actor work an explicit **job** (`Model.lean`, `Job`):

- a `Task { }` the code spawned that has not started (the reconciler's pass, the setup task, the
  share button's sources task, a pick's task, a capture stop);
- the continuation of an `await` whose environment call has completed (the device's side
  happens at the completion event; the code after the `await` is a job);
- the hop of a callback to the main actor (each `onEvent` / `onCameraNeeded` message, each
  camera or screen frame, each stream error).

Jobs wait in `jobs` in the order they were made. The scheduler event `run k` runs the `k`-th
pending job to its next suspension; **any** pending job may be chosen, and user, environment and
device events may come between any two jobs. The proofs hold under every such schedule. Nothing
in the model is a clock.

A trace that violates a property is classified by schedule, which is about order, not speed
(`UI.lean`; `oracle check` prints it). The schedules in §5 are those of the defects' traces
before their fixes.

- **UI-reachable with a drained queue**: every user event is one the UI offers in that state, and
  comes while no job is pending.
- **UI-reachable with pending callbacks**: every user event is offered by the UI, but at least one
  comes while a job is pending (a task not started yet, a completion not yet continued, a
  message not yet delivered). Whether that happens depends on how the main actor interleaves
  AppKit's event handling with its queue, which the model does not decide.
- **Not offered by the UI**: needs a user event the UI does not offer in that state.
- Separately, **FIFO** or not: whether every `run` runs the oldest job. The main actor is
  FIFO in practice; Swift does not guarantee it, so non-FIFO violations are real but less
  likely.

## 3. What is proved

All of the following are for every state reachable from **any** initial counter values (`Reach`),
or for every state outright, under any schedule. Statements are in `audit-expected.txt`. Each one
depends only on `propext`, `Classical.choice` and `Quot.sound`.

| Theorem | Statement (informally) | File |
|---|---|---|
| `ShareInv.reach` | The share invariant holds. Tokens are `tok0 + (index + 1)` (wrapping). The current share is a created capture under its own token. Every screen-share await, and every pending job that carries a share (its tasks, the continuations of its awaits, its frame and stop callbacks), names a created capture by that capture's token, and a stream it owns. | ShareInv.lean |
| `t2Frames_holds` | **T2 (frames)**: a frame of share `i` is submitted only if `i` is the current share. *Requires at most 2^64 shares made (`capNext ≤ 2^64`).* | Proofs.lean |
| `t2Stop_holds` | **T2 (stopping)**: a step that belongs to an obsolete share (a device event of its streams or sources, or any job carrying it) leaves the current share and `isPresenting` unchanged, never calls `setPresenting`, and stops only streams the current capture does not own. *Same bound.* | Proofs.lean |
| `t4ScreenObsolete_holds` | **T4 (obsolete share)**: a stream start whose continuation runs after its share was stopped or replaced stops the stream in that same job, and does not turn presenting on. *Same bound.* | Proofs.lean |
| `t4Camera_holds` | **T4 (camera)**: a camera start whose continuation runs once the camera is unwanted stops it in that same job. | Proofs.lean |
| `camStartWanted_holds` | The camera start is requested only while the app wants the camera (a live call or lobby with `callLocalVideo` on). This is **application** authorization; `t3Camera_holds` adds the user's choice. | Proofs.lean |
| `cameraFrames_gated` | Camera frames go to the call only from the camera's frame callback, only while the app wants the camera, the service asked for frames, and nothing is being presented. | Proofs.lean |
| `VidOk.reach` | `callLocalVideo` is the user's video choice (`userVideo`, ghost: set only by opening a lobby, accepting, and the video button). Nothing else changes either; before the D1 fix, `.outgoingCall` did. | Video.lean |
| `t3Camera_holds` | **T3 (camera)**: a camera start is requested, and a camera frame sent, only while the call or lobby is live and the user has video on. | Video.lean |
| `ended_not_live` | An instance that has ended is not live, in any reachable state. | Instances.lean |
| `t5_holds` | **T5**: an ended call instance is never live and accepted afterwards. | Instances.lean |

The proof is organised in layers:

- `Effects.lean` gives, for every function and job, the kinds of effect it can request.
- `Frames.lean` shows that everything outside the screen-share code leaves the share state alone;
  `Instances.lean` does the same for the active call and the instance counter.
- `ShareInv.lean` proves the share invariant for the screen-share functions and jobs one by one;
  `Instances.lean` proves that the call functions only end instances or make new ones;
  `Video.lean` that only the user's choice changes the video setting.

## 4. What is false: the 2^64 bound (proved)

| Property | Refutation | Schedule |
|---|---|---|
| T2, T4 at 2^64 | `t2Frames_wrap`, `t4ScreenObsolete_wrap` (Wrap.lean): in a call, share 0's source is picked and its pick task has not started; the share button is pressed 2^64 times (each press stops the share before it, D4's fix). The newest share now has share 0's token, so share 0's task starts a stream, which is presented, and its frame is sent. Symbolic proof by induction; the 2^64 steps are never evaluated. | theoretical |

Before the D1–D5 fixes, `Counterexamples.lean` refuted T1, T3 (camera, call request, call,
screen, screen sources, obsolete share), T4 (revoked call), acceptance and both cleanup
properties with 16 concrete traces, checked by the kernel (`decide`). Against the fixed model
none of them falsifies anything, so the theorems are gone. The traces are kept as regression
traces (`traces/regressions.src`, marked "fixed"); `oracle check` reports no property failing on
any of the 36. The file keeps the machinery (`Falsifies`, `refutes`, `schedule`) and the two
cleanup properties.

## 5. Production defects found, and fixed

| | Defect (before the fix) | Schedule | Consequence | Fix |
|---|---|---|---|---|
| D1 | `handleCallingEvent(.outgoingCall)` set `callLocalVideo` to the value setup captured at Start, without `updateCamera()`. | drained, FIFO | Turning video off during setup was undone: the camera started, and its frames went to the call once accepted. Video turned on during setup left the camera running with the UI showing video off. | `.outgoingCall` leaves `callLocalVideo` alone. If the user's choice differs from what setup started the call with, the app tells the service (`setOutgoingVideo`). Proved: `t3Camera_holds`. |
| D2 | Call events were matched by conversation id only: a late `ended` of the previous call, an incoming call from the same contact, a rejected offer's `ended`, a stale `accepted`. | drained, FIFO | A new lobby or call was closed, or showed another call's state, including `accepted` without an authorized start. | `CallingEvent` carries RingRTC's `CallId` (outgoing, incoming, state change, remote media). The active call takes its id from `.outgoingCall`, accepted only from this lobby's own setup (`setup:` token = `callGeneration`, which every teardown bumps) and only once; or from the ring the user accepted. State events apply only to that id. `endCall`, `acceptDirectCall` and `declineDirectCall` take the id and touch no other call. |
| D3 | `acceptCall` replaced `activeCall` without `releaseCallMedia`. | not UI (`CallManager` shows the incoming bar only without an active call) | The old call's share and setup carried over into the new call; a setup in progress placed its call. | `acceptCall` tears the current call down first (`endCallUI`). |
| D4 | `togglePresenting`, `cancelPresentingSources` and failed `sources()` dropped `screenCapture` without stopping its stream. | pending callbacks, FIFO; drained, not FIFO | A screen stream ran with no owner to stop it. | One `clearScreenShare()` for every path that drops a share: it cancels a start in progress and spawns the stop. |
| D5a | `togglePresenting`'s task did not check, when it started, that its share was still current. | pending callbacks, FIFO; drained, not FIFO | After a hang-up (or a second press), the task still asked ScreenCaptureKit for the shareable windows and screenshotted them for thumbnails. Nothing was shown or sent. | The task checks `isCurrentScreenShare` first, as the pick's task does. |
| D5b (hardening) | `callSetupTask` did not check `callGeneration` when it started. | pending callbacks, FIFO; drained, not FIFO | It asked the service to start a call after the hang-up. No call was placed only because the task was cancelled and the service's first `await` throws `CancellationError`. | The task checks `callGeneration` first. If the generation changed while it waited, it ends the call it placed, by id (`startOutgoingDirectCall` returns the `CallId`). |
| — | Tokens and generations are wrapping `UInt64`. | 2^64 shares | §4, `*_wrap`. | Not fixed: unreachable in practice. |

D5a and D5b were found by the scheduler revision: the earlier model ran each spawned task together
with the event that spawned it, so "the hang-up comes before the task starts" was not a reachable
interleaving.

On D2, upstream's reducer keys `CALL_STATE_CHANGE_FULFILLED` by conversation as well, so Serein is
now stricter than Signal-Desktop there.

`App/SignalSafe/Tests/SignalSafeTests/CallCaptureDefectRegressions.swift` asserts the fixed
behaviour in production (10 tests), through the same rig. Each fix is also undone as a mutant in
step 6, and each must be caught by the conformance tests.

A remaining, non-security wart: if the main actor runs a call's `ended` before its `incoming`
(not FIFO), the ring shows for a call that has ended. Accepting it shows a call screen that never
connects. With video on, the camera runs for the preview, but the service has no such call and
never asks for frames, so nothing is sent; hanging up clears it.

## 6. What is only tested against Swift

The Lean model is the oracle. `CallCaptureConformanceTests` drives the **production**
`SignalSession` (`Calls.swift`, `CallLinksAndPresenting.swift`), `CaptureReconciler`,
`ScreenShareCapture` and `ScreenStreamOutput`. Only the environment is replaced:

| Stand-in | Behaviour |
|---|---|
| Camera (`CameraBackend`) | `requestAccess`, and a device whose `startCapture` and `stopCapture` wait until the trace completes them. Production's device closures (`cameraReconciler`) and frame callback run. |
| ScreenCaptureKit (`ScreenShareBackend`, `ScreenStream`) | Sources, `startCapture` and `stopCapture` wait for the trace. `ScreenShareCapture.start` and its teardown run. |
| `RigService` (`CallControl`) | The environment rules of the model, including that the service's first await throws in a cancelled task. |

**The scheduler is the trace.** Production starts its main-actor tasks through `MainTasks`
(`Packages/SignalUI/.../MainTasks.swift`; `Task { }` in the app). The rig's `MainTasks` holds each
task at a gate until the trace's `run.k` releases it; it also holds the continuation of every
await on a fake after the trace completes it, and every service message. `run.k` then waits until
that task is suspended in a fake again or has ended: each fake reports when a task waits on it, and
the task wrapper reports when it ends. No other task can run meanwhile, because all others are at
their gate or in a fake. There is no yield counting; a task that neither waits nor ends within
10 s is reported as a failure.

**Callbacks go through production's wiring.** A frame of stream `j` is passed to that stream's
production `ScreenStreamOutput` (its `running` gate), which calls the closure `togglePresenting`
gave the capture (with the token it captured), which spawns the hop through `MainTasks`. Stream
errors go the same way, through `ScreenStreamOutput.stopped`. Camera frames go to the closure
production gave the camera device. The rig never calls `screenFrame`, `screenShareStopped` or
`cameraFrame` itself.

**Mutation check.** Step 6 plants each of these in production and requires a disagreement:

| Mutant | Killed by |
|---|---|
| The frame callback reads the current token instead of the one it captured. | `late-frame-of-replaced-share` |
| The stop callback reads the current token instead of the one it captured. | `old-stream-error` |
| The pick's task does not check `isCurrentScreenShare` when it starts. | `hangup-before-present-task-starts` |
| `ScreenStreamOutput` passes frames after `stop()`. | `replace-share` |
| D1 undone: the service keeps the video setup started it with. | `video-off-during-setup` |
| D2 undone: state events matched by conversation. | a random trace (the first failure reported) |
| D3 undone: accepting keeps the call on screen. | a random trace (the first failure reported) |
| D4 undone: a second share leaves the first running. | `replace-share-while-loading` |
| D5 undone: the setup task skips its start check. | `close-before-setup-task-starts` |
| D5 undone: the sources task skips its start check. | `hangup-before-sources-task-starts` |

After every event the rig prints the observation the oracle prints for that step: 21 fields of
session, reconciler, capture, stream (with the output's gate), service and job-queue state, plus
the ordered list of requested effects. Any difference is minimised (delta debugging, both sides
re-run) and reported with the differing fields.

Traces:

- `traces/regressions.txt` (written from `traces/regressions.src` by `oracle expand`): the earlier
  teardown regressions (`CallTeardownTests`, `CameraReconcilerTests`), tasks that start after a
  hang-up, continuations that run after one, late frames and errors of a replaced share, tasks
  and messages out of order, rapid redial, duplicates, cleanup failure, counter wrap, and the
  former D1–D5 counterexamples (36).
- 2,000 random traces from each of four generators: any events, UI-offered user events, drained,
  and drained with FIFO. Half start from an established call or a presenting share; a third
  start next to every counter's wrap.

Tested only, not proved:

- That production behaves as the model (the conformance above).
- T1 (all three variants), T3 for calls (request and placement), screens, screen sources and
  obsolete shares, T4 for screens (revoked call, publishing), acceptance requires authorization,
  and both cleanup properties. After the fixes the explorer finds no violation of any of them,
  in 160,000 traces across the four schedules, and the conformance tests agree, but **there is
  no proof**. Only §3 is proved.
- An "OK" in `explore-expected.txt` means only that no violation was found. The explorer misses
  things: before the fixes it reported cleanup-streams OK under the drained schedule, while
  `cleanupStreams_staleRing` was a kernel-checked drained counterexample.

## 7. Assumptions and limitations

**Model scope.** Direct (1:1) calls, the camera, and screen sharing. Not modelled:

- group calls and call links;
- `setCallAudio` (microphone mute);
- camera switching (`CaptureReconciler.restart`);
- ringtone, PiP and other UI;
- the screen-recording permission (always granted);
- `filter(for:)` beyond "needs the capture's sources to have loaded";
- `ScreenShareCapture`'s once-a-second repeat of a stale frame: in the rig its task never runs.
  It calls the same output and callback as a frame.

**Scheduling.** A job runs atomically up to its next suspension: the modelled code is isolated to
the main actor, and the only suspensions are awaits on the environment. Awaits that leave the main
actor (the `CameraCapture` actor, ScreenCaptureKit, the calling service) are environment calls,
completed by events. Task cancellation is modelled where the code uses it: `releaseCallMedia`
cancels `callSetupTask`. A cancelled setup task that has started is already covered, because the
same hang-up bumps `setupGeneration`, which the service checks. In the rig, frames and stream
errors are delivered on the main thread, while production delivers them on the sample queue.
The callback then hops in the same way.

**Environment.** The rules mirror `CallingService.swift`, `RingRTC+Events.swift` and GRDB's
cancellation behaviour, as read. They are not tested against the real `CallingService`, which
needs RingRTC's native code and a server. The real service's own `onEvent` hop
(`startCalling`) is replaced by the rig's message jobs.

- RingRTC holds one direct call.
- After `hangup`, `endCall` or `decline`, a call can only end.
- An incoming call becomes accepted only after `accept`.
- The service's messages arrive in any order (each is its own main-actor job).
- `setupGeneration` cancels setup after a hang-up; in a cancelled task, the service's first await
  throws `CancellationError`.
- A rejected offer reports `ended` under a call id of its own, except when the offer arrived
  while another call was active.
- The native call is created when setup completes. In reality it is created mid-setup and hung up
  if setup is cancelled.
- `handleIncomingCall` always attaches the call. The blocked and muted paths are not modelled.

**Devices.** The fakes allow more interleavings than the real devices, which is sound for safety
properties:

- Stops can be slow; production `CameraCapture.stop` is synchronous.
- A frame of a camera session that ever started can arrive at any later time. A stream that has
  run can deliver frames during and after its stop; its output's gate drops them.
- A stream error can arrive in any phase.

**Numeric semantics.** `callGeneration`, `lastScreenShareToken`, `setupGeneration` and each
capture's `generation` are `UInt64` with wrapping `+`, as in Swift. Indices that exist only for
the proofs (call instances, native-call owners, share, stream and camera-session numbers, the
ended-instance record) are ghost state and never influence a transition. The share theorems need
at most 2^64 shares made in the session, and §4 proves the bound is necessary. They don't depend
on generation counters.

**Production seams added for the adapter.** With no override set, behaviour is unchanged:

- the `CallControl` protocol, which `CallingService` conforms to; `SignalSession.callControl` is
  `callControlOverride ?? calling`;
- `SignalSession.screenShareBackend` (permission, sources, start) and `cameraBackend` (permission,
  device), with the `CallCamera` protocol that `CameraCapture` conforms to;
- `MainTasks`, through which the session, `CaptureReconciler` and `ScreenShareCapture` start their
  tasks (`system` is `Task { @MainActor in … }`);
- `ScreenShareCapture.start(makeStream:)`, and `ScreenStreamOutput.deliver` / `stopped`, which
  the SCStream delegate methods now call.

**The audit's reach.** The closure in step 3 covers every definition in the CallCapture modules
that a theorem statement uses, through definition bodies. Lean core definitions (lists, `UInt64`)
are not listed; they are fixed by the pinned toolchain. Hashes say *that* a definition changed;
the diff of the Lean sources says how.

**No translator.** The model was written by hand from the Swift. Signal-Desktop's TypeScript was
read as a reference only. No TS→Lean translation is involved.

## 8. Files and commands

| File | Contents |
|---|---|
| `CallCapture/Model.lean` | The model: state, jobs, events, effects, `step`, `Reach`. |
| `CallCapture/Props.lean` | The properties, as decidable checks on one step. |
| `CallCapture/UI.lean` | What the UI offers; the drained and FIFO schedules. |
| `CallCapture/Effects.lean`, `Frames.lean`, `ShareInv.lean`, `Proofs.lean`, `Instances.lean`, `Video.lean` | The proofs. |
| `CallCapture/Counterexamples.lean`, `Wrap.lean` | Refutation machinery and the cleanup properties; the 2^64 refutation. |
| `CallCapture/Trace.lean`, `Main.lean` | Trace format, observations, the `oracle` executable. |
| `Audit.lean`, `audit-expected.txt`, `explore-expected.txt` | What the script compares. |
| `traces/regressions.src`, `traces/regressions.txt` | Regression traces (source with `drain`, and expanded). |

```
lake build                                     # proofs + oracle
.lake/build/bin/oracle replay < traces/regressions.txt
.lake/build/bin/oracle check < traces/regressions.txt   # which properties each trace falsifies, and its schedule
.lake/build/bin/oracle explore 2026 40000 80 drained    # any | ui | drained | drained-fifo
.lake/build/bin/oracle gen 1 10 60 ui                   # random traces
.lake/build/bin/oracle expand < traces/regressions.src  # `drain` / `drain.n` written out as run events
.lake/build/bin/oracle counterexamples
```

Event notation in traces:

| Event | Meaning |
|---|---|
| `open.c.v` | Open a lobby for conversation `c` with video `v`. |
| `start` | Start the call from the lobby. |
| `accept.c.v`, `decline.c` | Accept or decline an incoming call. |
| `hangup`, `close` | Hang up, or close the lobby. |
| `video.b` | Turn video on or off. |
| `toggle`, `pick`, `cancel` | Share button; pick a source; cancel the picker. |
| `run.k` | Run the `k`-th pending main-actor job (`J=` in an observation lists them). |
| `nin.c.v` | RingRTC: incoming call. |
| `nst.P\|R\|A\|X` | RingRTC: call state change. |
| `nend.L\|R\|N` | RingRTC: call ended. |
| `nrej.c` | RingRTC: rejected offer. |
| `setup.q.ok` | The `q`-th `startOutgoingDirectCall` completes. |
| `cacc.g`, `cstart.ok`, `cstop`, `cframe.k` | Camera: access answered, start or stop completes, frame of session `k`. |
| `src.i.ok` | Screen sources of share `i` load. |
| `sstart.j.ok`, `sstop.j.ok` | Stream `j`'s start or stop completes. |
| `sframe.j`, `serr.j` | Stream `j` delivers a frame; stream `j` reports an error. |

A trace line is `cfg <callGeneration> <lastScreenShareToken> <setupGeneration> <capture generation> | events…`.

Results at the time of writing:

- Lean: 13 audited theorems (11 results and the 2 wrap-around refutations), all checked by the
  kernel, using only the standard axioms.
- Explorer: all 80 verdicts hold (20 properties, four schedules); none is falsified.
- Swift: 8,000 random traces plus 36 regression traces agree with the model at every step.
  10 regression tests confirm the D1–D5 fixes in production. 10 of 10 mutants are killed.
