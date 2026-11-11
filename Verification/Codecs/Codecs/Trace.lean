import Codecs.Model

/-! # Notation for the Swift rig

Bytes in hex. Failures as `fail:<offset>:<kind>`.

* `grammar`: `<hex> | <grammar>` → `ok:<items>` or a failure, for `parseComplete`. Grammars are
  S-expressions: `u8 u16be u16le u24be u24le u32be u32le u64be rest`, `bytes:n`, `skip:n`,
  `expect:<hex>`, `(seq A B)`, `(region n A)`, `(len u8|u16be|u32be max A)`, `(rep count max A)`,
  `(end max A)`, `(or A B)`.
* `cursor`: `<hex> | start stop | op op …` (ops as the primitives) → each result (`num:v`,
  `slice:lo:hi`, `unit`, with `@pos`) up to the first failure.
* `boxes`: `<hex> | top count max` → `ok:<count>` and the boxes `type@offset:lo:hi`, or a failure.
* `bits`: `<hex> | fail|zero | op …` with `b:n`, `p:n`, `a` → each value with `@position`, up to the
  first failure.
-/

namespace Codecs

def words (s : String) : List String := (s.splitOn " ").filter (!·.isEmpty)

def hexVal (c : Char) : Option Nat :=
  if '0' ≤ c && c ≤ '9' then some (c.toNat - '0'.toNat)
  else if 'a' ≤ c && c ≤ 'f' then some (c.toNat - 'a'.toNat + 10) else none

def hexBytes (s : String) : Option (List Nat) :=
  let cs := s.toList
  if cs.length % 2 != 0 then none
  else (List.range (cs.length / 2)).mapM fun i => do pure ((← hexVal (cs.getD (2 * i) '0')) * 16 + (← hexVal (cs.getD (2 * i + 1) '0')))

def kindName : Kind → String
  | .unexpectedEnd => "end" | .mismatch => "mismatch" | .invalid => "invalid" | .limit => "limit" | .trailing => "trailing"

def failCode (e : Fail) : String := s!"fail:{e.offset}:{kindName e.kind}"

def parseInt (s : String) : Option Int :=
  if s.startsWith "-" then (s.drop 1).toString.toNat?.map fun n => -(n : Int) else s.toNat?.map fun n => (n : Int)

def parsePrim (s : String) : Option Prim :=
  match s.splitOn ":" with
  | ["u8"] => some .u8 | ["u16be"] => some .u16be | ["u16le"] => some .u16le | ["u24be"] => some .u24be
  | ["u24le"] => some .u24le | ["u32be"] => some .u32be | ["u32le"] => some .u32le | ["u64be"] => some .u64be
  | ["rest"] => some .rest
  | ["bytes", n] => (parseInt n).map .bytes
  | ["skip", n] => (parseInt n).map .skip
  | ["expect", h] => (hexBytes h).map .expect
  | _ => none

def tokens (s : String) : List String := words ((s.replace "(" " ( ").replace ")" " ) ")

/-- A grammar from tokens; the rest. -/
def parseG : Nat → List String → Option (G × List String)
  | 0, _ => none
  | fuel + 1, "(" :: op :: rest => do
    match op with
    | "seq" =>
      let (a, rest) ← parseG fuel rest
      let (b, rest) ← parseG fuel rest
      match rest with | ")" :: rest => pure (.seq a b, rest) | _ => none
    | "or" =>
      let (a, rest) ← parseG fuel rest
      let (b, rest) ← parseG fuel rest
      match rest with | ")" :: rest => pure (.oneOf a b, rest) | _ => none
    | "region" =>
      match rest with
      | n :: rest =>
        let (a, rest) ← parseG fuel rest
        match rest with | ")" :: rest => pure (.region (← parseInt n) a, rest) | _ => none
      | _ => none
    | "len" =>
      match rest with
      | w :: m :: rest =>
        let (a, rest) ← parseG fuel rest
        match rest with | ")" :: rest => pure (.lenPrefixed (← parsePrim w) (← m.toNat?) a, rest) | _ => none
      | _ => none
    | "rep" =>
      match rest with
      | n :: m :: rest =>
        let (a, rest) ← parseG fuel rest
        match rest with | ")" :: rest => pure (.repeated (← parseInt n) (← m.toNat?) a, rest) | _ => none
      | _ => none
    | "end" =>
      match rest with
      | m :: rest =>
        let (a, rest) ← parseG fuel rest
        match rest with | ")" :: rest => pure (.toEnd (← m.toNat?) a, rest) | _ => none
      | _ => none
    | _ => none
  | _ + 1, t :: rest => do pure (.prim (← parsePrim t), rest)
  | _, [] => none

def grammarAnswer (line : String) : Option String :=
  match line.splitOn " | " with
  | [h, g] => do
    let bs ← hexBytes h
    let ts := tokens g
    let (g, rest) ← parseG (ts.length + 1) ts
    if !rest.isEmpty then none
    else pure (match parseComplete bs g with
      | .ok r => s!"ok:{r.items}"
      | .error e => failCode e)
  | _ => none

def valCode : Val → String
  | .num v => s!"num:{v}" | .slice lo hi => s!"slice:{lo}:{hi}" | .unit => "unit"

def cursorAnswer (line : String) : Option String :=
  match line.splitOn " | " with
  | [h, se, ops] => do
    let bs ← hexBytes h
    let (start, stop) ← match words se with | [a, b] => do pure (← a.toNat?, ← b.toNat?) | _ => none
    let ops ← (words ops).mapM parsePrim
    let mut c : Cursor := ⟨start, start, stop⟩
    let mut out : List String := []
    for p in ops do
      match prim bs c p with
      | .ok (v, c') => out := out ++ [s!"{valCode v}@{c'.pos}"]; c := c'
      | .error e => out := out ++ [failCode e]; break
    pure (" ".intercalate out)
  | _ => none

def boxesAnswer (line : String) : Option String :=
  match line.splitOn " | " with
  | [h, args] => do
    let bs ← hexBytes h
    let (top, count, mx) ← match words args with | [t, c, m] => do pure (t == "1", ← c.toNat?, ← m.toNat?) | _ => none
    pure (match children bs 0 bs.length top count mx with
      | .ok (bxs, n) => s!"ok:{n}" ++ String.join (bxs.map fun b => s!" {b.type}@{b.offset}:{b.lo}:{b.hi}")
      | .error e => failCode e)
  | _ => none

def bitsAnswer (line : String) : Option String :=
  match line.splitOn " | " with
  | [h, pol, ops] => do
    let bs ← hexBytes h
    let zero := pol == "zero"
    let mut r : Bits := ⟨0, false⟩
    let mut out : List String := []
    for op in words ops do
      match op.splitOn ":" with
      | ["b", n] =>
        match readBits bs zero r (← n.toNat?) with
        | .ok (v, r') => out := out ++ [s!"{v}@{r'.pos}"]; r := r'
        | .error e => out := out ++ [failCode e]; break
      | ["p", n] => out := out ++ [s!"{peekBits bs r (← n.toNat?)}@{r.pos}"]
      | ["a"] => r := align r; out := out ++ [s!"@{r.pos}"]
      | _ => none
    pure (" ".intercalate out)
  | _ => none

end Codecs
