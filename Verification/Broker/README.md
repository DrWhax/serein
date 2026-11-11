# The broker: the app and its sandboxed helpers

The eleventh verification slice covers what a sandboxed helper's reply can do in the app: the media
decoder, the voice-note encoder, the link-preview parser and fetcher, and the GIF service. It
has three parts:
- a Lean 4 model of the app's channels to them (`XPCChannel` and `MediaXPCClient` in
  `MediaXPCInterface`), with machine-checked proofs;
- Swift tests that run production against hostile helpers;
- mutants.

**The app is not formally verified.** The proofs are about the model.

```
Tools/verify-broker.sh                 # everything
SKIP_MUTANTS=1 Tools/verify-broker.sh
SKIP_SWIFT=1 Tools/verify-broker.sh    # the Lean side only
```

## 1. The boundary

Each helper sits behind one channel. A channel has at most one live session. A request goes out
on that session, and the channel opens a new session if it has none.

**A request is outstanding** from the moment it is sent until the first of these four events:
1. its reply arrives;
2. its failure arrives, because the session ended;
3. its watchdog times it out;
4. its caller's task is cancelled.

Only that first event reaches the caller, and only once.
- A reply is decoded as the request's own result type and validated with the request's own
  parameters. For example, a thumbnail must be exactly the size this request asked for.
- A reply that arrives after its request ended is too late and is discarded. If it names a
  session the helper opened for the request (a video player or a recording), the client closes
  that session.

The helper is the adversary. It can:
- answer any message it was sent, with anything, at any time;
- answer again;
- answer on a session that has ended;
- never answer;
- send messages nobody asked for;
- end its sessions, as a crash does.

The system (XPC) is trusted for the following. The rig exercises each point in process:
- a reply goes only to the message it answers, and only once (a second reply is dropped);
- a reply arrives only while that message's session is up;
- when a session ends, every message on it that is still waiting fails;
- a message nobody asked for is dropped, because the app's sessions have no handler for them.

**Quarantine.** An input is the untrusted bytes a decoder request carries.
- A timeout gives that input two strikes, so it is quarantined at once.
- A session that ends gives one strike to each input that was in flight on it, however many of
  that input's requests were in flight.
- Two strikes quarantine an input, and a quarantined input is refused without being sent.

**From one helper to another.** Some of what a helper returns becomes a request to another
helper:
- The parser service's answer to the app's empty message carries an endpoint. That endpoint is
  handed to the fetcher, and only when the answer has no payload.
- A GIF page is accepted only if every URL in it is on the Giphy CDN (https, `media0`–`media4`,
  no port, no credentials). The GIF service is asked for files only at such URLs.
- A link preview's image href must pass `FetchedLinkPreview.validated` and SignalCore's
  `shouldPreviewHref` before the fetcher is asked for it (read from code, see §5).

No reply entry is read except the payload, plus the endpoint in the parser's answer. XPC file
descriptors in a reply are ignored, so no reply becomes a file operation.

## 2. What is proved

| Theorem | Statement |
|---|---|
| `final_stable` | **A request ends once.** Once a request has ended, nothing that happens next changes how it ended: replies (again, or late), crashes, timeouts, cancellation. This holds in every state, reachable or not. |
| `okOwn_holds` | **A request succeeds only with a reply to its own message**, decoded and validated as its own. |
| `thumb_own` | A thumbnail comes back only at the size its own request asked for. |
| `session_own` | A session handed to a caller is the one its own reply named. |
| `pendingLive_holds` | **Nothing waits on a session that has ended.** A crash ends every request on its session at once, without help from the watchdog. |
| `crash_ends` | After a crash, nothing on that channel is still waiting, and there is no live session. |
| `send_fresh` | With no live session, a request goes on a new session that no earlier request used. |
| `other_channel` | **Channels are separate.** An event on one helper's channel leaves every request on the other channel, and the other channel's session, unchanged. |
| `noLeak_holds` | **No helper session is left behind.** A session a reply named for its request is either the caller's or released. This holds whether the reply came in time, was refused, or came after the request ended. |
| `releaseNamed_holds` | A release goes to the helper that named the session, and names only sessions that helper named. Video ids never go to the voice service, and voice ids never go to the decoder. |
| `strikes_holds` | **The strike count is exact**: an input gets two strikes for each timed-out request that carried it, and one for each ended session it was in flight on. |
| `quarantine_cause` | **An input is quarantined only if it hung, or if it was in flight on two different sessions that ended.** A single crash never quarantines anything. |
| `crash_strikes_le` | One crash adds at most one strike to an input. |
| `inert`, `unsolicited_inert` | A reply to a message that was already answered, whose session has ended, or that was never sent changes nothing. Neither does a message nobody asked for. Both hold by definition. |
| `quarantined_unsent` | A quarantined input is not sent: no message, and no session. This holds by definition. |
| `fileAsked_cdn`, `pageAccepted_cdn`, `handed_parser` | The flows between helpers: CDN URLs only, and only the parser's own endpoint. These hold by definition; the rig checks that production computes the same. |

