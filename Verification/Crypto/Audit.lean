import Crypto
import Lean

/-! Run by Tools/verify-crypto.sh; compared with `audit-expected.txt`. -/

open Crypto

#print Crypto.paddingBlock
#print Crypto.paddedLength
#print Crypto.pad
#print Crypto.stripRev
#print Crypto.unpad
#print Crypto.unpadUpstream
#print Crypto.ascii
#print Crypto.zeros
#print Crypto.Bytes
#print Crypto.dec
#print Crypto.b64char
#print Crypto.b64
#print Crypto.Source
#print Crypto.Prim
#print Crypto.Derivation
#print Crypto.Use
#print Crypto.derivation
#print Crypto.Canonical
#print Crypto.stripZeros
#print Crypto.Derivation.canonical
#print Crypto.Use.WF
#print Crypto.Key
#print Crypto.Material
#print Crypto.Key.material
#print Crypto.Key.WF
#print Crypto.Field
#print Crypto.Field.lengths
#print Crypto.nameBytes
#print Crypto.bucket
#print Crypto.padTo
#print Crypto.untilNUL
#print Crypto.decodeName
#print Crypto.decodeString
#print Crypto.Origin
#print Crypto.opens
#print Crypto.Err
#print Crypto.ManifestContent
#print Crypto.ManifestCase
#print Crypto.manifestKey
#print Crypto.fresh
#print Crypto.verifyManifest
#print Crypto.RecordContent
#print Crypto.ItemsCase
#print Crypto.itemKey
#print Crypto.decryptItems
#print Crypto.verifyItems
#print Crypto.ProfileContent
#print Crypto.ProfileCase
#print Crypto.ProfileValue
#print Crypto.readField
#print Crypto.decryptProfile
#print Crypto.StickerContent
#print Crypto.StickerCase
#print Crypto.stickerKeys
#print Crypto.decryptSticker
#print Crypto.ProvisionContent
#print Crypto.ProvisionCase
#print Crypto.provisioningKeys
#print Crypto.provisionShape
#print Crypto.decryptProvision
#print Crypto.Author
#print Crypto.DeviceNameContent
#print Crypto.DeviceNameCase
#print Crypto.deviceNameKey
#print Crypto.decryptDeviceName

open Lean Elab Command in
/-- Every constant of the Crypto modules that the statements of `roots` use, following
types and definition bodies (theorems' proofs are not followed), sorted, with hashes. -/
elab "#audit_closure " roots:ident* : command => do
  let env ← getEnv
  let ours (c : Name) : Bool :=
    match env.getModuleIdxFor? c with
    | some i => (env.header.moduleNames[i.toNat]!).getRoot == `Crypto
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

#audit_closure pad_length_bounds pad_length_iff unpad_pad unpad_eq_some unpad_upstream_differs unpad_upstream_same dec_inj b64_inj separated key_binds bucket_least lengths_sorted padTo_length padTo_none name_roundtrip string_roundtrip name_nul_splits manifest_ok manifest_bound items_ok items_bound profile_ok profile_field_unbound sticker_ok sticker_bound sticker_mac_first provision_ok provision_bound provision_mac_first deviceName_ok deviceName_bound deviceName_unauthenticated

#check @pad_length_bounds
#check @pad_length_iff
#check @unpad_pad
#check @unpad_eq_some
#check @unpad_upstream_differs
#check @unpad_upstream_same
#check @dec_inj
#check @b64_inj
#check @separated
#check @key_binds
#check @bucket_least
#check @lengths_sorted
#check @padTo_length
#check @padTo_none
#check @name_roundtrip
#check @string_roundtrip
#check @name_nul_splits
#check @manifest_ok
#check @manifest_bound
#check @items_ok
#check @items_bound
#check @profile_ok
#check @profile_field_unbound
#check @sticker_ok
#check @sticker_bound
#check @sticker_mac_first
#check @provision_ok
#check @provision_bound
#check @provision_mac_first
#check @deviceName_ok
#check @deviceName_bound
#check @deviceName_unauthenticated

open Lean Elab Command in
/-- `collectAxioms` for each theorem, on one line each. -/
elab "#audit_axioms " roots:ident* : command => do
  for r in roots do
    let n ← liftCoreM <| realizeGlobalConstNoOverloadWithInfo r
    let axs ← liftCoreM <| collectAxioms n
    let axs := axs.qsort (fun a b => a.toString < b.toString)
    logInfo m!"{n} depends on axioms: [{", ".intercalate (axs.toList.map toString)}]"

#audit_axioms pad_length_bounds pad_length_iff unpad_pad unpad_eq_some unpad_upstream_differs unpad_upstream_same dec_inj b64_inj separated key_binds bucket_least lengths_sorted padTo_length padTo_none name_roundtrip string_roundtrip name_nul_splits manifest_ok manifest_bound items_ok items_bound profile_ok profile_field_unbound sticker_ok sticker_bound sticker_mac_first provision_ok provision_bound provision_mac_first deviceName_ok deviceName_bound deviceName_unauthenticated
