import Media.Model

/-! # The properties, as checks on one step -/

namespace Media

def newOut (s s' : S) : List (String × Nat × Nat) := s'.out.drop s.out.length

/-- **Export, playback and opening need the message's own reference, now**: everything handed
out in a step (an export after the save panel returns, a video or voice note started) is
permitted by its message in the state of that step. -/
def handedOutPermitted (s : S) (_e : Ev) (s' : S) : Bool :=
  s'.out.length ≥ s.out.length && (newOut s s').all fun (_, m, p) => permits s.d m p

/-- **Expiry during decoding**: a finished decode enters the cache only if its message still
permits the file when it finishes. -/
def decodePermitted (s : S) (e : Ev) (s' : S) : Bool :=
  match e with
  | .decoded k => match s.decodes[k]? with
    | some (m, p) => s'.u.cache == s.u.cache || (s'.u.cache == p :: s.u.cache && permits s.d m p)
    | none => s'.u.cache == s.u.cache
  | .update => s'.u.cache.all (s.u.cache.contains ·)
  | _ => s'.u.cache == s.u.cache

/-- **An update closes what is no longer permitted**: after an availability update, the open
lightbox's message is live and references every file it shows; the inline video and the voice
note are their messages' own live references; every cached file is still referenced by some live
message. -/
def updateRevokes (_s : S) (e : Ev) (s' : S) : Bool :=
  match e with
  | .update =>
    (s'.u.lightbox.all fun (m, ps) => live s'.d m && ps.all fun p => permits s'.d m p) &&
    (s'.u.video.all fun (m, p) => permits s'.d m p) &&
    (s'.u.audio.all fun (m, p) => permits s'.d m p) &&
    s'.u.cache.all (permitsAny s'.d)
  | _ => true

def stepChecks : List (String × (S → Ev → S → Bool)) :=
  [("handed-out-permitted", handedOutPermitted), ("decode-permitted", decodePermitted), ("update-revokes", updateRevokes)]

end Media
