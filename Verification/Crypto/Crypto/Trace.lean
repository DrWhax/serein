import Crypto.Padding
import Crypto.Labels
import Crypto.Profile
import Crypto.Formats

/-! # Notation for the Swift rig

Bytes are lowercase hex, `-` for none. One case per line, one answer per line.

* `pad`: a message → its padding. `unpad`: bytes → the message, or `invalid`.
* `derive`: a use (`manifestKey 12`, `itemKey <hex>`, `deviceNameIv <hex>`, `storageKey`, …) →
  `<source> hmac <input>` or `<source> hkdf:<salt>:<length> <info>`.
* `profilePad`: `name <given> <family>`, `about <bytes>` or `aboutEmoji <bytes>` → the padded
  plaintext, or `tooLong`.
* Keys: `manifest:<storage>:<version>`, `item:<storage>:<id>`, `ikm:<ikm>:<id>`, `profile:<key>`,
  `sticker:<pack>`, `prov:<recipient>:<ephemeral>`, `device:<identity>:<ephemeral>`. An origin is
  `other`, or `sealed <key>` and its content.
* `manifest`: `<storage> <version> <current or -> <origin>`, content `<parses> <inner version>` →
  `ok:<version>` or the error.
* `items`: `<storage> <ikm or -> | <requested ids, comma-separated, or -> | <id>=<origin>;…` (or
  `-`), content `<parses>` → `ok:<records>:<missing>` or the error.
* `profile`: `<key> <field> <length> <origin>`, content `<field> <padded plaintext>` →
  `name:<given>:<family>`, `text:<bytes>` or the error.
* `sticker`: `<pack> <length> <origin>`, content `<plaintext length>` or `bad` → `ok:<length>`.
* `provision`: `<parses> <fields> <body length> <version> <keyOK> <ours> <ephemeral> <origin>`,
  content `ok`, `noparse` or `bad` → `ok`.
* `device`: `<parses> <fields> <keyOK> <identity> <ephemeral> <origin>`, content `us` or
  `other` and the plaintext → `ok:<plaintext>`.

Booleans are `0`/`1`. Errors: `tooShort malformed badKey badMAC badPadding proto versionMismatch
unrequested cannotDecrypt`.
-/

namespace Crypto

def words (s : String) : List String := (s.splitOn " ").filter (!·.isEmpty)
def bit (s : String) : Option Bool := if s == "1" then some true else if s == "0" then some false else none

def hexDigit (c : Char) : Option Nat :=
  if '0' ≤ c ∧ c ≤ '9' then some (c.toNat - 48) else if 'a' ≤ c ∧ c ≤ 'f' then some (c.toNat - 87) else none

def hexBytes (s : String) : Option (List Nat) :=
  if s == "-" then some [] else
  let rec go : List Char → Option (List Nat)
    | [] => some []
    | a :: b :: rest => do pure (((← hexDigit a) * 16 + (← hexDigit b)) :: (← go rest))
    | [_] => none
  go s.toList

def hex (l : List Nat) : String :=
  if l.isEmpty then "-" else
  String.join (l.map fun b => let d := "0123456789abcdef".toList; s!"{d.getD (b / 16) '0'}{d.getD (b % 16) '0'}")

def errName : Err → String
  | .tooShort => "tooShort" | .malformed => "malformed" | .badKey => "badKey" | .badMAC => "badMAC"
  | .badPadding => "badPadding" | .proto => "proto" | .versionMismatch => "versionMismatch"
  | .unrequested => "unrequested" | .cannotDecrypt => "cannotDecrypt"

def answer {α : Type} (f : α → String) : Except Err α → String
  | .ok a => f a
  | .error e => errName e

/-! ## Padding and derivations -/

def padAnswer (line : String) : Option String := do pure (hex (pad (← hexBytes line)))

def unpadAnswer (line : String) : Option String := do
  pure (match unpad (← hexBytes line) with | some m => hex m | none => "invalid")

def parseUse (line : String) : Option Use :=
  match words line with
  | ["storageKey"] => some .storageKey
  | ["manifestKey", v] => do pure (.manifestKey (← v.toNat?))
  | ["itemKey", r] => do pure (.itemKey (← hexBytes r))
  | ["itemKeyIkm", r] => do pure (.itemKeyIkm (← hexBytes r))
  | ["groupV1MasterKey"] => some .groupV1MasterKey
  | ["stickerPackKeys"] => some .stickerPackKeys
  | ["callLinkRoomId"] => some .callLinkRoomId
  | ["provisioningKeys"] => some .provisioningKeys
  | ["deviceNameAuth"] => some .deviceNameAuth
  | ["deviceNameCipher"] => some .deviceNameCipher
  | ["deviceNameIv", p] => do pure (.deviceNameIv (← hexBytes p))
  | ["deviceNameCipherKey", iv] => do pure (.deviceNameCipherKey (← hexBytes iv))
  | ["accessKeyVerifier"] => some .accessKeyVerifier
  | _ => none

def sourceName : Source → String
  | .masterKey => "masterKey" | .storageKey => "storageKey" | .recordIkm => "recordIkm" | .groupV1Id => "groupV1Id"
  | .packKey => "packKey" | .callLinkRoot => "callLinkRoot" | .provisioningSecret => "provisioningSecret"
  | .deviceNameSecret => "deviceNameSecret" | .deviceNameAuth => "deviceNameAuth" | .deviceNameCipher => "deviceNameCipher"
  | .accessKey => "accessKey"

