# The calling boundary: what the calling service can make the app do

The thirteenth verification slice. ringrtc (WebRTC) runs in its own sandboxed process,
SignalCalling.xpc. That process reads what remote peers send (RTP, RTCP, ICE, DTLS, call
signalling), so it is the part of Serein most exposed to an attacker, and this slice treats it
as compromised. It covers two things:
- **what the service's events may make the app do**: send signalling, show an incoming call,
  send call messages and group messages, report a group ring;
- **the app's endpoint in the service and its generations**: what happens when the service
  crashes or is ended, and what a call made before that may still send.

The slice has three parts:
- a Lean 4 model of `RemoteCallEndpoint` (`Packages/SignalRingRTC/Sources/CallXPC`) and of
  RingRTC's handling of the service's events (`RingRTC.swift`, `RingRTC+Events.swift`, `Call`,
  `GroupCall`), with machine-checked proofs;
- a Swift rig that runs production RingRTC, over production `RemoteCallEndpoint`, against a
  hostile calling service;
- mutants.

**The app is not formally verified.** The proofs are about the model.

```
Tools/verify-callboundary.sh                 # everything
SKIP_MUTANTS=1 Tools/verify-callboundary.sh
SKIP_SWIFT=1 Tools/verify-callboundary.sh    # the Lean side only
```

## 1. The boundary

**The adversary is the calling service.** It can:
- send any event, at any time, while the client's endpoint is live (events reach the app only
  through the live endpoint's event wait);
- choose the call ids and group call client ids it answers;
- claim any participants for a call;
- lose the client's endpoint at any time, as a crash or the app ending its session does.

**What it may make the app do.** Each request is judged in the state it arrives in:

