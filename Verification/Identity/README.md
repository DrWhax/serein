# Identity approval: a Lean model, proofs, and conformance with production Swift

The second verification slice: what changes trust in a contact's identity key. It contains:

- a Lean 4 model of SignalCore's identity store (`ProtocolStore.saveIdentity`, `setVerified`,
  `setApproval`, `needsApproval`), of the two user actions that change trust
  (`Messenger.approveIdentities`, the safety-number dialog's "Send anyway", and
  `Messenger.setVerified`, its verification toggle), of the storage service's ContactRecord merge
  (`StorageRecords.mergeContact`, identity part), and of the Verified syncs they queue;
- machine-checked proofs of the properties below, for every peer and every reachable state;
- a Swift test that drives the **production** SignalCore APIs on a real (temporary, encrypted)
  GRDB database and compares them with the model after every step, and mutants that must be
  caught.

**The app is not formally verified.** The proofs are about the model. That production behaves
like the model is tested on many traces, not proved.

```
Tools/verify-identity.sh                 # everything (about 20 minutes: step 6 rebuilds per mutant)
SKIP_MUTANTS=1 Tools/verify-identity.sh  # a few minutes
SKIP_SWIFT=1 Tools/verify-identity.sh    # the Lean side only
```

The script checks, in order: no escape hatches (`sorry`, `axiom`, `native_decide`, …); `lake
build` (the kernel checks every proof); the audit (`Audit.lean` against `audit-expected.txt`:
the property definitions, every definition the theorem statements depend on with a hash, the
statements, and only `propext`, `Classical.choice`, `Quot.sound` as axioms); the explorer's
verdicts; the Swift conformance tests; the mutants.

## 1. What is modelled

| Model | Production |
|---|---|
| `Row` (key, `firstUse`, `recent`, verified state, `approved`) | an `identityKeys` row; `recent` is "timestamp within `approvalWindow` of now", `approved` is `nonblockingApproval` |
| `saveKey p k` | `ProtocolStore.saveIdentity`: first key (first use), same key (no change), or a new key (not first use, recent, not approved, a verified or unverified contact becomes unverified, a key-change notice) |
| `Snap` | `ReviewedIdentity`: our ACI and identity key, their service id and the key the safety number was computed from |
| `view p` (trace `show.p`) | `Messenger.safetyNumber(with:)`, which the review dialog and the safety-number sheet show |
| `confirm`, then `commit` | "Send anyway": the dialog keeps the shown snapshots; its task runs `approveIdentities` later, with anything in between |
| `race k p key` | the same commit, started while a key change holds the database's writer |
| `approve` | `approveIdentities`: one write transaction; every snapshot is validated first; then an unverified contact goes back to default (notice, queued Verified sync of the reviewed key) and the key is approved |
| `setVer` | `setVerified`: one write transaction; validated; the state, a notice, a queued Verified sync of the reviewed key |
| `account a k` | another account of ours (re-link, re-registration): another `Messenger` over the same database |
| `window p` | the approval window passing |
| `storage p k v first` | a ContactRecord merge: it takes the record's key only on the first sync, when we have no key, or when it is our key |
| `sync j` | the `j`-th queued VerifiedSync job runs (`Messenger.verifiedSyncMessage`, what the job sends) |

