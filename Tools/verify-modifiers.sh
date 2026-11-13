#!/bin/sh
# Verifies the message-modifier model (Verification/Modifiers) and its conformance with the
# production SignalCore, in one go:
#   1. no `sorry`, `admit`, axioms or other escape hatches in the Lean sources;
#   2. `lake build`: the kernel checks every proof;
#   3. the audit: property definitions, a hash of every definition the theorem statements depend
#      on (transitively), and the theorem statements must equal audit-expected.txt, and every
#      theorem may depend only on propext, Classical.choice and Quot.sound;
#   4. the explorer's verdict per property (fixed seed) must equal explore-expected.txt;
#   5. Swift: MessageModifiers' decisions on a real database, whole runs of messages and modifiers
#      (the stored messages, what they show, the waiting list), and the waiting list's evictions,
#      against the Lean oracle (SEREIN_MODIFIERS_CASES, default 3000);
#   6. mutants: each check weakened in production must make step 5 fail. Each is applied to the
#      working tree and the file restored afterwards (also on interrupt).
#
#   Tools/verify-modifiers.sh                    everything
#   SKIP_SWIFT=1 Tools/verify-modifiers.sh       only the Lean side
#   SKIP_MUTANTS=1 Tools/verify-modifiers.sh     without step 6
#   UPDATE_EXPECTED=1 Tools/verify-modifiers.sh  rewrite the expected files (review the diff!)
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
dir="$root/Verification/Modifiers"
cd "$dir"

if ! command -v lake >/dev/null 2>&1 && [ -f "$HOME/.elan/env" ]; then . "$HOME/.elan/env"; fi
command -v lake >/dev/null 2>&1 || { echo "error: Lean is not installed (brew install elan-init)" >&2; exit 1; }
echo "toolchain: $(cat lean-toolchain)"

echo "== 1. escape hatches"
if grep -rnE '\b(sorry|admit|native_decide|implemented_by|extern|unsafe|axiom)\b|skipKernelTC|ofReduceBool|debug\.' \
     --include='*.lean' Modifiers Main.lean Modifiers.lean Audit.lean; then
  echo "error: forbidden construct (above)" >&2; exit 1
fi
echo "none"

echo "== 2. lake build (the kernel checks every proof)"
if ! lake build > /dev/null 2>&1; then lake build; exit 1; fi
echo "ok"

echo "== 3. audit: definitions, statements, axioms"
tmp=$(mktemp -d)
backup="$tmp/backup"
mutated=""
restore() { if [ -n "$mutated" ]; then cp "$backup" "$mutated"; mutated=""; fi; }
trap 'restore; rm -rf "$tmp"' EXIT
trap 'restore; rm -rf "$tmp"; exit 130' INT TERM
if ! lake env lean Audit.lean > "$tmp/audit" 2>&1; then cat "$tmp/audit" >&2; exit 1; fi
if [ "${UPDATE_EXPECTED:-}" = 1 ]; then cp "$tmp/audit" audit-expected.txt; fi
if ! diff -u audit-expected.txt "$tmp/audit"; then
  echo "error: definitions or theorem statements changed (review, then UPDATE_EXPECTED=1)" >&2; exit 1
fi
total=$(grep -c ' depends on axioms: ' "$tmp/audit")
bad=$(grep ' depends on axioms: ' "$tmp/audit" | sed 's/.* depends on axioms: \[\(.*\)\]$/\1/' | tr ',' '\n' | tr -d ' ' \
      | grep -vxE '(propext|Classical\.choice|Quot\.sound)?' || true)
if [ -n "$bad" ] || [ "$total" -eq 0 ]; then
  echo "error: unexpected axioms:" >&2; echo "$bad" >&2; exit 1
fi
echo "$total theorems; axioms used: propext, Classical.choice, Quot.sound; $(grep -m1 ' definitions$' "$tmp/audit") in the audited closure"

