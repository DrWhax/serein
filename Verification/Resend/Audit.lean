import Resend
import Lean

/-! Run by Tools/verify-resend.sh; compared with `audit-expected.txt`. -/

open Resend

#print S
#print Payload
#print Row
#print SList
#print Out
#print Answer
#print prune
#print payloadFor
#print addRow
#print record
#print receipt
#print find
#print listed
#print answer
#print countOf
#print bump
#print step
#print Reach
#print Logged
#print ResentDelivered
#print outCount
#print Bounded
#print Resend.Inv


open Lean Elab Command in
/-- Every constant of the Resend modules that the statements of `roots` use, following
types and definition bodies (theorems' proofs are not followed), sorted, with hashes. -/
elab "#audit_closure " roots:ident* : command => do
  let env ← getEnv
  let ours (c : Name) : Bool :=
    match env.getModuleIdxFor? c with
    | some i => (env.header.moduleNames[i.toNat]!).getRoot == `Resend
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

#audit_closure answer_logged answer_story answer_limit logged_holds resentDelivered_holds bounded_holds

#check @answer_logged
#check @answer_story
#check @answer_limit
#check @logged_holds
#check @resentDelivered_holds
#check @bounded_holds

open Lean Elab Command in
/-- `collectAxioms` for each theorem, on one line each. -/
elab "#audit_axioms " roots:ident* : command => do
  for r in roots do
    let n ← liftCoreM <| realizeGlobalConstNoOverloadWithInfo r
    let axs ← liftCoreM <| collectAxioms n
    let axs := axs.qsort (fun a b => a.toString < b.toString)
    logInfo m!"{n} depends on axioms: [{", ".intercalate (axs.toList.map toString)}]"

#audit_axioms answer_logged answer_story answer_limit logged_holds resentDelivered_holds bounded_holds
