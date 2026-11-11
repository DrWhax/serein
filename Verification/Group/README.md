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
| `Inv.reach`, `holdersRecorded_holds` | Every device holding our current key is recorded as having it — also when a send stops part-way and when sends interleave. |
| `rotation_targets`, `rotated_holds` | **Rotation after a removal**: once a send has planned, every device recorded as having our current key belongs to one of its targets, members at that moment. With the invariant: no non-member holds the key the next content is encrypted with. |
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

**G3: the record of who has our key is added to as the key goes out, never replaced.** It was saved
once after the distribution loop, and replaced by that send's targets: a send that stopped part-way
(a refusal, a failure) or another send running meanwhile (group call messages do not go through the
job queue) could leave a device holding the key unrecorded, and then a later removal of its account
would not rotate the key. Now each account's devices are recorded as soon as they get the key
(`SenderKeyInfo.recording`, a union until the next reset).

## 4. What is only tested against Swift

`GroupConformanceTests` (SignalCore): random cases each of `GroupSendPlan.make` (membership,
recipients with duplicates and ourselves, update or content), `SenderKeyInfo.rotation` and
`recording` (recorded devices, the send's devices, its targets), and `authorization` for a group
payload on a real database (a group in `GroupStore` with random members; random DataMessages with or
without a group context and content, and key distribution messages; one-by-one and multi-recipient),
together with `isGroupUpdateOnly`.

Mutants (step 6): content plans include non-members; a group update no longer reaches those it
removes; a removed account does not rotate our key; the key record replaced, not added to; the
submission check skips membership; a one-recipient group send not checked; a group update with
content counts as an update; a sender-key message counts as a group update.

## 5. Assumptions and limitations

- The send pipeline (plan, distribute, submit) is modelled from `GroupSender`; it is not run against
  production, which needs a server and group send endorsements. The rig compares the decisions it
  is made of.
- Endorsements are not modelled: members without one get one-by-one sends, which are content to
  members and checked the same way.
- When two sends interleave and one replaces the key after the other planned, the other may submit
  under the new key to targets it did not give it to: they cannot decrypt (availability, not
  secrecy); it is not modelled as a failure.
- The membership is the local group state; what the server or other members believe is outside.
