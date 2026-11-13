import Group.Proofs
namespace Group
private def initial : S := S.init [0, 1] (fun _ => [0])
-- An older send targets only 1. A concurrent send reserves and delivers the same key to 0.
private def exposure : List Ev := [.queue [1] false, .plan 0, .queue [0, 1] false, .plan 1,
  .distribute 0, .distribute 1, .remove 0]
private def before : S := exposure.foldl step initial
example : (0, 0, before.epoch) ∈ before.holders := by decide
example : before.members = [1] := by decide
example : newOut before (step before (.submit 0)) = [] := by decide
-- A fabricated output with the old bug is rejected by the independent property.
example : contentKeySafe before (.submit 0) { before with out := before.out ++ [(1, "content")] } = false := by decide
-- The original adversarial trace now rotates before the second send. Late delivery of the
-- old distribution does not acquire the new generation or restore old reservations.
private def oldTrace : List Ev := [.queue [0] false, .plan 0, .queue [1] false, .plan 1,
  .distribute 0, .distribute 1, .remove 0]
private def ready : S := oldTrace.foldl step initial
example : (0, 0, ready.epoch) ∉ ready.holders := by decide
example : newOut ready (step ready (.submit 1)) = [(1, "content")] := by decide
example : contentKeySafe ready (.submit 1) (step ready (.submit 1)) = true := by decide
-- Planning is a durable reservation; delivery is a separate scheduler event.
private def reserved : S := ([Ev.queue [0] false, .plan 0]).foldl step initial
example : reserved.distributed = [(0, 0)] ∧ reserved.holders = [] := by decide
end Group
