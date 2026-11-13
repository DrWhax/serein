import Group.Model

/-! # The properties -/

namespace Group

def newOut (s s' : S) : List (Nat × String) := s'.out.drop s.out.length

/-- **Removed members get no new sender key**: a key distribution goes only to an account that is
a member at that submission. -/
def keysToMembers (s : S) (_e : Ev) (s' : S) : Bool :=
  (newOut s s').all fun (a, k) => k != "key" || s.members.contains a

/-- **Removed members get no newly authorized content**: content goes only to accounts that are
members at that submission. -/
def contentToMembers (s : S) (_e : Ev) (s' : S) : Bool :=
  (newOut s s').all fun (a, k) => k != "content" || s.members.contains a

/-- **The key is recorded wherever it went**: every device holding our current key is recorded as
having it (so the rotation rule sees it). -/
def holdersRecorded (_s : S) (_e : Ev) (s' : S) : Bool :=
  s'.holders.all fun (a, d, g) => g != s'.epoch || s'.distributed.contains (a, d)

/-- **Rotation after a removal**: once a send has planned, every device recorded as having our
current key belongs to one of its targets — members at that moment. Submission safety is
checked separately by `contentKeySafe`, because other sends may distribute between these steps. -/
def rotated (s : S) (e : Ev) (s' : S) : Bool :=
  match e with
  | .plan k => match s.jobs[k]?, s'.jobs[k]? with
    | some _, some ⟨_, _, some (targets, _, _), _, _⟩ => s'.distributed.all fun d => targets.contains d.1 && s.members.contains d.1
    | _, _ => true
  | _ => true

/-- At content submission no non-member holds the generation used for encryption. -/
def contentKeySafe (s : S) (e : Ev) (s' : S) : Bool :=
  !(newOut s s').any (fun x => x.2 == "content") ||
    match e with
    | .submit k => match s.jobs[k]? with
      | some j => !s.stale && s.holders.all (fun h => h.2.2 != j.generation || s.members.contains h.1)
      | none => false
    | _ => false

def stepChecks : List (String × (S → Ev → S → Bool)) :=
  [("keys-to-members", keysToMembers), ("content-to-members", contentToMembers), ("holders-recorded", holdersRecorded),
   ("rotated", rotated), ("content-key-safe", contentKeySafe)]

end Group
