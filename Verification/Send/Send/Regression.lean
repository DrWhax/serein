import Send.Proofs
namespace Send
private def initial : P := ⟨⟨[], [], [], fun _ => .live, fun _ => []⟩, [], [], 0⟩
private def started : P := step (step initial (.queue (.direct 0) (.data ⟨true, false⟩) [0])) (.start 0)
-- Dropping an authorized retraction must fail the property itself.
example : retractionGoes started (.submit 0) started = false := by decide
example : retractionGoes started (.submit 0) (step started (.submit 0)) = true := by decide
end Send
