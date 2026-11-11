# Media revocation: a Lean model, proofs, and conformance with production Swift

The fourth verification slice: what lets the app display, play or export an attachment's
decrypted data. It contains:

- a Lean 4 model of `MediaAvailability.permits(path:messageId:)` and `fetch` (SignalCore), of the
  session's `applyMediaAvailability` (the lightbox, the inline video, the playing voice note, the
  decoded-pixel cache), and of a session in which messages are deleted, erased and expire while
  viewers are open, decodes are in flight, and the save panel is up;
- machine-checked proofs of the properties below;
- Swift tests that compare production's decisions (on a real database) and its viewers (on a
  real `SignalSession`) with the model, a test of the export's re-check, and mutants.

**The app is not formally verified.** The proofs are about the model.

```
Tools/verify-media.sh                 # everything
SKIP_MUTANTS=1 Tools/verify-media.sh
SKIP_SWIFT=1 Tools/verify-media.sh    # the Lean side only
```

## 1. What authorizes media

A **message–attachment relation** (`message_attachments`: message, file / thumbnail / screenshot
path) whose message exists, is not erased (deleted for everyone), and has not expired. A file path
alone authorizes nothing: two messages may reference one file (a forward), and deleting one of them
must not let its viewer go on because the other still references the file.

## 2. What is proved

| Theorem | Statement |
|---|---|
| `permits_other_ref` | **Authorization belongs to the relation, not the file**: another message referencing the same file changes nothing about whether this message may show it. |
| `deleted_permits_nothing`, `erased_permits_nothing`, `expired_permits_nothing` | A deleted, erased or expired message permits nothing, whatever else references the file. |
| `handedOutPermitted_holds` | Everything handed out in a step (an export after the save panel returns, a video or voice note started) is permitted by its own message at that step: **expiry or deletion while the save panel is open refuses the export.** |
| `decodePermitted_holds` | **Expiry during decoding**: a finished decode enters the cache only if its message still permits the file when it finishes. |
| `updateRevokes_holds` | After an availability update, the open lightbox's message is live and references every file it shows; the inline video and the voice note are their messages' own live references; every cached file is still referenced by some live message. |

**What the proofs are worth.** `permits_other_ref` and the three `_permits_nothing` theorems are
about the decision production's `permits` and `fetch` are compared with; `updateRevokes_holds` is
about `apply`, which production's `applyMediaAvailability` is compared with. The other two follow
from the model's actions re-checking at their moment, which is read from the code: the open,
play and decode re-checks are not run by a rig (the export's is).

**Latency, stated precisely.** An open viewer is closed at the next availability update: the
database observation (deletions, erasures) or the expiry timer (scheduled for the next
`expiresAt`). Between a revocation and that update, a viewer already open stays open; nothing new
is started, decoded into a viewer, or exported in that window (the actions re-check).

## 3. Production changes made for this slice

**M1: the lightbox's large decode is checked against its own message when it finishes.** It was
checked by file only (`mediaIsAvailable(path:)`): a lightbox whose message expired during the
decode, with another message referencing the same file, would have shown the result until the
expiry update closed it. Timeline decodes stay checked by file: their cache is shared by file, and
a bubble is only drawn for a live message.

**M2: the export after the save panel is one SignalCore function** (`MediaAvailability.export`):
the message's own reference is checked and the plaintext written in one database read. It was the
same check inline in the app; now the test can call exactly what the app calls.

## 4. What is only tested against Swift

- `MediaAvailabilityConformanceTests.randomStates` (SignalCore): 3,000 random states of a real
  database — four messages (live, erased, expiring at a random time, deleted), attachment rows
  sharing three files freely, a random `now` — comparing `permits` for every message × file,
  `permits` without a message, and `fetch` (whose message ids and paths must equal those of its
  references) with the oracle.
- `exportRechecksTheMessage`: the export succeeds while the message is live, is refused once it is
  erased, and once the other message referencing the same file expires.
- `MediaApplyConformanceTests.randomViewers` (app): 3,000 random viewer states (a lightbox with one
  or two attachments, or none downloaded; an inline video; a voice note; cached files) and random
  availabilities through `applyMediaAvailability`, against the oracle.

Mutants (step 6), each of which must fail step 5: `permits` ignores which message, erasure, or
expiry; `fetch` ignores erasure or expiry; the export does not check again; the lightbox, the inline
video or the voice note kept by any message's reference to its file; the lightbox ignores whether
its message is live; decoded pixels outliving the last reference.

## 5. Assumptions and limitations

- The session model's actions (open, play, decode, save) are modelled from the code; the rigs test
  the decision functions and `applyMediaAvailability`, not the asynchronous UI flows (decodes,
  `NSSavePanel`).
- The lightbox's open check covers the shown item (as production); its other attachments belong to
  the same message.
- Message rows store expiry as `expirationStartTimestamp + expireTimer`; the rig sets those columns.

## 6. Files

`Media/Model.lean` (the model), `Media/Props.lean`, `Media/Proofs.lean`, `Media/Trace.lean`,
`Main.lean` (the `oracle`: `db`, `apply`, `explore`), `Audit.lean`, `audit-expected.txt`,
`explore-expected.txt`.
