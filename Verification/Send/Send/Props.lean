import Send.Model

/-! # The properties, as checks on one pipeline step -/

namespace Send

/-- What a step submitted, if anything. -/
def submitted (p p' : P) : Option Out := if p'.out.length = p.out.length + 1 then p'.out.getLast? else none

/-- **Forbidden content never submits**: every submission is authorized in the state at the
boundary (the state the submit step starts from): not to a blocked contact (by id or number),
not to a blocked group, and naming only messages that still exist, unerased — unless it only
retracts them. -/
def submitAuthorized (p : P) (_e : Ev) (p' : P) : Bool :=
  (p'.out.length == p.out.length || p'.out.length == p.out.length + 1) &&
  match submitted p p' with
  | some o => authorized p.s o.target o.content o.ids
  | none => true

/-- **Content needs its source**: a submission that carries message content names only live
messages. -/
def contentNeedsSource (p : P) (_e : Ev) (p' : P) : Bool :=
  match submitted p p' with
  | some o => !o.content.carries || o.ids.all fun m => p.s.msgs m == .live
  | none => true

/-- **A retraction is not refused for its removed source**: a started send that only retracts,
to a target that is not blocked, is submitted whatever happened to the messages it names. -/
def retractionGoes (p : P) (e : Ev) (_p' : P) : Bool :=
  match e with
  | .submit j => match p.jobs[j]? with
    | some ⟨t, c, ids, .started _⟩ =>
      !c.onlyRetracts || !authorized { p.s with msgs := fun _ => .live } t c ids ||
        (stepCore p e).out.length == p.out.length + 1
    | _ => true
  | _ => true

/-- **Group recipients are the members we have not blocked**: a group send that starts chooses
exactly its members that are not blocked at that moment (`recipients_mem`), and a submission
goes to the recipients its send chose (`step_out`). -/
def groupRecipients (p : P) (e : Ev) (p' : P) : Bool :=
  match e with
  | .start j => match p.jobs[j]? with
    | some ⟨.group g, c, ids, .queued⟩ =>
      !authorized p.s (.group g) c ids || p'.jobs[j]? == some ⟨.group g, c, ids, .started (recipients p.s g)⟩
    | _ => true
  | _ => true

def stepChecks : List (String × (P → Ev → P → Bool)) :=
  [("submit-authorized", submitAuthorized), ("content-needs-source", contentNeedsSource),
   ("retraction-goes", retractionGoes), ("group-recipients", groupRecipients)]

end Send
