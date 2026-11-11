import Identity.Model

/-! # Trace notation and observations (shared with the Swift rig) -/

namespace Identity

def b01 (b : Bool) : String := if b then "1" else "0"

def VS.code : VS → String | .dflt => "D" | .verified => "V" | .unverified => "U"
def VS.parse : String → Option VS | "D" => some .dflt | "V" => some .verified | "U" => some .unverified | _ => none

def Ev.code : Ev → String
  | .view p => s!"show.{p}"
  | .confirm is => "confirm" ++ String.join (is.map fun i => s!".{i}")
  | .commit k => s!"commit.{k}"
  | .race k p kk => s!"race.{k}.{p}.{kk}"
  | .verify i b => s!"verify.{i}.{b01 b}"
  | .key p k => s!"key.{p}.{k}"
  | .account a k => s!"acct.{a}.{k}"
  | .window p => s!"win.{p}"
  | .storage p k v f => s!"store.{p}.{k}.{v.code}.{b01 f}"
  | .sync j => s!"sync.{j}"

def Ev.parse (t : String) : Option Ev :=
  let parts := t.splitOn "."
  let n (i : Nat) : Option Nat := parts[i]?.bind (·.toNat?)
  let b (i : Nat) : Option Bool := parts[i]?.bind fun | "1" => some true | "0" => some false | _ => none
  match parts[0]? with
  | some "show" => (n 1).map .view
  | some "confirm" => (parts.drop 1).mapM (fun (x : String) => x.toNat?) |>.map .confirm
  | some "commit" => (n 1).map .commit
  | some "race" => do pure (.race (← n 1) (← n 2) (← n 3))
  | some "verify" => do pure (.verify (← n 1) (← b 2))
  | some "key" => do pure (.key (← n 1) (← n 2))
  | some "acct" => do pure (.account (← n 1) (← n 2))
  | some "win" => (n 1).map .window
  | some "store" => do pure (.storage (← n 1) (← n 2) (← parts[3]?.bind VS.parse) (← b 4))
  | some "sync" => (n 1).map .sync
  | _ => none

def traceCode (es : List Ev) : String := " ".intercalate (es.map Ev.code)

def parseTrace (line : String) : Except String (List Ev) :=
  ((line.splitOn " ").filter (· ≠ "")).mapM fun t => match Ev.parse t with
    | some e => .ok e
    | none => .error s!"bad event '{t}'"

def Res.code : Res → String | .none => "-" | .ok => "ok" | .stale => "stale"

def Sync.code (j : Sync) : String := s!"{j.peer}.{j.key}.{b01 j.verified}"

/-- What both sides print after each step: account, the rows and notices of peers 0–2, how
many safety numbers are held and reviews pending, the queued and sent Verified syncs, and the
result of the step's user action. -/
def obs (s : S) : String :=
  let row (p : Nat) : String := match s.rows p with
    | some r => s!"{r.key}.{b01 r.firstUse}.{b01 r.recent}.{r.verified.code}.{b01 r.approved}"
    | none => "-"
  let rows := ",".intercalate ([0, 1, 2].map fun p => s!"{row p}/{s.keyChanges p}.{s.localNotices p}.{s.remoteNotices p}")
  s!"A={s.aci}.{s.ourKey} R={rows} H={s.held.length} P={s.pending.length} J=[{",".intercalate (s.jobs.map Sync.code)}] T=[{",".intercalate (s.sent.map Sync.code)}] L={s.last.code}"

end Identity
