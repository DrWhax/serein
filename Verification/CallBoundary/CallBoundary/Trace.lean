import CallBoundary.Model

/-! # Notation for the Swift rig

One event per line, as the rig sees it (`us` is a comma list of numbers, `-` for none):
* the app: `self`; `start p c`; `offer p c`; `msg u` (a call message from `u`);
  `group gid client link` (`link` 0 or 1); `members client us`; `ccmd`; `gcmd client`;
  `cancel gid`; `xs u`, `xr gid` (the window passing);
* the service: `in p c` (an incoming call), `sig p c` (signalling), `cm u` (a call message),
  `gm gid us` (a group message), `ring u gid`, `end c` (a call ended), `dev client us` (remote
  devices), `gend client` (a group call ended);
* `crash` (the service loses the endpoint), `wait` (a turn of the event pump).

The state the rig compares, one line:
`ep E gen G rep R | call P:C:ENDED | groups CL:GID:GEN;… | out …;… | cmds EP:ORIGIN;…`
with `-` for none, a call-link group's `GID` as `-`, outputs `s:p:c`, `i:p:c`, `m:u`, `g:gid:us`,
`r:u:gid`, `e:client`, and origins `r` (RingRTC), `c` (the call), `g` (a group call). -/

namespace CallBoundary

def nums (t : String) : Option (List Nat) :=
  if t == "-" then some [] else (t.splitOn ",").mapM String.toNat?

def parse (line : String) : Option Ev :=
  match (line.splitOn " ").filter (· ≠ "") with
  | ["self"] => some .setSelf
  | ["start", p, c] => do pure (.start (← p.toNat?) (← c.toNat?))
  | ["offer", p, c] => do pure (.offer (← p.toNat?) (← c.toNat?))
  | ["msg", u] => do pure (.callMsg (← u.toNat?))
  | ["group", g, c, l] => do pure (.group (← g.toNat?) (← c.toNat?) (l == "1"))
  | ["members", c, us] => do pure (.members (← c.toNat?) (← nums us))
  | ["ccmd"] => some .callCmd
  | ["gcmd", c] => do pure (.groupCmd (← c.toNat?))
  | ["cancel", g] => do pure (.cancelRing (← g.toNat?))
  | ["xs", u] => do pure (.expireSender (← u.toNat?))
  | ["xr", g] => do pure (.expireRing (← g.toNat?))
  | ["in", p, c] => do pure (.incoming (← p.toNat?) (← c.toNat?))
  | ["sig", p, c] => do pure (.signal (← p.toNat?) (← c.toNat?))
  | ["cm", u] => do pure (.message (← u.toNat?))
  | ["gm", g, us] => do pure (.groupMessage (← g.toNat?) (← nums us))
  | ["ring", u, g] => do pure (.ring (← u.toNat?) (← g.toNat?))
  | ["end", c] => do pure (.callEnded (← c.toNat?))
  | ["dev", c, us] => do pure (.devices (← c.toNat?) (← nums us))
  | ["gend", c] => do pure (.groupEnded (← c.toNat?))
  | ["crash"] => some .crash
  | ["wait"] => some .wait
  | _ => none

def showNums (us : List Nat) : String := if us.isEmpty then "-" else ",".intercalate (us.map toString)

def showOut : Out → String
  | .signal p c => s!"s:{p}:{c}"
  | .incoming p c => s!"i:{p}:{c}"
  | .message u => s!"m:{u}"
  | .groupMessage g us => s!"g:{g}:{showNums us}"
  | .ring u g => s!"r:{u}:{g}"
  | .groupEnded c => s!"e:{c}"

def showOrigin : Origin → String
  | .rtc => "r"
  | .call => "c"
  | .group => "g"

def showList (xs : List String) : String := if xs.isEmpty then "-" else ";".intercalate xs

def line (s : St) : String :=
  let ep := match s.ep with
    | some e => toString e
    | none => "-"
  let call := match s.call with
    | some k => s!"{k.peer}:{k.id}:{if k.ended then 1 else 0}"
    | none => "-"
  let groups := showList (s.groups.map fun g => s!"{g.client}:{if g.link then "-" else toString g.group}:{g.gen}")
  s!"ep {ep} gen {s.gen} rep {s.reported} | call {call} | groups {groups} | out {showList (s.out.map showOut)} | cmds {showList (s.cmds.map fun c => s!"{c.ep}:{showOrigin c.origin}")}"

end CallBoundary
