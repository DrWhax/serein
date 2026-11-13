import Attachments.Props
namespace Attachments.Nonvacuity
def candidate (s : S) (e : Ev) : S := step s e
private def att : Att := ⟨0, 7, 3, 3, 16, 16, true, false, .pending, none⟩
private def waiting : S := step (S.init 100) (.arrive att)
private def response : Resp := ⟨ciphertextSize 16, some 7⟩
example : (candidate waiting (.download 0 response)).atts.head?.bind (·.path) = some 0 := by decide
private def ready : S := step waiting (.download 0 response)
example : (candidate ready (.consume 0)).delivered = [(0, some 7, 3)] := by decide
-- This safety predicate alone accepts a missing successful action. The positive assertions
-- above are intentionally independent and must fail for that mutant.
example : deliveredB waiting = true := by decide
end Attachments.Nonvacuity