The model's helper chooses every reply freely. The proofs therefore don't depend on what helpers
send, only on how the client matches, bounds and validates replies.

`final_stable` doesn't rely on the system delivering each reply only once: the request's own
status guards it.

## 3. Production changes made for this slice

- **B1: one crash could quarantine an innocent input.**
  - **Before:** when a session was lost, each request that failed struck *every* input still in
    flight on the client. The requests fail one after another, so the j-th one to fail got j
    strikes. With two or more requests in flight, a single crash therefore quarantined all but
    one of them, at random, possibly an innocent image the user then could not open until
    restart.
  - **Now:** the channel reports which session was lost (`request(..., lost:)`), and an input
    gets one strike per ended session (`MediaQuarantine.strike(_:lostSession:)`). `InFlight` is
    gone.
- **B2: a cancelled caller's request stayed outstanding.**
  - **Before:** `XPCChannel.request` ignored task cancellation. A cancelled caller waited until
    the reply or the request's budget (up to 30 s), and a reply after the cancellation still
    completed the request.
  - **Now:** the request ends at once with `CancellationError`. If the cancellation came before
    sending, nothing is sent. A later reply is late. The per-request ending is now one object,
    `Outcome`, replacing `OnceFlag`.
- **B3: sessions opened for a request nobody waits for are closed.**
  - **Now:** a late reply to `openVideo` or `startVoiceNote` is decoded, and the session it
    names is closed (`closeVideo`, `cancelVoiceNote`). So is the session of an `openVideo` whose
    video info fails validation.
  - **Before:** a reply arriving between the client's budget and the service's own cancellation
    (one second later) left the session open in the helper. The decoder allows 24 open videos
    and the encoder 4 recordings. With B2, every cancelled open would have leaked one.
- **For the rig:**
  - `XPCChannel` has an internal init that takes the watchdog's sleep, so tests fire timeouts
    themselves.
  - `MediaXPCClient` has an internal init that takes its two channels.

## 4. What is only tested against Swift

**`BrokerConformanceTests.randomRuns`** (SignalMediaService). It runs 300 runs of 30 events
against production `MediaXPCClient`, with two hostile helpers: in-process listeners on raw XPC
that keep every message.
- **App calls:** `thumbnail` at three sizes, `openVideo`, and `startVoiceNote`, on four inputs.
- **Helper replies**, to any message the helper holds (in time, again, late, or on an ended
  session):
  - mostly the result the request expects;
  - otherwise any kind of result, a thumbnail of another size, an invalid video, garbage (some
    of it larger than the request's reply limit), an error, or a file descriptor in place of the
    payload;
  - sometimes with extra entries nobody reads: a file descriptor, an endpoint and a second payload.
- **Other events:** the helper ends its sessions, it sends messages nobody asked for, the
  watchdog fires for any request, and callers are cancelled.

After every event, production must reach the model's state, which is read from the oracle as the
run goes. That state covers:
- each call's result;
- the sessions each helper saw, and the messages it saw (releases included);
- the strikes of every input.

**`aLateNoticeAboutAnOldSessionLeavesTheLiveOne`** delivers a late notice about an ended session
by hand, after the next session opened, and checks that the live session stays. A late notice
is the ended session's cancellation handler, or a failed reply on it. In process such notices
arrive before the next event, so the runs never show this case. The model's crash is atomic and
has no late notices either.

**`gifURLsAreChecked`**: 300 URLs and pages are built from https or not, eight hosts, ports and
credentials, and run through production's `GifSearchClient.file` (against a recording GIF
service) and `PaginatedGifResults.validated`.

