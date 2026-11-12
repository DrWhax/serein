import Crypto.Padding
import Crypto.Labels
import Crypto.Profile
import Crypto.Formats

/-! # The proofs -/

namespace Crypto

/-! ## Transport padding -/

theorem paddedLength_eq (n : Nat) : paddedLength n = ((n + 1) / 80 + 1) * 80 - 1 := by
  unfold paddedLength paddingBlock; omega

theorem pad_length (m : List Nat) : (pad m).length = paddedLength m.length := by
  simp only [pad, List.length_append, List.length_cons, List.length_replicate, paddedLength_eq]; omega

/-- A padded message plus one byte is whole blocks, the message, its terminator and at least one
more byte, and less than one block more. -/
theorem pad_length_bounds (n : Nat) : (paddedLength n + 1) % 80 = 0 ∧ n + 2 ≤ paddedLength n + 1 ∧ paddedLength n + 1 < n + 2 + 80 := by
  rw [paddedLength_eq]; omega

/-- **The length shows only the block count**: two messages pad to the same length exactly when
`(length + 1) / 80` is the same. -/
theorem pad_length_iff (m m' : List Nat) : (pad m).length = (pad m').length ↔ (m.length + 1) / 80 = (m'.length + 1) / 80 := by
  rw [pad_length, pad_length, paddedLength_eq, paddedLength_eq]; omega

theorem stripRev_zeros (k : Nat) (t : List Nat) : stripRev (List.replicate k 0 ++ 0x80 :: t) = some t := by
  induction k with
  | zero => simp [stripRev]
  | succ k ih => simp [List.replicate_succ, stripRev, ih]

theorem stripRev_eq_some (r t : List Nat) : stripRev r = some t ↔ ∃ k, r = List.replicate k 0 ++ 0x80 :: t := by
  induction r with
  | nil => simp [stripRev]
  | cons b r ih =>
    constructor
    · intro h
      simp only [stripRev] at h
      split at h
      · exact ⟨0, by simp_all⟩
      · split at h
        · obtain ⟨k, hk⟩ := ih.mp h
          exact ⟨k + 1, by simp_all [List.replicate_succ]⟩
        · simp at h
    · rintro ⟨k, hk⟩
      rw [hk, stripRev_zeros]

/-- **Unpadding inverts padding**, for every message. -/
theorem unpad_pad (m : List Nat) : unpad (pad m) = some m := by
  simp [unpad, pad, List.reverse_append, List.reverse_replicate, stripRev_zeros]

/-- **What `unpad` accepts**: exactly a message, the terminator, and zeros. -/
theorem unpad_eq_some (d m : List Nat) : unpad d = some m ↔ ∃ k, d = m ++ 0x80 :: List.replicate k 0 := by
  unfold unpad
  constructor
  · intro h
    obtain ⟨t, ht, rfl⟩ := Option.map_eq_some_iff.mp h
    obtain ⟨k, hk⟩ := (stripRev_eq_some _ _).mp ht
    refine ⟨k, ?_⟩
    have := congrArg List.reverse hk
    simpa [List.reverse_append, List.reverse_replicate] using this
  · rintro ⟨k, rfl⟩
    simp [List.reverse_append, List.reverse_replicate, stripRev_zeros]

/-- **The one difference from upstream**: input with no terminator (empty, or only zeros) is
refused, where upstream hands it back as the message. -/
theorem unpad_upstream_differs (d : List Nat) (h : ∀ x ∈ d, x = 0) : unpad d = none ∧ unpadUpstream d = some d := by
  constructor
  · cases hu : unpad d with
    | none => rfl
    | some m =>
      obtain ⟨k, rfl⟩ := (unpad_eq_some _ _).mp hu
      exact absurd (h 0x80 (by simp)) (by decide)
  · have : d.all (· == 0) = true := by simpa using h
    simp only [unpadUpstream, this, ↓reduceIte]

/-- On every other input, `unpad` and upstream agree. -/
theorem unpad_upstream_same (d : List Nat) (h : ¬ ∀ x ∈ d, x = 0) : unpad d = unpadUpstream d := by
  simp only [unpadUpstream]
  split
  · rename_i hall; exact absurd (by simpa using hall) h
  · rfl

/-! ## Key separation -/

/-- Reads decimal back. -/
def undec (l : List Nat) : Nat := l.foldl (fun acc c => acc * 10 + (c - 48)) 0

theorem undec_dec (n : Nat) : undec (dec n) = n := by
  induction n using Nat.strongRecOn with
  | ind n ih =>
    rw [dec]
    split
    · simp [undec]
    · have := ih (n / 10) (by omega)
      simp only [undec, List.foldl_append, List.foldl_cons, List.foldl_nil] at this ⊢
      rw [this]; omega

/-- Different versions have different decimal forms. -/
theorem dec_inj {m n : Nat} (h : dec m = dec n) : m = n := by
  have := congrArg undec h; rwa [undec_dec, undec_dec] at this

/-- The value of a base64 character. -/
def b64val (c : Nat) : Nat :=
  if 65 ≤ c ∧ c ≤ 90 then c - 65 else if 97 ≤ c ∧ c ≤ 122 then c - 71 else if 48 ≤ c ∧ c ≤ 57 then c + 4 else if c = 43 then 62 else 63

theorem b64val_char (n : Nat) (h : n < 64) : b64val (b64char n) = n := by
  unfold b64char b64val
  repeat (first | omega | split)

theorem b64char_ne (n : Nat) : b64char n ≠ 61 := by
  unfold b64char; repeat (first | omega | split)

/-- Reads base64 back. -/
def unb64 : List Nat → List Nat
  | w :: x :: y :: z :: rest =>
    if z = 61 ∧ rest = [] then
      if y = 61 then [b64val w * 4 + b64val x / 16]
      else [b64val w * 4 + b64val x / 16, b64val x % 16 * 16 + b64val y / 4]
    else (b64val w * 4 + b64val x / 16) :: (b64val x % 16 * 16 + b64val y / 4) :: (b64val y % 4 * 64 + b64val z) :: unb64 rest
  | _ => []

theorem unb64_b64 (l : List Nat) (h : Bytes l) : unb64 (b64 l) = l := by
  induction l using b64.induct with
  | case1 => simp [b64, unb64]
  | case2 a =>
    have ha := h a (by simp)
    simp only [b64, unb64, b64val_char _ (show a / 4 < 64 by omega), b64val_char _ (show a % 4 * 16 < 64 by omega)]
    simp; omega
  | case3 a b =>
    have ha := h a (by simp); have hb := h b (by simp)
    simp only [b64, unb64, b64val_char _ (show a / 4 < 64 by omega), b64val_char _ (show a % 4 * 16 + b / 16 < 64 by omega),
      b64val_char _ (show b % 16 * 4 < 64 by omega), b64char_ne]
    simp; omega
  | case4 a b c rest ih =>
    have ha := h a (by simp); have hb := h b (by simp); have hc := h c (by simp)
    have hr : Bytes rest := fun x hx => h x (by simp [hx])
    simp only [b64, unb64, b64val_char _ (show a / 4 < 64 by omega), b64val_char _ (show a % 4 * 16 + b / 16 < 64 by omega),
      b64val_char _ (show b % 16 * 4 + c / 64 < 64 by omega), b64val_char _ (show c % 64 < 64 by omega), b64char_ne, ih hr]
    simp; omega

/-- Different byte strings have different base64 forms. -/
theorem b64_inj {l l' : List Nat} (h : Bytes l) (h' : Bytes l') (e : b64 l = b64 l') : l = l' := by
  have := congrArg unb64 e; rwa [unb64_b64 _ h, unb64_b64 _ h'] at this

theorem manifest_ne_item (a b : List Nat) : ascii "Manifest_" ++ a ≠ ascii "Item_" ++ b := by
  have h1 : ascii "Manifest_" = 77 :: ascii "anifest_" := by decide
  have h2 : ascii "Item_" = 73 :: ascii "tem_" := by decide
  rw [h1, h2]; simp

theorem stripZeros_zeros : stripZeros (zeros 32) = [] := by decide
theorem stripZeros_nil : stripZeros [] = [] := rfl

/-- **Key separation**: no two uses (purposes and parameters) put the same input through the
same primitive keyed by the same source, even counting HKDF salts that differ only in trailing
zeros as one, and ignoring HKDF's output length. -/
theorem separated (u u' : Use) (hu : u.WF) (hu' : u'.WF) (h : (derivation u).canonical = (derivation u').canonical) : u = u' := by
  cases u <;> cases u' <;> simp only [derivation, Derivation.canonical, Canonical.mk.injEq, stripZeros_zeros, stripZeros_nil,
      reduceCtorEq, false_and, and_false] at h <;>
    simp only [Use.WF] at hu hu' <;> (try rfl)
  all_goals obtain ⟨-, -, -, h⟩ := h
  all_goals first
    | exact absurd h (manifest_ne_item _ _)
    | exact absurd h.symm (manifest_ne_item _ _)
    | exact absurd h (by decide)
    | rw [h]
    | (have e := List.append_cancel_left h; first | rw [dec_inj e] | rw [b64_inj hu hu' e] | rw [e])

/-- **Keys with the same material are the same key**: the same secret and the same use. -/
theorem key_binds {k k' : Key} (hk : k.WF) (hk' : k'.WF) (h : k.material = k'.material) : k = k' := by
  cases k <;> cases k' <;> simp only [Key.material, Material.derived.injEq, Material.profile.injEq, reduceCtorEq] at h
  · obtain ⟨rfl, h⟩ := h; rw [separated _ _ hk hk' h]
  · rw [h]

/-! ## Profile padding -/

/-- In a sorted list, the first length that fits is the smallest that fits. -/
theorem bucket_least (L : List Nat) (hs : L.Pairwise (· < ·)) (n b : Nat) (h : bucket L n = some b) :
    b ∈ L ∧ n ≤ b ∧ ∀ b' ∈ L, n ≤ b' → b ≤ b' := by
  induction L with
  | nil => simp [bucket] at h
  | cons x t ih =>
    simp only [bucket, List.find?_cons] at h
    obtain ⟨hx, ht⟩ := List.pairwise_cons.mp hs
    by_cases hn : n ≤ x
    · simp only [hn, decide_true] at h
      cases h
      refine ⟨by simp, hn, fun b' hb' _ => ?_⟩
      rcases List.mem_cons.mp hb' with rfl | hb'
      · omega
      · exact Nat.le_of_lt (hx b' hb')
    · simp only [hn, decide_false] at h
      obtain ⟨h1, h2, h3⟩ := ih ht h
      refine ⟨List.mem_cons_of_mem _ h1, h2, fun b' hb' hnb => ?_⟩
      rcases List.mem_cons.mp hb' with rfl | hb'
      · omega
      · exact h3 b' hb' hnb

theorem lengths_sorted (f : Field) : f.lengths.Pairwise (· < ·) := by cases f <;> decide

/-- **The padded length is the bucket**, so a ciphertext shows only which length was used; the
item comes first, then zeros. -/
theorem padTo_length (L item p : List Nat) (h : padTo L item = some p) :
    bucket L item.length = some p.length ∧ item.length ≤ p.length ∧ p = item ++ List.replicate (p.length - item.length) 0 := by
  simp only [padTo] at h
  obtain ⟨b, hb, rfl⟩ := Option.map_eq_some_iff.mp h
  have hle : item.length ≤ b := by
    have := List.find?_some hb; simpa using this
  simp only [List.length_append, List.length_replicate]
  refine ⟨by rw [hb]; congr 1; omega, by omega, by congr 2; omega⟩

/-- An item is refused exactly when no length fits. -/
theorem padTo_none (L item : List Nat) : padTo L item = none ↔ ∀ b ∈ L, b < item.length := by
  simp only [padTo, bucket, Option.map_eq_none_iff, List.find?_eq_none, decide_eq_true_eq]
  constructor <;> intro h b hb <;> have := h b hb <;> omega

theorem untilNUL_append_zero (g r : List Nat) (hg : 0 ∉ g) : untilNUL (g ++ 0 :: r) = g := by
  induction g with
  | nil => simp [untilNUL]
  | cons x t ih =>
    have hx : x ≠ 0 := fun e => hg (by simp [e])
    have ht : 0 ∉ t := fun e => hg (by simp [e])
    simp [untilNUL, hx] at ih ⊢; exact ih ht

theorem untilNUL_no_zero (g : List Nat) (hg : 0 ∉ g) : untilNUL g = g := by
  induction g with
  | nil => rfl
  | cons x t ih =>
    have hx : x ≠ 0 := fun e => hg (by simp [e])
    have ht : 0 ∉ t := fun e => hg (by simp [e])
    simp [untilNUL, hx] at ih ⊢; exact ih ht

theorem untilNUL_zeros (k : Nat) : untilNUL (List.replicate k 0) = [] := by
  cases k <;> simp [untilNUL, List.replicate_succ]

theorem untilNUL_append_zeros (g : List Nat) (k : Nat) (hg : 0 ∉ g) : untilNUL (g ++ List.replicate k 0) = g := by
  cases k with
  | zero => simpa using untilNUL_no_zero g hg
  | succ k => rw [List.replicate_succ]; exact untilNUL_append_zero g _ hg

/-- **A name reads back as written**, if neither part has a NUL. -/
theorem name_roundtrip (g f p : List Nat) (hg : 0 ∉ g) (hf : 0 ∉ f) (h : padTo Field.name.lengths (nameBytes g f) = some p) :
    decodeName p = (g, f) := by
  obtain ⟨-, -, hp⟩ := padTo_length _ _ _ h
  generalize p.length - (nameBytes g f).length = k at hp
  subst hp
  by_cases hfe : f = []
  · subst hfe
    simp only [nameBytes, ite_true, decodeName, untilNUL_append_zeros g k hg]
    simp only [List.drop_append, List.drop_eq_nil_of_le (show g.length ≤ g.length + 1 by omega), List.nil_append]
    simp only [List.drop_replicate, untilNUL_zeros]
  · simp only [nameBytes, hfe, ite_false, decodeName, List.append_assoc, List.cons_append, untilNUL_append_zero g _ hg]
    simp only [List.drop_append, List.drop_eq_nil_of_le (show g.length ≤ g.length + 1 by omega), List.nil_append,
      Nat.add_sub_cancel_left]
    simp [untilNUL_append_zeros f k hf]

/-- So does an about text or emoji without a NUL. -/
theorem string_roundtrip (L s p : List Nat) (hs : 0 ∉ s) (h : padTo L s = some p) : decodeString p = s := by
  obtain ⟨-, -, hp⟩ := padTo_length _ _ _ h
  rw [hp]; exact untilNUL_append_zeros s _ hs

/-- A NUL inside a given name splits it: the rest reads as a family name. -/
theorem name_nul_splits : ∃ g p, padTo Field.name.lengths (nameBytes g []) = some p ∧ decodeName p = ([65], [66]) ∧ g = [65, 0, 66] :=
  ⟨[65, 0, 66], _, rfl, by decide, rfl⟩

/-! ## Encrypted formats -/

/-- What opens was sealed under a key with the same material, and is what was sealed. -/
theorem opens_some {C : Type} {k : Key} {o : Origin C} {c : C} (h : opens k o = some c) :
    ∃ k', o = .sealed k' c ∧ k'.material = k.material := by
  cases o with
  | sealed k' c' =>
    simp only [opens] at h
    split at h
    · cases h; exact ⟨k', rfl, by assumption⟩
    · simp at h
  | other => simp [opens] at h

theorem sealed_binds {C : Type} {k k' : Key} {o : Origin C} {c c' : C} (h : o = .sealed k c) (h' : o = .sealed k' c')
    (hm : k'.material = k₀.material) (hk : k.WF) (hk₀ : k₀.WF) : k = k₀ := by
  rw [h] at h'; injection h' with e _; subst e; exact key_binds hk hk₀ hm

/-- **An accepted manifest** was sealed under a key with the material of the manifest key for the
version the server named, its record parses and names that version, and it is newer than ours. -/
theorem manifest_ok (c : ManifestCase) (v : Nat) (h : verifyManifest c = .ok v) :
    v = c.version ∧ fresh c.current c.version = true ∧
    ∃ k m, c.origin = .sealed k m ∧ k.material = (manifestKey c.storage c.version).material ∧ m.parses = true ∧ m.inner = c.version := by
  unfold verifyManifest at h
  split at h
  · simp at h
  · rename_i m hm
    obtain ⟨k, ho, hk⟩ := opens_some hm
    split at h
    · simp at h
    split at h
    · simp at h
    split at h
    · simp at h
    cases h
    refine ⟨rfl, by simp_all, k, m, ho, hk, by simp_all, by simp_all⟩

/-- **The server cannot pass one ciphertext off as another**: whatever an accepted manifest was
sealed under is our storage key's manifest key for exactly that version: not another version's,
not a storage record's, not any other key's. -/
theorem manifest_bound (c : ManifestCase) (v : Nat) (h : verifyManifest c = .ok v) (k : Key) (m : ManifestContent)
    (ho : c.origin = .sealed k m) (hk : k.WF) : k = manifestKey c.storage c.version := by
  obtain ⟨-, -, k', m', ho', hm, -⟩ := manifest_ok c v h
  exact sealed_binds ho ho' hm hk (by simp [manifestKey, Key.WF, Use.WF])

theorem decryptItems_ok (s : Nat) (ikm : Option Nat) (items : List (List Nat × Origin RecordContent)) (ids : List (List Nat))
    (h : decryptItems s ikm items = .ok ids) :
    ids = items.map (·.1) ∧ ∀ i ∈ items, ∃ k r, i.2 = .sealed k r ∧ k.material = (itemKey s ikm i.1).material ∧ r.parses = true := by
  induction items generalizing ids with
  | nil => simp only [decryptItems, Except.ok.injEq] at h; simp [h]
  | cons i rest ih =>
    obtain ⟨raw, o⟩ := i
    simp only [decryptItems] at h
    split at h
    · simp at h
    · rename_i r hr
      split at h
      · simp at h
      · rename_i hp
        cases hd : decryptItems s ikm rest with
        | error e => rw [hd] at h; cases h
        | ok ids' =>
          rw [hd] at h
          injection h with h
          obtain ⟨ih1, ih2⟩ := ih ids' hd
          obtain ⟨k, ho, hk⟩ := opens_some hr
          refine ⟨by rw [← h, ih1]; rfl, ?_⟩
          intro i hi
          rcases List.mem_cons.mp hi with rfl | hi
          · exact ⟨k, r, ho, hk, by simpa using hp⟩
          · exact ih2 i hi

/-- **Accepted records**: every item was asked for, and each was sealed under a key with the
material of its own id's item key and parses. -/
theorem items_ok (c : ItemsCase) (ids : List (List Nat)) (n : Nat) (h : verifyItems c = .ok (ids, n)) :
    ids = c.items.map (·.1) ∧ ∀ i ∈ c.items, i.1 ∈ c.requested ∧
      ∃ k r, i.2 = .sealed k r ∧ k.material = (itemKey c.storage c.ikm i.1).material ∧ r.parses = true := by
  unfold verifyItems at h
  split at h
  · cases h
  · rename_i hall
    cases hd : decryptItems c.storage c.ikm c.items with
    | error e => rw [hd] at h; cases h
    | ok ids' =>
      rw [hd] at h
      injection h with h
      injection h with h1 _
      obtain ⟨d1, d2⟩ := decryptItems_ok _ _ _ _ hd
      have hall' : ∀ x y, (x, y) ∈ c.items → x ∈ c.requested := by simpa using hall
      refine ⟨h1 ▸ d1, fun i hi => ⟨?_, d2 i hi⟩⟩
      obtain ⟨a, b⟩ := i
      exact hall' a b hi

theorem itemKey_wf (s : Nat) (ikm : Option Nat) (raw : List Nat) (h : Bytes raw) : (itemKey s ikm raw).WF := by
  cases ikm <;> simp [itemKey, Key.WF, Use.WF, h]

/-- **A record is bound to its id**: what it was sealed under is the item key for exactly that id
(from the manifest's record IKM, or our storage key): not another record's value, not a manifest. -/
theorem items_bound (c : ItemsCase) (ids : List (List Nat)) (n : Nat) (h : verifyItems c = .ok (ids, n))
    (i : List Nat × Origin RecordContent) (hi : i ∈ c.items) (hb : Bytes i.1) (k : Key) (r : RecordContent)
    (ho : i.2 = .sealed k r) (hk : k.WF) : i.1 ∈ c.requested ∧ k = itemKey c.storage c.ikm i.1 := by
  obtain ⟨-, h2⟩ := items_ok c ids n h
  obtain ⟨hreq, k', r', ho', hm, -⟩ := h2 i hi
  exact ⟨hreq, sealed_binds ho ho' hm hk (itemKey_wf _ _ _ hb)⟩

theorem profile_material {k : Key} {p : Nat} (h : k.material = (Key.profile p).material) : k = .profile p := by
  cases k <;> simp_all [Key.material]

/-- **An accepted profile field** was sealed under the contact's profile key, and is its plaintext
read as the field asked for. -/
theorem profile_ok (c : ProfileCase) (v : ProfileValue) (h : decryptProfile c = .ok v) :
    29 ≤ c.len ∧ ∃ p, c.origin = .sealed (.profile c.key) p ∧ v = readField c.field p.plain := by
  unfold decryptProfile at h
  split at h
  · cases h
  · split at h
    · cases h
    · rename_i p hp
      obtain ⟨k, ho, hk⟩ := opens_some hp
      cases h
      exact ⟨by omega, p, profile_material hk ▸ ho, rfl⟩

/-- Fields are not bound to their kind: one served as another (here an about text read as the
name) decrypts. -/
theorem profile_field_unbound : ∃ c v, decryptProfile c = .ok v ∧ ∃ p, c.origin = .sealed (.profile c.key) p ∧ p.field ≠ c.field :=
  ⟨⟨0, .name, 100, .sealed (.profile 0) ⟨.about, [65]⟩⟩, .name [65] [], rfl, ⟨.about, [65]⟩, rfl, by decide⟩

/-- **An accepted sticker** was sealed under a key with the material of the pack key's derived keys,
and its padding was valid. -/
theorem sticker_ok (c : StickerCase) (n : Nat) (h : decryptSticker c = .ok n) :
    48 ≤ c.len ∧ ∃ k s, c.origin = .sealed k s ∧ k.material = (stickerKeys c.pack).material ∧ s.plain = some n := by
  unfold decryptSticker at h
  split at h
  · cases h
  · split at h
    · cases h
    · rename_i s hs
      obtain ⟨k, ho, hk⟩ := opens_some hs
      split at h
      · cases h
      · rename_i n' hn; cases h; exact ⟨by omega, k, s, ho, hk, hn⟩

/-- Under exactly this pack's keys. -/
theorem sticker_bound (c : StickerCase) (n : Nat) (h : decryptSticker c = .ok n) (k : Key) (s : StickerContent)
    (ho : c.origin = .sealed k s) (hk : k.WF) : k = stickerKeys c.pack := by
  obtain ⟨-, k', s', ho', hm, -⟩ := sticker_ok c n h
  exact sealed_binds ho ho' hm hk (by simp [stickerKeys, Key.WF, Use.WF])

/-- No padding oracle: whatever was not sealed under the pack's keys gets an answer that depends
on its length alone; AES and its padding are never reached. -/
theorem sticker_mac_first (c : StickerCase) (h : opens (stickerKeys c.pack) c.origin = none) :
    decryptSticker c = .error (if c.len < 48 then .tooShort else .badMAC) := by
  unfold decryptSticker; split <;> simp_all

/-- **An accepted provisioning envelope** passed every check before the tag and was sealed under a
key with the material of the keys for our provisioning key and its ephemeral key. -/
theorem provision_ok (c : ProvisionCase) (h : decryptProvision c = .ok ()) :
    provisionShape c = none ∧ ∃ k p, c.origin = .sealed k p ∧ k.material = (provisioningKeys c.ours c.eph).material ∧ p.plain = some true := by
  unfold decryptProvision at h
  split at h
  · cases h
  · rename_i hs
    split at h
    · cases h
    · rename_i p hp
      obtain ⟨k, ho, hk⟩ := opens_some hp
      split at h
      · cases h
      · cases h
      · rename_i hpl; exact ⟨hs, k, p, ho, hk, hpl⟩

/-- Under exactly those keys: someone made it with our provisioning public key. -/
theorem provision_bound (c : ProvisionCase) (h : decryptProvision c = .ok ()) (k : Key) (p : ProvisionContent)
    (ho : c.origin = .sealed k p) (hk : k.WF) : k = provisioningKeys c.ours c.eph := by
  obtain ⟨-, k', p', ho', hm, -⟩ := provision_ok c h
  exact sealed_binds ho ho' hm hk (by simp [provisioningKeys, Key.WF, Use.WF])

/-- No padding oracle: an envelope not sealed for our key and its ephemeral key gets the verdict of
the checks before the tag, or `badMAC`; AES and its padding are never reached. -/
theorem provision_mac_first (c : ProvisionCase) (h : opens (provisioningKeys c.ours c.eph) c.origin = none) :
    decryptProvision c = .error ((provisionShape c).getD .badMAC) := by
  unfold decryptProvision; split <;> simp_all

/-- **An accepted device name** was sealed under a key with the material of the key for our
identity key and its ephemeral key. -/
theorem deviceName_ok (c : DeviceNameCase) (p : List Nat) (h : decryptDeviceName c = .ok p) :
    ∃ k d, c.origin = .sealed k d ∧ k.material = (deviceNameKey c.identity c.eph).material ∧ d.plain = p := by
  unfold decryptDeviceName at h
  split at h
  · cases h
  · split at h
    · cases h
    · split at h
      · cases h
      · split at h
        · cases h
        · rename_i d hd
          obtain ⟨k, ho, hk⟩ := opens_some hd
          cases h; exact ⟨k, d, ho, hk, rfl⟩

/-- Under exactly that key. -/
theorem deviceName_bound (c : DeviceNameCase) (p : List Nat) (h : decryptDeviceName c = .ok p) (k : Key) (d : DeviceNameContent)
    (ho : c.origin = .sealed k d) (hk : k.WF) : k = deviceNameKey c.identity c.eph := by
  obtain ⟨k', d', ho', hm, -⟩ := deviceName_ok c p h
  exact sealed_binds ho ho' hm hk (by simp [deviceNameKey, Key.WF, Use.WF])

/-- Anyone can make a device name we accept: it is encrypted to our public identity key. -/
theorem deviceName_unauthenticated : ∃ c p, decryptDeviceName c = .ok p ∧
    ∃ d, c.origin = .sealed (deviceNameKey c.identity c.eph) d ∧ d.author = .someoneElse :=
  ⟨⟨true, true, true, 0, 1, .sealed (deviceNameKey 0 1) ⟨.someoneElse, [65]⟩⟩, [65], rfl, ⟨.someoneElse, [65]⟩, rfl, rfl⟩

end Crypto
