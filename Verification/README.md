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
| [Queue](Queue/README.md) | The job queue: one worker, shutdown's postcondition, termination if handlers finish | `Tools/verify-queue.sh` |

Every script: rejects escape hatches (`sorry`, `axiom`, …); builds (the kernel checks every proof);
diffs an audit of the property definitions, every definition the theorems depend on (hashed), the
statements and their axioms (only `propext`, `Classical.choice`, `Quot.sound`) against
`audit-expected.txt`; diffs the random explorer's verdicts; runs the Swift tests; applies each
mutant and requires the tests to fail. `SKIP_MUTANTS=1` and `SKIP_SWIFT=1` skip the slow steps;
`UPDATE_EXPECTED=1` rewrites the expected files (review the diff). Lean 4.35.0, core only.
