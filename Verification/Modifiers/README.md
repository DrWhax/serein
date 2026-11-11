# Message modifiers: edits, deletes, replay

The seventh verification slice: what a modifier — a delete for everyone, an admin delete, an
edit, a reaction, a poll vote or termination, a pin or unpin — may do to a stored message, when it
arrives before its target, late, out of order or more than once. It contains a Lean 4 model of
`MessageModifiers` (target lookup, every decision, the waiting list and its application when a
message or a revision arrives), machine-checked proofs, Swift tests comparing production with the
model on a real database, and mutants.

**The app is not formally verified.** The proofs are about the model.

```
Tools/verify-modifiers.sh                 # everything
SKIP_MUTANTS=1 Tools/verify-modifiers.sh
SKIP_SWIFT=1 Tools/verify-modifiers.sh    # the Lean side only
```

## 1. What the model is

A modifier names its target by **author and timestamp**. The timestamp is the message's own, or
one of its edits' (`MessageModifiers.target`: by `sent_at` first, then `edited_messages`). Once
found, the target is judged by `accepts`, which is the conjunction of production's checks:

| Kind | Accepted only if |
|---|---|
| delete | not already deleted; in the target's conversation; not note-to-self; **by the author**; within 48 h of the target (server time) |
| admin delete | the same, but by an **administrator** of the target's group |
| edit | **by the author, in the target's conversation** (from any device); not deleted, erased, view-once or a voice message; on time and not in a blocked group (unless ours); **newer than the revision shown** |
| reaction | not deleted or view-once; someone else's: in the target's conversation, a member, not blocked, and on our message only if it was sent to them |
| poll vote | a poll not terminated; a member; someone else's: in the conversation, not blocked, and on our poll only if it was sent to them |
| termination | a poll not terminated; by the author; in the conversation |
| pin, unpin | not deleted or a gift badge; in the conversation; not blocked; a member who may edit the group's attributes (an administrator, unless they are open to members); an unpin also needs a pin |

A modifier whose target is not there waits (`keep`): there are at most 500 entries, each kept for
48 hours. When a message arrives, everything waiting for it is applied, in timestamp order.
When an edit is accepted, everything waiting for its revision is applied the same way. A message
arriving with the author and timestamp of a stored one is a **duplicate** and dropped, whatever
happened to the stored one (`MessageStore.find`). A message can be removed here (delete for
me, expiry).

## 2. What is proved

