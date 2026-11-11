import Resend.Model

/-! # Notation for the Swift rig

`stories | ev ; ev ; …` with `stories` the contents that are stories to lists, and events
`s ts content recipient devices` (a send), `d recipient device ts` (a delivery receipt),
`t hours`, `y ts list` (one of our stories), `l id block deleted members` (a list as it is now),
`q requester device ts` (a retry request). Lists comma-separated, `-` for none. The answer: one
per request, `r:ts:content` (that payload again), `n` (a NullMessage) or `x` (nothing).
-/

namespace Resend

def nums (s : String) : List Nat := (s.splitOn ",").filterMap (·.toNat?)
def words (s : String) : List String := (s.splitOn " ").filter (!·.isEmpty)

def parseEv (s : String) : Option Ev :=
  match words s with
  | ["s", ts, c, r, ds] => do pure (.send (← ts.toNat?) (← c.toNat?) (← r.toNat?) (nums ds))
  | ["d", r, dv, ts] => do pure (.receipt (← r.toNat?) (← dv.toNat?) (← ts.toNat?))
  | ["t", n] => do pure (.tick (← n.toNat?))
  | ["y", ts, l] => do pure (.story (← ts.toNat?) (← l.toNat?))
  | ["l", i, b, del, ms] => do pure (.setList ⟨← i.toNat?, b == "1", del == "1", nums ms⟩)
  | ["q", a, dv, ts] => do pure (.retry (← a.toNat?) (← dv.toNat?) (← ts.toNat?))
  | _ => none

def answerCode : Answer → String
  | .resend p => s!"r:{p.ts}:{p.content}"
  | .null => "n"
  | .nothing => "x"

/-- Each request's answer, in order. -/
def answers (w : World) (evs : List Ev) : List String := Id.run do
  let mut s := S.init
  let mut out := []
  for e in evs do
    match e with
    | .retry a d ts =>
      let s' := { s with counts := bump s.counts (a, d, ts) (countOf s (a, d, ts)) }
      out := out ++ [answerCode (answer w s' a d ts (countOf s (a, d, ts)))]
    | _ => pure ()
    s := step w s e
  out

def runAnswer (line : String) : Option String :=
  match line.splitOn " | " with
  | [st, evs] => do
    let evs ← ((evs.splitOn " ; ").filter (!·.isEmpty)).mapM parseEv
    let a := answers ⟨nums st⟩ evs
    pure (if a.isEmpty then "-" else " ".intercalate a)
  | _ => none

end Resend
