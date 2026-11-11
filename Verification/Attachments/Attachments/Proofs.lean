import Attachments.Model
import Attachments.Props

/-!
# The proofs

1. Decryption: a plaintext comes out only if the keys and the blob's shape are right, the tag
   verifies, the incremental MAC (if any) is valid, and the integrity source (a non-empty digest
   of the blob, or the plaintext's hash) matches; it is no longer than the pointer's size nor
   than what the blob holds. By the contracts, that means the upload's own blob.
2. Every reachable state: consumers got only the named uploads' plaintexts; paths exactly for
   published attachments, to files written from verified responses; bounded downloads.
-/

namespace Attachments

/-! ## 1. Decryption -/

theorem decrypt_ok (b : Blob) (n : Nat) (h : decrypt b = .ok n) :
    b.keyOK = true ∧ shapeOK b.len = true ∧ b.macOK = true ∧ (b.inc = .none ∨ b.inc = .ok) ∧
    (b.integrity = .macOnly ∨ b.integrity = .hash true ∨ b.integrity = .digest false true) ∧ n ≤ b.size ∧ ∃ p, b.plain = some p ∧ n ≤ p := by
  unfold decrypt at h
  by_cases h1 : b.keyOK = true <;> simp only [h1, Bool.not_true, Bool.not_false, ite_true, ite_false, reduceCtorEq] at h
  by_cases h2 : shapeOK b.len = true <;> simp only [h2, Bool.not_true, Bool.not_false, ite_true, ite_false, reduceCtorEq] at h
  by_cases h3 : b.macOK = true <;> simp only [h3, Bool.not_true, Bool.not_false, ite_true, ite_false, reduceCtorEq] at h
  have h4 : b.inc = .none ∨ b.inc = .ok := by
    cases hi : b.inc <;> simp_all
  have h4' : (b.inc == .bad || b.inc == .huge) = false := by rcases h4 with h4 | h4 <;> simp [h4]
  simp only [h4', Bool.false_eq_true, ite_false] at h
  refine ⟨h1, h2, h3, h4, ?_⟩
  cases hp : b.plain with
  | none => rw [hp] at h; simp at h
  | some p =>
    rw [hp] at h
    simp only at h
    cases hg : b.integrity with
    | digest e m =>
      rw [hg] at h
      cases e <;> cases m <;> simp at h
      subst h
      exact ⟨.inr (.inr rfl), Nat.min_le_left _ _, p, rfl, Nat.min_le_right _ _⟩
    | hash m =>
      rw [hg] at h
      cases m <;> simp at h
      subst h
      exact ⟨.inr (.inl rfl), Nat.min_le_left _ _, p, rfl, Nat.min_le_right _ _⟩
    | macOnly =>
      rw [hg] at h
      simp at h
      subst h
      exact ⟨.inl rfl, Nat.min_le_left _ _, p, rfl, Nat.min_le_right _ _⟩

/-- **By the contracts, a response passes only if it is the named upload's own blob**, and the
pointer had a digest or a plaintext hash. -/
theorem describe_ok (a : Att) (r : Resp) (n : Nat) (h : decrypt (describe a r) = .ok n) :
    r.genuine = some a.upload ∧ (a.hasDigest = true ∨ a.hasHash = true) ∧ n ≤ a.size := by
  have ⟨_, _, hm, _, hi, hs, _⟩ := decrypt_ok _ n h
  simp only [describe] at hm hi hs
  refine ⟨by simpa using hm, ?_, hs⟩
  cases hd : a.hasDigest <;> cases hh : a.hasHash <;> simp_all

/-! ## 2. Reachable states -/

structure Inv (s : S) : Prop where
  ids : (s.atts.map (·.id)).Nodup
  paths : (s.files.map (·.path)).Nodup
  lt : ∀ f ∈ s.files, f.path < s.nextPath
  pub : Published s
  delivered : Delivered s
  fetched : Fetched s

theorem nodup_unique {α : Type} (key : α → Nat) : ∀ {l : List α}, (l.map key).Nodup → ∀ {x y : α}, x ∈ l → y ∈ l → key x = key y → x = y
  | [], _, _, _, hx, _, _ => absurd hx List.not_mem_nil
  | z :: zs, hnd, x, y, hx, hy, hk => by
    simp only [List.map_cons, List.nodup_cons] at hnd
    obtain ⟨hz, hzs⟩ := hnd
    rcases List.mem_cons.mp hx with h1 | h1 <;> rcases List.mem_cons.mp hy with h2 | h2
    · rw [h1, h2]
    · have : key y ∈ zs.map key := List.mem_map_of_mem h2
      rw [← hk, h1] at this
      exact absurd this hz
    · have : key x ∈ zs.map key := List.mem_map_of_mem h1
      rw [hk, h2] at this
      exact absurd this hz
    · exact nodup_unique key hzs h1 h2 hk

theorem mem_setAtt {atts : List Att} {id : Nat} {f : Att → Att} {x : Att} (h : x ∈ setAtt atts id f) :
    ∃ y ∈ atts, x = if y.id == id then f y else y := by
  simp only [setAtt, List.mem_map] at h
  obtain ⟨y, hy, he⟩ := h
  exact ⟨y, hy, he.symm⟩

theorem setAtt_ids (atts : List Att) (id : Nat) (f : Att → Att) (hf : ∀ y, (f y).id = y.id) :
    (setAtt atts id f).map (·.id) = atts.map (·.id) := by
  simp only [setAtt, List.map_map]
  congr 1
  funext y
  by_cases h : y.id = id <;> simp [h, hf]

/-- The attachment found for `id` is the one every other row with that id is. -/
theorem find_att {s : S} (h : Inv s) {id : Nat} {a : Att} (hf : s.atts.find? (·.id == id) = some a) :
    a ∈ s.atts ∧ a.id = id ∧ ∀ y ∈ s.atts, y.id = id → y = a := by
  have hm := List.mem_of_find?_eq_some hf
  have hi : a.id = id := by simpa using List.find?_some hf
  exact ⟨hm, hi, fun y hy hyi => nodup_unique (·.id) h.ids hy hm (hyi.trans hi.symm)⟩

/-- Changing attachment `id` (found as `a`) to `f a`, keeping its id, and adding `files`/`fetched`. -/
theorem update_inv (s : S) (h : Inv s) (id : Nat) (a : Att) (hf : s.atts.find? (·.id == id) = some a) (g : Att → Att)
    (hg : ∀ y, (g y).id = y.id ∧ (g y).upload = y.upload ∧ (g y).size = y.size ∧ (g y).bucket = y.bucket)
    (newFiles : List File) (newFetched : List (Nat × Nat)) (np : Nat)
    (hlt : ∀ f ∈ s.files ++ newFiles, f.path < np) (hpaths : ((s.files ++ newFiles).map (·.path)).Nodup)
    (hga : ((g a).path.isSome = true ↔ (g a).st = .published) ∧
           ∀ p, (g a).path = some p → ∃ f ∈ s.files ++ newFiles, f.path = p ∧ f.content = some a.upload ∧ f.len ≤ a.size)
    (hfetch : ∀ x ∈ newFetched, x.1 = id ∧ x.2 ≤ ciphertextSize a.bucket + margin + 1 ∧ a.size ≤ s.maxSize) :
    Inv { s with atts := setAtt s.atts id g, files := s.files ++ newFiles, nextPath := np, fetched := s.fetched ++ newFetched } := by
  have ⟨ha, hai, huniq⟩ := find_att h hf
  have hrow : ∀ x ∈ setAtt s.atts id g, (x ∈ s.atts ∧ x.id ≠ id) ∨ x = g a := by
    intro x hx
    obtain ⟨y, hy, he⟩ := mem_setAtt hx
    by_cases hyi : y.id = id
    · rw [huniq y hy hyi] at he
      simp [hai] at he
      exact .inr he
    · have : (y.id == id) = false := by simpa using hyi
      rw [this] at he
      simp at he
      subst he
      exact .inl ⟨hy, hyi⟩
  refine ⟨by rw [setAtt_ids _ _ _ (fun y => (hg y).1)]; exact h.ids, hpaths, hlt, ?_, ?_, ?_⟩
  · intro x hx
    rcases hrow x hx with ⟨hx0, _⟩ | rfl
    · have ⟨h1, h2⟩ := h.pub x hx0
      refine ⟨h1, fun p hp => ?_⟩
      obtain ⟨f, hf, hfp, hc, hl⟩ := h2 p hp
      exact ⟨f, List.mem_append_left _ hf, hfp, hc, hl⟩
    · have ⟨_, hu, hs, _⟩ := hg a
      refine ⟨hga.1, fun p hp => ?_⟩
      obtain ⟨f, hf, hfp, hc, hl⟩ := hga.2 p hp
      exact ⟨f, hf, hfp, by rw [hu]; exact hc, by rw [hs]; exact hl⟩
  · intro x hx
    obtain ⟨y, hy, hyi, hc, hl⟩ := h.delivered x hx
    by_cases hyid : y.id = id
    · have := huniq y hy hyid
      subst this
      have ⟨hi, hu, hs, _⟩ := hg y
      refine ⟨g y, ?_, by rw [hi]; exact hyi, by rw [hu]; exact hc, by rw [hs]; exact hl⟩
      simp only [setAtt, List.mem_map]
      exact ⟨y, hy, by simp [hai]⟩
    · refine ⟨y, ?_, hyi, hc, hl⟩
      simp only [setAtt, List.mem_map]
      exact ⟨y, hy, by simp [hyid]⟩
  · intro x hx
    simp only [List.mem_append] at hx
    rcases hx with hx | hx
    · obtain ⟨y, hy, hyi, hb, hm⟩ := h.fetched x hx
      by_cases hyid : y.id = id
      · have := huniq y hy hyid
        subst this
        have ⟨hi, _, hs, hp⟩ := hg y
        refine ⟨g y, ?_, by rw [hi]; exact hyi, by rw [hp]; exact hb, by rw [hs]; exact hm⟩
        simp only [setAtt, List.mem_map]
        exact ⟨y, hy, by simp [hai]⟩
      · refine ⟨y, ?_, hyi, hb, hm⟩
        simp only [setAtt, List.mem_map]
        exact ⟨y, hy, by simp [hyid]⟩
    · obtain ⟨hx1, hb, hm⟩ := hfetch x hx
      have ⟨hi, _, hs, hp⟩ := hg a
      refine ⟨g a, ?_, by rw [hi, hai, hx1], by rw [hp]; exact hb, by rw [hs]; exact hm⟩
      simp only [setAtt, List.mem_map]
      exact ⟨a, ha, by simp [hai]⟩

theorem download_inv (s : S) (id : Nat) (r : Resp) (h : Inv s) : Inv (download s id r) := by
  unfold download
  cases hf : s.atts.find? (·.id == id) with
  | none => exact h
  | some a =>
    have ⟨ha, _, _⟩ := find_att h hf
    have hpend : a.st = .pending → a.path = none := by
      intro hp
      cases hpa : a.path with
      | none => rfl
      | some p =>
        have := ((h.pub a ha).1).mp (by simp [hpa])
        rw [hp] at this; exact absurd this (by decide)
    simp only
    by_cases hst : (a.st != .pending) = true
    · simp only [hst, ite_true]; exact h
    simp only [hst, Bool.false_eq_true, ite_false]
    have hp0 : a.path = none := hpend (by simpa using hst)
    have hgs : ∀ st, ∀ y : Att, ({ y with st := st } : Att).id = y.id ∧ ({ y with st := st } : Att).upload = y.upload ∧
        ({ y with st := st } : Att).size = y.size ∧ ({ y with st := st } : Att).bucket = y.bucket := fun _ _ => ⟨rfl, rfl, rfl, rfl⟩
    have hnone : ∀ st, st ≠ .published → ((({ a with st := st } : Att).path.isSome = true ↔ ({ a with st := st } : Att).st = .published) ∧
        ∀ p, ({ a with st := st } : Att).path = some p → ∃ f ∈ s.files ++ [], f.path = p ∧ f.content = some a.upload ∧ f.len ≤ a.size) := by
      intro st hne
      refine ⟨by simp [hp0, hne], fun p hp => by simp [hp0] at hp⟩
    by_cases hbig : s.maxSize < a.size
    · simp only [hbig, ite_true]
      have := update_inv s h id a hf ({ · with st := .tooBig }) (hgs _) [] [] s.nextPath (by simpa using h.lt) (by simpa using h.paths)
        (hnone .tooBig (by decide)) (by simp)
      simpa using this
    simp only [hbig, ite_false]
    have hfetch : ∀ x ∈ [(id, min r.len (ciphertextSize a.bucket + margin + 1))], x.1 = id ∧ x.2 ≤ ciphertextSize a.bucket + margin + 1 ∧ a.size ≤ s.maxSize := by
      intro x hx
      simp at hx
      subst hx
      exact ⟨rfl, Nat.min_le_right _ _, by omega⟩
    by_cases hcap : ciphertextSize a.bucket + margin < r.len
    · simp only [hcap, ite_true]
      have := update_inv s h id a hf (fun x => x) (fun _ => ⟨rfl, rfl, rfl, rfl⟩) [] _ s.nextPath (by simpa using h.lt) (by simpa using h.paths)
        ⟨(h.pub a ha).1, fun p hp => by obtain ⟨f, hf', h1, h2, h3⟩ := (h.pub a ha).2 p hp; exact ⟨f, List.mem_append_left _ hf', h1, h2, h3⟩⟩ hfetch
      have hid : setAtt s.atts id (fun x => x) = s.atts := by simp [setAtt]
      simpa [hid] using this
    simp only [hcap, ite_false]
    cases hd : decrypt (describe a r) with
    | error e =>
      have := update_inv s h id a hf ({ · with st := .error }) (hgs _) [] _ s.nextPath (by simpa using h.lt) (by simpa using h.paths)
        (hnone .error (by decide)) hfetch
      simpa using this
    | ok n =>
      have ⟨hgen, _, hn⟩ := describe_ok a r n hd
      have hlt : ∀ f ∈ s.files ++ [(⟨s.nextPath, r.genuine, true, n⟩ : File)], f.path < s.nextPath + 1 := by
        intro f hf'
        simp only [List.mem_append, List.mem_singleton] at hf'
        rcases hf' with hf' | rfl
        · have := h.lt f hf'; omega
        · simp
      have hpaths : ((s.files ++ [(⟨s.nextPath, r.genuine, true, n⟩ : File)]).map (·.path)).Nodup := by
        simp only [List.map_append, List.map_cons, List.map_nil]
        rw [List.nodup_append]
        refine ⟨h.paths, by simp, ?_⟩
        intro x hx y hy
        simp at hy
        subst hy
        obtain ⟨f, hf', rfl⟩ := List.mem_map.mp hx
        have := h.lt f hf'
        omega
      have hga : ((({ a with st := .published, path := some s.nextPath } : Att).path.isSome = true ↔
            ({ a with st := .published, path := some s.nextPath } : Att).st = .published) ∧
          ∀ p, ({ a with st := .published, path := some s.nextPath } : Att).path = some p →
            ∃ f ∈ s.files ++ [(⟨s.nextPath, r.genuine, true, n⟩ : File)], f.path = p ∧ f.content = some a.upload ∧ f.len ≤ a.size) := by
        refine ⟨by simp, fun p hp => ?_⟩
        simp at hp
        subst hp
        exact ⟨⟨s.nextPath, r.genuine, true, n⟩, List.mem_append_right _ (List.mem_singleton_self _), rfl, hgen, hn⟩
      have := update_inv s h id a hf ({ · with st := .published, path := some s.nextPath }) (fun y => ⟨rfl, rfl, rfl, rfl⟩)
        [⟨s.nextPath, r.genuine, true, n⟩] _ (s.nextPath + 1) hlt hpaths hga hfetch
      simpa using this

theorem consume_inv (s : S) (id : Nat) (h : Inv s) : Inv (consume s id) := by
  unfold consume
  cases hf : s.atts.find? (·.id == id) with
  | none => exact h
  | some a =>
    have ⟨ha, hai, _⟩ := find_att h hf
    split
    · rename_i p heq
      cases hfi : s.files.find? (·.path == p) with
      | none => exact h
      | some f =>
        simp only
        by_cases hc : f.intact = true
        · simp only [hc, ite_true]
          have hfm := List.mem_of_find?_eq_some hfi
          have hfp : f.path = p := by simpa using List.find?_some hfi
          obtain ⟨f', hf', hfp', hc', hl'⟩ := (h.pub a ha).2 p (by cases heq; rfl)
          have : f = f' := nodup_unique (·.path) h.paths hfm hf' (hfp.trans hfp'.symm)
          subst this
          refine ⟨h.ids, h.paths, h.lt, h.pub, ?_, h.fetched⟩
          intro x hx
          simp only [List.mem_append, List.mem_singleton] at hx
          rcases hx with hx | rfl
          · exact h.delivered x hx
          · exact ⟨a, ha, hai, hc', hl'⟩
        · simp only [hc, Bool.false_eq_true, ite_false]; exact h
    · exact h

theorem step_inv (s : S) (e : Ev) (h : Inv s) : Inv (step s e) := by
  cases e with
  | arrive a =>
    simp only [step]
    by_cases hd : (s.atts.any (·.id == a.id)) = true
    · simp only [hd, ite_true]; exact h
    simp only [hd, Bool.false_eq_true, ite_false]
    have hnot : ∀ y ∈ s.atts, y.id ≠ a.id := by
      intro y hy hyi
      exact hd (List.any_eq_true.mpr ⟨y, hy, by simp [hyi]⟩)
    refine ⟨?_, h.paths, h.lt, ?_, ?_, ?_⟩
    · simp only [List.map_append, List.map_cons, List.map_nil]
      rw [List.nodup_append]
      refine ⟨h.ids, by simp, ?_⟩
      intro x hx y hy
      simp at hy
      subst hy
      obtain ⟨z, hz, rfl⟩ := List.mem_map.mp hx
      exact hnot z hz
    · intro x hx
      simp only [List.mem_append, List.mem_singleton] at hx
      rcases hx with hx | rfl
      · exact h.pub x hx
      · exact ⟨by simp, fun p hp => by simp at hp⟩
    · intro x hx
      obtain ⟨y, hy, h1, h2, h3⟩ := h.delivered x hx
      exact ⟨y, List.mem_append_left _ hy, h1, h2, h3⟩
    · intro x hx
      obtain ⟨y, hy, h1, h2, h3⟩ := h.fetched x hx
      exact ⟨y, List.mem_append_left _ hy, h1, h2, h3⟩
  | download id r => exact download_inv s id r h
  | consume id => exact consume_inv s id h
  | tamper p =>
    simp only [step]
    have hmap : (s.files.map fun f => if f.path == p then { f with intact := false } else f).map (·.path) = s.files.map (·.path) := by
      simp only [List.map_map]
      congr 1
      funext f
      by_cases hf : f.path = p <;> simp [hf]
    refine ⟨h.ids, by rw [hmap]; exact h.paths, ?_, ?_, h.delivered, h.fetched⟩
    · intro f hf
      obtain ⟨g, hg, he⟩ := List.mem_map.mp hf
      have := h.lt g hg
      by_cases hgp : g.path == p <;> simp [hgp] at he <;> rw [← he] <;> exact this
    · intro a ha
      have ⟨h1, h2⟩ := h.pub a ha
      refine ⟨h1, fun q hq => ?_⟩
      obtain ⟨f, hf, hfp, hc, hl⟩ := h2 q hq
      by_cases hfq : f.path == p
      · exact ⟨{ f with intact := false }, List.mem_map.mpr ⟨f, hf, by simp [hfq]⟩, hfp, hc, hl⟩
      · exact ⟨f, List.mem_map.mpr ⟨f, hf, by simp [hfq]⟩, hfp, hc, hl⟩

theorem reach_inv {m : Nat} {s : S} (h : Reach m s) : Inv s := by
  induction h with
  | init => exact ⟨by simp [S.init], by simp [S.init], by simp [S.init], by simp [Published, S.init], by simp [Delivered, S.init],
                   by simp [Fetched, S.init]⟩
  | step e _ ih => exact step_inv _ e ih

/-- **Only authentic bytes reach decoding or export.** -/
theorem delivered_holds {m : Nat} {s : S} (h : Reach m s) : Delivered s := (reach_inv h).delivered

/-- **Nothing partially validated is published.** -/
theorem published_holds {m : Nat} {s : S} (h : Reach m s) : Published s := (reach_inv h).pub

/-- **Malformed lengths cannot bypass the limits.** -/
theorem fetched_holds {m : Nat} {s : S} (h : Reach m s) : Fetched s := (reach_inv h).fetched

end Attachments
