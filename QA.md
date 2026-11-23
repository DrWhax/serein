# QA: checking that every test and proof still passes

One command runs everything, one step after another, and prints a table:

```
Tools/qa.sh                          # everything, mutants included (slow, see the baseline below)
QUICK=1 Tools/qa.sh                  # without mutants
Tools/qa.sh lean:broker test:media   # only these steps
Tools/qa.sh --list                   # the steps
```

Each step's full output goes to `.build/qa/<step>.log`. The run exits 1 if any step failed,
and its last line says `QA: ok` or `QA: FAILED`. Run it on an otherwise idle machine: some tests
use the real clock (the audio and video playback engines, the animated-image test).

## 1. What "everything passes" means

**The Lean slices** (`lean:<slice>` = `Tools/verify-<slice>.sh`, thirteen of them; see
[Verification/README.md](Verification/README.md)). Each script runs six steps, and all six must
pass:
1. no `sorry`, `admit`, `axiom` or other escape hatch in the Lean sources;
2. `lake build`: the kernel checks every proof;
3. the audit: the property definitions, a hash of every definition the theorems depend on, the
   theorem statements and their axioms (only `propext`, `Classical.choice`, `Quot.sound`) equal
   `audit-expected.txt`;
4. the random explorer's verdict for each property equals `explore-expected.txt` (the broker
   keeps one deliberately false property, `never-refused`, the crypto slice four limits, and
   the call boundary one, `message-to-app-known`; they must still fail);
5. the Swift conformance rig: production runs against the model's oracle;
6. the mutants: each bug planted in production must make step 5 fail, and fail in the expected
   way.

**The package tests** (`test:<package>` = `swift test` in that package). Every test passes, and
no conformance suite is skipped (see the first trap in §3).

**The other checks:**
- `lint:codecs` (`Tools/lint-codecs.sh`): SignalCodecs imports no Apple media frameworks and no
  Foundation, uses no `Unsafe*` APIs outside `CodecCore/Unsafe`, and builds with strict memory
  safety.
- `lint:calling` checks the calling package's Swift sources and verifies strict memory safety
  and warnings as errors in debug and release compiler invocations. It checks that the source
  lint rejects an explicit safety escape and compiles the interop test targets without linking
  the native reference library.