Ghost state, never read by a transition: `shown` (every safety number shown) and `grant` (for
each peer, the key its current approval or verification was granted for, and whether by the
user or by our own devices' storage record).

## 2. What is proved

Every property is a check on one step for a list of peers `ps`; each theorem proves it for every
list (so for every peer). Statements are in `audit-expected.txt`.

| Theorem | Statement (informally) | For |
|---|---|---|
| `staleNoChange_holds` | **A batch containing one stale identity makes no trust changes**: if any snapshot in a commit no longer validates (the peer's key changed, or our ACI or identity key did), no row, notice, grant or queued sync changes. The same for a stale verification. | every state |
| `targets_holds` | **Approval and verification target the reviewed key, all or nothing**: a commit changes only reviewed peers' rows, never their key, and only where the key on record is the reviewed one; a batch that validates is applied whole (every reviewed peer approved, not unverified, under the reviewed key). A verification changes only the reviewed peer, under the reviewed key. | every state |
| `keyChangeRevokes_holds` | **Either key changing invalidates the review**: a new key for a peer leaves the row neither approved nor verified, drops its grant, and every held snapshot with the old key stops validating; a new account of ours does the same for every snapshot of the old one. | every state |
| `grantShown_holds` | Every approved or verified row was granted for exactly the key on record; a grant by the user was for a key that had been shown. | reachable states |
| `syncShown_holds` | **Delayed sync work cannot substitute a newer key**: every Verified sync, queued or sent, carries a key that was shown for that peer. | reachable states |
| `syncExact_holds` | A sync job sends exactly what it carries; no other step sends one. | every state |
| `storageNoSubstitute_holds` | After the first sync, a ContactRecord with another key never replaces the key on record or its trust. | every state |
| `Inv.reach` | The invariant behind the two state properties. | reachable states |

**Validation and mutation are one transaction.** In the model `approve` and `setVer` are one
step by construction; `staleNoChange` and `targets` together say its effect is all or nothing,
judged on the state before any change. That production's transaction is atomic is tested: the
`race` event starts the commit while a key change holds the writer, and the "validates outside
its transaction" mutant must be caught.

## 3. Production change made for this slice

**The Verified sync is now a queued job, written in the same transaction as the trust change,
and it carries the reviewed key** (`ConversationJob.verifiedSync`, upstream's
singleProtoJobQueue). Before, `approveIdentities` and `setVerified` sent the sync directly after
their transaction:

- offline, the send threw after the trust change had committed, so the dialog's "Send anyway"
  ran its `cancelled` path: the approval stood, but the waiting send was dropped;
- the sync was then lost (never retried).

The job's message is built from the job alone (`verifiedSyncMessage`); it never looks the key up
again, by which time the contact may have a newer key nobody reviewed.

## 4. What is only tested against Swift

`IdentityConformanceTests` (in SignalCore's tests) runs each trace on production:
`safetyNumber(with:)`, `approveIdentities`, `setVerified` (through three `Messenger`s for our
accounts), `ProtocolStore.saveIdentity`, `StorageRecords.mergeContact` with a real
`Signalservice_ContactRecord`, and the VerifiedSync job's `verifiedSyncMessage`. After every step
both sides print the account, each peer's row (key, first use, recent, state, approved), its
key-change and verified-change notices (ours and from storage), the held and pending reviews,
the queued and sent syncs, and the result of the user action. Traces: `traces/regressions.txt`
(22), and 2,000 random traces of 40 events.

Mutants (step 6), each of which must make a trace disagree:

| Mutant |
|---|
| The review's peer key is not checked. |
| Our account's identity key is not checked. |
| Our ACI is not checked. |
| Approval validates in a read before its write transaction (a split transaction). |
| Verification is not validated. |
| The sync job looks its key up again when it runs. |
| The storage merge ignores the key match. |
| A new key keeps the old key's approval. |

## 5. Assumptions and limitations

- The rig's random traces use three peers, four keys and two ACIs × two keys of ours. The proofs
  are for any numbers.
- `recent` is wall-clock time in production (5 s, upstream's `TIMESTAMP_THRESHOLD`); the rig moves
  a row's timestamp back for `window`, and assumes a trace runs in under 5 s.
- The race event shows atomicity for one interleaving (the commit queued behind a key change
  holding the writer); a split implementation is caught because its read runs meanwhile. It does
  not show GRDB's or SQLite's transaction isolation, which is assumed.
- Sending is not modelled: a queued sync is run through the job's message builder, which is what
  the job hands to `sendToSelf`.
- The UI around the dialog (`IdentityReview` in the app: merging reviews, `cancelled`) is not
  in the model. It holds the snapshots `safetyNumber(with:)` returned and passes them to
  `approveIdentities` unchanged.
- The storage merge's other parts (names, profile key, conversation fields) are run by the rig
  but not observed.
- Incoming Verified sync messages are dropped by `MessageReceiver` (as upstream); not modelled.

## 6. Files

| File | Contents |
|---|---|
| `Identity/Model.lean` | State, events, `step`, `Reach`. |
| `Identity/Props.lean` | The properties, as checks on one step. |
| `Identity/Proofs.lean` | The proofs. |
| `Identity/Trace.lean`, `Main.lean` | Trace notation, observations, the `oracle` executable. |
| `Audit.lean`, `audit-expected.txt`, `explore-expected.txt` | What the script compares. |
| `traces/regressions.txt` | Regression traces. |

```
lake build
.lake/build/bin/oracle replay < traces/regressions.txt
.lake/build/bin/oracle check < traces/regressions.txt
.lake/build/bin/oracle explore 2026 40000 60
.lake/build/bin/oracle gen 1 10 40
```

Trace notation: `show.p`, `confirm.i.j…` (held indices), `commit.k`, `race.k.p.key`,
`verify.i.b`, `key.p.k`, `acct.a.k`, `win.p`, `store.p.k.{D,V,U}.{0,1}` (state, first sync),
`sync.j`.
