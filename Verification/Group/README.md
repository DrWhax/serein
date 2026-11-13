# Group authorization and sender-key rotation

The sixth verification slice: who a group send reaches, and who holds our sender key, while the
membership and members' device lists change, other sends run, sends stop part-way and are retried.
It contains a Lean 4 model of `GroupSender.send` / `sendViaSenderKey` from planning to submission,
machine-checked proofs, Swift tests comparing production's decisions with the model, and mutants.

**The app is not formally verified.** The proofs are about the model.

```
Tools/verify-group.sh                 # everything
SKIP_MUTANTS=1 Tools/verify-group.sh
SKIP_SWIFT=1 Tools/verify-group.sh    # the Lean side only
```

## 1. When a membership change takes effect

**When it is committed to the local group state.** From that moment:

- every group send plans from it (`GroupSendPlan.make`): **after** the caller's uploads (the plan is
  made inside `GroupSender.send`, which runs once the attachments are uploaded), and again on every
  retry (a 409/410 device-list refresh, a refused submission);
- content goes to members only; a group update also reaches the accounts it removes (and invitees,
  requesters), one by one, never through our sender key;
- every submission of a group payload — a key distribution, content, a multi-recipient message — is
  checked against the membership at that moment (`MessageSender.authorization`); a refusal makes
  the send plan again (`SendError.notAMember`).

So a member removed while a send uploads, between its key distribution and its submission, or
between two attempts, receives neither the content nor a newly distributed key. What was submitted
before the commit is not recalled.

## 2. What is proved

| Theorem | Statement |
|---|---|
| `keysToMembers_holds` | **Removed members get no new sender key**: a key distribution goes only to an account that is a member at that submission. |
| `contentToMembers_holds` | **Removed members get no newly authorized content**: content goes only to members at that submission. |
| `Inv.reach`, `holdersRecorded_holds` | Every device holding our current key is reserved in its generation, including deliveries completed after a reset and sends that stop part-way. |
| `contentKeySafe_holds` | When content submits, every holder of the send's captured key generation is a current member, and the key is not marked stale. |
| `rotation_targets`, `rotated_holds` | **Rotation after a removal**: once a send has planned, every device recorded as having our current key belongs to one of its targets, members at that moment. This is a planning postcondition; `contentKeySafe_holds` separately checks the key at submission. |
| `out_step` | What a step can add to the output (the basis of the first two). |

`keysToMembers` and `contentToMembers` follow from the model checking at each submission; what
ties production to them is the conformance of `authorization` (and that `GroupSender` passes it to
every submission). `holdersRecorded` and `rotated` are the substantive ones: they hold because of
the rotation rule and the recording rule, and the explorer finds `holdersRecorded` false with
production's previous recording rule (below).

## 3. Production changes made for this slice

**G1: a group send plans from the membership when it runs, and the submission checks it.**
`GroupSender.send` took its recipients from the caller (the group state read when the job started,
before uploads) and the submission checked only the group's block. A member removed during an
upload got the content; and when that send also replaced our key (expiry, a member's identity
change), they got the new key. Now the plan is made from the committed membership inside
`GroupSender.send`, content drops non-members, and `authorization` refuses a group payload to a
non-member (`recipients` for the multi-recipient submission, `to` for one-by-one sends and key
distributions).

**G2: a group update reaches those it removes without our sender key.** It went through the
sender-key path to members before and after, so a removed member could be handed a new key; now the
non-members it reaches get it one by one.

**G3: reservations and delivery completions are separate.** Planning, rotation, reservation and
construction of the key distribution message share one database transaction. Reservations merge
with persisted state before network delivery, so concurrent sends cannot lose a potential holder.
Confirmed deliveries merge in a later transaction under the captured generation; failed sends
still distribute on retry. A completion for a retired generation cannot restore its old snapshot.

**G4: encryption and submission check the captured generation and all reserved holders.**
Every reset creates a fresh local generation identifier (the protocol distribution id stays the
same). The encryption transaction checks that identifier, the reset flag and current membership
of every reserved holder. The transport repeats the check in its authorization read immediately
before submission. A failure replans through the existing bounded retry path. Existing persisted
state without a generation is reset on first use.

## 4. What is only tested against Swift

`GroupConformanceTests` (SignalCore): random cases each of `GroupSendPlan.make` (membership,
recipients with duplicates and ourselves, update or content), `SenderKeyInfo.rotation` and
`recording` (recorded devices, the send's devices, its targets), and `authorization` for a group
payload on a real database (a group in `GroupStore` with random members; random DataMessages with or
without a group context and content, and key distribution messages; one-by-one and multi-recipient),
together with `isGroupUpdateOnly`.

`GroupReservationTests` exercises production database operations: two sends held before delivery
must persist the union of their reservations and later completions; removal of an unaddressed
holder invalidates an already-created authorization closure; a reset rejects stale generations
and late completions; interrupted reservations still distribute on retry; legacy state migrates.
`Group/Regression.lean` kernel-checks the adversarial interleavings and a fabricated bad output
that the strengthened property must reject.

Mutants (step 6): content plans include non-members; a group update no longer reaches those it
removes; a removed account does not rotate our key; the key record replaced, not added to; the
submission check skips membership; a one-recipient group send not checked; a group update with
content counts as an update; a sender-key message counts as a group update; reservations count as completed delivery;
completion replaces concurrent deliveries; generation checks are omitted; removed holders no
longer block submission. All 12 must be killed.

## 5. Assumptions and limitations

- The send pipeline (plan, distribute, submit) is modelled from `GroupSender`; it is not run against
  production, which needs a server and group send endorsements. The rig compares the decisions it
  is made of.
- Endorsements are not modelled: members without one get one-by-one sends, which are content to
  members and checked the same way.
- When another send replaces the key, an older send is refused at encryption or submission and
  replans. A late distribution of the old key remains an old-generation delivery; its completion
  cannot modify the new generation. Reservations may overcount deliveries, causing conservative
  rotation. Network failure and device-list refresh can affect delivery availability; the holder
  secrecy boundary is membership of the account, while the model snapshots its device list.
- The gated database tests exercise the actual preparation/completion and authorization methods,
  not the full endorsed network send. SQLite transaction isolation and transport invocation of
  the authorization closure remain assumptions covered by their existing boundary tests.
- The membership is the local group state; what the server or other members believe is outside.
