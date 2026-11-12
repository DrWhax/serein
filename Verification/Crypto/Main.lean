import Crypto.Padding
import Crypto.Labels
import Crypto.Profile
import Crypto.Formats
import Crypto.Props
import Crypto.Trace

/-!
# The oracle executable

* `oracle pad | unpad | derive | profilePad | manifest | items | profile | sticker | provision |
  device`: cases on stdin (see `Trace.lean`), one answer per line.
* `oracle explore <seed> <runs>`: random inputs for every property (messages and byte strings
  heavy in 0x00 and 0x80; uses with near-colliding parameters; names with and without NULs;
  every format's cases with origins sealed under the right key, under keys one parameter away,
  under unrelated keys, or not sealed at all).
-/

open Crypto

structure Rng where
  s : UInt64

def Rng.next (r : Rng) : UInt64 × Rng :=
  let s := r.s + 0x9E3779B97F4A7C15
  let z := (s ^^^ (s >>> 30)) * 0xBF58476D1CE4E5B9
  let z := (z ^^^ (z >>> 27)) * 0x94D049BB133111EB
  (z ^^^ (z >>> 31), ⟨s⟩)

def Rng.below (r : Rng) (n : Nat) : Nat × Rng :=
  let (x, r) := r.next
  (if n == 0 then 0 else x.toNat % n, r)

def Rng.coin (r : Rng) : Bool × Rng := let (x, r) := r.below 2; (x == 0, r)

/-- Bytes, mostly from a few values (0, 0x80, 1, 255, 'A') so that near collisions are common. -/
def Rng.bytes (r : Rng) (maxLen : Nat) : List Nat × Rng := Id.run do
  let (n, r) := r.below (maxLen + 1)
  let mut r := r
  let mut out := []
  for _ in [0:n] do
    let (k, r1) := r.below 8
    let (b, r2) := r1.below 256
    r := r2
    out := out ++ [match k with | 0 | 1 => 0 | 2 => 0x80 | 3 => 1 | 4 => 255 | 5 => 65 | _ => b]
  (out, r)

def Rng.noNul (r : Rng) (maxLen : Nat) : List Nat × Rng :=
  let (l, r) := r.bytes maxLen
  (l.map fun b => if b == 0 then 66 else b, r)

def Rng.use (r : Rng) : Use × Rng :=
  let (k, r) := r.below 13
  let (v, r) := r.below 12
  let (big, r) := r.coin
  let (raw, r) := r.bytes 5
  let v := if big then v * 10 else v
  (match k with
    | 0 => .storageKey | 1 => .manifestKey v | 2 => .itemKey raw | 3 => .itemKeyIkm raw | 4 => .groupV1MasterKey
    | 5 => .stickerPackKeys | 6 => .callLinkRoomId | 7 => .provisioningKeys | 8 => .deviceNameAuth | 9 => .deviceNameCipher
    | 10 => .deviceNameIv raw | 11 => .deviceNameCipherKey raw | _ => .accessKeyVerifier, r)

/-- A key that is `right` with probability 1/2, else an unrelated one or `right` with one
parameter changed (`near`). -/
def Rng.key (r : Rng) (right : Key) (near : List Key) : Key × Rng :=
  let (k, r) := r.below 6
  let (u, r) := r.use
  let (a, r) := r.below 3
  let (b, r) := r.below 3
  let (i, r) := r.below (near.length + 1)
  (match k with
    | 0 | 1 | 2 => right
    | 3 => near.getD i right
    | 4 => .derived [a] u
    | _ => if a == 0 then .profile b else .derived [a, b] u, r)

def Rng.origin {C : Type} (r : Rng) (right : Key) (near : List Key) (content : C) : Origin C × Rng :=
  let (k, r) := r.below 5
  let (key, r) := r.key right near
  (if k == 0 then .other else .sealed key content, r)

