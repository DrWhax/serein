import Crypto.Labels
import Crypto.Profile

/-!
# Encrypted formats: the model

Six decryptions SignalCore does itself, each as the checks production makes, in its order:

* **Storage manifests** (`StorageService.verifyManifest`): AES-256-GCM under the key for the
  version the server says the manifest has; the record inside must parse and name that same
  version, and be newer than the one we have (or both 0).
* **Storage records** (`StorageService.requestedOnly`, then `decryptItem` for each): the server
  may return only keys we asked for; each value is AES-256-GCM under the key for its own item
  id (from the manifest's record IKM, or the legacy storage-key derivation) and must parse.
* **Profile fields** (`ProfileService.decryptName`, `decryptString`): at least nonce, one byte
  and tag; AES-256-GCM under the contact's profile key; then the padding is read (`Profile`).
* **Sticker images and manifests** (`Stickers.decrypt`, `AttachmentCipher.decryptV1`): at
  least IV and tag; the HMAC tag under the MAC half of the pack key's derived keys; then
  AES-256-CBC with PKCS#7 under the AES half.
* **Provisioning envelopes** (`ProvisioningCipher.decrypt`): the envelope parses and has a
  public key and a body of at least version, IV, one block and tag; version 1; a valid public
  key; the HMAC tag under the keys derived from X25519(our provisioning key, that public key);
  then AES-256-CBC with PKCS#7, and the ProvisionMessage must parse.
* **Device names** (`DeviceNameCipher.decrypt`): the DeviceName parses and has its three fields
  (a 16-byte synthetic IV); a valid ephemeral key; AES-256-CTR under the cipher key, then the
  synthetic IV must equal the HMAC of the plaintext under the auth key.

What the bytes are is an `Origin`: the intact output of an encryption under some key, or not.
**The contract** (`opens`, assumed) is what makes a decryption authenticated: it succeeds exactly
on the intact output of an encryption under a key with the same material (`Key.material`, from
the key-separation table), and yields what was encrypted. Changed, cut, extended or made-up bytes
never verify. Who can make an origin under a key is whoever holds it: our devices for storage;
whoever has the profile key (every contact it was shared with) for profile fields; whoever has
the pack key for stickers; whoever saw the QR code (it alone carries our provisioning public
key) for provisioning; and anyone, the server included, for device names, since they are
encrypted to our public identity key.
-/

namespace Crypto

inductive Origin (C : Type)
  /-- The intact output of an encryption under `key`, holding `content`. -/
  | sealed (key : Key) (content : C)
  /-- Anything else: changed after encryption, cut, extended, or made without a key. -/
  | other
  deriving Repr

/-- **The contract**: decryption under `k` succeeds exactly on what was sealed under a key with
the same material. -/
def opens {C : Type} (k : Key) : Origin C → Option C
  | .sealed k' c => if k'.material = k.material then some c else none
  | .other => none

inductive Err
  | tooShort | malformed | badKey | badMAC | badPadding | proto | versionMismatch | unrequested | cannotDecrypt
  deriving DecidableEq, Repr

/-! ## Storage manifests -/

structure ManifestContent where
  parses : Bool
  /-- The version the writer put inside the record. -/
  inner : Nat
  deriving DecidableEq, Repr

structure ManifestCase where
  /-- Our storage key (an id). -/
  storage : Nat
  /-- `StorageManifest.version`: what the server says. -/
  version : Nat
  /-- The version we have, if any. -/
  current : Option Nat
  origin : Origin ManifestContent
  deriving Repr

def manifestKey (storage version : Nat) : Key := .derived [storage] (.manifestKey version)

/-- No rollback: newer than ours, or both 0 (upstream's rule). -/
def fresh (current : Option Nat) (v : Nat) : Bool :=
  match current with
  | none => true
  | some c => c < v || (v == 0 && c == 0)

/-- `StorageService.verifyManifest`: the version accepted, or the first check that fails. -/
def verifyManifest (c : ManifestCase) : Except Err Nat :=
  match opens (manifestKey c.storage c.version) c.origin with
  | none => .error .cannotDecrypt
  | some m =>
    if !m.parses then .error .proto
    else if m.inner != c.version then .error .versionMismatch
    else if !fresh c.current c.version then .error .versionMismatch
    else .ok c.version

/-! ## Storage records -/

structure RecordContent where
  parses : Bool
  deriving DecidableEq, Repr

structure ItemsCase where
  storage : Nat
  /-- The manifest's record IKM (an id), if it has one. -/
  ikm : Option Nat
  /-- The item ids we asked for. -/
  requested : List (List Nat)
  /-- The server's answer: each item's id and value. -/
  items : List (List Nat × Origin RecordContent)
  deriving Repr

def itemKey (storage : Nat) (ikm : Option Nat) (raw : List Nat) : Key :=
  match ikm with
  | some i => .derived [i] (.itemKeyIkm raw)
  | none => .derived [storage] (.itemKey raw)

/-- `decryptItem` for each item in order: their ids, or the first that fails. -/
def decryptItems (storage : Nat) (ikm : Option Nat) : List (List Nat × Origin RecordContent) → Except Err (List (List Nat))
  | [] => .ok []
  | (raw, o) :: rest =>
    match opens (itemKey storage ikm raw) o with
    | none => .error .cannotDecrypt
    | some r => if !r.parses then .error .proto else (raw :: ·) <$> decryptItems storage ikm rest

/-- `requestedOnly` (the whole answer is refused if it has an id we did not ask for), then
`decryptItems`: the records' ids, and how many requested ids have no item. -/
def verifyItems (c : ItemsCase) : Except Err (List (List Nat) × Nat) :=
  if !c.items.all (fun i => c.requested.contains i.1) then .error .unrequested
  else (·, (c.requested.eraseDups.filter fun r => !c.items.any (·.1 == r)).length) <$> decryptItems c.storage c.ikm c.items

/-! ## Profile fields -/

structure ProfileContent where
  /-- The field the writer encrypted (decryption cannot tell). -/
  field : Field
  /-- The padded plaintext. -/
  plain : List Nat
  deriving DecidableEq, Repr

structure ProfileCase where
  /-- The contact's profile key (an id). -/
  key : Nat
  /-- The field it is read as. -/
  field : Field
  /-- The ciphertext's length: nonce ‖ ciphertext ‖ tag. -/
  len : Nat
  origin : Origin ProfileContent
  deriving Repr

inductive ProfileValue
  | name (gname fname : List Nat)
  | text (s : List Nat)
  deriving DecidableEq, Repr

def readField (f : Field) (plain : List Nat) : ProfileValue :=
  match f with
  | .name => let (g, fam) := decodeName plain; .name g fam
  | _ => .text (decodeString plain)

def decryptProfile (c : ProfileCase) : Except Err ProfileValue :=
  if c.len < 12 + 1 + 16 then .error .tooShort
  else match opens (.profile c.key) c.origin with
    | none => .error .badMAC
    | some p => .ok (readField c.field p.plain)

/-! ## Stickers -/

structure StickerContent where
  /-- AES-256-CBC's result: the plaintext's length once its PKCS#7 padding is removed, or `none`
  if that padding is invalid or the ciphertext is not whole blocks. -/
  plain : Option Nat
  deriving DecidableEq, Repr

structure StickerCase where
  /-- The pack key (an id). -/
  pack : Nat
  len : Nat
  origin : Origin StickerContent
  deriving Repr

def stickerKeys (pack : Nat) : Key := .derived [pack] .stickerPackKeys

def decryptSticker (c : StickerCase) : Except Err Nat :=
  if c.len < 16 + 32 then .error .tooShort
  else match opens (stickerKeys c.pack) c.origin with
    | none => .error .badMAC
    | some s => match s.plain with
      | none => .error .badPadding
      | some n => .ok n

/-! ## Provisioning -/

structure ProvisionContent where
  /-- AES-256-CBC's result: `none` if its padding is invalid, else whether the ProvisionMessage
  parses. -/
  plain : Option Bool
  deriving DecidableEq, Repr

structure ProvisionCase where
  /-- The ProvisionEnvelope parses, and has a public key and a body. -/
  parses : Bool
  fields : Bool
  bodyLen : Nat
  /-- The body's first byte. -/
  version : Nat
  /-- The envelope's public key is a valid X25519 key. -/
  keyOK : Bool
  /-- Our provisioning key and the envelope's ephemeral key (ids). -/
  ours : Nat
  eph : Nat
  origin : Origin ProvisionContent
  deriving Repr

def provisioningKeys (recipient eph : Nat) : Key := .derived [recipient, eph] .provisioningKeys

/-- The checks before the tag: their verdict, if one fails. -/
def provisionShape (c : ProvisionCase) : Option Err :=
  if !c.parses then some .proto
  else if !c.fields then some .malformed
  else if c.bodyLen < 1 + 16 + 16 + 32 then some .malformed
  else if c.version != 1 then some .malformed
  else if !c.keyOK then some .badKey
  else none

def decryptProvision (c : ProvisionCase) : Except Err Unit :=
  match provisionShape c with
  | some e => .error e
  | none =>
    match opens (provisioningKeys c.ours c.eph) c.origin with
    | none => .error .badMAC
    | some p => match p.plain with
      | none => .error .badPadding
      | some false => .error .proto
      | some true => .ok ()

/-! ## Device names -/

inductive Author | ourDevice | someoneElse
  deriving DecidableEq, Repr

structure DeviceNameContent where
  /-- Who encrypted it (decryption cannot tell). -/
  author : Author
  plain : List Nat
  deriving DecidableEq, Repr

structure DeviceNameCase where
  parses : Bool
  /-- An ephemeral key, a 16-byte synthetic IV and a ciphertext. -/
  fields : Bool
  keyOK : Bool
  /-- Our identity key and the DeviceName's ephemeral key (ids). -/
  identity : Nat
  eph : Nat
  origin : Origin DeviceNameContent
  deriving Repr

/-- The construction is keyed by X25519(identity, ephemeral); it is named by its auth key. -/
def deviceNameKey (identity eph : Nat) : Key := .derived [identity, eph] .deviceNameAuth

def decryptDeviceName (c : DeviceNameCase) : Except Err (List Nat) :=
  if !c.parses then .error .proto
  else if !c.fields then .error .malformed
  else if !c.keyOK then .error .badKey
  else match opens (deviceNameKey c.identity c.eph) c.origin with
    | none => .error .badMAC
    | some d => .ok d.plain

end Crypto
