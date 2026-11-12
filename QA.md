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

**The Lean slices** (`lean:<slice>` = `Tools/verify-<slice>.sh`, twelve of them; see
[Verification/README.md](Verification/README.md)). Each script runs six steps, and all six must
pass:
1. no `sorry`, `admit`, `axiom` or other escape hatch in the Lean sources;
2. `lake build`: the kernel checks every proof;
3. the audit: the property definitions, a hash of every definition the theorems depend on, the
   theorem statements and their axioms (only `propext`, `Classical.choice`, `Quot.sound`) equal
   `audit-expected.txt`;
4. the random explorer's verdict for each property equals `explore-expected.txt` (the broker
   keeps one deliberately false property, `never-refused`, and the crypto slice four limits,
   which must still fail);
5. the Swift conformance rig: production runs against the model's oracle;
6. the mutants: each bug planted in production must make step 5 fail, and fail in the expected
   way.

**The package tests** (`test:<package>` = `swift test` in that package). Every test passes, and
no conformance suite is skipped (see the first trap in §3).

**The other checks:**
- `lint:codecs` (`Tools/lint-codecs.sh`): SignalCodecs imports no Apple media frameworks and no
  Foundation, uses no `Unsafe*` APIs outside `CodecCore/Unsafe`, and builds with strict memory
  safety.
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
- **SignalRingRTC:** `Tools/build-ringrtc-ffi.sh` once, to build the dylib its tests link.
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
| `SendLog` | `lean:resend` `test:core` |
| `JobQueue` | `lean:queue` `test:core` |
| `Identity`, `ProtocolStore`, `Messenger+IdentityApproval`, `StorageRecords+Conversations` | `lean:identity` `test:core` |
| `Calls.swift`, `CallLinksAndPresenting.swift`, SignalUI `ScreenShare.swift` | `lean:calls` `test:app` `test:ui` |
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

| Step | Lean theorems | Swift | Mutants killed | Time |
|---|---|---|---|---|
| `lean:attachments` | 5 | rig: 4 tests | 14 | 1.5 min |
| `lean:broker` | 19 | rig: 4 tests | 19 | 2.5 min |
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
| `test:core` | | 285 tests | | 1 min |
| `test:i18n` | | 24 tests | | 5 s |
| `test:media` | | 78 tests | | 10 s |
| `test:ringrtc` | | 5 tests | | 2 s |
| `test:ui` | | 561 tests | | 13.5 min |
| `test:app` | | 35 + 5 tests | | 20 s |
| `lint:codecs` | | ok | | 3 s |
| `app:sandbox` | | build, then `check-sandbox-profile: ok` | | 2.5 min |
| `vectors` | | upstream read all 34 Swift outputs | | 5 s |

`QUICK=1` skips the mutants; most of a `lean:` step's time is its mutants (each rebuilds and
reruns the rig). Update this table when the counts change on purpose.