def Rng.items (r : Rng) (storage : Nat) (ikm : Option Nat) (ids : List (List Nat)) : List (List Nat × Origin RecordContent) × Rng := Id.run do
  let (n, r) := r.below 4
  let mut r := r
  let mut out := []
  for _ in [0:n] do
    let (i, r1) := r.below (ids.length + 1)
    let (extra, r2) := r1.bytes 3
    let raw := ids.getD i extra
    let (j, r3) := r2.below (ids.length + 1)
    let other := ids.getD j extra
    let (p, r4) := r3.below 6
    let (o, r5) := r4.origin (itemKey storage ikm raw) [itemKey storage ikm other, itemKey storage none raw, itemKey (storage + 1) ikm raw,
                              .derived [storage] (.manifestKey 1)] (⟨p != 0⟩ : RecordContent)
    r := r5
    out := out ++ [(raw, o)]
  (out, r)

def randomField (r : Rng) : Field × Rng := let (k, r) := r.below 3; (match k with | 0 => .name | 1 => .about | _ => .aboutEmoji, r)

/-- One random input for every property: (name, holds). -/
def round (r : Rng) : List (String × Bool) × Rng := Id.run do
  let (m, r) := r.bytes 200
  let (m', r) := r.bytes 200
  let (d, r) := r.bytes 6
  let (useZeros, r) := r.below 4
  let d := if useZeros == 0 then List.replicate d.length 0 else d
  let (u, r) := r.use
  let (u', r) := r.use
  let (f, r) := randomField r
  let (item, r) := r.bytes 600
  let (g, r) := r.bytes 30
  let (fam, r) := r.bytes 30
  let (g0, r) := r.noNul 60
  let (fam0, r) := r.noNul 250
  -- Manifests.
  let (s, r) := r.below 3
  let (v, r) := r.below 6
  let (cur, r) := r.below 8
  let (inner, r) := r.below 6
  let (parses, r) := r.below 8
  let (mo, r) := r.origin (manifestKey s v) [manifestKey s (v + 1), manifestKey (s + 1) v, .derived [s] (.itemKey [v])]
                  (⟨parses != 0, if inner < 4 then v else inner⟩ : ManifestContent)
  let mc : ManifestCase := ⟨s, v, if cur < 6 then some cur else none, mo⟩
  -- Items.
  let (ikmK, r) := r.below 3
  let ikm := if ikmK == 0 then none else some ikmK
  let (id1, r) := r.bytes 3
  let (id2, r) := r.bytes 3
  let ids := [id1, id2].eraseDups
  let (its, r) := r.items s ikm ids
  let ic : ItemsCase := ⟨s, ikm, ids, its⟩
  -- Profiles.
  let (pk, r) := r.below 3
  let (pf, r) := randomField r
  let (wf, r) := randomField r
  let (plain, r) := r.bytes 60
  let (plen, r) := r.below 120
  let (same, r) := r.below 3
  let (po, r) := r.origin (.profile pk) [.profile (pk + 1)] (⟨if same != 0 then pf else wf, plain⟩ : ProfileContent)
  let pc : ProfileCase := ⟨pk, pf, plen, po⟩
  -- Stickers.
  let (sp, r) := r.below 3
  let (slen, r) := r.below 120
  let (sbad, r) := r.below 5
  let (so, r) := r.origin (stickerKeys sp) [stickerKeys (sp + 1), .derived [sp] .provisioningKeys] (⟨if sbad == 0 then none else some slen⟩ : StickerContent)
  let sc : StickerCase := ⟨sp, slen, so⟩
  -- Provisioning.
  let (flags, r) := r.below 64
  let (blen, r) := r.below 120
  let (ver, r) := r.below 3
  let (ours, r) := r.below 2
  let (eph, r) := r.below 3
  let (pv, r) := r.below 4
  let (pvo, r) := r.origin (provisioningKeys ours eph) [provisioningKeys (ours + 1) eph, provisioningKeys ours (eph + 1), deviceNameKey ours eph]
                    (⟨if pv == 0 then none else some (pv != 1)⟩ : ProvisionContent)
  let vc : ProvisionCase := ⟨flags % 8 != 0, flags / 8 % 8 != 0, blen, if ver == 0 then 2 else 1, flags % 5 != 0, ours, eph, pvo⟩
  -- Device names.
  let (dflags, r) := r.below 64
  let (di, r) := r.below 2
  let (de, r) := r.below 3
  let (author, r) := r.coin
  let (dplain, r) := r.bytes 20
  let (dvo, r) := r.origin (deviceNameKey di de) [deviceNameKey (di + 1) de, deviceNameKey di (de + 1), provisioningKeys di de]
                    (⟨if author then .ourDevice else .someoneElse, dplain⟩ : DeviceNameContent)
  let dc : DeviceNameCase := ⟨dflags % 8 != 0, dflags / 8 % 8 != 0, dflags % 5 != 0, di, de, dvo⟩
  ([("unpad-inverts-pad", unpadInvertsB m), ("pad-length-blocks", padLengthB m m'),
    ("unpad-accepts-only-padded", unpadOnlyPaddedB d), ("unpad-matches-upstream", unpadUpstreamB d),
    ("derivations-separated", separatedB u u' && separatedB u u),
    ("profile-length-bucket", bucketLengthB f item), ("name-roundtrip", nameRoundtripB g0 fam0 && nameRoundtripB g fam),
    ("name-roundtrip-any-bytes", nameRoundtripAnyB g fam),
    ("manifest-bound", manifestBoundB mc), ("items-bound", itemsBoundB ic),
    ("profile-key-bound", profileKeyBoundB pc), ("profile-field-bound", profileFieldBoundB pc),
    ("sticker-bound", stickerBoundB sc), ("sticker-mac-first", stickerMacFirstB sc),
    ("provision-bound", provisionBoundB vc), ("provision-mac-first", provisionMacFirstB vc),
    ("device-name-bound", deviceNameBoundB dc), ("device-name-from-our-devices", deviceNameOursB dc)], r)

def explore (seed count : Nat) : IO Unit := do
  let mut r : Rng := ⟨UInt64.ofNat seed⟩
  let mut found : List String := []
  let mut names : List String := []
  for _ in [0:count] do
    let (results, r') := round r
    r := r'
    names := results.map (·.1)
    for (name, ok) in results do
      if !found.contains name && !ok then found := found ++ [name]
  for name in names do
    IO.println (if found.contains name then s!"FAIL {name}" else s!"OK {name}: no violation in {count} random inputs")

def forLines (f : String → Option String) : IO UInt32 := do
  let stdin ← IO.getStdin
  repeat
    let line ← stdin.getLine
    if line.isEmpty then break
    let line := line.trimAsciiEnd.toString
    if line.isEmpty || line.startsWith "#" then continue
    match f line with
    | some a => IO.println a
    | none => IO.eprintln s!"bad case: {line}"; return 1
  return 0

def main (args : List String) : IO UInt32 := do
  match args with
  | ["pad"] => forLines padAnswer
  | ["unpad"] => forLines unpadAnswer
  | ["derive"] => forLines deriveAnswer
  | ["profilePad"] => forLines profilePadAnswer
  | ["manifest"] => forLines manifestAnswer
  | ["items"] => forLines itemsAnswer
  | ["profile"] => forLines profileAnswer
  | ["sticker"] => forLines stickerAnswer
  | ["provision"] => forLines provisionAnswer
  | ["device"] => forLines deviceAnswer
  | ["explore", seed, count] => explore seed.toNat! count.toNat!; return 0
  | _ => IO.eprintln "usage: oracle pad | unpad | derive | profilePad | manifest | items | profile | sticker | provision | device | explore <seed> <runs>"; return 2
