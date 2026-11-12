/-!
# Profile padding: the model

Profile fields are AES-256-GCM under the profile key, each padded with zeros to the first of a
few fixed lengths that fits (`ProfileService.encryptPadded`, upstream
`encryptProfileItemWithPadding` and `PaddedLengths`), so a ciphertext's length shows only which
length was used:

| Field | Lengths |
|---|---|
| name | 53, 257 |
| about | 128, 254, 512 |
| about emoji | 32 |

A name is `given ‖ 0x00 ‖ family`, or just `given` without a family name (`encryptName`).
Reading one back (`decryptName`, upstream `decryptProfileName`): the given name runs to the first
NUL, the family name is the next run of non-NUL bytes after it; anything else is padding. The
other fields run to the first NUL (`decryptString`). An empty result is no value.
-/

namespace Crypto

inductive Field | name | about | aboutEmoji
  deriving DecidableEq, Repr

def Field.lengths : Field → List Nat
  | .name => [53, 257]
  | .about => [128, 254, 512]
  | .aboutEmoji => [32]

/-- `encryptName`'s plaintext before padding. -/
def nameBytes (gname fname : List Nat) : List Nat := if fname = [] then gname else gname ++ 0 :: fname

/-- The first length that fits. -/
def bucket (lengths : List Nat) (n : Nat) : Option Nat := lengths.find? (n ≤ ·)

/-- `encryptPadded`'s plaintext: zero-padded to the bucket, or `none` (`ProfileWriteError.tooLong`). -/
def padTo (lengths : List Nat) (item : List Nat) : Option (List Nat) :=
  (bucket lengths item.length).map fun b => item ++ List.replicate (b - item.length) 0

def untilNUL (l : List Nat) : List Nat := l.takeWhile (· != 0)

/-- `decryptName`: the given and the family name (empty: none). -/
def decodeName (padded : List Nat) : List Nat × List Nat :=
  let g := untilNUL padded
  (g, untilNUL (padded.drop (g.length + 1)))

/-- `decryptString` (about, about emoji). -/
def decodeString (padded : List Nat) : List Nat := untilNUL padded

end Crypto
