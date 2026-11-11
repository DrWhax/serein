import Codecs.Model

/-!
# The properties

* **Reads stay in their region** (`Within`): a run from a cursor in `[start, stop)` ends inside it,
  and every byte range it read or handed out lies between where it started and where it ended. A
  sub-grammar under `region` / `lengthPrefixed` reads only the declared bytes, whatever its length
  field said, and consumes them all.
* **Budget preservation** (`items ≤ budget g`): what a grammar's repetitions allocate is bounded by
  its limits alone, never by a count read from the input.
* **Container boundaries** (`BoxesWithin`): every box lies in its container, after its header, in
  order and disjoint; every box counts against the file's budget, which a successful walk never
  exceeds.
* **The bit reader** returns `n`-bit values and never consumes past the input.
-/

namespace Codecs

def Good (c : Cursor) : Prop := c.start ≤ c.pos ∧ c.pos ≤ c.stop

/-- `r` is a run from `c`. -/
def Within (c : Cursor) (r : R) : Prop :=
  r.c.start = c.start ∧ r.c.stop = c.stop ∧ c.pos ≤ r.c.pos ∧ r.c.pos ≤ c.stop ∧
    ∀ x ∈ r.reads, c.pos ≤ x.1 ∧ x.1 ≤ x.2 ∧ x.2 ≤ r.c.pos

def BoxesWithin (lo hi : Nat) (bxs : List Box) : Prop :=
  (∀ b ∈ bxs, lo ≤ b.offset ∧ b.offset + 8 ≤ b.lo ∧ b.lo ≤ b.hi ∧ b.hi ≤ hi) ∧ bxs.Pairwise (fun a b => a.hi ≤ b.offset)

end Codecs
