import Identity.Props
namespace Identity.Nonvacuity
def candidate (s : S) (e : Ev) : S := step s e
private def reviewed : S := run S.init [.key 0 7, .view 0]
example : ((candidate reviewed (.verify 0 true)).rows 0).map (·.verified) = some .verified := by decide
example : (candidate reviewed (.verify 0 true)).jobs = [⟨0, 7, true⟩] := by decide
private def verified : S := step reviewed (.verify 0 true)
example : (candidate verified (.sync 0)).sent = [⟨0, 7, true⟩] := by decide
-- This safety predicate alone accepts a missing successful action. The positive assertions
-- above are intentionally independent and must fail for that mutant.
example : targets [0] reviewed (.verify 0 true) reviewed = true := by decide
end Identity.Nonvacuity