def deriveAnswer (line : String) : Option String := do
  let d := derivation (← parseUse line)
  let prim := match d.prim with | .hmac => "hmac" | .hkdf salt n => s!"hkdf:{hex salt}:{n}"
  pure s!"{sourceName d.source} {prim} {hex d.input}"

def parseField : String → Option Field
  | "name" => some .name | "about" => some .about | "aboutEmoji" => some .aboutEmoji | _ => none

def profilePadAnswer (line : String) : Option String := do
  let item ← match words line with
    | ["name", g, f] => do pure (Field.name, nameBytes (← hexBytes g) (← hexBytes f))
    | [k, b] => do pure (← parseField k, ← hexBytes b)
    | _ => none
  pure (match padTo item.1.lengths item.2 with | some p => hex p | none => "tooLong")

/-! ## Formats -/

def parseKey (s : String) : Option Key :=
  match s.splitOn ":" with
  | ["manifest", a, v] => do pure (.derived [← a.toNat?] (.manifestKey (← v.toNat?)))
  | ["item", a, r] => do pure (.derived [← a.toNat?] (.itemKey (← hexBytes r)))
  | ["ikm", a, r] => do pure (.derived [← a.toNat?] (.itemKeyIkm (← hexBytes r)))
  | ["profile", p] => do pure (.profile (← p.toNat?))
  | ["sticker", k] => do pure (.derived [← k.toNat?] .stickerPackKeys)
  | ["prov", r, e] => do pure (.derived [← r.toNat?, ← e.toNat?] .provisioningKeys)
  | ["device", i, e] => do pure (.derived [← i.toNat?, ← e.toNat?] .deviceNameAuth)
  | _ => none

/-- `other`, or `sealed <key>` followed by the content's words. -/
def parseOrigin {C : Type} (content : List String → Option C) : List String → Option (Origin C)
  | ["other"] => some .other
  | "sealed" :: k :: rest => do pure (.sealed (← parseKey k) (← content rest))
  | _ => none

def manifestAnswer (line : String) : Option String :=
  match words line with
  | s :: v :: cur :: origin => do
    let current ← if cur == "-" then some none else (some <$> cur.toNat?)
    let o ← parseOrigin (fun | [p, i] => do pure ⟨← bit p, ← i.toNat?⟩ | _ => none) origin
    pure (answer (fun v => s!"ok:{v}") (verifyManifest ⟨← s.toNat?, ← v.toNat?, current, o⟩))
  | _ => none

def parseItem (it : String) : Option (List Nat × Origin RecordContent) :=
  match it.splitOn "=" with
  | [r, o] => do pure (← hexBytes r, ← parseOrigin (fun | [p] => do pure ⟨← bit p⟩ | _ => none) (words o))
  | _ => none

def itemsAnswer (line : String) : Option String :=
  match line.splitOn " | " with
  | [head, req, resp] => do
    let (s, ikm) ← match words head with
      | [s, i] => do
        let ikm : Option Nat ← (if i == "-" then some none else some <$> i.toNat?)
        pure (← s.toNat?, ikm)
      | _ => none
    let requested ← if req == "-" then some [] else (req.splitOn ",").mapM hexBytes
    let items ← if resp == "-" then some [] else (resp.splitOn ";").mapM parseItem
    pure (answer (fun (ids, missing) => s!"ok:{ids.length}:{missing}") (verifyItems ⟨s, ikm, requested, items⟩))
  | _ => none

def profileAnswer (line : String) : Option String :=
  match words line with
  | k :: f :: len :: origin => do
    let o ← parseOrigin (fun | [f, p] => do pure ⟨← parseField f, ← hexBytes p⟩ | _ => none) origin
    pure (answer (fun | .name g fam => s!"name:{hex g}:{hex fam}" | .text t => s!"text:{hex t}")
      (decryptProfile ⟨← k.toNat?, ← parseField f, ← len.toNat?, o⟩))
  | _ => none

def stickerAnswer (line : String) : Option String :=
  match words line with
  | k :: len :: origin => do
    let o ← parseOrigin (fun | ["bad"] => some ⟨none⟩ | [n] => do pure ⟨some (← n.toNat?)⟩ | _ => none) origin
    pure (answer (fun n => s!"ok:{n}") (decryptSticker ⟨← k.toNat?, ← len.toNat?, o⟩))
  | _ => none

def provisionAnswer (line : String) : Option String :=
  match words line with
  | p :: f :: len :: v :: k :: ours :: eph :: origin => do
    let o ← parseOrigin (fun | ["ok"] => some ⟨some true⟩ | ["noparse"] => some ⟨some false⟩ | ["bad"] => some ⟨none⟩ | _ => none) origin
    pure (answer (fun _ => "ok") (decryptProvision ⟨← bit p, ← bit f, ← len.toNat?, ← v.toNat?, ← bit k, ← ours.toNat?, ← eph.toNat?, o⟩))
  | _ => none

def deviceAnswer (line : String) : Option String :=
  match words line with
  | p :: f :: k :: i :: e :: origin => do
    let o ← parseOrigin (fun
      | [a, t] => do pure ⟨← (if a == "us" then some .ourDevice else if a == "other" then some .someoneElse else none), ← hexBytes t⟩
      | _ => none) origin
    pure (answer (fun t => s!"ok:{hex t}") (decryptDeviceName ⟨← bit p, ← bit f, ← bit k, ← i.toNat?, ← e.toNat?, o⟩))
  | _ => none

end Crypto
