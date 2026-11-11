/-!
# Media revocation: the model

What lets the app display, play or export an attachment's decrypted data: a message–attachment
relation (`message_attachments`) whose message is still there, not erased (deleted for
everyone), and not expired (disappearing). `MediaAvailability.permits(path:messageId:)` and
`MediaAvailability.fetch` read it; the session applies each fetched availability to its open
viewers (`applyMediaAvailability`: the lightbox, the inline video, the playing voice note, the
decoded-pixel cache), and re-checks after an asynchronous decode and after the save panel.
-/

namespace Media

structure Row where
  erased : Bool
  expires : Option Nat
  deriving DecidableEq, Repr

structure Db where
  rows : Nat → Option Row
  /-- `message_attachments`: (message, path), a path being the file, thumbnail or screenshot. -/
  rel : List (Nat × Nat)
  now : Nat

def live (d : Db) (m : Nat) : Bool :=
  match d.rows m with
  | some r => !r.erased && r.expires.all (· > d.now)
  | none => false

/-- `permits(path:messageId:)`: this message's own reference to the file. -/
def permits (d : Db) (m p : Nat) : Bool := live d m && d.rel.contains (m, p)

/-- `permits(path:)` without a message: any live message's reference. -/
def permitsAny (d : Db) (p : Nat) : Bool := d.rel.any fun x => x.2 == p && live d x.1

/-- `fetch`: the live messages' references. -/
def avail (d : Db) : List (Nat × Nat) := d.rel.filter fun x => live d x.1

structure UI where
  lightbox : Option (Nat × List Nat)
  video : Option (Nat × Nat)
  audio : Option (Nat × Nat)
  /-- Paths with decoded pixels (`images` / `imagePaths`). -/
  cache : List Nat
  deriving DecidableEq, Repr

/-- `applyMediaAvailability`, for an availability `a` (the live references). -/
def apply (a : List (Nat × Nat)) (u : UI) : UI where
  lightbox := u.lightbox.filter fun (m, ps) => a.any (·.1 == m) && ps.all fun p => a.contains (m, p)
  video := u.video.filter fun x => a.contains x
  audio := u.audio.filter fun x => a.contains x
  cache := u.cache.filter fun p => a.any (·.2 == p)

-- ## The session

structure S where
  d : Db
  u : UI
  /-- Decodes in flight: (message the viewer shows, path). -/
  decodes : List (Nat × Nat)
  /-- The save panel, open for (message, path). -/
  save : Option (Nat × Nat)
  /-- What was handed to the user: shown in the lightbox, played, exported. -/
  out : List (String × Nat × Nat)

inductive Ev where
  | openLightbox (m : Nat) (ps : List Nat)
  | playVideo (m p : Nat)
  | playAudio (m p : Nat)
  /-- The lightbox asks for a large decode of `p` for message `m`. -/
  | decode (m p : Nat)
  /-- The `k`-th decode finishes. -/
  | decoded (k : Nat)
  | openSave (m p : Nat)
  /-- The save panel returns "Save". -/
  | confirmSave
  | delete (m : Nat)
  | erase (m : Nat)
  | expireAt (m t : Nat)
  | tick
  /-- Another message `m` references file `p` (a forward). -/
  | ref (m p : Nat)
  /-- The availability observation (or the expiry timer) delivers the current state. -/
  | update
  deriving DecidableEq, Repr

def upd {α : Type} (f : Nat → α) (i : Nat) (v : α) : Nat → α := fun x => if x = i then v else f x

def stepCore (s : S) : Ev → S
  | .openLightbox m ps => if ps.all (permits s.d m) then { s with u := { s.u with lightbox := some (m, ps) } } else s
  | .playVideo m p => if permits s.d m p then { s with u := { s.u with video := some (m, p) }, out := s.out ++ [("video", m, p)] } else s
  | .playAudio m p => if permits s.d m p then { s with u := { s.u with audio := some (m, p) }, out := s.out ++ [("audio", m, p)] } else s
  | .decode m p => { s with decodes := s.decodes ++ [(m, p)] }
  | .decoded k => match s.decodes[k]? with
    | some (m, p) =>
      let s := { s with decodes := s.decodes.eraseIdx k }
      if permits s.d m p then { s with u := { s.u with cache := p :: s.u.cache } } else s
    | none => s
  | .openSave m p => if permits s.d m p then { s with save := some (m, p) } else s
  | .confirmSave => match s.save with
    | some (m, p) => if permits s.d m p then { s with save := none, out := s.out ++ [("export", m, p)] } else { s with save := none }
    | none => s
  | .delete m => { s with d := { s.d with rows := upd s.d.rows m none } }
  | .erase m => { s with d := { s.d with rows := upd s.d.rows m ((s.d.rows m).map fun r => { r with erased := true }) } }
  | .expireAt m t => { s with d := { s.d with rows := upd s.d.rows m ((s.d.rows m).map fun r => { r with expires := some t }) } }
  | .tick => { s with d := { s.d with now := s.d.now + 1 } }
  | .ref m p => { s with d := { s.d with rows := if (s.d.rows m).isSome then s.d.rows else upd s.d.rows m (some ⟨false, none⟩), rel := (m, p) :: s.d.rel } }
  | .update => { s with u := apply (avail s.d) s.u }

def step (s : S) (e : Ev) : S := stepCore s e

end Media