**`onlyTheParsersEndpointReachesTheFetcher`**: 150 answers from a hostile parser to the app's
empty message. Each answer has one of two endpoints, another XPC type under that key, or nothing.
It also has no payload, an empty one, or a byte, with or without an error. The test checks what a
recording fetcher is handed when production's `LinkPreviewFetcherClient` fetches a page.

Mutants (step 6), each of which must fail step 5:
- **The transport:**
  - a cancelled caller keeps waiting;
  - the watchdog does not end the request;
  - a reply after the end is dropped;
  - an old session's end drops the live one (killed by the late-notice test);
  - the endpoint entry is read whatever its XPC type.
- **Quarantine:**
  - one crash strikes an input once per request;
  - every crash counts as the same one;
  - an ended session strikes nothing;
  - a timeout does not quarantine;
  - a quarantined input is sent.
- **Releases:**
  - a video session opened too late is kept;
  - a video session whose answer is refused is kept;
  - a recording opened too late is kept;
  - every release goes to the decoder.
- **Validation:** a thumbnail is checked against a fixed size.
- **Between helpers:**
  - the parser's answer may carry a payload;
  - a GIF file is fetched from any URL;
  - a GIF URL with a port counts as the CDN;
  - a page's preview URLs are not checked.

All 19 are killed.

## 5. Assumptions and limitations

- **Peers.** Who may connect to whom (`XPCPeer` requirements) is not modelled. The rig's helpers
  are in-process anonymous listeners without requirements. `Tools/check-sandbox-profile.sh`
  tests peer requirements on the built app.
- **Crashes.** A crash is modelled as the helper ending its session. The client sees the same
  thing either way: every waiting message fails with "connection interrupted".
  - The model's crash is atomic. A request sent between a crash and the client hearing of it
    fails as lost, and strikes its input once. The rig waits for that notification.
  - A session that is cancelled between activation and installation behaves like a crash just
    after sending.
- **Opening a session can fail.** If no session can be made at all (the service is missing),
  production reports that as lost, and it strikes the input although the input never reached a
  helper. This is a pre-existing behaviour; the model does not cover it.
- **Reply size limit.** The limit checked before a reply is copied (`maxReplyBytes`) never
  decides an outcome in the model, because a reply over it is refused either way. It bounds
  memory, and `XPCTransportTests.limitsComeBeforeCopying` tests it.
- **Validation coverage.** The rig covers thumbnails (exact size), `openVideo` (video info),
  `startVoiceNote` (UUID) and releases (`MediaEmpty`). The decoder's other requests use the same
  path with their own `validated(...)` but are not in the rig.
- **What a reply can contain.** A helper can return content that is wrong but valid for its own
  request, for example another image of the same size. The broker bounds what a reply can be; it
  does not judge content. One decoder process holds every attachment it is given, and no
  isolation between those attachments is claimed.
- **Restarts.** Helper sessions are named by random UUIDs, so a session from before a restart is
  unknown to the new process (`invalidResult`). The model does not track helper-side state.
- **Link-preview image hrefs.** `FetchedLinkPreview.validated` (https, no control characters or
  spaces, bounded length) and SignalCore's `LinkPreviewRules.shouldPreviewHref` gate
  `fetcher.image`. That is read from code, not run by the rig. The fetcher re-checks every URL
  and redirect, and connects only to public addresses (`PublicDestinationTransport`).
- **Channels in the rig.** Only the decoder and voice channels are in the event rig. The parser,
  fetcher and GIF channels are the same `XPCChannel`; their flows between helpers are checked as
  data.

## 6. Files

`Broker/Model.lean`, `Broker/Props.lean`, `Broker/Proofs.lean`, `Broker/Trace.lean`, `Main.lean`
(the `oracle`: `step`, `deputy`, `explore`), `Audit.lean`, `audit-expected.txt`,
`explore-expected.txt`.