| Request | Allowed only |
|---|---|
| 1:1 signalling (offer, answer, ICE, hangup, busy) | to the peer of the current call under that call's id, or to the sender of an offer the app passed in under that offer's id |
| An incoming call | for an offer the app passed in, from that offer's sender |
| A call message (media keys, ring answers) | to ourselves, to a member of a Signal group call ringrtc runs (the members are the app's own list, `setGroupMembers`), or to a participant of a call-link call it runs (see §2) |
| A group message (rings and their cancellations) | to a Signal group with a call client, or one whose ring the app just cancelled, and only if every recipient passes as a call message |
| A group ring | from someone whose call message the app passed in, recently |
| `onEnded` of a group call | for a client the app has |

Upstream runs ringrtc inside the app, so it makes none of these checks; here they are stricter
than upstream. SFU requests (ringrtc's HTTP) go through the app only to the configured SFU
(`CallingService.isSFU`, unit-tested in SignalCore's `CallingSFUTests`, not modelled here).

**Generations.** The client's endpoint has a generation:
- A command runs on the live endpoint, or on a new one when there is none. `setSelfUuid` is
  replayed onto a new endpoint first; it is recorded before it runs, so even a run that fails
  gets it replayed.
- A command from a call or a group call carries the generation it was made on, and is refused
  once that generation has passed. Such a command may come from any group call object the app
  made, even one RingRTC no longer has: CallingService and the call UI keep theirs after a call
  ends, and a "leave" pressed after a crash comes from exactly such an object.
- A command or event wait that finds the endpoint gone moves the generation on.
- The next wait reports the loss once. RingRTC then ends the current call and every group call
  client made on a lost generation.

## 2. What is proved

| Theorem | Statement |
|---|---|
| `step_out` | **Everything the app does for the service was allowed** (the table above) in the state the request arrived in. |
| `stale_refused` | **A command made on a passed generation reaches nothing.** |
| `inv_reach` (`cmdsGen`) | **A command reaches only the endpoint of the generation it was made on**: nothing a call or group call from before a loss sends reaches the endpoint that replaced the lost one. That endpoint numbers its own calls and clients afresh, so this matters. |
| `inv_reach` (`callGen`, `groupGen`), `gens_report` | **A reported loss ends everything made before it**: once a loss is reported, the current call (unless it has ended) and every group call client were made on a generation not yet lost. |
| `inv_reach` (`configured`) | Once `setSelfUuid` is known, the live endpoint has it. |
| `send_cases`, `send_none_cases` | The four things a command can do: be refused, find the endpoint gone, run on the live endpoint, or run on a new one (with `setSelfUuid` replayed). Without a generation it is never refused. |
| `message_from_service` | The limit below, by a counterexample. |

**The limit.** `message-to-app-known` fails in the explorer, and `message_from_service` shows
why. A call message can go to someone who is neither ourselves nor a member the app gave. In a
call-link call there is no list of the app's own: ringrtc learns the participants from the SFU
and decrypts them with the link's key, so they are the service's word.
- A compromised service in a call-link call can therefore have the app send call messages to
  people it names.
- Those messages are end-to-end encrypted Signal messages from us. Their content is ringrtc's
  opaque data, so a recipient's ringrtc parses it.
- Checking this would need the app to decrypt the SFU's participant list itself.
- For Signal group calls the check is complete. ringrtc can name a participant only through
  the members list, so members are the whole set.

## 3. What is only tested against Swift

**`CallBoundaryConformanceTests.randomRuns`** (SignalRingRTC) runs 200 runs of 25 events
against production RingRTC over production `RemoteCallEndpoint`. The hostile calling service is
an in-process XPC listener that speaks the service's requests.
- **App calls:** `setSelfUuid`, `startOutgoingCall`, offers and opaque call messages handed in,
  Signal group calls and call-link calls, `setGroupMembers`, call and group call commands (from
  any group call object the app made, ended or not), and ring cancellations.
- **Service events:** incoming calls, signalling, call messages, group messages, rings, ended
  calls, remote devices and ended group calls. They involve three peers, four users (one of
  them ourselves), two groups and three clients.
- **Crashes:** the service loses the client's endpoint, and the event pump finds and reports
  the loss.

After every event, production must reach the model's state:
- the endpoint, its generation and the losses reported;
- the current call;
- the group call clients and their generations;
- every request the app carried out for the service;
- every command the service ran, with the endpoint it ran on and whether it came from RingRTC,
  the call or a group call.

Every kind of request must be carried out at least once over the runs.

Not exercised by the rig, only by the proofs and the explorer:
- the window passing (120 s in production);
- a loss found by a command rather than by the event wait (the rig waits for the pump).

**Also tested elsewhere:**
- `RemoteEndpointTests` (a real loss over XPC ends the call, the next command starts afresh);
- `EndpointChecksTests` (each check, both ways);
- `LoopbackCallTests` (real 1:1 calls and video frames through the service's handler over XPC);
- `Tools/check-sandbox-profile.sh` (a real call between two endpoints in the sandboxed service;
  the service gone once its host's session ends).

Mutants (step 6), each of which must fail step 5:
- **What the service may ask for:**
  - signalling goes to anyone;
  - signalling goes to the call's peer under any call id;
  - an incoming call needs no offer;
  - an incoming call is accepted for an offer from someone else;
  - a Signal group call's participants count as members;
  - call messages to ourselves are dropped;
  - call messages go to anyone;
  - group messages go to any group;
  - a group message's recipients are not checked;
  - rings come from anyone.
- **Generations and losses:**
  - a call's commands ignore its generation;
  - a group call's commands ignore its generation;
  - the endpoint does not check generations;
  - a loss does not move the generation on;
  - a loss is never reported;
  - a reported loss leaves the call running;
  - a reported loss leaves the group calls;
  - a new endpoint does not get `setSelfUuid`.

## 4. Production changes made for this slice

- **`mayMessage`:** call messages go to ourselves, to members for Signal group calls, and to
  participants only for call links. It used to accept the service-reported participants of any
  group call, which let a compromised service name anyone.
- **`setSelfUuid`:** RingRTC keeps our uuid (`selfUuid`), so ring answers and keys for our other
  devices pass. `RemoteCallEndpoint` records `setSelfUuid` for replay before running it.
- **Losses:** a loss ends the group call clients in client order (it was dictionary order).

The first run of the mutants found a gap in the model and rig, not in production. Only group
calls RingRTC still had could send commands, and a loss removes those. So no stale group call
ever sent one, and the mutant that drops the group calls' generation survived. The model now
keeps every group call object the app made (`held`), and so does the rig.

## 5. Assumptions and limitations

- **Transport.** The XPC transport underneath is the Broker slice's, which models its
  asynchronous requests. The calling service uses its blocking requests (`XPCChannel.sendSync`),
  modelled here only as their outcome: a command runs, or the endpoint is found gone.
  - A blocking request that times out ends the session.
  - The service exits when its session ends (checked by `Tools/check-sandbox-profile.sh`), so a
    timeout is a loss of the endpoint.
- **What the app does with what passes** is beyond the boundary. Examples: CallingService's own
  checks of a ring's group, and the call UI.
- **The service's other events** (call states, audio levels, network routes, peek results,
  remote device states) change only what the app shows about a call, and are not modelled.
  - The service can lie in them, or end calls at will.
  - It also chooses the ids it answers.
- **The 120 s windows** for cancelled rings and call-message senders are modelled as the window
  passing, at any time.
