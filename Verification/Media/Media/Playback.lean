import Media.Model
/-!
# Playback across awaits

A request captures a session generation and its own message/file relation. Completion rechecks
both after loading/seeking. Stopping or replacing the session invalidates pending work; another
message's reference is never sufficient. Engine cancellation tests tie these events to Swift.
-/
namespace Media.Playback
structure Ticket where
  generation : Nat
  message : Nat
  path : Nat
  deriving DecidableEq, Repr
structure S where
  db : Db
  generation : Nat
  pending : Option Ticket
  out : List (Nat × Nat)
inductive Ev
  | request (message path : Nat)
  | ready
  | stop
  | erase (message : Nat)
  | replaceSession (db : Db)

def step (s : S) : Ev → S
  | .request m p => if permits s.db m p then { s with pending := some ⟨s.generation, m, p⟩ } else s
  | .stop => { s with generation := s.generation + 1, pending := none }
  | .replaceSession db => { s with db, generation := s.generation + 1, pending := none }
  | .erase m => { s with db := { s.db with rows := upd s.db.rows m ((s.db.rows m).map fun r => { r with erased := true }) } }
  | .ready => match s.pending with
    | some t => if t.generation == s.generation && permits s.db t.message t.path then
        { s with pending := none, out := s.out ++ [(t.message, t.path)] }
      else s
    | none => s

def safe (s s' : S) : Prop := s'.out = s.out ∨
  ∃ t, s.pending = some t ∧ t.generation = s.generation ∧ permits s.db t.message t.path = true ∧
    s'.out = s.out ++ [(t.message, t.path)]

theorem completion_authorized (s : S) (e : Ev) : safe s (step s e) := by
  cases e <;> simp only [step, safe]
  case request m p => split <;> exact Or.inl rfl
  case stop => simp
  case replaceSession db => simp
  case erase m => simp
  case ready =>
    split
    · rename_i t ht
      split
      · rename_i h
        simp only [Bool.and_eq_true, beq_iff_eq] at h
        exact Or.inr ⟨t, ht, h.1, h.2, rfl⟩
      · exact Or.inl rfl
    · exact Or.inl rfl

private def initial : S := ⟨⟨fun _ => some ⟨false, none⟩, [(0, 7), (1, 7)], 0⟩, 0, none, []⟩
private def loading : S := step initial (.request 0 7)
example : (step loading .ready).out = [(0, 7)] := by decide
example : (step (step loading (.erase 0)) .ready).out = [] := by decide
example : (step (step loading .stop) .ready).out = [] := by decide
example : (step (step loading (.replaceSession initial.db)) .ready).out = [] := by decide
end Media.Playback
