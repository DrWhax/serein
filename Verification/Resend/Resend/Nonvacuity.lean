import Resend.Props
namespace Resend.Nonvacuity
def candidate (s : S) (e : Ev) : S := step ⟨[]⟩ s e
private def ready : S := step ⟨[]⟩ S.init (.send 0 7 0 [1])
example : (candidate ready (.retry 0 1 0)).out.map (·.carried) = [some (0, 7)] := by decide
example : (candidate S.init (.retry 0 1 0)).out.length = 1 := by decide
-- This safety predicate alone accepts a missing successful action. The positive assertions
-- above are intentionally independent and must fail for that mutant.
example : resentDeliveredB ready = true := by decide
end Resend.Nonvacuity
