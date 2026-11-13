import Send.Props
namespace Send.Nonvacuity
def candidate (s : P) (e : Ev) : P := step s e
private def initial : P := ⟨⟨[], [], [], fun _ => .live, fun _ => []⟩, [], [], 0⟩
private def ready (c : Content) : P := step (step initial (.queue (.direct 0) c [0])) (.start 0)
example : (candidate (ready .content) (.submit 0)).out.length = 1 := by decide
example : (candidate (ready (.data ⟨true, false⟩)) (.submit 0)).out.length = 1 := by decide
-- This safety predicate alone accepts a missing successful action. The positive assertions
-- above are intentionally independent and must fail for that mutant.
example : submitAuthorized (ready .content) (.submit 0) (ready .content) = true := by decide
end Send.Nonvacuity