- `calling:staged` checks the signed app built by `app:sandbox`. Two strict Swift peers send generated video of different brightness through a loopback TURN relay, verify the decoded picture in both directions and hang up. The QA host uses the bundle’s XPC signing identifiers and exchanges signaling in memory. Its temporary copy of the calling service has a loopback UDP grant and no microphone entitlement. To check another signed build, run `python3 Tools/check-staged-calling.py /path/to/Serein.app`. The standalone command defaults to `App/SignalSafe/.build/Serein.app`. A team-signed build requires the matching `SIGNALSAFE_SIGN_IDENTITY`.
- `calling:playout` exercises the production PCM renderer in the signed calling sandbox and checks Core Audio’s output state. Run `Tools/check-calling-playout.sh --duplex` to open the microphone too. The probe renders locally muted PCM and checks that both devices stop.
- `Tools/check-calling-playout.sh --echo` measures acoustic echo through the current speaker and microphone. It plays the same quiet signal three times with processing off, on, then off again. The probe keeps microphone samples in memory and reports the reduction in dB. Exit status 77 means the output was muted or there was insufficient signal for a reliable comparison. A valid measurement passes at 3 dB of reduction or more. Use `--echo-route` to inspect the output settings or `--echo-calibration` to check the measurement with synthetic audio.
- `calling:speech` checks two-way decoded speech over direct UDP with each peer originating a call. It synthesizes two different phrases locally with macOS `say`. A private build of RingRTC reads one phrase from a file at its microphone boundary and writes its decoded PCM to a file at its speaker boundary. Serein's Swift Opus encoder and decoder process the other side. The check compares each playout against both phrases. The hardware microphone and speakers stay idle.
- `calling:speech-relay` repeats both calls through a local authenticated coturn server and requires RingRTC to report a relay candidate at both ends of its selected pair. Install coturn's `turnserver` on the test machine or set `SEREIN_TURNSERVER` to an existing executable. The test server binds only to loopback.
- Run `python3 Tools/check-calling-dred.py --weights /path/to/calling-dred_weights-1_6_1-f4aed08a.bin` to test packet-loss recovery with Serein’s optional Signal speech model. The check verifies the model’s SHA-512, synthesizes speech to a file, and drops consecutive 20 ms packets in both directions between Swift and the Opus codec in the pinned RingRTC archive. Add `--fixture /path/to/output` to retain the packets, recovered audio and native PCM reference. The codec test uses local files throughout. With the local SFU binary available, run `python3 Tools/check-calling-speech.py --group --seconds 15 --dred-weights /path/to/model.bin` for file-backed two-way speech through both a Signal group and an administrator-approved call link. It drops pairs of packets in both directions between RingRTC and the SFU and checks the Swift receiver’s DRED recovery count. To exercise XPC asset registration, direct calls in both roles and RTCP under bidirectional audio loss, run `python3 Tools/check-calling-speech.py --dred-weights /path/to/model --seconds 60`. Use `Tools/with-calling-turn.py python3 Tools/check-calling-speech.py --relay --dred-weights /path/to/model` to require relay candidates at both ends.
- `calling:turn-streams` checks two-way audio with only server-reflexive ICE candidates, then deletes a live UDP relay allocation and requires a private call to recover two-way audio. It exercises both ICE roles with a relay-only endpoint and a direct-only peer. For each call direction it also requires decoded VP8-only and VP9-only video through both symmetric and asymmetric relay routes, and tests retransmission with a deliberately dropped video packet on a direct route. It checks TURN over TCP and TLS with coturn. TCP-only runs exercise UDP fallback and two-way speech through the endpoint. TLS runs use a fresh local certificate authority, reject an untrusted chain and a wrong hostname, and exchange encrypted speech with RingRTC in both roles. The RingRTC side uses a UDP relay for the TLS test because the stock binary has its own certificate roots.
- `calling:sfu` tests two-way encrypted group audio, video and device data over UDP, TCP and TLS against the upstream Signal Calling Service. Mixed RingRTC/Swift calls exercise encrypted video retransmission and scalable VP9 camera and screen sharing. Three-client tests exercise independent VP8 subscriptions at 180p, 360p and 720p. Set `SEREIN_TEST_SFU_BINARY` to its `calling_backend` binary. Every listener binds to loopback. Linux uses the SFU's native stream listeners. The upstream macOS packet server supports UDP, so the runner bridges RFC 4571 streams to the real SFU locally. The TLS fixture uses a private, temporary certificate authority. The admission test runs the upstream backend in ad hoc mode, exercises approval, denial, removal and blocking, and checks that pending participants cannot publish media. Its HTTP adapter supplies the development server’s local credentials. The two-recipient chat test uses the mock server pinned in Serein’s lockfile. Set `SIGNAL_DESKTOP_CHECKOUT` to a Signal Desktop checkout at `5dad34ad5ea1a5b6229412e5c8ac0a696ff7532d` when running `Tools/build-mock-server.sh`. The pinned calling backend sets `drop_fragmentable_updates` to `true` and suppresses its endorsement packets, so this run exercises individual delivery. To cover SFU-issued endorsements too, use a second checkout at the same revision and apply `Tools/calling-sfu/deliver-test-endorsements.patch` before building `calling_backend`. Set `SEREIN_TEST_SFU_ENDORSEMENT_BINARY` to that executable. The suite then verifies the SFU’s signed updates in SignalCore, including the token’s exact admitted recipients.
- `CallLinkFrontendTests` checks encrypted titles and admin credentials against Signal’s HTTP frontend with an ephemeral DynamoDB emulator. In a checkout of `signalapp/Signal-Calling-Service` at `8718215e64a7259e88d9731a24491664ed0e0532`, copy Serein’s `Tools/calling-sfu/issue-test-credentials.rs` to `frontend/examples/serein_local_credentials.rs`. Run `cargo +stable build --locked --bin calling_frontend --example serein_local_credentials`. Install `boto3` and `moto[server,dynamodb]` in a test virtual environment. From Serein, run the following with that environment active and `SFU_CHECKOUT` set to the upstream checkout. The test issues its own credentials.

  ```sh
  python3 Tools/with-calling-frontend.py \
    --frontend "$SFU_CHECKOUT/target/debug/calling_frontend" \
    --issuer "$SFU_CHECKOUT/target/debug/examples/serein_local_credentials" \
    swift test --package-path Packages/SignalRingRTC -c release --enable-testable-imports --filter CallLinkFrontendTests
  ```

  To check a solo call, build `calling_backend` as well and add `--backend "$SFU_CHECKOUT/target/debug/calling_backend"` alongside `--frontend`. The Swift backend joins an empty approval-required room as its owner over XPC, establishes ICE, and RingRTC checks that exactly that device was admitted. The test uses simulated audio devices. The upstream frontend requires the local media backend’s signaling listener on `127.0.0.1:8080`.

