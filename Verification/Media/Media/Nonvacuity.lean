import Media.Props
namespace Media.Nonvacuity
-- The mutation runner substitutes this transition, independently of the safety proofs.
def candidate (s : S) (e : Ev) : S := step s e
private def initial : S := ⟨⟨fun _ => some ⟨false, none⟩, [(0, 7)], 0⟩, ⟨none, none, none, []⟩, [], none, []⟩
example : (candidate initial (.playAudio 0 7)).out = [("audio", 0, 7)] := by decide
example : (candidate initial (.playVideo 0 7)).out = [("video", 0, 7)] := by decide
example : (candidate (step initial (.decode 0 7)) (.decoded 0)).u.cache = [7] := by decide
example : (candidate (step initial (.openSave 0 7)) .confirmSave).out = [("export", 0, 7)] := by decide
-- This safety predicate alone accepts a missing successful action. The positive assertions
-- above are intentionally independent and must fail for that mutant.
example : handedOutPermitted initial (.playAudio 0 7) initial = true := by decide
end Media.Nonvacuity
