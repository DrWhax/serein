import Broker.Model

/-! # Notation for the Swift rig

One event per line, as the rig sees it:
* `ct size input`, `co input`, `cs`: the app calls `thumbnail`, `openVideo`, `startVoiceNote`;
* `r c p reply`: the helper answers the `p`th message it received on channel `c` (`d` or `v`)
  with `t w h`, `o u valid`, `v u`, `e`, `g` (garbage) or `x` (an error, or no payload);
* `k c`: the helper's session on `c` ends; `u c`: it sends a message nobody asked for;
* `w c p`: the `p`th request sent on `c` times out; `z n`: the `n`th call's caller is cancelled.

The state the rig compares, one line: each call's status (`p`, `t:w:h`, `s:u`, `e`, or a
failure `T` timed out, `L` lost, `C` cancelled, `R` refused, `H` helper error, `Q` quarantined),
then per channel the sessions opened and the messages received (`t:size:input`, `o:input`, `s`,
`r:u`), then the strikes of inputs 0–3.
-/

namespace Broker

def words (s : String) : List String := (s.splitOn " ").filter (!·.isEmpty)

def parseCh : String → Option Ch
  | "d" => some .dec
  | "v" => some .voice
  | _ => none

/-- Indices of the requests sent on `c`, in order: the `p`th message the helper got there. -/
def sentOn (s : St) (c : Ch) : List Nat :=
  (List.range s.reqs.length).filter fun m => match s.reqs[m]? with
    | some q => q.sess.isSome && q.kind.ch == c
    | none => false

/-- Indices of the app's calls, in order. -/
def calls (s : St) : List Nat :=
  (List.range s.reqs.length).filter fun m => match s.reqs[m]? with
    | some { kind := .release .., .. } => false
    | some _ => true
    | none => false

def parseReply : List String → Option Reply
  | ["t", w, h] => do pure (.thumb (← w.toNat?) (← h.toNat?))
  | ["o", u, v] => do pure (.opened (← u.toNat?) (v == "1"))
  | ["v", u] => do pure (.voiceId (← u.toNat?))
  | ["e"] => some .empty
  | ["g"] => some .garbage
  | ["x"] => some .error
  | _ => none

/-- The event, against the state it happens in (messages are named as the rig sees them). An
event about a message that does not exist is none. -/
def parseEv (s : St) (line : String) : Option Ev :=
  match words line with
  | ["ct", size, i] => do pure (.call (.thumb (← size.toNat?) (← i.toNat?)))
  | ["co", i] => do pure (.call (.openV (← i.toNat?)))
  | ["cs"] => some (.call .start)
  | "r" :: c :: p :: rest => do
    let m ← (sentOn s (← parseCh c))[← p.toNat?]?
    pure (.reply m (← parseReply rest))
  | ["k", c] => do pure (.crash (← parseCh c))
  | ["u", c] => do pure (.unsolicited (← parseCh c))
  | ["w", c, p] => do pure (.timeout (← (sentOn s (← parseCh c))[← p.toNat?]?))
  | ["z", n] => do pure (.cancel (← (calls s)[← n.toNat?]?))
  | _ => none

def statusCode : Status → String
  | .pending => "p"
  | .ok (.thumb w h) => s!"t:{w}:{h}"
  | .ok (.session u) => s!"s:{u}"
  | .ok .empty => "e"
  | .failed .timedOut => "T"
  | .failed .lost => "L"
  | .failed .cancelled => "C"
  | .failed .refused => "R"
  | .failed .helper => "H"
  | .failed .quarantined => "Q"

def kindCode : Kind → String
  | .thumb size i => s!"t:{size}:{i}"
  | .openV i => s!"o:{i}"
  | .start => "s"
  | .release _ u => s!"r:{u}"

def orDash (xs : List String) (sep : String) : String := if xs.isEmpty then "-" else sep.intercalate xs

def chLine (s : St) (c : Ch) (name : String) : String :=
  let n := (s.sess.filter (·.ch == c)).length
  let msgs := (sentOn s c).filterMap fun m => (s.reqs[m]?).map (kindCode ·.kind)
  s!"{name} {n} {orDash msgs ","}"

def observe (s : St) : String :=
  let st := (calls s).filterMap fun m => (s.reqs[m]?).map (statusCode ·.status)
  let strikes := (List.range 4).map fun i => toString (s.strikes i)
  s!"{orDash st " "} | {chLine s .dec "d"} | {chLine s .voice "v"} | {",".intercalate strikes}"

/-! ## The other flows -/

def parseUrl (s : String) : Option Url :=
  match s.splitOn ":" with
  | [h, host, p, u] => do pure ⟨h == "1", ← host.toNat?, p == "1", u == "1"⟩
  | _ => none

/-- `g url` (whether `file` asks the service), `p url;url;…` (whether a page is accepted),
`e endpoint payload` (`-` for none: what the fetcher is handed). -/
def deputy (line : String) : Option String :=
  match words line with
  | ["g", u] => do pure (if fileAsked (← parseUrl u) then "1" else "0")
  | ["p", us] => do pure (if pageAccepted (← (us.splitOn ";").mapM parseUrl) then "1" else "0")
  | ["e", ep, n] => do
    let r : EndpointReply := ⟨if ep == "-" then none else ep.toNat?, ← n.toNat?⟩
    pure ((handed r).map toString |>.getD "-")
  | _ => none

end Broker
