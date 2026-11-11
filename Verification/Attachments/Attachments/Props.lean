import Attachments.Model

/-!
# The properties

* **Only authentic bytes are consumed** (`Delivered`): everything a consumer (decoding, export,
  the thumbnail) was handed is the plaintext of the upload its attachment's pointer names, never a
  substituted, forged or changed blob, and no longer than the pointer's size.
* **Nothing partially validated is published** (`Published`): an attachment has a path exactly
  when it is published, and its file was written from a response that passed every check; a
  failed download publishes nothing.
* **Lengths cannot bypass the limits** (`Fetched`): a download holds at most the ciphertext size
  for the pointer's size plus the margin (and one byte), and only for an attachment within the
  incoming limit.
-/

namespace Attachments

def Delivered (s : S) : Prop :=
  ∀ x ∈ s.delivered, ∃ a ∈ s.atts, a.id = x.1 ∧ x.2.1 = some a.upload ∧ x.2.2 ≤ a.size

def Published (s : S) : Prop :=
  ∀ a ∈ s.atts, (a.path.isSome = true ↔ a.st = .published) ∧
    ∀ p, a.path = some p → ∃ f ∈ s.files, f.path = p ∧ f.content = some a.upload ∧ f.len ≤ a.size

def Fetched (s : S) : Prop :=
  ∀ x ∈ s.fetched, ∃ a ∈ s.atts, a.id = x.1 ∧ x.2 ≤ ciphertextSize a.bucket + margin + 1 ∧ a.size ≤ s.maxSize

/-! ## Checks of one state (the explorer) -/

def deliveredB (s : S) : Bool := s.delivered.all fun x => s.atts.any fun a => a.id == x.1 && x.2.1 == some a.upload && x.2.2 ≤ a.size

def publishedB (s : S) : Bool := s.atts.all fun a => (a.path.isSome == (a.st == .published)) && match a.path with
  | some p => s.files.any fun f => f.path == p && f.content == some a.upload && f.len ≤ a.size
  | none => true

def fetchedB (s : S) : Bool := s.fetched.all fun x => s.atts.any fun a => a.id == x.1 && x.2 ≤ ciphertextSize a.bucket + margin + 1 && a.size ≤ s.maxSize

def checks (s : S) : List (String × Bool) :=
  [("delivered-authentic", deliveredB s), ("published-validated", publishedB s), ("fetched-bounded", fetchedB s)]

end Attachments
