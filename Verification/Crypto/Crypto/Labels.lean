/-!
# Key separation: the model

Every key, MAC or identifier SignalCore derives itself, with the primitive, the key it is keyed
by, and the exact input (HMAC's message, or HKDF's info). `derivation` is the whole table;
`Use` names each purpose with its parameter (a manifest's version, a storage item's id, the
plaintext a device name's synthetic IV is computed over, …).

| Use | Source | Primitive | Input |
|---|---|---|---|
| `storageKey` | the master key | HMAC | `Storage Service Encryption` |
| `manifestKey v` | the storage key | HMAC | `Manifest_` ‖ decimal(v) |
| `itemKey raw` (legacy) | the storage key | HMAC | `Item_` ‖ base64(raw) |
| `itemKeyIkm raw` | the manifest's record IKM | HKDF, no salt, 32 | `20240801_SIGNAL_STORAGE_SERVICE_ITEM_` ‖ raw |
| `groupV1MasterKey` | a GV1 group id | HKDF, salt 0³², 32 | `GV2 Migration` |
| `stickerPackKeys` | a sticker pack key | HKDF, salt 0³², 64 | `Sticker Pack` |
| `callLinkRoomId` | a call link root key's first 16 bytes | HKDF, no salt, 32 | `20230501-Signal-CallLinkRootKey-RoomId` |
| `provisioningKeys` | X25519(our provisioning key, the primary's ephemeral key) | HKDF, no salt, 64 | `TextSecure Provisioning Message` |
| `deviceNameAuth` | X25519(identity key, ephemeral key) | HMAC | `auth` |
| `deviceNameCipher` | the same secret | HMAC | `cipher` |
| `deviceNameIv p` | the `auth` key | HMAC | the name `p` |
| `deviceNameCipherKey iv` | the `cipher` key | HMAC | the synthetic IV |
| `accessKeyVerifier` | an access key | HMAC | 0³² |

A 64-byte output is split into an AES key (the first 32 bytes) and a MAC key (the last 32).

Keys libsignal derives (the access key from a profile key, the master key's other uses, the
Signal protocol's own keys) are not in the table.
-/

namespace Crypto

def ascii (s : String) : List Nat := s.toList.map Char.toNat

def zeros (n : Nat) : List Nat := List.replicate n 0

/-- Every element is a byte. -/
def Bytes (l : List Nat) : Prop := ∀ x ∈ l, x < 256

/-! ## Decimal (`"\(version)"` of a `UInt64`) -/

def dec (n : Nat) : List Nat := if n < 10 then [48 + n] else dec (n / 10) ++ [48 + n % 10]
termination_by n
decreasing_by omega

/-! ## Base64 (`Data.base64EncodedString()`: the standard alphabet, `=` padding) -/

/-- The character for a 6-bit value: `A`–`Z`, `a`–`z`, `0`–`9`, `+`, `/`. -/
def b64char (n : Nat) : Nat :=
  if n < 26 then 65 + n else if n < 52 then 71 + n else if n < 62 then n - 4 else if n = 62 then 43 else 47

def b64 : List Nat → List Nat
  | [] => []
  | [a] => [b64char (a / 4), b64char (a % 4 * 16), 61, 61]
  | [a, b] => [b64char (a / 4), b64char (a % 4 * 16 + b / 16), b64char (b % 16 * 4), 61]
  | a :: b :: c :: rest =>
    b64char (a / 4) :: b64char (a % 4 * 16 + b / 16) :: b64char (b % 16 * 4 + c / 64) :: b64char (c % 64) :: b64 rest

/-! ## The table -/

inductive Source
  | masterKey | storageKey | recordIkm | groupV1Id | packKey | callLinkRoot
  | provisioningSecret | deviceNameSecret | deviceNameAuth | deviceNameCipher | accessKey
  deriving DecidableEq, Repr

inductive Prim
  | hmac
  /-- HKDF-SHA256 with this salt and output length. -/
  | hkdf (salt : List Nat) (length : Nat)
  deriving DecidableEq, Repr

structure Derivation where
  source : Source
  prim : Prim
  /-- HMAC's message, or HKDF's info. -/
  input : List Nat
  deriving DecidableEq, Repr

inductive Use
  | storageKey
  | manifestKey (version : Nat)
  | itemKey (raw : List Nat)
  | itemKeyIkm (raw : List Nat)
  | groupV1MasterKey
  | stickerPackKeys
  | callLinkRoomId
  | provisioningKeys
  | deviceNameAuth
  | deviceNameCipher
  | deviceNameIv (plaintext : List Nat)
  | deviceNameCipherKey (iv : List Nat)
  | accessKeyVerifier
  deriving DecidableEq, Repr

def derivation : Use → Derivation
  | .storageKey => ⟨.masterKey, .hmac, ascii "Storage Service Encryption"⟩
  | .manifestKey v => ⟨.storageKey, .hmac, ascii "Manifest_" ++ dec v⟩
  | .itemKey raw => ⟨.storageKey, .hmac, ascii "Item_" ++ b64 raw⟩
  | .itemKeyIkm raw => ⟨.recordIkm, .hkdf [] 32, ascii "20240801_SIGNAL_STORAGE_SERVICE_ITEM_" ++ raw⟩
  | .groupV1MasterKey => ⟨.groupV1Id, .hkdf (zeros 32) 32, ascii "GV2 Migration"⟩
  | .stickerPackKeys => ⟨.packKey, .hkdf (zeros 32) 64, ascii "Sticker Pack"⟩
  | .callLinkRoomId => ⟨.callLinkRoot, .hkdf [] 32, ascii "20230501-Signal-CallLinkRootKey-RoomId"⟩
  | .provisioningKeys => ⟨.provisioningSecret, .hkdf [] 64, ascii "TextSecure Provisioning Message"⟩
  | .deviceNameAuth => ⟨.deviceNameSecret, .hmac, ascii "auth"⟩
  | .deviceNameCipher => ⟨.deviceNameSecret, .hmac, ascii "cipher"⟩
  | .deviceNameIv p => ⟨.deviceNameAuth, .hmac, p⟩
  | .deviceNameCipherKey iv => ⟨.deviceNameCipher, .hmac, iv⟩
  | .accessKeyVerifier => ⟨.accessKey, .hmac, zeros 32⟩

/-- What decides a derived key's bytes. HMAC pads a short key with zeros, so HKDF salts that
differ only in trailing zeros (none, or 32 zero bytes) are the same salt; and HKDF's first bytes
do not depend on how many are asked for, so the length is left out. -/
structure Canonical where
  source : Source
  hkdf : Bool
  salt : List Nat
  input : List Nat
  deriving DecidableEq, Repr

def stripZeros (l : List Nat) : List Nat := (l.reverse.dropWhile (· == 0)).reverse

def Derivation.canonical (d : Derivation) : Canonical :=
  match d.prim with
  | .hmac => ⟨d.source, false, [], d.input⟩
  | .hkdf salt _ => ⟨d.source, true, stripZeros salt, d.input⟩

/-- A use's parameters are bytes (only the legacy item key's id needs it). -/
def Use.WF : Use → Prop
  | .itemKey raw => Bytes raw
  | _ => True

/-! ## Keys

A key is named by the secret it comes from (ids: which storage key, which pack key; for X25519
the two keys' ids) and its use, or is a profile key, which encrypts profile fields directly.
**The contract** (assumed): two keys are the same bytes exactly when they have the same
`material`: a raw profile key, or the same secret put through the same canonical derivation.
HMAC and HKDF are pseudorandom functions and the secrets are independent, so different material
gives keys that cannot be told from independent random keys; the same material gives the same
key. -/

inductive Key
  | derived (secret : List Nat) (use : Use)
  | profile (key : Nat)
  deriving DecidableEq, Repr

inductive Material
  | derived (secret : List Nat) (d : Canonical)
  | profile (key : Nat)
  deriving DecidableEq, Repr

def Key.material : Key → Material
  | .derived s u => .derived s (derivation u).canonical
  | .profile k => .profile k

def Key.WF : Key → Prop
  | .derived _ u => u.WF
  | .profile _ => True

end Crypto
