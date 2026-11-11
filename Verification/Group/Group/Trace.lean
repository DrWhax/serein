import Group.Model

/-! # Decisions for the Swift rig -/

namespace Group

/-- The submission check for a group payload (`MessageSender.authorization`): a group update
goes anywhere; anything else only to members. -/
def boundary (members addressed : List Nat) (update : Bool) : Bool := update || addressed.all members.contains

/-- `OutgoingPayload.isGroupUpdateOnly`, from the rig's reading of a DataMessage: it has a group
context, and nothing beyond it and the envelope fields. -/
def isUpdate (group extra : Bool) : Bool := group && !extra

def nums (s : String) : List Nat := (s.splitOn ",").filterMap (·.toNat?)
def numsCode (xs : List Nat) : String := if xs.isEmpty then "-" else ",".intercalate (xs.map toString)
def sortN (xs : List Nat) : List Nat := xs.eraseDups.mergeSort (· ≤ ·)
def pairs (s : String) : List (Nat × Nat) :=
  (s.splitOn ",").filterMap fun x => match x.splitOn ":" with
    | [a, b] => do pure (← a.toNat?, ← b.toNat?)
    | _ => none
def pairsCode (xs : List (Nat × Nat)) : String :=
  let xs := xs.eraseDups.mergeSort fun a b => a.1 < b.1 || (a.1 == b.1 && a.2 ≤ b.2)
  if xs.isEmpty then "-" else ",".intercalate (xs.map fun (a, b) => s!"{a}:{b}")
def b01 (b : Bool) : String := if b then "1" else "0"

/-- `members | recipients | update` → members, outside, dropped. -/
def planAnswer (line : String) : Option String :=
  match line.splitOn " | " with
  | [m, rs, u] =>
    let members := nums m
    let rs := nums rs
    let update := u == "1"
    let (inGroup, outside) := planOf members rs update
    let dropped := if update then [] else rs.filter (!members.contains ·)
    some s!"{numsCode (sortN inGroup)} {numsCode (sortN outside)} {numsCode (sortN dropped)}"
  | _ => none

/-- `distributed | current | targets` → reset, distribute. -/
def rotationAnswer (line : String) : Option String :=
  match line.splitOn " | " with
  | [d, c, t] => let (r, g) := rotation (pairs d) (pairs c) (nums t); some s!"{b01 r} {pairsCode g}"
  | _ => none

/-- `members | addressed | group extra` → allowed, update. -/
def authAnswer (line : String) : Option String :=
  match line.splitOn " | " with
  | [m, a, f] => match f.splitOn " " with
    | [g, x] => let u := isUpdate (g == "1") (x == "1"); some s!"{b01 (boundary (nums m) (nums a) u)} {b01 u}"
    | _ => none
  | _ => none

end Group