| Theorem | Statement |
|---|---|
| `accepts_conversation`, `accepts_edit_conversation` | **The right conversation**: someone else's accepted modifier was sent in its target's conversation. An edit always was, from any device. |
| `accepts_author`, `accepts_admin` | **The right author**: deletes, edits and terminations are by the target's author; admin deletes are by an administrator of its group. |
| `accepts_member`, `accepts_sent` | Someone else's reaction, vote or pin is by a member of the target's conversation who is not blocked. On our message, it is by someone the message was sent to. |
| `deleted_accepts_nothing`, `edit_refuses`, `edit_newer` | A message deleted for everyone accepts nothing. Erased, view-once and voice messages accept no edit. An edit is accepted only if newer than what is shown. |
| `resolvedCorrect_holds` | In every reachable state, every modifier that reached a target named it (author, and its timestamp or an edit's), and was applied exactly if the decision accepted it. |
| `pendingUnresolvable_holds` | **Modifiers arriving before their target**: nothing waits whose target is there. When a message or a revision arrives, everything that named it has been applied or refused, also through chains of edits naming edits. |
| `newestShown_holds` | **Older edits cannot overwrite newer revisions**: a message shows the newest of the valid edits that reached it, else its original, whatever order they arrived in. |
| `stepOk_holds` | **No resurrection; only the target changes**: in every step, a stored message keeps its author, timestamp and conversation, and its revision never goes back. Once deleted for everyone, it never changes again: a duplicate is dropped, and edits and everything else are refused. It changes only through an accepted modifier that named it, or it is removed here. |
| `evict_heaviest`, `evict_spares_lighter`, `kept_sub` | **The waiting list is fair**: an eviction takes the oldest entry of the sender with the most waiting, never an entry of a sender with fewer waiting than another. The list only loses entries, and gains the new one. |

**What the proofs are worth.** The decision theorems are about the function production's
decisions are compared with. The reachability theorems come from the model's state machine
(lookup, waiting list, nested application), which the run comparison ties to production. The
invariant behind them is substantive. Both the explorer and the kernel find a violation if
accepted edits do not apply what waited for their revision (production's previous behaviour),
and also if the order check is dropped.

The explorer (step 4) also checks that the model's nested application never runs out of fuel.
That is checked, not proved.

## 3. Production changes made for this slice

Upstream (Signal-Desktop) is the reference. The changes marked *stricter* go beyond it.

- **R1: someone else's modifiers act only in their target's conversation.** Reactions and
  deletes already did. Now so do edits (upstream: "Edit is not in the same conversation as the
  original", for every source), votes, terminations, pins and unpins (*stricter*: upstream checks
  only that the sender belongs to the target's conversation). A group member could otherwise vote
  or pin in a group through a 1:1 message, seen only by us.
- **R2: edits.**
  - Refused for erased, view-once, contact-share and voice messages (upstream parity; an opened
    view-once message could be given a body).
  - Refused in a blocked group, at arrival (upstream) and when they waited for their target.
  - Ordered by timestamp, the original's included (*stricter*: upstream lets the last to arrive
    win). An edit no newer than the revision shown changes nothing; before, only edits older than
    the last edit were refused, not those older than the original.
- **R3: modifiers waiting for a revision are applied when the revision arrives.** Upstream edits
  name the latest revision. If an edit arrived before the one it names, it waited forever, and the
  message showed the older revision.
- **R4: poll votes.** On our poll, a vote counts only from someone it was sent to. Votes are also
  refused in a blocked conversation (upstream `isValidPollVote`).
- **R5: pins and unpins.** Unpins are validated like pins (upstream `validatePinnedMessageTarget`:
  block, membership, attribute access, deleted, gift badge); before, an unpin only needed the
  sender to belong. Attribute access follows upstream: an administrator, or anyone when attributes
  are open to members. Before, only admin-only attributes were enforced.
- **R6: the waiting list evicts from the sender with the most entries.** Before, it evicted the
  oldest entries, so anyone could flood it with 500 modifiers naming nothing and push out a
  waiting delete. The message it named would then have arrived and stayed. Waiting modifiers
  apply in timestamp order, ties in arrival order (a stable sort).

## 4. What is only tested against Swift

`ModifierConformanceTests` (SignalCore):

- **`randomDecisions`**: 3,000 cases on a real database. Each has random group members,
  administrators, attribute access (all five levels) and block lists. A fresh message gets a
  random author, conversation and flags (view-once, voice, poll, gift badge, recipients), maybe an
  edit, a pin, a terminated poll, or an erasure or deletion for everyone. One modifier of any kind
  names it, from any sender, conversation and source, at any time. Production's `apply` is
  compared with `accepts`.
- **`randomRuns`**: 300 runs of 30 events in fresh worlds. Messages arrive (and arrive again)
  and are removed. Modifiers of every kind name a message, one of its edits or nothing; they
  arrive before or after their targets, held back and released late, or replayed. The stored
  messages are compared with the model: deleted, the revision shown, the edits, pinned, poll,
  terminated. So is the waiting list. Each message must show exactly the body of the revision it
  reports.
- **`randomKept`**: 3,000 waiting lists (ages, senders, limits) against `kept`.

Mutants (step 6), each of which must fail step 5:
- conversation and edit checks: any conversation for modifiers or for edits; deleted, view-once
  or voice messages editable; older edits overwriting; first edits not compared with the
  original; waiting edits for a revision not applied; blocked-group edits accepted;
- author and admin checks: deletes needing no author; admin deletes needing no administrator;
- sent-to and block checks: reactions or votes on our message from someone it was not sent to;
  votes in a blocked conversation;
- pins: unpins validated as before; the old attribute rule; a non-member pinning;
- the waiting list: oldest-first eviction; old entries not dropped; duplicates stored again.

All 20 are killed.

## 5. Assumptions and limitations

- The runs call production's functions (`MessageModifiers.apply`, `applyPending`,
  `MessageStore.find`, `DeleteForMe.deleteMessage`) as the receiver does. The receiver's own glue
  (building modifiers from a DataMessage, the edit envelope) is not run by the rig.
- Group membership, administrators and blocks are fixed during a run. A modifier is judged when
  applied, so a waiting one meets the state at its target's arrival (as upstream).
- Reactions' and votes' contents (emoji, option indexes, vote counts), the pin limit and pin
  durations are not modelled (the rig sets the pin limit high). Neither are view-once opens (our
  own devices).
- Timestamps are unique per author in the rig, as they are on Signal clients. With collisions, the
  lookup's preference (the message's own timestamp first) is the model's too, but untested.
- "Shown" is the newest revision **that reached the message**. An edit naming a revision that was
  refused for being older waits until it ages out. Only an author's forked edit history (two
  devices editing at once) produces that.
- A message removed here (delete for me, expiry) leaves no record: the same message arriving
  again would be stored again. Replay of an envelope is refused by the protocol (libsignal), and a
  resend only follows our own failure to decrypt it.
- Waiting entries live for 48 hours and are at most 500. Fairness is per sender, so one sender
  cannot evict another's entries. Many senders, each with as many entries as the delete's author,
  still can.

## 6. Files

`Modifiers/Model.lean` (the model), `Modifiers/Props.lean`, `Modifiers/Proofs.lean`,
`Modifiers/Trace.lean`, `Main.lean` (the `oracle`: `decide`, `run`, `kept`, `explore`), `Audit.lean`,
`audit-expected.txt`, `explore-expected.txt`.
