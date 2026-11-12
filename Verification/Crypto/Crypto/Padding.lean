/-!
# Transport padding: the model

Every message's plaintext is padded before libsignal encrypts it, and unpadded after it decrypts
it (`MessageSender.pad`, `MessageReceiver.unpad`; upstream `padMessage` and `#unpad`):

    padded = message ‖ 0x80 ‖ 0x00 …   its length plus one a multiple of 80 (upstream PADDING_BLOCK)

`unpad` reads from the end: zeros are skipped, and the first other byte must be the terminator
0x80; everything before it is the message.

Bytes are natural numbers here; nothing below needs them to be under 256.
-/

namespace Crypto

def paddingBlock : Nat := 80

/-- `pad`'s length for a message of `n` bytes: `n + 2` rounded up to whole blocks, minus one. -/
def paddedLength (n : Nat) : Nat := (n + 2 + paddingBlock - 1) / paddingBlock * paddingBlock - 1

/-- `MessageSender.pad`. -/
def pad (m : List Nat) : List Nat := m ++ 0x80 :: List.replicate (paddedLength m.length - m.length - 1) 0

/-- `unpad` on the reversed input: skip zeros; the first other byte must be 0x80. -/
def stripRev : List Nat → Option (List Nat)
  | [] => none
  | b :: t => if b = 0x80 then some t else if b = 0 then stripRev t else none

/-- `MessageReceiver.unpad`: the message, or `none` (`ReceiveError.invalidPadding`). -/
def unpad (d : List Nat) : Option (List Nat) := (stripRev d.reverse).map List.reverse

/-- Upstream's `#unpad`: the same, except that input with no terminator at all (empty, or only
zeros) is handed back unchanged instead of refused. -/
def unpadUpstream (d : List Nat) : Option (List Nat) := if d.all (· == 0) then some d else unpad d

end Crypto