- To add a native RingRTC participant to a signed Serein QA build, build it with `SEREIN_QA_CALL_PEER=1 Tools/build-app.sh` (a shipping build compiles the test peer out, and `build-app.sh` fails one that still contains it), then run `Tools/stage-call-test-peer.py /path/to/QA/Serein.app` before launching it. This embeds a separate sandboxed XPC service and re-signs that app copy. For a team-signed app, set `SIGNALSAFE_SIGN_IDENTITY` to its signing identity. Join the link in Serein and choose **Start test peer**. Other devices already in the room may belong to the same Signal account. The test picture and voice are delivered to Serein on this Mac. For an approval-required link, use the account that owns it. The peer sends moving color bars and a repeating spoken phrase, uses generated input, and discards incoming audio. **Stop test peer** removes it. For a loopback SFU fixture, supply `--local-sfu-udp-port` and `--local-sfu-tcp-port` with that run’s ports so the peer can reach only the test backend.

- To exercise this through the signed app host with a disposable account, first run `Tools/build-app.sh` with ad-hoc signing and `Tools/build-mock-server.sh`. From the workspace root, activate the Python environment with boto3 and moto, then run the following. The fixture checks an owner’s room and an unrestricted guest link using simulated audio devices. Serein receives the peer’s video and speech. The fixture supplies its own window at the system picker callback and captures it through ScreenCaptureKit. RingRTC checks two patterns in its decoded frames, observes when sharing stops, and confirms that a third window update stays local. This test needs an unlocked graphical session.

  ```sh
  SEREIN_TEST_MOCK_ZK_PARAMS_FILE=Tests/MockServer/.mock-server/certs/zk-params.json \
    python3 Tools/with-calling-frontend.py \
      --frontend "$SFU_CHECKOUT/target/debug/calling_frontend" \
      --backend "$SFU_CHECKOUT/target/debug/calling_backend" \
      python3 Tools/check-call-link-peer.py
  ```

- `python3 Tools/check-calling-speech.py --live-hardware` places a local call through a signed, launchd-hosted `SignalCalling.xpc`. The Swift endpoint opens the default microphone and speaker. RingRTC sends a quiet spoken phrase, reports the microphone RTP it receives, and discards the samples. The host checks playback, mute and hangup. macOS may request microphone permission. As in the existing local video test, the temporary service profile permits same-Mac UDP. The app bundle keeps its production profile.
- `Tools/with-calling-turn.py python3 Tools/check-calling-speech.py --live-hardware --relay` runs the hardware call through coturn. RingRTC must report a relayed local and remote candidate for the selected pair.
- `App/SignalSafe/.build/Serein.app/Contents/MacOS/Serein --check-calling-service` starts the signed production endpoint, queries its audio devices and exits before opening the account. `Tools/check-shipping-calling.py` verifies the signature and checks the bundle and Mach-O files for native RingRTC and WebRTC. The release build also passes the calling service’s linker map to this check.
- `app:sandbox` (`Tools/build-app.sh`, then `Tools/check-sandbox-profile.sh`): builds Serein.app,
  then runs each XPC service under its real Seatbelt profile. Each may do what its process needs
  and nothing else, and the services refuse a host signed with any other identifier.
- `vectors` (`Tools/crypto-vectors/check.sh`): the Swift crypto matches Signal-Desktop's both
  ways. Desktop's TypeScript still produces the committed vectors, and upstream's code decrypts
  what Swift encrypts.

## 2. Before the first run

- **Swift:** Xcode with the macOS 27 SDK. `Tools/build-app.sh` must work, which also applies
  `Tools/vendor-patches` to the submodules.
- **Lean:** `brew install elan-init`. Each slice's `lean-toolchain` pins Lean 4.35.0, which elan
  fetches. The scripts load `~/.elan/env` themselves.
- **Native reference for interop tests.** `Tools/qa.sh interop:prepare` initializes the pinned RingRTC checkout, fetches its verified WebRTC artifact and builds the reference library. The full QA suite includes this step. The production app build and `calling:staged` run independently of it.
- **Vectors:** Node 22 or newer, the `Signal-Desktop` checkout, and network for the first
  `npm install`.
- **Peer requirements:** with `SIGNALSAFE_SIGN_IDENTITY=<identity>` set (for both
  `build-app.sh` and `check-sandbox-profile.sh`), the check also proves that an ad-hoc-signed host
  with the app's own identifier is refused. Without it, that case is not tested.

## 3. Traps

