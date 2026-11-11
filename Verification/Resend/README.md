# Retry and resend authorization

The eighth verification slice: what a DecryptionErrorMessage can obtain from us. When a recipient
fails to decrypt a message we sent, it asks us to send it again. It contains a Lean 4 model of the
send log and of the answer, machine-checked proofs, Swift tests comparing production with the
model on a real database, and mutants.

**The app is not formally verified.** The proofs are about the model.

```
Tools/verify-resend.sh                 # everything
SKIP_MUTANTS=1 Tools/verify-resend.sh
SKIP_SWIFT=1 Tools/verify-resend.sh    # the Lean side only
```

## 1. The boundary

**The send log is an authorization boundary.**
- `SendLog.record` keeps each payload (by timestamp and content) together with the devices it
  was delivered to: for a 1:1 send, the devices encrypted for and accepted; for a sender-key send,
  each recipient's devices in the multi-recipient message, minus those the server reports gone.
- A delivery receipt removes a device. Payloads older than a day go.

A request names a requester (the authenticated sender of the DecryptionErrorMessage), its device,
and the timestamp of our message. **`SendLog.answer`** decides:

1. past `retryLimit` (5) requests for that (requester, device, timestamp): nothing;
2. otherwise the oldest payload at that timestamp logged as delivered to **that device of that
   requester**, and not older than a day; none: a NullMessage, which carries nothing;
3. a story to distribution lists only while the requester is a member of a list (not a block
   list, not deleted) one of our stories at that timestamp went to; otherwise nothing.

The payload goes to the requester only, through `MessageSender.authorization`, which the send
slice covers: not to a blocked contact, and nothing naming a message removed since unless it is a
retraction. A group's content goes back 1:1, as upstream does, without our sender key.

## 2. What is proved

| Theorem | Statement |
|---|---|
| `answer_logged` | A resend is of a payload in the log at the requested timestamp, not older than a day, with a row for exactly that requester's that device. |
| `answer_story` | A story to lists is resent only while the requester is in such a list. |
| `answer_limit` | Past the limit, nothing. |
| `logged_holds` | In every reachable state, every device the log lists for a payload was delivered that payload by a send. |
| `resentDelivered_holds` | **A retry gets back only what that very device was delivered, at that timestamp, and only the requester gets it.** A requester never obtains another recipient's plaintext, a message from a conversation it was not sent, or anything it was not delivered, whatever sends, receipts, list changes and requests came before. |
| `bounded_holds` | At most `retryLimit` answers per (requester, device, timestamp). |

The model's sends are arbitrary: any content to any recipient's devices. So `resentDelivered_holds`
does not depend on what was sent, only on the log recording deliveries and the lookup matching the
device.

## 3. Production changes made for this slice

- **X1: at lookup, the log ignores payloads older than a day** (upstream
  `getSentProtoByRecipient` prunes first). It pruned only when something new was logged, so after
  a quiet day an old payload could still be resent. If several payloads match, the oldest is
  chosen (`ORDER BY p.id`, as upstream's grouping).
- **X2: a request is answered at most five times** (upstream `RETRY_LIMIT`, in memory:
  `RetryLimiter`). There was no limit: every DecryptionErrorMessage caused a resend.
- **X3: a story is resent only to a requester still in a list it went to** (upstream
  `checkDistributionListAndAddSKDM`). Stricter for My Story as a block list: never. Upstream's
  check reads a block list's members, who are the excluded.
- The decision is one function (`SendLog.answer`) that the rig calls, as `Messenger.resend` does.
- Kept from before, stricter than upstream: the lookup matches the requester's **device**
  (upstream matches the account), and resends go through the removed-message check.

## 4. What is only tested against Swift

`ResendConformanceTests.randomRuns` (SignalCore): 300 runs of 40 events on a real database, with
fresh accounts and lists per run.
- Sends are any of four contents (two messages, a story to lists, a group's story) at one of
  eight timestamps, to any recipient's devices.
- Other events: delivery receipts, time passing (past the day), our stories at a timestamp to
  one of two lists, list changes (members, block list, deletion), and retry requests from any
  account's any device about any timestamp, sometimes in bursts past the limit.
- Every request's answer from `SendLog.answer` (with `RetryLimiter`) is compared with the model.

Mutants (step 6), each of which must fail step 5:
- the lookup: ignores the device; takes another recipient's payload; resends a payload older
  than a day; chooses the newest payload;
- the limit: none; the limiter not counting;
- stories: resent whatever the lists; block lists counting as lists; a group's story checked
  like a list story;
- receipts: removing the recipient's other devices; removing a payload others still wait for.

All 11 are killed.

## 5. Assumptions and limitations

- The model's sends record what they were given. That production records the devices it actually
  delivered to (`MessageSender.send`, `GroupSender.sendViaSenderKey`) is read from the code, not
  run by the rig, which would need a server.
- The requester's identity and device are the DecryptionErrorMessage's authenticated sender
  (sealed sender or session). Only requests about messages this device sent are queued (the
  message's `deviceId`).
- The limiter is in memory, as upstream's: a restart resets it. It counts each run of the resend
  job, so a job retried after a network failure counts again (upstream counts each request once):
  stricter, at worst fewer resends on a flaky network.
- A resend goes to all the requester's current devices, as upstream's. Devices of one account are
  one principal.
- Session archiving on a matching ratchet key, and the NullMessage's session effects, are not
  modelled.

## 6. Files

`Resend/Model.lean`, `Resend/Props.lean`, `Resend/Proofs.lean`, `Resend/Trace.lean`, `Main.lean`
(the `oracle`: `run`, `explore`), `Audit.lean`, `audit-expected.txt`, `explore-expected.txt`.
