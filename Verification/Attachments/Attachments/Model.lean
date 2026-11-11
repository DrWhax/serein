/-!
# Attachment authentication and processing: the model

**Decryption** (`AttachmentCipher.decrypt`), on what a downloaded blob and its pointer are:
the keys' length, the blob's length, whether its HMAC tag verifies, the incremental MAC, and the
integrity source (the pointer's digest of the blob, else a plaintext hash, or nothing for local
files). The checks run in production's order; the plaintext is the padded plaintext trimmed to the
pointer's size.

**The pipeline** (`AttachmentDownloadManager.download` and `run`, `AttachmentStore`): an
attachment whose size is beyond the incoming limit is too big; the response is read no further
than its ciphertext size plus a margin (`HTTPClient.bounded`); the blob is decrypted, re-encrypted
under a fresh local key and written; only then is the path published. A consumer (decoding,
export, the thumbnail) reads a published path through `decryptLocal`, whose MAC check fails on a
file changed on disk.

**The cryptographic contracts** are assumptions, not proved: a blob's tag verifies under an
upload's keys only if it is that upload's blob (the MAC is unforgeable and the keys are secret);
the digest matches only that blob (SHA-256 is collision resistant); a local file's tag verifies
only if it is the file written. They are how the pipeline turns a CDN response into the decryption
descriptors (`describe`).
-/

namespace Attachments

/-! ## Decryption -/

inductive Err | badKey | tooShort | badMAC | badIncrementalMAC | badPadding | missingDigest | badDigest | badPlaintextHash
  deriving DecidableEq, Repr

/-- The incremental MAC: absent (or chunk size 0), valid, invalid, or a chunk size no pointer can
carry. -/
inductive Inc | none | ok | bad | huge
  deriving DecidableEq, Repr

inductive Integrity
  /-- The pointer's digest: empty, or whether it is the blob's. -/
  | digest (empty good : Bool)
  /-- A plaintext hash: whether it is the trimmed plaintext's. -/
  | hash (good : Bool)
  /-- A local file: the MAC alone. -/
  | macOnly
  deriving DecidableEq, Repr

structure Blob where
  keyOK : Bool
  len : Nat
  macOK : Bool
  inc : Inc
  integrity : Integrity
  size : Nat
  /-- AES-256-CBC's result: the length once its PKCS#7 padding is removed, or `none` if that
  padding is invalid. -/
  plain : Option Nat
  deriving DecidableEq, Repr

def ivLength : Nat := 16
def macLength : Nat := 32

/-- IV, at least one AES block, the tag; whole blocks. -/
def shapeOK (len : Nat) : Bool := ivLength + 16 + macLength ≤ len && (len - ivLength - macLength) % 16 == 0

/-- `AttachmentCipher.decrypt`: the plaintext's length, or the first check that fails. -/
def decrypt (b : Blob) : Except Err Nat :=
  if !b.keyOK then .error .badKey
  else if !shapeOK b.len then .error .tooShort
  else if !b.macOK then .error .badMAC
  else if b.inc == .bad || b.inc == .huge then .error .badIncrementalMAC
  else match b.plain with
  | none => .error .badPadding
  | some p =>
    let n := min b.size p
    match b.integrity with
    | .digest empty good => if empty then .error .missingDigest else if !good then .error .badDigest else .ok n
    | .hash good => if !good then .error .badPlaintextHash else .ok n
    | .macOnly => .ok n

/-! ## The pipeline -/

/-- `ciphertextSize` and the response bound (`maxResponseBytes`): the margin is 64 KiB. -/
def ciphertextSize (pad : Nat) : Nat := ivLength + (1 + pad / 16) * 16 + macLength
def margin : Nat := 65536

inductive St | pending | published | error | tooBig
  deriving DecidableEq, Repr

