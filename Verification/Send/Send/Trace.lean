import Send.Model

/-! # Notation (shared with the Swift rig) -/

namespace Send

def b01 (b : Bool) : String := if b then "1" else "0"
def p01 : String → Option Bool | "1" => some true | "0" => some false | _ => none

def Data.code (d : Data) : String := s!"{b01 d.retract}.{b01 d.extra}"

/-- `data.R.X`, `sent.R.X.U.S.E` (R.X `-.-` without a message), `content`, `other`. -/
def Content.code : Content → String
  | .data d => s!"data.{d.code}"
  | .sent m u st ed => s!"sent.{match m with | some d => d.code | none => "-.-"}.{b01 u}.{b01 st}.{b01 ed}"
  | .content => "content"
  | .other => "other"

def Content.parse (parts : List String) : Option Content :=
  match parts with
  | ["data", r, x] => do pure (.data ⟨← p01 r, ← p01 x⟩)
  | ["sent", "-", "-", u, st, ed] => do pure (.sent none (← p01 u) (← p01 st) (← p01 ed))
  | ["sent", r, x, u, st, ed] => do pure (.sent (some ⟨← p01 r, ← p01 x⟩) (← p01 u) (← p01 st) (← p01 ed))
  | ["content"] => some .content
  | ["other"] => some .other
  | _ => none

def Target.code : Target → String | .direct p => s!"d{p}" | .self => "self" | .group g => s!"g{g}"
def Target.parse (t : String) : Option Target :=
  if t == "self" then some .self
  else if t.startsWith "d" then ((t.drop 1).toString.toNat?).map .direct
  else if t.startsWith "g" then ((t.drop 1).toString.toNat?).map .group
  else none

def nums (s : String) : List Nat := (s.splitOn ",").filterMap (·.toNat?)
def numsCode (xs : List Nat) : String := ",".intercalate (xs.map toString)

/-- A pipeline event: `queue.T.ids.CONTENT…` is written `queue:T:ids:content` (content with dots). -/
def Ev.code : Ev → String
  | .queue t c ids => s!"queue:{t.code}:{numsCode ids}:{c.code}"
  | .start j => s!"start:{j}"
  | .submit j => s!"submit:{j}"
  | .block p b => s!"block:{p}:{b01 b}"
  | .blockNumber p b => s!"blocknum:{p}:{b01 b}"
  | .blockGroup g b => s!"blockgroup:{g}:{b01 b}"
  | .erase m => s!"erase:{m}"
  | .remove m => s!"remove:{m}"

def Ev.parse (tok : String) : Option Ev :=
  match tok.splitOn ":" with
  | ["queue", t, ids, c] => do pure (.queue (← Target.parse t) (← Content.parse (c.splitOn ".")) (nums ids))
  | ["start", j] => j.toNat?.map .start
  | ["submit", j] => j.toNat?.map .submit
  | ["block", p, b] => do pure (.block (← p.toNat?) (← p01 b))
  | ["blocknum", p, b] => do pure (.blockNumber (← p.toNat?) (← p01 b))
  | ["blockgroup", g, b] => do pure (.blockGroup (← g.toNat?) (← p01 b))
  | ["erase", m] => m.toNat?.map .erase
  | ["remove", m] => m.toNat?.map .remove
  | _ => none

def Msg.code : Msg → String | .live => "L" | .erased => "E" | .gone => "G"
def Msg.parse : Char → Msg | 'E' => .erased | 'G' => .gone | _ => .live

/-- A decision case from the rig: `ids nums groups msgs members | target content named`. -/
def parseCase (line : String) : Option (S × Target × Content × List Nat) :=
  match line.splitOn " | " with
  | [st, q] =>
    match st.splitOn " ", q.splitOn " " with
    | [ids, ns, gs, ms, mem], [t, c, named] => do
      let msgs := ms.toList.map Msg.parse
      let s : S := ⟨nums ids, nums ns, nums gs, fun m => msgs.getD m .gone, fun _ => nums mem⟩
      pure (s, ← Target.parse t, ← Content.parse (c.splitOn "."), nums named)
    | _, _ => none
  | _ => none

end Send