echo "== 4. explorer verdicts (40000 random runs of 60 events, seed 2026)"
./.lake/build/bin/oracle explore 2026 40000 60 > "$tmp/explore-raw"
grep -E '^(OK|FAIL)' "$tmp/explore-raw" | sed -E 's/^(OK|FAIL) ([A-Za-z0-9-]+).*/\2 \1/' > "$tmp/explore"
if [ "${UPDATE_EXPECTED:-}" = 1 ]; then cp "$tmp/explore" explore-expected.txt; fi
if ! diff -u explore-expected.txt "$tmp/explore"; then
  echo "error: a property's verdict changed (review, then UPDATE_EXPECTED=1)" >&2; exit 1
fi
echo "$(grep -c ' OK$' explore-expected.txt) hold, $(grep -c ' FAIL$' explore-expected.txt) falsified"

if [ "${SKIP_SWIFT:-}" = 1 ]; then echo "== 5. Swift: skipped"; exit 0; fi
oracle="$dir/.lake/build/bin/oracle"
cd "$root/Packages/SignalCore"

echo "== 5. Swift: decisions and runs against the oracle"
status=0
SEREIN_MODIFIERS_ORACLE="$oracle" SEREIN_MODIFIERS_CASES="${SEREIN_MODIFIERS_CASES:-3000}" \
  swift test --filter 'ModifierConformanceTests' > "$tmp/swift" 2>&1 || status=$?
grep -E 'Test run|passed after|failed after|disagree|model |content:' "$tmp/swift" | tail -40
[ "$status" -eq 0 ] || exit "$status"

if [ "${SKIP_MUTANTS:-}" = 1 ]; then echo "== 6. mutants: skipped"; exit 0; fi
echo "== 6. mutants: each planted bug must make production and the model disagree"
# mutant <name> <file> <perl substitution> [what must fail]
killed=0
mutant() {
  name="$1"; file="$root/$2"; expr="$3"; expect="${4:-disagree.* at step|content: }"
  cp "$file" "$backup"
  mutated="$file"
  perl -0pi -e "$expr" "$file"
  if cmp -s "$file" "$backup"; then echo "error: mutant '$name' did not apply" >&2; exit 1; fi
  if [ "${DRY_RUN:-}" = 1 ]; then restore; echo "applies: $name"; return; fi
  SEREIN_MODIFIERS_ORACLE="$oracle" SEREIN_MODIFIERS_CASES=2000 \
    swift test --filter 'ModifierConformanceTests' > "$tmp/mutant" 2>&1 && survived=1 || survived=0
  restore
  if [ "$survived" = 1 ]; then echo "error: mutant '$name' survived the conformance tests" >&2; exit 1; fi
  if ! grep -qE "$expect" "$tmp/mutant"; then
    echo "error: mutant '$name' failed, but not as expected (did it build?)" >&2; tail -20 "$tmp/mutant" >&2; exit 1
  fi
  killed=$((killed + 1))
  echo "killed: $name — $(grep -m1 -E "$expect" "$tmp/mutant" | sed 's/^[^a-zA-Z]*//' | cut -c1-100)"
}
mods=Packages/SignalCore/Sources/SignalCore/Messaging/MessageModifiers.swift
store=Packages/SignalCore/Sources/SignalCore/Messaging/MessageStore.swift
mutant "someone else's modifier counts in any conversation" "$mods" \
  's/t\.conversationId == c\.conversationId \|\| c\.source != \.someoneElse\n    \}/t.conversationId == c.conversationId || c.source != .someoneElse || !c.sender.isEmpty\n    }/'
mutant "an edit counts in any conversation" "$mods" \
  's/as\? String == c\.sender, t\.conversationId == c\.conversationId,/as? String == c.sender,/'
mutant "a message deleted for everyone can be edited" "$mods" \
  's/guard !t\.deletedForEveryone, t\.json\["isErased"\] as\? Bool != true, t\.json\["isViewOnce"\] as\? Bool != true,/guard t.json["isViewOnce"] as? Bool != true,/'
mutant "a view-once message can be edited" "$mods" \
  's/t\.json\["isErased"\] as\? Bool != true, t\.json\["isViewOnce"\] as\? Bool != true,/t.json["isErased"] as? Bool != true,/'
mutant "a voice message can be edited" "$mods" \
  's/""", arguments: \[t\.id\]\) == nil\n    \}/""", arguments: [t.id]) == nil || !t.id.isEmpty\n    }/'