structure Att where
  id : Nat
  /-- The upload its pointer names (ghost); the pointer's size; the upload's real plaintext
  length and the length the sender padded it to; the padding bucket of the pointer's size (what
  the response bound is computed from). -/
  upload : Nat
  size : Nat
  plainLen : Nat
  pad : Nat
  bucket : Nat
  /-- The pointer carries a digest, else a plaintext hash, else neither. -/
  hasDigest : Bool
  hasHash : Bool
  st : St
  path : Option Nat
  deriving DecidableEq, Repr

structure File where
  path : Nat
  /-- The upload whose plaintext it holds (`none`: anything else). -/
  content : Option Nat
  /-- Its local MAC verifies (false once changed on disk). -/
  intact : Bool
  len : Nat
  deriving DecidableEq, Repr

/-- What the CDN returns: its length, and whether it is byte for byte some upload's blob. -/
structure Resp where
  len : Nat
  genuine : Option Nat
  deriving DecidableEq, Repr

structure S where
  atts : List Att
  files : List File
  nextPath : Nat
  maxSize : Nat
  /-- Ghost: what consumers were handed (attachment, content, length), and the bytes each
  download held. -/
  delivered : List (Nat × Option Nat × Nat)
  fetched : List (Nat × Nat)
  deriving Repr

/-- The decryption descriptors of a response, by the contracts: the tag and the digest verify
exactly for the upload's own blob. -/
def describe (a : Att) (r : Resp) : Blob :=
  let own := r.genuine == some a.upload
  { keyOK := true, len := r.len, macOK := own, inc := .none,
    integrity := if a.hasDigest then .digest false own else if a.hasHash then .hash (own && a.size == a.plainLen) else .digest true false,
    size := a.size, plain := some a.pad }

def setAtt (atts : List Att) (id : Nat) (f : Att → Att) : List Att := atts.map fun x => if x.id == id then f x else x

/-- `download` + `run` for attachment `id` and response `r`. -/
def download (s : S) (id : Nat) (r : Resp) : S :=
  match s.atts.find? (·.id == id) with
  | none => s
  | some a =>
    if a.st != .pending then s
    else if s.maxSize < a.size then { s with atts := setAtt s.atts id ({ · with st := .tooBig }) }
    else
      let cap := ciphertextSize a.bucket + margin
      let held := min r.len (cap + 1)
      let s := { s with fetched := s.fetched ++ [(id, held)] }
      -- Read no further than the bound: the transfer stops and is retried later (still pending).
      if cap < r.len then s
      else match decrypt (describe a r) with
        | .ok n =>
          let p := s.nextPath
          { s with files := s.files ++ [⟨p, r.genuine, true, n⟩], nextPath := p + 1,
                   atts := setAtt s.atts id ({ · with st := .published, path := some p }) }
        | .error _ => { s with atts := setAtt s.atts id ({ · with st := .error }) }

/-- A consumer reads attachment `id`: its published file, through the local MAC. -/
def consume (s : S) (id : Nat) : S :=
  match s.atts.find? (·.id == id) with
  | some { st := .published, path := some p, .. } =>
    match s.files.find? (·.path == p) with
    | some f => if f.intact then { s with delivered := s.delivered ++ [(id, f.content, f.len)] } else s
    | none => s
  | _ => s

inductive Ev
  /-- A new attachment from a message (pending). -/
  | arrive (a : Att)
  | download (id : Nat) (r : Resp)
  | consume (id : Nat)
  /-- A file is changed on disk. -/
  | tamper (path : Nat)
  deriving Repr

def step (s : S) : Ev → S
  | .arrive a =>
    if s.atts.any (·.id == a.id) then s else { s with atts := s.atts ++ [{ a with st := .pending, path := none }] }
  | .download id r => download s id r
  | .consume id => consume s id
  | .tamper p => { s with files := s.files.map fun f => if f.path == p then { f with intact := false } else f }

def S.init (maxSize : Nat) : S := ⟨[], [], 0, maxSize, [], []⟩

inductive Reach (maxSize : Nat) : S → Prop
  | init : Reach maxSize (S.init maxSize)
  | step {s} (e : Ev) : Reach maxSize s → Reach maxSize (step s e)

end Attachments