- **A missing oracle skips its conformance suite, silently.** Each conformance suite is
  `.enabled(if: <Slice>Oracle.available)`. The oracle is `Verification/<Slice>/.lake/build/bin/oracle`,
  and `.lake` is not committed. On a fresh clone a plain `swift test` therefore passes while
  skipping every Lean comparison. `Tools/qa.sh` runs the `lean:` steps first, which build the
  oracles, and fails a test step whose log says "build the oracle". By hand: run
  `lake build` in each `Verification/<Slice>` (or its verify script) first, and look for that
  phrase in the output.
- **A stale oracle tests the old model.** After changing a Lean model, run its verify script (it
  rebuilds) before running `swift test` alone.
- **Don't use `swift test --skip Live` in SignalMediaService.** It also skips the broker's
  `aLateNoticeAboutAnOldSessionLeavesTheLiveOne`, the only test that kills one of its mutants.
  The live network tests are already off unless `GIPHY_LIVE` or `LINK_PREVIEW_LIVE` is set.
- **Mutants edit production files in place.** The scripts restore them on exit, interrupt and
  termination. A run killed with `kill -9` cannot, so check `git diff` afterwards. Don't edit a
  file while a mutant may be applied to it.
- **One verify script at a time.** They build the same packages, and SwiftPM serializes builds of
  one package. `Tools/qa.sh` runs everything in sequence.
- **`UPDATE_EXPECTED=1` rewrites `audit-expected.txt` and `explore-expected.txt`.** Use it only
  when you meant to change what a slice states, and read the diff: it is the list of changed
  definitions and statements.
- **The SignalUI tests open a small blank window** for under a second
  (`AnimatedImageTests.aTimelineViewPlaysTheFrames`: SwiftUI only drives a `TimelineView` in a
  window).

## 4. What to run after a change

`Tools/qa.sh` before an installer or a release. For a smaller change, the steps that cover it.
The files listed are the ones each slice's mutants patch; the slice's README says everything its
rig covers.

