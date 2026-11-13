# Send authorization: a Lean model, proofs, and conformance with production Swift

The third verification slice: what may reach the transport. It contains:

- a Lean 4 model of SignalCore's send authorization: the payload classifier
  (`OutgoingPayload.onlyRetracts`), the decision (`MessageSender.authorization`), a group send's
  recipients (`GroupSender.sendableRecipients`), and a send pipeline in which blocks and deletions
  can happen between a send's start and its submission;
- machine-checked proofs of the properties below;
- Swift tests that compare production's decisions with the model on random database states and
  random protobuf payloads, a test of the submission boundary in the transport, and mutants.

**The app is not formally verified.** The proofs are about the model; production's decisions
are compared with it on many cases, not proved.

```
Tools/verify-send.sh                 # everything (step 6 rebuilds per mutant)
SKIP_MUTANTS=1 Tools/verify-send.sh  # about a minute once built
SKIP_SWIFT=1 Tools/verify-send.sh    # the Lean side only
```

## 1. The submission boundary

Every send path of `SocketManager` (`authenticatedRequest`, `unauthenticatedRequest`,
`sendMultiRecipient`) sets up its connection, then calls `authorize()`, then hands the request to
libsignal. `MessageSender` and `GroupSender` pass `MessageSender.authorization(...)` as
`authorize`, so the decision is a database read made immediately before submission, for every
attempt (and once more when the send starts). **Submission** is the call into libsignal after
that read. What was submitted is not recalled by a later block or deletion; the model's pipeline
has no such step.

## 2. What is modelled

| Model | Production |
|---|---|
| `Data` (`retract`, `extra`) | a DataMessage: does it have a `delete` or `adminDelete`; does it have any field beyond those and the envelope (timestamp, profile key, group context) |
| `Content.data / sent / content / other` | `Content.dataMessage`; `syncMessage.sent` (a transcript, or a recipient update, possibly carrying a story or an edit); `editMessage` / `storyMessage`; everything else (receipts, typing, calls, other syncs) |
| `Content.onlyRetracts` | `OutgoingPayload.onlyRetracts` |
| `Content.carries` | the specification of "message content" (production has no such function) |
| `authorized s t c ids` | `MessageSender.authorization(to:groupId:messageIds:retracting:)` |
| `recipients s g` | `GroupSender.sendableRecipients`: members not blocked by service id or number |
| `start`, `submit` | a send's first check (and, for a group, its recipients); each submission's check |

## 3. What is proved

| Theorem | Statement |
|---|---|
| `onlyRetracts_carries` | **The exemption needs no content**: a payload that qualifies as retraction-only carries no message content. |
| `onlyRetracts_extra` | Adding any content field (a body, attachments, …) to a delete disqualifies it. |
| `content_needs_live` | An authorized payload that carries content names only live (existing, unerased) messages. |
| `retraction_ignores_messages` | A retraction's authorization does not read the messages it names: **an otherwise authorized retraction is not refused because its local source was removed.** |
| `blocked_contact_refused`, `blocked_group_refused` | A direct payload to a contact blocked by id or number, or a group payload to a blocked group, is refused. |
| `group_ignores_contacts`, `direct_ignores_groups` | Direct and group blocking are separate decisions: a group payload's authorization never reads a contact's block, a direct one never a group's. |
| `recipients_mem` | A group send's recipients are exactly the members not blocked when it starts. |
| `step_out` | Only a submit step submits, and only what its own check authorized at that moment. |
| `submitAuthorized_holds` | **Forbidden content never submits**: every submission is authorized in the state at the boundary. |
| `contentNeedsSource_holds` | A submission carrying content names only live messages. |
| `retractionGoes_holds` | A started retraction to an unblocked target is submitted whatever happened to its messages. |
| `groupRecipients_holds` | A started group send chose exactly its unblocked members. |

**What the proofs are worth.** The classifier theorems (`onlyRetracts_carries`,
`onlyRetracts_extra`, `retraction_ignores_messages`, the blocking ones) are about the decision
production's functions are compared with. The pipeline theorems (`step_out` and the `_holds`
ones) follow from the model's structure — each submission is checked at its moment — and state
the boundary precisely; what ties production to them is the conformance of `authorization` and
the boundary test, not a proof.

