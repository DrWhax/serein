import Resend.Model

/-!
# The properties

* **The log records deliveries** (`Logged`): every device the log lists for a payload was
  delivered that payload by a send.
* **A retry gets back only what that device was sent, and only the requester gets it**
  (`ResentDelivered`): every answer goes to the requester; one carrying a payload carries one
  delivered to the very device that asked, at the timestamp it asked about. So a requester never
  obtains another recipient's plaintext, a message from a conversation it was not sent, or
  anything it was never delivered.
* **Answers are bounded** (`Bounded`): at most `retryLimit` per (requester, device, timestamp).
-/

namespace Resend

def Logged (s : S) : Prop :=
  ∀ r ∈ s.rows, ∃ p ∈ s.payloads, p.id = r.id ∧ (p.ts, p.content, r.recipient, r.device) ∈ s.delivered

def ResentDelivered (s : S) : Prop :=
  ∀ o ∈ s.out, o.dest = o.requester ∧ ∀ c, o.carried = some c → c.1 = o.ts ∧ (c.1, c.2, o.requester, o.device) ∈ s.delivered

def outCount (s : S) (k : Nat × Nat × Nat) : Nat := (s.out.filter fun o => o.requester == k.1 && o.device == k.2.1 && o.ts == k.2.2).length

def Bounded (s : S) : Prop := ∀ k, outCount s k ≤ retryLimit

/-! ## Checks of one state (the explorer) -/

def loggedB (s : S) : Bool := s.rows.all fun r => s.payloads.any fun p => p.id == r.id && s.delivered.contains (p.ts, p.content, r.recipient, r.device)

def resentDeliveredB (s : S) : Bool := s.out.all fun o => o.dest == o.requester && match o.carried with
  | some c => c.1 == o.ts && s.delivered.contains (c.1, c.2, o.requester, o.device)
  | none => true

def boundedB (s : S) : Bool := s.out.all fun o => outCount s (o.requester, o.device, o.ts) ≤ retryLimit

def checks (s : S) : List (String × Bool) :=
  [("logged", loggedB s), ("resent-delivered", resentDeliveredB s), ("bounded", boundedB s)]

end Resend
