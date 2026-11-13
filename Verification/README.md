# Verification

Lean 4 models of security-relevant parts of Serein, machine-checked proofs about them, and Swift
tests that compare production with each model (plus mutants: bugs planted in production that the
tests must catch). **The app is not formally verified**: proofs are about the models, and that
production behaves like them is tested, not proved. Each slice's README says exactly what is
proved, what is only tested, and what is assumed.

| Slice | What it covers | Run |
|---|---|---|
| [CallCapture](CallCapture/README.md) | Call and capture lifecycle: call events, camera, screen sharing, under any main-actor schedule | `Tools/verify-calls.sh` |
| [Identity](Identity/README.md) | Identity-key approval and verification: the reviewed key, stale reviews, one transaction, Verified syncs | `Tools/verify-identity.sh` |
| [Send](Send/README.md) | Send authorization: blocking (direct and group), removed messages, the retraction exemption, the submission boundary | `Tools/verify-send.sh` |
| [Media](Media/README.md) | Media revocation: message–attachment authorization, viewers closing, re-checks after decoding and the save panel | `Tools/verify-media.sh` |
| [Queue](Queue/README.md) | The job queue: one worker, shutdown's postcondition, existence of a terminating drain schedule | `Tools/verify-queue.sh` |
| [Group](Group/README.md) | Group authorization and sender-key rotation: when a membership change takes effect, who gets content and our key, rotation after removals | `Tools/verify-group.sh` |
| [Modifiers](Modifiers/README.md) | Edits, deletes and replay: the right author, message and conversation, newest revision shown, no resurrection, modifiers before their target, a fair waiting list | `Tools/verify-modifiers.sh` |
| [Resend](Resend/README.md) | Retry and resend: the send log as a boundary, only what that device was delivered goes back, a day, story lists, the retry limit | `Tools/verify-resend.sh` |
| [Attachments](Attachments/README.md) | Attachment authentication: only the named upload's verified plaintext reaches decoding or export, nothing partially validated is published, bounded transfers | `Tools/verify-attachments.sh` |
| [Codecs](Codecs/README.md) | Codec components: byte cursor reads stay in their region, regions consumed exactly, allocation within static budgets, box boundaries and the box budget, the bit reader | `Tools/verify-codecs.sh` |
| [Broker](Broker/README.md) | The app and its sandboxed helpers: a reply completes only its own outstanding request, once; cancellation, crashes, late and duplicate replies; no helper session left behind (a video, a recording, a microphone recording); quarantine strikes; what one helper's answer may ask of another | `Tools/verify-broker.sh` |
| [CallBoundary](CallBoundary/README.md) | The calling service (ringrtc, in its own sandbox) as the adversary: what it can make the app send (signalling, incoming calls, call and group messages, rings), and the endpoint's generations: commands of lost calls refused, losses reported once, everything made before a loss ended | `Tools/verify-callboundary.sh` |
| [Crypto](Crypto/README.md) | Crypto formats: transport padding; separation of every key SignalCore derives; profile padding; what an accepted storage manifest or record, profile field, sticker, provisioning envelope or device name can have been; no padding oracles | `Tools/verify-crypto.sh` |

Every script: rejects escape hatches (`sorry`, `axiom`, …); builds (the kernel checks every proof);
diffs an audit of the property definitions, every definition the theorems depend on (hashed), the
statements and their axioms (only `propext`, `Classical.choice`, `Quot.sound`) against
`audit-expected.txt`; diffs the random explorer's verdicts; runs the Swift tests; applies each
mutant and requires the tests to fail. `SKIP_MUTANTS=1` and `SKIP_SWIFT=1` skip the slow steps;
`UPDATE_EXPECTED=1` rewrites the expected files (review the diff). Lean 4.35.0, core only.

`python3 Tools/test-verification-runners.py` tests the runner failure paths with stub oracles:
malformed regression input and explorer failures before or after valid-looking output must fail
the verification command. Oracle exit status is checked before output is filtered.

## Progress and async boundary regressions

`python3 Tools/verify-model-progress.py` builds isolated model copies and kills no-op,
output-dropping and reject-all transitions in Media, Attachments, Identity, Send, Group, Queue
and Resend (21 mutants). Their `Nonvacuity.lean` files assert successful behavior independently
of preservation proofs. These are finite positive regressions, not universal liveness proofs;
a safety property alone may correctly accept a system that never produces output.

`python3 Tools/verify-async-boundaries.py` runs the new Swift regressions and requires mutations
of identity submission checks, resend context, publication snapshots/leases, and
playback cancellation to fail at runtime. It temporarily edits one source at a time and restores
it even on failure; do not run alongside other edits to those files.
