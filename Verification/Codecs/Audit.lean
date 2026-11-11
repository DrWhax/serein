import Codecs
import Lean

/-! Run by Tools/verify-codecs.sh; compared with `audit-expected.txt`. -/

open Codecs

#print Cursor
#print Prim
#print Val
#print need
#print be
#print le
#print fixedRead
#print prim
#print G
#print R
#print readRange
#print iterate
#print toEndLoop
#print complete
#print run
#print budget
#print Box
#print header
#print boxes
#print children
#print bitAt
#print bitsVal
#print Bits
#print readBits
#print Good
#print Within
#print BoxesWithin


open Lean Elab Command in
/-- Every constant of the Codecs modules that the statements of `roots` use, following
types and definition bodies (theorems' proofs are not followed), sorted, with hashes. -/
elab "#audit_closure " roots:ident* : command => do
  let env ← getEnv
  let ours (c : Name) : Bool :=
    match env.getModuleIdxFor? c with
    | some i => (env.header.moduleNames[i.toNat]!).getRoot == `Codecs
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

#audit_closure need_spec prim_within run_within region_exact run_budget children_within children_budget bitsVal_lt readBits_spec

#check @need_spec
#check @prim_within
#check @run_within
#check @region_exact
#check @run_budget
#check @children_within
#check @children_budget
#check @bitsVal_lt
#check @readBits_spec

open Lean Elab Command in
/-- `collectAxioms` for each theorem, on one line each. -/
elab "#audit_axioms " roots:ident* : command => do
  for r in roots do
    let n ← liftCoreM <| realizeGlobalConstNoOverloadWithInfo r
    let axs ← liftCoreM <| collectAxioms n
    let axs := axs.qsort (fun a b => a.toString < b.toString)
    logInfo m!"{n} depends on axioms: [{", ".intercalate (axs.toList.map toString)}]"

#audit_axioms need_spec prim_within run_within region_exact run_budget children_within children_budget bitsVal_lt readBits_spec
