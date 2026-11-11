import Modifiers.Model

/-! # Notation for the Swift rig

Numbers separated by spaces; lists comma-separated, `-` for none.

* World (8 fields): members, admins, open of group 10; the same of group 11; blocked accounts;
  blocked groups. We are account 0.
* Row (15): author sentAt conv server outgoing sentTo viewOnce voice poll terminated giftBadge
  pinned deleted erased rev.
* Mod (8): kind sender conv src author target ts server, with kind 0–7 (delete, adminDelete,
  edit, reaction, vote, terminate, pin, unpin) and src 0–2 (other, sync, here).
-/

namespace Modifiers

def nums (s : String) : List Nat := (s.splitOn ",").filterMap (·.toNat?)
def numsCode (xs : List Nat) : String := if xs.isEmpty then "-" else ",".intercalate (xs.map toString)
def b01 (b : Bool) : String := if b then "1" else "0"
def words (s : String) : List String := (s.splitOn " ").filter (!·.isEmpty)

def kindOf : Nat → Kind
  | 0 => .delete | 1 => .adminDelete | 2 => .edit | 3 => .reaction | 4 => .vote | 5 => .terminate | 6 => .pin | _ => .unpin
def kindCode : Kind → Nat
  | .delete => 0 | .adminDelete => 1 | .edit => 2 | .reaction => 3 | .vote => 4 | .terminate => 5 | .pin => 6 | .unpin => 7
def srcOf : Nat → Src
  | 0 => .other | 1 => .sync | _ => .here

def parseWorld (s : String) : Option World :=
  match words s with
  | [m10, a10, o10, m11, a11, o11, bl, bg] =>
    some { us := 0, groups := [⟨10, nums m10, nums a10, o10 == "1"⟩, ⟨11, nums m11, nums a11, o11 == "1"⟩],
           blocked := nums bl, blockedGroups := nums bg }
  | _ => none

def parseRow (xs : List String) : Option Row :=
  match xs with
  | [a, t, c, sv, o, st, vo, v, p, te, gb, pi, d, er, rv] => do
    pure { gen := 0, author := ← a.toNat?, sentAt := ← t.toNat?, conv := ← c.toNat?, server := ← sv.toNat?, outgoing := o == "1",
           sentTo := nums st, viewOnce := vo == "1", voice := v == "1", poll := p == "1", terminated := te == "1",
           giftBadge := gb == "1", pinned := pi == "1", deleted := d == "1", erased := er == "1", rev := ← rv.toNat?, revs := [] }
  | _ => none

def parseMod (xs : List String) : Option Mod :=
  match xs with
  | [k, s, c, sr, a, t, ts, sv] => do
    pure { kind := kindOf (← k.toNat?), sender := ← s.toNat?, conv := ← c.toNat?, src := srcOf (← sr.toNat?), author := ← a.toNat?,
           target := ← t.toNat?, ts := ← ts.toNat?, server := ← sv.toNat? }
  | _ => none

/-- `world | row | mod` → whether the modifier is accepted. -/
def decideAnswer (line : String) : Option String :=
  match line.splitOn " | " with
  | [w, r, m] => do
    let w ← parseWorld w
    let r ← parseRow (words r)
    let m ← parseMod (words m)
    pure (b01 (accepts w r m))
  | _ => none

/-- An event: `r author sentAt conv server outgoing sentTo viewOnce voice poll giftBadge`,
`m <mod>`, `f author sentAt`. -/
def parseEv (s : String) : Option Ev :=
  match words s with
  | "r" :: a :: t :: c :: sv :: o :: st :: vo :: v :: p :: gb :: [] =>
    (parseRow [a, t, c, sv, o, st, vo, v, p, "0", gb, "0", "0", "0", "0"]).map .recv
  | "m" :: rest => (parseMod rest).map .mod
  | ["f", a, t] => do pure (.forget (← a.toNat?) (← t.toNat?))
  | _ => none

def rowCode (r : Row) : String :=
  let revs := r.revs.mergeSort (· ≤ ·)
  s!"{r.author}:{r.sentAt}:{b01 r.deleted}:{r.rev}:{if revs.isEmpty then "-" else ".".intercalate (revs.map toString)}:{b01 r.pinned}:{b01 r.poll}:{b01 r.terminated}"

def stateCode (s : S) : String :=
  let rows := if s.rows.isEmpty then "-" else " ".intercalate (s.rows.map rowCode)
  let pending := if s.pending.isEmpty then "-" else " ".intercalate (s.pending.map fun e => s!"{kindCode e.mod.kind}:{e.mod.author}:{e.mod.target}")
  s!"{rows} | {pending}"

/-- `world | ev ; ev ; …` → the stored messages (in arrival order) and the waiting list. -/
def runAnswer (line : String) : Option String :=
  match line.splitOn " | " with
  | [w, evs] => do
    let w ← parseWorld w
    let evs ← ((evs.splitOn " ; ").filter (!·.isEmpty)).mapM parseEv
    let s := run w S.init evs
    if s.exhausted then none else pure (stateCode s)
  | _ => none

/-- `limit now | sender:storedAt … | sender:storedAt` → the indices of what is kept (the new
entry's index is the number of old ones). -/
def keptAnswer (line : String) : Option String :=
  match line.splitOn " | " with
  | [h, old, new] => do
    let (limit, now) ← match words h with
      | [l, n] => do pure (← l.toNat?, ← n.toNat?)
      | _ => none
    let entry (i : Nat) (x : String) : Option Entry := match x.splitOn ":" with
      | [s, t] => do pure ⟨{ (default : Mod) with sender := ← s.toNat?, target := i }, ← t.toNat?⟩
      | _ => none
    let olds := if old == "-" then [] else words old
    let es ← (olds.zip (List.range olds.length)).mapM fun (x, i) => entry i x
    let e ← entry es.length new
    pure (numsCode ((kept es e limit now).map (·.mod.target)))
  | _ => none

end Modifiers