mutant "an older edit overwrites a newer one" "$mods" \
  's/guard m\.timestamp > shownRevision\(t\) else/guard m.timestamp != shownRevision(t) else/'
mutant "the first edit is not compared with the original" "$mods" \
  's/max\(UInt64\(max\(t\.sentAt, 0\)\), /max(UInt64(max(t.sentAt, 0)) \& 0, /'
mutant "edits waiting for a revision are not applied" "$mods" \
  's/if ok \{ try applyPending\(db, author: p\.context\.sender/if ok \&\& p.payload.isEmpty { try applyPending(db, author: p.context.sender/'
mutant "an edit for a blocked group counts" "$mods" \
  's/if c\.source == \.someoneElse, try isBlocked/if c.source == .someoneElse \&\& c.sender.isEmpty, try isBlocked/'
mutant "a delete for everyone needs no author" "$mods" \
  's/guard t\.json\["sourceServiceId"\] as\? String == c\.sender else \{ return false \}/guard t.json["sourceServiceId"] as? String == c.sender || !c.sender.isEmpty else { return false }/'
mutant "an admin delete needs no administrator" "$mods" \
  's/g\.state\?\.isAdmin\(c\.sender\) == true else/g.state?.isAdmin(c.sender) == true || !c.sender.isEmpty else/'
mutant "a reaction to our message counts from someone it was not sent to" "$mods" \
  's/if t\.type == "outgoing", !wasSent\(t, to: try conversationOf\(db, sender: c\.sender\)\) \{ return false \}\n        \}\n        let fromId/if t.type == "outgoing" \&\& t.id.isEmpty, !wasSent(t, to: try conversationOf(db, sender: c.sender)) { return false }\n        }\n        let fromId/'
mutant "a vote on our poll counts from someone it was not sent to" "$mods" \
  's/sender: c\.sender\) else \{ return false \}\n            if t\.type == "outgoing", !wasSent/sender: c.sender) else { return false }\n            if t.type == "outgoing" \&\& t.id.isEmpty, !wasSent/'
mutant "a vote in a blocked conversation counts" "$mods" \
  's/guard inTargetConversation\(t, c\), try !isBlocked\(db, conversationId: t\.conversationId, sender: c\.sender\) else \{ return false \}/guard inTargetConversation(t, c) else { return false }/'
mutant "an unpin is not validated like a pin" "$mods" \
  's/guard try pinnable\(db, t, c, ourAci: ourAci\) else \{ return false \}\n        try db\.execute\(sql: "DELETE FROM pinnedMessages/guard try senderBelongs(db, sender: c.sender, conversationId: t.conversationId, ourAci: ourAci) else { return false }\n        try db.execute(sql: "DELETE FROM pinnedMessages/'
mutant "pins under the old attribute rule" "$mods" \
  's/state\.isAdmin\(c\.sender\) \|\| state\.accessControl\.attributes == GroupAccess\.member/state.isAdmin(c.sender) || state.accessControl.attributes != GroupAccess.administrator/'
mutant "a non-member may pin in a group" "$mods" \
  's/guard let state = g\.state, state\.isMember\(c\.sender\),/guard let state = g.state,/'
mutant "a flood evicts the oldest entry, whoever sent it" "$mods" \
  's/list\.firstIndex\(where: \{ counts\[\$0\.context\.sender\] == most \}\)/list.firstIndex(where: { (counts[\$0.context.sender] ?? 0) + most >= 0 })/'
mutant "old entries are not dropped" "$mods" \
  's/list\.filter \{ now - \$0\.storedAt <= pendingMaxAge \}/list.filter { now - \$0.storedAt <= pendingMaxAge || now != 0 }/'
mutant "a duplicate message is stored again" "$store" \
  's/"SELECT id FROM messages WHERE sourceServiceId = \? AND sent_at = \? LIMIT 1"/"SELECT id FROM messages WHERE sourceServiceId = ? AND sent_at = ? AND type = '"'"'none'"'"' LIMIT 1"/'
echo "$killed mutants killed"