| You changed | Steps |
|---|---|
| `CodecCore`: `ByteSlice.swift` (byte cursor), `Parser.swift`, the bit readers | `lean:codecs` `test:codecs` `lint:codecs` |
| A decoder in SignalCodecs (PNG, GIF, WebP, JPEG, HEIF, AV1, HEVC, H.264, audio) | `test:codecs` `test:media` `lint:codecs` (decoders are not modelled in Lean) |
| `MediaXPCInterface` (`XPCTransport`, `MediaXPC`, `Containment`, `WebServices`), a service's handler or `main.swift`, a `.sb` profile | `lean:broker` `test:media` `app:sandbox` |
| SignalCore `AttachmentCipher`, `AttachmentDownloadManager`, `HTTPClient` | `lean:attachments` `test:core` |
| SignalCore `MediaAvailability`; the app's image cache and viewers (`SignalSession`, `MediaAvailability.swift`, `MediaViewer.swift`) | `lean:media` `test:core` `test:app` |
| `MessageSender`, `GroupSender`, `SocketManager` | `lean:send` `lean:group` `test:core` |
| `MessageModifiers`, `MessageStore` | `lean:modifiers` `test:core` |
| View-once media: the app's `ViewOnce.swift`, `Messenger.openViewOnce`, `TimelineMessage.isViewOnce` | `lean:modifiers` `test:core` `test:app`, and one real view-once photo in the app |
| `SendLog` | `lean:resend` `test:core` |
| `JobQueue` | `lean:queue` `test:core` |
| `Identity`, `ProtocolStore`, `Messenger+IdentityApproval`, `StorageRecords+Conversations` | `lean:identity` `test:core` |
| `Calls.swift`, `CallsExtras.swift` (group rings, peek, raised hands, reactions), `CallLinksAndPresenting.swift`, SignalUI `ScreenShare.swift` | `lean:calls` `test:app` `test:ui` |
| SignalRingRTC (`RingRTC`, `RingRTC+Events`, `Call`, `GroupCall`, `CallXPC`, `CallService`), `CallingService`, `Sandbox/SignalCalling.sb` | `lean:callboundary` `test:ringrtc` `test:core` `lean:calls` `app:sandbox` |
| SwiftCalling speech codec, ICE, SRTP or TURN | `lint:calling` `test:ringrtc` `calling:speech` `calling:speech-relay` `calling:turn-streams` |
| SignalRingRTC `CallLinkRootKey` (call-link keys, era ids) | `test:ringrtc` (compared with ringrtc's own) |
| Voice-note recording (`VoiceNoteService`, `MediaXPCClient.recordVoiceNote`, the app's `VoiceRecorder.swift`), `Sandbox/SignalVoiceNoteEncoder.sb`, `Serein.sb`'s microphone rule | `lean:broker` `test:media` `app:sandbox` (it records a second from the terminal's microphone), and one real voice note in the app |
| SignalUI components | `test:ui` (the snapshot tests compare with upstream Storybook captures) |
| Transport padding (`MessageSender.pad`, `MessageReceiver.unpad`); a key derivation (`StorageService`, `Stickers`, `StorageRecords.roomId`, `ProfileService.accessKeyVerifier`, `ProvisioningCipher`, `DeviceNameCipher`); profile padding (`ProfileService`); `AttachmentCipher.decryptV1` | `lean:crypto` `test:core` `vectors` |
| Other crypto in SignalCore | `vectors` `test:core` |

## 5. When a step fails

- **Lean steps 1–4:**
  - **1:** an escape hatch was added.
  - **2:** a proof no longer checks (`lake build` output in the log).
  - **3:** the audit differs. A definition a theorem depends on, or a statement, changed. Read
    what the theorem now says before accepting it with `UPDATE_EXPECTED=1`.
  - **4:** the explorer found a different verdict.
- **Step 5:** production and the model disagree. The log names the first event where they part
  ("disagree at step N", with both states). Fix production or the model, whichever is wrong.
- **Step 6:**
  - **"mutant … survived":** the rig no longer catches that bug. Strengthen the rig; don't drop
    the mutant.
  - **"failed, but not as expected (did it build?)":** the mutant's pattern no longer matches
    production, or the mutated code doesn't compile. Update the pattern to the new code.
  - Broker only: `ONLY='<mutant name>' Tools/verify-broker.sh` reruns one mutant.
- **Test steps:** the log has each failing test, with Swift Testing's `✘` lines and XCTest's
  `error:` lines. A "build the oracle" failure means a `lean:` step has not run (§3).

## 6. Baseline

The last full run, for comparison: the counts to expect and roughly how long each step takes on
this machine. The Lean column is the number of theorems in `audit-expected.txt`.

2026-11-11, on top of 3c15ad7 with the changes committed after it; the whole run took about an
hour. The SignalMediaService, SignalUI, SignalCore and app tests, Broker, the lint, the sandbox
check and the vectors are from a second run after the fixes that run needed; everything else is
from the first. `lean:crypto` and `test:core` are from a later run, when the crypto slice was added.
`lean:callboundary`, `lean:broker`, `lean:calls`, `app:sandbox` and the RingRTC, SignalCore, media
and app tests are from 2026-11-12, after ringrtc moved into SignalCalling.xpc. The SignalCore,
SignalUI and app tests were rerun later that day, after the unconnected controls were wired up.

| Step | Lean theorems | Swift | Mutants killed | Time |
|---|---|---|---|---|
| `lean:attachments` | 5 | rig: 4 tests | 14 | 1.5 min |
| `lean:broker` | 19 | rig: 4 tests | 20 | 2.5 min |
| `lean:callboundary` | 9 | rig: 1 test (200 runs) | 18 | 4 min |
| `lean:calls` | 15 | rig: 16 tests | 10 | 16.5 min |
| `lean:codecs` | 9 | rig: 4 tests | 21 | 2 min |
| `lean:crypto` | 32 | rig: 9 tests | 24 | 2.5 min |
| `lean:group` | 7 | rig: 3 tests | 8 | 1 min |
| `lean:identity` | 8 | rig: 2 tests | 8 | 4.5 min |
| `lean:media` | 9 | rig: 2 tests | 11 | 1.5 min |
| `lean:modifiers` | 16 | rig: 3 tests | 20 | 2.5 min |
| `lean:queue` | 5 | rig: 2 tests | 5 | 3 min |
| `lean:resend` | 6 | rig: 1 test | 11 | 1 min |
| `lean:send` | 14 | rig: 3 tests | 12 | 2 min |
| `test:codecs` | | 146 tests (12 test runs) | | 0.5 min |
| `test:core` | | 292 tests | | 1 min |
| `test:i18n` | | 24 tests | | 5 s |
| `test:media` | | 80 tests | | 10 s |
| `test:ringrtc` | | 17 tests | | 1.5 min |
| `test:ui` | | 569 tests | | 14 min |
| `test:app` | | 36 + 5 tests | | 20 s |
| `lint:codecs` | | ok | | 3 s |
| `app:sandbox` | | build, then `check-sandbox-profile: ok` | | 2.5 min |
| `vectors` | | upstream read all 34 Swift outputs | | 5 s |

`QUICK=1` skips the mutants; most of a `lean:` step's time is its mutants (each rebuilds and
reruns the rig). Update this table when the counts change on purpose.