## 4. Production changes made for this slice

**S1: a delete that carries content no longer qualifies as a retraction.** `onlyRetracts`
accepted any DataMessage with a `delete`, so a payload with a delete *and* a body or attachments
skipped the removed-message check. Now it must have nothing but the delete (or an admin delete)
and the envelope fields; a transcript must not carry a story or an edit. The comparison is with
the field-for-field rebuilt message, so unknown fields also disqualify. `adminDelete` now counts
as a retraction too (it had not, so an admin delete of a removed message would have been refused
if it named it).

**S2: contacts we blocked no longer receive our group messages** (upstream parity:
`getValidRecipients`, `getMessageRecipients` drop blocked recipients from every group send).
`GroupSender` chose all members. Now it leaves out members blocked by service id or number, when
the send starts, and reports them; a group message's send state then drops them, so it is not
left waiting (which the start-up repair would turn into "failed"). One `MessageSender.isBlocked`
serves both the direct check and the group's recipients.

## 5. What is only tested against Swift

`SendAuthorizationConformanceTests.randomDecisions` (SignalCore tests): 5,000 cases. Each sets
a real database's block lists (service ids, numbers, the group), four messages (live, erased,
or gone), a random target (a contact, ourselves, the group) and a random protobuf payload with
random fields, and compares production's `authorization` result, `onlyRetracts`, and group
recipients with the oracle. `productionRetractionsQualify`: the payloads production builds for a
delete for everyone, an admin delete and a story recipient update qualify, and the same delete
with a body does not. `SubmissionBoundaryTests`: each transport path refuses when `authorize`
throws.

Mutants (step 6), each of which must fail step 5:

| Mutant | Caught by |
|---|---|
| A delete with content counts as a retraction (the old check). | random decisions |
| A transcript carrying a story or an edit counts as a retraction. | random decisions |
| The named messages are not checked. | random decisions |
| A retraction is refused once its message is gone. | random decisions |
| An erased message counts as present. | random decisions |
| A contact blocked by number is not blocked. | random decisions |
| A blocked contact is not refused. | random decisions |
| A blocked group is not refused. | random decisions |
| A group send goes to members we blocked. | random decisions |
| Each of the three transport paths skips the check. | the boundary test |

## 6. Assumptions and limitations

- The pipeline (start, then submit, with anything in between) is modelled from the code; it is
  not run against production, which would need a server. Production's two checks are the same
  function (`authorization`), compared with the model; the boundary test shows the transport calls
  it before sending.
- A group member blocked after the send started is not taken out of that send (its payload is
  already encrypted for them); the group's own block is checked again at submission. Upstream
  chooses recipients once too.
- Identity trust (untrusted keys) is checked during encryption and is the identity slice's
  subject, not this one's.
- "Content" is defined by the rig's list of fields (`randomData`); a field production adds later
  counts as content to `onlyRetracts` automatically (it is not in the rebuilt message).

## 7. Files

| File | Contents |
|---|---|
| `Send/Model.lean` | Payloads, the decision, recipients, the pipeline. |
| `Send/Props.lean`, `Send/Proofs.lean` | The properties and proofs. |
| `Send/Trace.lean`, `Main.lean` | Notation and the `oracle` (`decide`, `check`, `explore`). |
| `Audit.lean`, `audit-expected.txt`, `explore-expected.txt`, `traces/regressions.txt` | What the script compares. |

## Cross-slice async regressions

`CrossSliceSendTests` gates real sends after encryption and real attachment uploads through an
injected upload-form source. Blocking, deleting the source message, or changing the peer identity
while suspended must prevent submission. An allowed retry after unblocking must succeed.
Encryption now captures the peer identity in its transaction; authorization checks that exact
key again at submission, even if a different key has since been approved. Group distribution
also uses this direct-send boundary. Group-key generation/reset checks remain in the Group slice.

The same suite tests real group sends followed by membership removal or group blocking before
resend, and a retained Messenger after account replacement/logout. These composition tests are
not implied by the separate Lean proofs. `Tools/verify-async-boundaries.py` runs targeted runtime
mutants; `Send/Nonvacuity.lean` independently checks positive model behavior.
