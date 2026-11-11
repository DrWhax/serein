import Identity
import Lean

/-! Run by Tools/verify-identity.sh. It prints, and the script compares with
`audit-expected.txt` (a change there needs review, not just a green build):

1. the definitions the properties are written in, readably (`#print`);
2. every definition the theorem statements depend on, transitively, through definition bodies
   (not proofs) within the Identity modules, each with a hash of its type and value;
3. the statement of every theorem;
4. the axioms each theorem depends on, one theorem per line (the script accepts only `propext`,
   `Classical.choice` and `Quot.sound`). -/

open Identity

#print S
#print Row
#print Snap
#print step
#print stepCore
#print Reach
#print saveKey
#print valid
#print approveOne
#print approve
#print setVer
#print storage
#print commitOf
#print trust
#print staleNoChange
#print targets
#print grantShown
#print syncShown
#print syncExact
#print keyChangeRevokes
#print storageNoSubstitute
#print Inv
#print GrantOk


open Lean Elab Command in
/-- Every constant of the Identity modules that the statements of `roots` use, following
types and definition bodies (theorems' proofs are not followed), sorted, with hashes. -/
elab "#audit_closure " roots:ident* : command => do
  let env ← getEnv
  let ours (c : Name) : Bool :=
    match env.getModuleIdxFor? c with
    | some i => (env.header.moduleNames[i.toNat]!).getRoot == `Identity
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

#audit_closure staleNoChange_holds targets_holds grantShown_holds syncShown_holds syncExact_holds keyChangeRevokes_holds storageNoSubstitute_holds Inv.reach

#check @staleNoChange_holds
#check @targets_holds
#check @grantShown_holds
#check @syncShown_holds
#check @syncExact_holds
#check @keyChangeRevokes_holds
#check @storageNoSubstitute_holds
#check @Inv.reach

open Lean Elab Command in
/-- `collectAxioms` for each theorem, on one line each. -/
elab "#audit_axioms " roots:ident* : command => do
  for r in roots do
    let n ← liftCoreM <| realizeGlobalConstNoOverloadWithInfo r
    let axs ← liftCoreM <| collectAxioms n
    let axs := axs.qsort (fun a b => a.toString < b.toString)
    logInfo m!"{n} depends on axioms: [{", ".intercalate (axs.toList.map toString)}]"

#audit_axioms staleNoChange_holds targets_holds grantShown_holds syncShown_holds syncExact_holds keyChangeRevokes_holds storageNoSubstitute_holds Inv.reach
