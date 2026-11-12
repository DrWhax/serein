import Crypto.Padding
import Crypto.Labels
import Crypto.Profile
import Crypto.Formats

/-!
# The properties the explorer checks

Each is a theorem in `Proofs.lean` (or, for the four that fail, a limit proved there by a
counterexample); the explorer checks them on random inputs too, which also shows the checks are
not vacuous: the four limits are found.

* Padding: `unpad-inverts-pad`, `pad-length-blocks`, `unpad-accepts-only-padded`; and
  `unpad-matches-upstream`, which **fails**: input with no terminator is refused here and handed
  back upstream (`unpad_upstream_differs`).
* `derivations-separated`.
* Profile padding: `profile-length-bucket`, `name-roundtrip`; and `name-roundtrip-any-bytes`,
  which **fails**: a NUL inside a name splits it (`name_nul_splits`).
* Formats: `manifest-bound`, `items-bound`, `profile-key-bound`, `sticker-bound`,
  `sticker-mac-first`, `provision-bound`, `provision-mac-first`, `device-name-bound`; and two
  that **fail**: `profile-field-bound` (a field served as another decrypts,
  `profile_field_unbound`) and `device-name-from-our-devices` (anyone can encrypt a device name
  to our public identity key, `deviceName_unauthenticated`).
-/

namespace Crypto

def isError {α : Type} (e : Err) : Except Err α → Bool
  | .error e' => e' == e
  | .ok _ => false

def unpadInvertsB (m : List Nat) : Bool := unpad (pad m) == some m

def padLengthB (m m' : List Nat) : Bool :=
  ((pad m).length + 1) % 80 == 0 && m.length + 2 ≤ (pad m).length + 1 &&
    ((pad m).length == (pad m').length) == ((m.length + 1) / 80 == (m'.length + 1) / 80)

def unpadOnlyPaddedB (d : List Nat) : Bool :=
  match unpad d with
  | some m => d == m ++ 0x80 :: List.replicate (d.length - m.length - 1) 0
  | none => true

def unpadUpstreamB (d : List Nat) : Bool := unpad d == unpadUpstream d

def separatedB (u u' : Use) : Bool := (derivation u).canonical != (derivation u').canonical || u == u'

def bucketLengthB (f : Field) (item : List Nat) : Bool :=
  match padTo f.lengths item with
  | some p => bucket f.lengths item.length == some p.length && item.length ≤ p.length &&
      f.lengths.all (fun b => b < item.length || p.length ≤ b) && p.take item.length == item
  | none => f.lengths.all (· < item.length)

def nameRoundtripAnyB (g f : List Nat) : Bool :=
  match padTo Field.name.lengths (nameBytes g f) with
  | some p => decodeName p == (g, f)
  | none => true

def nameRoundtripB (g f : List Nat) : Bool := g.contains 0 || f.contains 0 || nameRoundtripAnyB g f

def sealedUnder {C : Type} (k : Key) : Origin C → Bool
  | .sealed k' _ => k' == k
  | .other => false

def manifestBoundB (c : ManifestCase) : Bool :=
  match verifyManifest c with
  | .ok v => v == c.version && sealedUnder (manifestKey c.storage c.version) c.origin && fresh c.current v
  | .error _ => true

def itemsBoundB (c : ItemsCase) : Bool :=
  match verifyItems c with
  | .ok _ => c.items.all fun (raw, o) => c.requested.contains raw && sealedUnder (itemKey c.storage c.ikm raw) o
  | .error _ => true

def profileKeyBoundB (c : ProfileCase) : Bool :=
  match decryptProfile c with
  | .ok _ => sealedUnder (.profile c.key) c.origin
  | .error _ => true

def profileFieldBoundB (c : ProfileCase) : Bool :=
  match decryptProfile c, c.origin with
  | .ok _, .sealed _ p => p.field == c.field
  | _, _ => true

def stickerBoundB (c : StickerCase) : Bool :=
  match decryptSticker c with
  | .ok _ => sealedUnder (stickerKeys c.pack) c.origin
  | .error _ => true

def stickerMacFirstB (c : StickerCase) : Bool :=
  (opens (stickerKeys c.pack) c.origin).isSome || isError (if c.len < 48 then .tooShort else .badMAC) (decryptSticker c)

def provisionBoundB (c : ProvisionCase) : Bool :=
  match decryptProvision c with
  | .ok _ => sealedUnder (provisioningKeys c.ours c.eph) c.origin
  | .error _ => true

def provisionMacFirstB (c : ProvisionCase) : Bool :=
  (opens (provisioningKeys c.ours c.eph) c.origin).isSome || isError ((provisionShape c).getD .badMAC) (decryptProvision c)

def deviceNameBoundB (c : DeviceNameCase) : Bool :=
  match decryptDeviceName c with
  | .ok _ => sealedUnder (deviceNameKey c.identity c.eph) c.origin
  | .error _ => true

def deviceNameOursB (c : DeviceNameCase) : Bool :=
  match decryptDeviceName c, c.origin with
  | .ok _, .sealed _ d => d.author == .ourDevice
  | _, _ => true

end Crypto
