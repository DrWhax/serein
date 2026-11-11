import Modifiers
import Lean

/-! Run by Tools/verify-modifiers.sh; compared with `audit-expected.txt`. -/

open Modifiers

#print S
#print Row
#print Mod
#print World
#print Entry
#print accepts
#print editValid
#print pinnable
#print belongs
#print blockedIn
#print canEditAttrs
#print effect
#print resolves
#print lookup
#print heaviestFrom
#print heaviest
#print evict
#print trim
#print kept
#print applyMod
#print step
#print fresh
#print Reach
#print S.get
#print ResolvedCorrect
#print PendingUnresolvable
#print NewestShown
#print StepOk
#print Inv


open Lean Elab Command in
/-- Every constant of the Modifiers modules that the statements of `roots` use, following
types and definition bodies (theorems' proofs are not followed), sorted, with hashes. -/
elab "#audit_closure " roots:ident* : command => do
  let env ← getEnv
  let ours (c : Name) : Bool :=
    match env.getModuleIdxFor? c with
    | some i => (env.header.moduleNames[i.toNat]!).getRoot == `Modifiers
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

#audit_closure accepts_conversation accepts_edit_conversation accepts_author accepts_admin accepts_member accepts_sent deleted_accepts_nothing edit_newer edit_refuses evict_heaviest evict_spares_lighter kept_sub resolvedCorrect_holds pendingUnresolvable_holds newestShown_holds stepOk_holds

#check @accepts_conversation
#check @accepts_edit_conversation
#check @accepts_author
#check @accepts_admin
#check @accepts_member
#check @accepts_sent
#check @deleted_accepts_nothing
#check @edit_newer
#check @edit_refuses
#check @evict_heaviest
#check @evict_spares_lighter
#check @kept_sub
#check @resolvedCorrect_holds
#check @pendingUnresolvable_holds
#check @newestShown_holds
#check @stepOk_holds

open Lean Elab Command in
/-- `collectAxioms` for each theorem, on one line each. -/
elab "#audit_axioms " roots:ident* : command => do
  for r in roots do
    let n ← liftCoreM <| realizeGlobalConstNoOverloadWithInfo r
    let axs ← liftCoreM <| collectAxioms n
    let axs := axs.qsort (fun a b => a.toString < b.toString)
    logInfo m!"{n} depends on axioms: [{", ".intercalate (axs.toList.map toString)}]"

#audit_axioms accepts_conversation accepts_edit_conversation accepts_author accepts_admin accepts_member accepts_sent deleted_accepts_nothing edit_newer edit_refuses evict_heaviest evict_spares_lighter kept_sub resolvedCorrect_holds pendingUnresolvable_holds newestShown_holds stepOk_holds
