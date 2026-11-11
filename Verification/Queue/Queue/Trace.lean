import Queue.Model

/-! # Notation for the Swift rig: user and environment events, the actor's own work settled -/

namespace Queue

def Outcome.code : Outcome → String | .ok => "ok" | .permanent => "perm" | .retry => "retry" | .cancelled => "cancel"

def Ev.code : Ev → String
  | .runLoop => "run.loop" | .runWake => "run.wake" | .runReturn k => s!"run.ret.{k}"
  | .start => "start" | .stop => "stop" | .stopAndWait => "stopwait"
  | .enqueue j => s!"enqueue.{j}" | .handlerReturns o => s!"ret.{o.code}"

def Ev.parse (t : String) : Option Ev :=
  match t.splitOn "." with
  | ["start"] => some .start
  | ["stop"] => some .stop
  | ["stopwait"] => some .stopAndWait
  | ["enqueue", j] => j.toNat?.map .enqueue
  | ["ret", "ok"] => some (.handlerReturns .ok)
  | ["ret", "perm"] => some (.handlerReturns .permanent)
  | ["ret", "retry"] => some (.handlerReturns .retry)
  | ["ret", "cancel"] => some (.handlerReturns .cancelled)
  | _ => none

/-- The actor's own work, run until none is left: the loop's segments, wake-ups, returns. -/
def settle : Nat → S → S
  | 0, s => s
  | n + 1, s =>
    match s.loop with
    | some .select | some (.after _ _) => settle n (step s .runLoop)
    | _ =>
      if s.wakes != 0 then settle n (step s .runWake)
      else if !s.returns.isEmpty then settle n (step s (.runReturn 0))
      else s

def b01 (b : Bool) : String := if b then "1" else "0"
def list (xs : List Nat) : String := ",".intercalate (xs.map toString)

def obs (s : S) : String :=
  let l := match s.loop with
    | none => "none" | some .waiting => "wait" | some (.executing j) => s!"exec.{j}"
    | some .select => "select" | some (.after j _) => s!"after.{j}"
  s!"L={l} W={b01 s.wantsRunning} D={s.draining} DB=[{list s.db}] DONE=[{list s.done}] R={s.returned.length}"

end Queue
