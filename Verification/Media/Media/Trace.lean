import Media.Model

/-! # Notation for the Swift rigs -/

namespace Media

def b01 (b : Bool) : String := if b then "1" else "0"
def pairs (s : String) : List (Nat × Nat) :=
  (s.splitOn ",").filterMap fun x => match x.splitOn ":" with
    | [a, b] => do pure (← a.toNat?, ← b.toNat?)
    | _ => none
def pairsCode (xs : List (Nat × Nat)) : String :=
  if xs.isEmpty then "-" else ",".intercalate (xs.map fun (a, b) => s!"{a}:{b}")
def nums (s : String) : List Nat := (s.splitOn ",").filterMap (·.toNat?)
def numsCode (xs : List Nat) : String := if xs.isEmpty then "-" else ",".intercalate (xs.map toString)

/-- Rows: `L` (live), `E` (erased), `G` (gone), `X<t>` (expires at `t`), comma-separated. -/
def parseRows (s : String) : List (Option Row) :=
  (s.splitOn ",").map fun r =>
    if r == "L" then some ⟨false, none⟩ else if r == "E" then some ⟨true, none⟩
    else if r.startsWith "X" then some ⟨false, (r.drop 1).toString.toNat?⟩ else none

/-- `rows rel now` → the database. -/
def parseDb (line : String) : Option Db :=
  match line.splitOn " " with
  | [rs, rel, now] => do
    let rows := parseRows rs
    pure ⟨fun m => rows.getD m none, pairs rel, ← now.toNat?⟩
  | _ => none

def sortPairs (xs : List (Nat × Nat)) : List (Nat × Nat) :=
  (xs.eraseDups).mergeSort fun a b => a.1 < b.1 || (a.1 == b.1 && a.2 ≤ b.2)

/-- `permits` for messages 0..3 × paths 0..2, `permits` without a message for each path, and the
fetched references (sorted). -/
def dbAnswer (d : Db) : String :=
  let grid := String.join ((List.range 4).flatMap fun m => (List.range 3).map fun p => b01 (permits d m p))
  let any := String.join ((List.range 3).map fun p => b01 (permitsAny d p))
  s!"{grid} {any} {pairsCode (sortPairs (avail d))}"

/-- `avail | lightbox video audio cache` (lightbox `m:p.p…`). -/
def parseApply (line : String) : Option (List (Nat × Nat) × UI) :=
  match line.splitOn " | " with
  | [a, ui] => match ui.splitOn " " with
    | [lb, v, au, c] =>
      let lightbox := match lb.splitOn ":" with
        | [m, ps] => m.toNat?.map fun m => (m, (ps.splitOn ".").filterMap (·.toNat?))
        | _ => none
      some (pairs a, ⟨lightbox, (pairs v).head?, (pairs au).head?, nums c⟩)
    | _ => none
  | _ => none

def uiCode (u : UI) : String :=
  let lb := match u.lightbox with
    | some (m, ps) => s!"{m}:{".".intercalate (ps.map toString)}"
    | none => "-"
  s!"{lb} {pairsCode u.video.toList} {pairsCode u.audio.toList} {numsCode (u.cache.mergeSort (· ≤ ·))}"

end Media
