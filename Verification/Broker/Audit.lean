import Broker
import Lean

/-! Run by Tools/verify-broker.sh; compared with `audit-expected.txt`. -/

open Broker

#print St
#print Req
#print Sess
#print Kind
#print Kind.ch
#print Kind.input
#print Reply
#print Status
#print Err
#print Val
#print accept
#print late
#print ended
#print opened
#print send
#print quarantined
#print call
#print answer
#print reply
#print endReq
#print inFlight
#print crash
#print bump
#print timeout
#print cancel
#print step
#print Reach
#print chOf
#print Url
#print cdn
#print pageAccepted
#print fileAsked
#print EndpointReply
#print handed
#print Shaped
#print LiveOpen
#print OneOpen
#print PendingLive
#print LostEnded
#print Answered
#print OkOwn
#print NoLeak
#print ReleaseNamed
#print timedOutCount
#print lostOn
#print lostSessions
#print StrikesExact
#print Broker.Inv

open Lean Elab Command in
/-- Every constant of the Broker modules that the statements of `roots` use, following
types and definition bodies (theorems' proofs are not followed), sorted, with hashes. -/
elab "#audit_closure " roots:ident* : command => do
  let env ← getEnv
  let ours (c : Name) : Bool :=
    match env.getModuleIdxFor? c with
    | some i => (env.header.moduleNames[i.toNat]!).getRoot == `Broker
    | none => false
  let mut todo : Array Name := #[]
  for r in roots do
    let n ← liftCoreM <| realizeGlobalConstNoOverloadWithInfo r
    let some ci := env.find? n | throwError "unknown {n}"
    todo := todo ++ ci.type.getUsedConstants
  let mut seen : NameSet := {}
  while h : todo.size > 0 do
    let c := todo[todo.size - 1]
    todo := todo.pop
    if seen.contains c || !ours c then continue
    seen := seen.insert c
    let some ci := env.find? c | continue
    todo := todo ++ ci.type.getUsedConstants
    match ci with
    | .defnInfo v => todo := todo ++ v.value.getUsedConstants
    | .inductInfo v => todo := todo ++ v.ctors.toArray
    | .ctorInfo v => todo := todo.push v.induct
    | _ => pure ()
  let names := seen.toArray.qsort (fun a b => a.toString < b.toString)
  logInfo m!"{names.size} definitions"
  for c in names do
    let some ci := env.find? c | continue
    let v := match ci with
      | .defnInfo v => toString v.value.hash
      | .inductInfo v => toString (hash (v.ctors.map toString))
      | _ => "-"
    logInfo m!"{c} {ci.type.hash} {v}"

#audit_closure final_stable pendingLive_holds okOwn_holds thumb_own session_own noLeak_holds releaseNamed_holds strikes_holds quarantine_cause crash_strikes_le crash_ends send_fresh other_channel inert unsolicited_inert quarantined_unsent fileAsked_cdn pageAccepted_cdn handed_parser

#check @final_stable
#check @pendingLive_holds
#check @okOwn_holds
#check @thumb_own
#check @session_own
#check @noLeak_holds
#check @releaseNamed_holds
#check @strikes_holds
#check @quarantine_cause
#check @crash_strikes_le
#check @crash_ends
#check @send_fresh
#check @other_channel
#check @inert
#check @unsolicited_inert
#check @quarantined_unsent
#check @fileAsked_cdn
#check @pageAccepted_cdn
#check @handed_parser

open Lean Elab Command in
/-- `collectAxioms` for each theorem, on one line each. -/
elab "#audit_axioms " roots:ident* : command => do
  for r in roots do
    let n ← liftCoreM <| realizeGlobalConstNoOverloadWithInfo r
    let axs ← liftCoreM <| collectAxioms n
    let axs := axs.qsort (fun a b => a.toString < b.toString)
    logInfo m!"{n} depends on axioms: [{", ".intercalate (axs.toList.map toString)}]"

#audit_axioms final_stable pendingLive_holds okOwn_holds thumb_own session_own noLeak_holds releaseNamed_holds strikes_holds quarantine_cause crash_strikes_le crash_ends send_fresh other_channel inert unsolicited_inert quarantined_unsent fileAsked_cdn pageAccepted_cdn handed_parser
