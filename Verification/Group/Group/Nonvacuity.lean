import Group.Props
namespace Group.Nonvacuity
def candidate (s : S) (e : Ev) : S := step s e
private def waiting : S := ([Ev.queue [0, 1] false, .plan 0]).foldl step (S.init [0, 1] (fun _ => [0]))
example : (candidate waiting (.distribute 0)).out = [(0, "key")] := by decide
private def ready : S := ([Ev.distribute 0, .distribute 0]).foldl step waiting
example : (candidate ready (.submit 0)).out = [(0, "key"), (1, "key"), (0, "content"), (1, "content")] := by decide
-- This safety predicate alone accepts a missing successful action. The positive assertions
-- above are intentionally independent and must fail for that mutant.
example : contentToMembers ready (.submit 0) ready = true := by decide
end Group.Nonvacuity
