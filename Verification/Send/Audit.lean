import Send
import Lean

/-! Run by Tools/verify-send.sh; compared with `audit-expected.txt`: the definitions the
properties are written in, every definition the theorem statements depend on (with hashes), the
statements, and each theorem's axioms (only `propext`, `Classical.choice`, `Quot.sound`). -/

open Send

#print Data
#print Content
#print Content.carries
#print Data.onlyDeletes
#print Content.onlyRetracts
#print Target
#print S
#print S.blocked
#print authorized
#print recipients
#print stepCore
#print submitted
#print submitAuthorized
#print contentNeedsSource
#print retractionGoes
#print groupRecipients


open Lean Elab Command in
/-- Every constant of the Send modules that the statements of `roots` use, following
types and definition bodies (theorems' proofs are not followed), sorted, with hashes. -/
elab "#audit_closure " roots:ident* : command => do
  let env ← getEnv
  let ours (c : Name) : Bool :=
    match env.getModuleIdxFor? c with
    | some i => (env.header.moduleNames[i.toNat]!).getRoot == `Send
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

#audit_closure onlyRetracts_carries onlyRetracts_extra group_ignores_contacts direct_ignores_groups blocked_contact_refused blocked_group_refused retraction_ignores_messages content_needs_live recipients_mem step_out submitAuthorized_holds contentNeedsSource_holds retractionGoes_holds groupRecipients_holds

#check @onlyRetracts_carries
#check @onlyRetracts_extra
#check @group_ignores_contacts
#check @direct_ignores_groups
#check @blocked_contact_refused
#check @blocked_group_refused
#check @retraction_ignores_messages
#check @content_needs_live
#check @recipients_mem
#check @step_out
#check @submitAuthorized_holds
#check @contentNeedsSource_holds
#check @retractionGoes_holds
#check @groupRecipients_holds

open Lean Elab Command in
/-- `collectAxioms` for each theorem, on one line each. -/
elab "#audit_axioms " roots:ident* : command => do
  for r in roots do
    let n ← liftCoreM <| realizeGlobalConstNoOverloadWithInfo r
    let axs ← liftCoreM <| collectAxioms n
    let axs := axs.qsort (fun a b => a.toString < b.toString)
    logInfo m!"{n} depends on axioms: [{", ".intercalate (axs.toList.map toString)}]"

#audit_axioms onlyRetracts_carries onlyRetracts_extra group_ignores_contacts direct_ignores_groups blocked_contact_refused blocked_group_refused retraction_ignores_messages content_needs_live recipients_mem step_out submitAuthorized_holds contentNeedsSource_holds retractionGoes_holds groupRecipients_holds
