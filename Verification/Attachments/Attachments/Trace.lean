import Attachments.Model

/-! # Notation for the Swift rig

* `decrypt`: `keyOK len macOK inc integrity size plain` (`plain`: AES's unpadded length or `x`) with `inc` one of `none ok bad huge` and
  `integrity` one of `d:<empty>:<good>`, `h:<good>`, `m` (booleans 0/1) → `ok:<length>` or the
  error's name.
* `download`: `maxSize | size plainLen pad bucket hasDigest hasHash | length genuine` with `genuine` one of `own`
  (the upload's blob), `other` (another upload's), `forged` → `published:<length>`, `error` or
  `tooBig`.
-/

namespace Attachments

def words (s : String) : List String := (s.splitOn " ").filter (!·.isEmpty)
def bit (s : String) : Bool := s == "1"

def errName : Err → String
  | .badKey => "badKey" | .tooShort => "tooShort" | .badMAC => "badMAC" | .badIncrementalMAC => "badIncrementalMAC"
  | .badPadding => "badPadding" | .missingDigest => "missingDigest" | .badDigest => "badDigest" | .badPlaintextHash => "badPlaintextHash"

def parseInc : String → Option Inc
  | "none" => some .none | "ok" => some .ok | "bad" => some .bad | "huge" => some .huge | _ => none

def parseIntegrity (s : String) : Option Integrity :=
  match s.splitOn ":" with
  | ["d", e, g] => some (.digest (bit e) (bit g))
  | ["h", g] => some (.hash (bit g))
  | ["m"] => some .macOnly
  | _ => none

def decryptAnswer (line : String) : Option String :=
  match words line with
  | [k, l, m, i, g, sz, pl] => do
    let b : Blob := { keyOK := bit k, len := ← l.toNat?, macOK := bit m, inc := ← parseInc i, integrity := ← parseIntegrity g,
                      size := ← sz.toNat?, plain := pl.toNat? }
    pure (match decrypt b with
      | .ok n => s!"ok:{n}"
      | .error e => errName e)
  | _ => none

def downloadAnswer (line : String) : Option String :=
  match line.splitOn " | " with
  | [mx, att, resp] => do
    let maxSize ← mx.toNat?
    let (size, plainLen, pad, bucket, hd, hh) ← match words att with
      | [a, b, c, d, e, f] => do pure (← a.toNat?, ← b.toNat?, ← c.toNat?, ← d.toNat?, bit e, bit f)
      | _ => none
    let (len, g) ← match words resp with
      | [a, b] => do pure (← a.toNat?, b)
      | _ => none
    let genuine := match g with | "own" => some 1 | "other" => some 2 | _ => none
    let a : Att := { id := 0, upload := 1, size, plainLen, pad, bucket, hasDigest := hd, hasHash := hh, st := .pending, path := none }
    let s := step (step (S.init maxSize) (.arrive a)) (.download 0 ⟨len, genuine⟩)
    match s.atts.head?, s.files.head? with
    | some { st := .published, .. }, some f => pure s!"published:{f.len}"
    | some { st := .tooBig, .. }, _ => pure "tooBig"
    | some { st := .error, .. }, _ => pure "error"
    | _, _ => pure "pending"
  | _ => none

end Attachments
