import CallCapture
import Lean

/-! Run by Tools/verify-calls.sh. It prints, and the script compares with `audit-expected.txt`
(a change there needs review, not just a green build):

1. the definitions the properties are written in, readably (`#print`);
2. every definition the theorem statements below depend on, transitively, through definition
   bodies (not proofs) within the CallCapture modules, each with a hash of its type and value:
   the whole model, so a change anywhere in what a theorem is about shows up by name;
3. the statement of every theorem;
4. the axioms each theorem depends on, transitively, one theorem per line (the script accepts
   only `propext`, `Classical.choice` and `Quot.sound`). -/

open CallCapture

#print Reach
#print step
#print stepCore
#print noteEnded
#print instLive
#print curShare
#print shareRevoked
#print streamOwner
#print streamLive
#print jobOf
#print evMsg
#print leavesActive
#print t1
#print t1Rejected
#print t1OtherConv
#print t2Frames
#print evShare
#print t2Stop
#print wanted
#print t3Camera
#print VidOk
#print camStartWanted
#print t3CallRequest
#print t3Call
#print t3ScreenSources
#print t3Screen
#print t3ScreenObsolete
#print noPresentOn
#print t4Screen
#print t4ScreenObsolete
#print t4ScreenPublish
#print t4Camera
#print acceptedLive
#print t5
#print acceptAuthorized
#print jobMentions
#print noOrphanStream
#print noIdleUnwantedCamera
#print cleanupCamera
#print cleanupStreams
#print uiEnabled
#print drainedEnabled
#print fifoEnabled
#print isUserEv
#print enabledIn
#print allIn
#print fifoTrace
#print schedule
#print firstFailure

open Lean Elab Command in
/-- Every constant of the CallCapture modules that the statements of `roots` use, following
types and definition bodies (theorems' proofs are not followed), sorted, with hashes. -/
elab "#audit_closure " roots:ident* : command => do
  let env ← getEnv
  let ours (c : Name) : Bool :=
    match env.getModuleIdxFor? c with
    | some i => (env.header.moduleNames[i.toNat]!).getRoot == `CallCapture
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

#audit_closure ShareInv.reach t2Frames_holds t2Stop_holds t4ScreenObsolete_holds t4Camera_holds camStartWanted_holds cameraFrames_gated VidOk.reach t3Camera_holds ended_not_live t5_holds t2Frames_wrap t4ScreenObsolete_wrap

#check @ShareInv.reach
#check @t2Frames_holds
#check @t2Stop_holds
#check @t4ScreenObsolete_holds
#check @t4Camera_holds
#check @camStartWanted_holds
#check @cameraFrames_gated
#check @VidOk.reach
#check @t3Camera_holds
#check @ended_not_live
#check @t5_holds
#check @t2Frames_wrap
#check @t4ScreenObsolete_wrap

open Lean Elab Command in
/-- `collectAxioms` for each theorem, on one line each. -/
elab "#audit_axioms " roots:ident* : command => do
  for r in roots do
    let n ← liftCoreM <| realizeGlobalConstNoOverloadWithInfo r
    let axs ← liftCoreM <| collectAxioms n
    let axs := axs.qsort (fun a b => a.toString < b.toString)
    logInfo m!"{n} depends on axioms: [{", ".intercalate (axs.toList.map toString)}]"

#audit_axioms ShareInv.reach t2Frames_holds t2Stop_holds t4ScreenObsolete_holds t4Camera_holds camStartWanted_holds cameraFrames_gated VidOk.reach t3Camera_holds ended_not_live t5_holds t2Frames_wrap t4ScreenObsolete_wrap
