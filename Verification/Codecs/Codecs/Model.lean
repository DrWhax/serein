/-!
# Codec components: the model

The parts of SignalCodecs every decoder is built on (`CodecCore`, `ContainerMP4`):

* **`ByteCursor`**: a position inside a region `[start, stop)` of shared bytes; every read checks
  the region (`need`), big- and little-endian integers, no-copy slices (`bytes`, `rest`), skips,
  literals;
* **the grammar combinators** (`Parser`, `Grammar`): sequencing; `region` and `lengthPrefixed`,
  which run a sub-grammar on a new cursor bounded to exactly the declared length and require it to
  consume all of it; `repeated` (a count checked against its limit before any work) and
  `repeatedToEnd` (a limit, and progress on every item); `oneOf` (ordered choice, the furthest
  failure reported);
* **the MP4/HEIF box walker** (`BoxGrammar.children`): size fields (32-bit, 64-bit `largesize`, 0 =
  to the end at top level), `uuid` user types, bodies within their container, a box budget shared
  by the whole file, a truncated final `mdat` at top level;
* **the MSB-first bit reader** (`MSBBitReader`), against its specification: `bits n` is the next
  `n` bits of the bytes, then zeros (`zeroFill`) or a failure (`fail`).

Bytes are a list of numbers; offsets are absolute.
-/

namespace Codecs

/-! ## Failures -/

inductive Kind | unexpectedEnd | mismatch | invalid | limit | trailing
  deriving DecidableEq, Repr

structure Fail where
  offset : Nat
  kind : Kind
  deriving DecidableEq, Repr

/-! ## The cursor -/

structure Cursor where
  start : Nat
  pos : Nat
  stop : Nat
  deriving DecidableEq, Repr

def byteAt (bs : List Nat) (i : Nat) : Nat := bs.getD i 0

def be (bs : List Nat) (p k : Nat) : Nat := (List.range k).foldl (fun acc i => acc * 256 + byteAt bs (p + i)) 0
def le (bs : List Nat) (p k : Nat) : Nat := (List.range k).foldr (fun i acc => acc * 256 + byteAt bs (p + i)) 0

/-- `need`: `n` bytes are left in the region. -/
def need (c : Cursor) (n : Int) : Bool := 0 ≤ n && n ≤ ((c.stop - c.pos : Nat) : Int)

inductive Prim
  | u8 | u16be | u16le | u24be | u24le | u32be | u32le | u64be
  | bytes (n : Int)
  | skip (n : Int)
  | expect (lit : List Nat)
  | rest
  deriving DecidableEq, Repr

/-- A value read: a number, or a slice handed out (absolute bounds). -/
inductive Val | num (v : Nat) | slice (lo hi : Nat) | unit
  deriving DecidableEq, Repr

def advance (c : Cursor) (n : Nat) : Cursor := { c with pos := c.pos + n }

def fixedRead (bs : List Nat) (c : Cursor) (k : Nat) (big : Bool) : Except Fail (Val × Cursor) :=
  if need c k then .ok (.num (if big then be bs c.pos k else le bs c.pos k), advance c k)
  else .error ⟨c.pos, .unexpectedEnd⟩

def prim (bs : List Nat) (c : Cursor) : Prim → Except Fail (Val × Cursor)
  | .u8 => fixedRead bs c 1 true
  | .u16be => fixedRead bs c 2 true
  | .u16le => fixedRead bs c 2 false
  | .u24be => fixedRead bs c 3 true
  | .u24le => fixedRead bs c 3 false
  | .u32be => fixedRead bs c 4 true
  | .u32le => fixedRead bs c 4 false
  | .u64be => match fixedRead bs c 4 true with
    | .ok (.num hi, c1) => match fixedRead bs c1 4 true with
      | .ok (.num lo, c2) => .ok (.num (hi * 4294967296 + lo), c2)
      | .ok _ => .error ⟨c1.pos, .invalid⟩
      | .error e => .error e
    | .ok _ => .error ⟨c.pos, .invalid⟩
    | .error e => .error e
  | .bytes n => if need c n then .ok (.slice c.pos (c.pos + n.toNat), advance c n.toNat) else .error ⟨c.pos, .unexpectedEnd⟩
  | .skip n => if need c n then .ok (.unit, advance c n.toNat) else .error ⟨c.pos, .unexpectedEnd⟩
  | .expect lit =>
    if !need c lit.length then .error ⟨c.pos, .unexpectedEnd⟩
    else if (List.range lit.length).all fun i => byteAt bs (c.pos + i) == lit.getD i 0 then .ok (.unit, advance c lit.length)
    else .error ⟨c.pos, .mismatch⟩
  | .rest => .ok (.slice c.pos c.stop, { c with pos := c.stop })

/-! ## Grammars -/

inductive G
  | prim (p : Prim)
  | seq (a b : G)
  /-- `Grammar.region`: the next `n` bytes, consumed completely by `g`. -/
  | region (n : Int) (g : G)
  /-- `Grammar.lengthPrefixed` with a `u8`, `u16be` or `u32be` length of at most `max`. -/
  | lenPrefixed (w : Prim) (max : Nat) (g : G)
  /-- `repeated(count:maxCount:)`. -/
  | repeated (count : Int) (max : Nat) (g : G)
  /-- `repeatedToEnd(maxCount:)`. -/
  | toEnd (max : Nat) (g : G)
  /-- `Grammar.oneOf([a, b])`. -/
  | oneOf (a b : G)
  deriving Repr

/-- A run's result: the cursor after it, every byte range it read or handed out, and how many
items its repetitions allocated. -/
structure R where
  c : Cursor
  reads : List (Nat × Nat)
  items : Nat
  deriving Repr

def readRange (c c' : Cursor) (v : Val) : List (Nat × Nat) :=
  match v with
  | .slice lo hi => [(c.pos, c'.pos), (lo, hi)]
  | _ => [(c.pos, c'.pos)]

/-- Runs `f` `k` times from `r`, adding up what it reads and allocates. -/
def iterate (f : Cursor → Except Fail R) : Nat → R → Except Fail R
  | 0, r => .ok r
  | k + 1, r => match f r.c with
    | .ok r' => iterate f k ⟨r'.c, r.reads ++ r'.reads, r.items + r'.items + 1⟩
    | .error e => .error e

/-- `repeatedToEnd`: items until the region's end, at most `max` of them (`n` so far), each
consuming something. -/
def toEndLoop (f : Cursor → Except Fail R) (max : Nat) : Nat → Nat → R → Except Fail R
  | 0, _, r => if r.c.pos < r.c.stop then .error ⟨r.c.pos, .invalid⟩ else .ok r
  | fuel + 1, n, r =>
    if r.c.stop ≤ r.c.pos then .ok r
    else if max ≤ n then .error ⟨r.c.pos, .limit⟩
    else match f r.c with
      | .ok r' => if r'.c.pos == r.c.pos then .error ⟨r.c.pos, .invalid⟩
                  else toEndLoop f max fuel (n + 1) ⟨r'.c, r.reads ++ r'.reads, r.items + r'.items + 1⟩
      | .error e => .error e

/-- A sub-grammar on exactly `[lo, hi)`, required to consume it all. -/
def complete (f : Cursor → Except Fail R) (lo hi : Nat) : Except Fail R :=
  match f ⟨lo, lo, hi⟩ with
  | .ok r => if r.c.pos == hi then .ok r else .error ⟨r.c.pos, .trailing⟩
  | .error e => .error e

def run (bs : List Nat) : G → Cursor → Except Fail R
  | .prim p, c => match prim bs c p with
    | .ok (v, c') => .ok ⟨c', readRange c c' v, 0⟩
    | .error e => .error e
  | .seq a b, c => match run bs a c with
    | .ok ra => match run bs b ra.c with
      | .ok rb => .ok ⟨rb.c, ra.reads ++ rb.reads, ra.items + rb.items⟩
      | .error e => .error e
    | .error e => .error e
  | .region n g, c =>
    if need c n then
      match complete (run bs g) c.pos (c.pos + n.toNat) with
      | .ok r => .ok ⟨advance c n.toNat, (c.pos, c.pos + n.toNat) :: r.reads, r.items⟩
      | .error e => .error e
    else .error ⟨c.pos, .unexpectedEnd⟩
  | .lenPrefixed w max g, c => match prim bs c w with
    | .ok (.num len, c1) =>
      if max < len then .error ⟨c.pos, .limit⟩
      else if need c1 len then
        match complete (run bs g) c1.pos (c1.pos + len) with
        | .ok r => .ok ⟨advance c1 len, (c.pos, c1.pos + len) :: r.reads, r.items⟩
        | .error e => .error e
      else .error ⟨c1.pos, .unexpectedEnd⟩
    | .ok _ => .error ⟨c.pos, .invalid⟩
    | .error e => .error e
  | .repeated count max g, c =>
    if count < 0 then .error ⟨c.pos, .invalid⟩
    else if (max : Int) < count then .error ⟨c.pos, .limit⟩
    else iterate (run bs g) count.toNat ⟨c, [], 0⟩
  | .toEnd max g, c => toEndLoop (run bs g) max (c.stop - c.pos + 1) 0 ⟨c, [], 0⟩
  | .oneOf a b, c => match run bs a c with
    | .ok r => .ok r
    | .error ea => match run bs b c with
      | .ok r => .ok r
      | .error eb => .error (if ea.offset < eb.offset then eb else ea)

/-- `Parser.parseComplete` over the whole input. -/
def parseComplete (bs : List Nat) (g : G) : Except Fail R := complete (run bs g) 0 bs.length

/-- What a grammar can allocate, from its limits alone. -/
def budget : G → Nat
  | .prim _ => 0
  | .seq a b => budget a + budget b
  | .region _ g => budget g
  | .lenPrefixed _ _ g => budget g
  | .repeated _ max g => max * (1 + budget g)
  | .toEnd max g => max * (1 + budget g)
  | .oneOf a b => Nat.max (budget a) (budget b)

/-! ## The box walker -/

structure Box where
  type : Nat
  offset : Nat
  lo : Nat
  hi : Nat
  deriving DecidableEq, Repr

def uuid : Nat := 0x75756964
def mdat : Nat := 0x6d646174

/-- One box header at `pos` (in `[pos, hi)`): its type, where its body starts, and its declared
total size (`none`: to the end, size 0). -/
def header (bs : List Nat) (pos hi : Nat) (top : Bool) : Except Fail (Nat × Nat × Nat) :=
  let size32 := be bs pos 4
  let type := be bs (pos + 4) 4
  let p := pos + 8
  -- (type, body start, total size)
  let sized : Except Fail (Nat × Nat) :=
    if size32 == 1 then
      -- `u64be` is two `u32be` reads.
      if hi - p < 4 then .error ⟨p, .unexpectedEnd⟩
      else if hi - p < 8 then .error ⟨p + 4, .unexpectedEnd⟩
      else .ok (p + 8, be bs p 8)
    else if size32 == 0 then
      if top then .ok (p, hi - p + 8) else .error ⟨p, .invalid⟩
    else .ok (p, size32)
  match sized with
  | .error e => .error e
  | .ok (p, size) =>
    if type == uuid then
      if hi - p < 16 then .error ⟨p, .unexpectedEnd⟩ else .ok (type, p + 16, size)
    else .ok (type, p, size)

/-- `BoxGrammar.children` over `[lo, hi)`; `count` is the file's box count so far. -/
def boxes (bs : List Nat) (hi : Nat) (top : Bool) (maxBoxes : Nat) : Nat → Nat → List Box → Nat → Except Fail (List Box × Nat)
  | 0, _, out, count => .ok (out, count)
  | fuel + 1, pos, out, count =>
    if hi ≤ pos then .ok (out, count)
    else if hi - pos < 8 then (if top then .ok (out, count) else .error ⟨pos, .unexpectedEnd⟩)
    else match header bs pos hi top with
      | .error e => .error e
      | .ok (type, p, size) =>
        let headerLen := p - pos
        if size < headerLen then .error ⟨p, .invalid⟩
        else
          let body := size - headerLen
          if hi - p < body then
            if top && type == mdat then
              if maxBoxes < count + 1 then .error ⟨p, .limit⟩
              else .ok (out ++ [⟨type, pos, p, hi⟩], count + 1)
            else .error ⟨p, .unexpectedEnd⟩
          else if maxBoxes < count + 1 then .error ⟨p, .limit⟩
          else boxes bs hi top maxBoxes fuel (p + body) (out ++ [⟨type, pos, p, p + body⟩]) (count + 1)

def children (bs : List Nat) (lo hi : Nat) (top : Bool) (count maxBoxes : Nat) : Except Fail (List Box × Nat) :=
  boxes bs hi top maxBoxes (hi - lo + 1) lo [] count

/-! ## The bit reader (its specification) -/

def bitAt (bs : List Nat) (i : Nat) : Nat := if i < 8 * bs.length then (byteAt bs (i / 8) / 2 ^ (7 - i % 8)) % 2 else 0

def bitsVal (bs : List Nat) (p n : Nat) : Nat := (List.range n).foldl (fun acc i => acc * 2 + bitAt bs (p + i)) 0

/-- Bits consumed, and whether reading went past the end (zero fill). -/
structure Bits where
  pos : Nat
  exhausted : Bool
  deriving DecidableEq, Repr

def readBits (bs : List Nat) (zeroFill : Bool) (r : Bits) (n : Nat) : Except Fail (Nat × Bits) :=
  if n == 0 then .ok (0, r)
  else if r.pos + n ≤ 8 * bs.length then .ok (bitsVal bs r.pos n, { r with pos := r.pos + n })
  else if zeroFill then .ok (bitsVal bs r.pos n, ⟨8 * bs.length, true⟩)
  else .error ⟨bs.length, .unexpectedEnd⟩

def peekBits (bs : List Nat) (r : Bits) (n : Nat) : Nat := bitsVal bs r.pos n

def align (r : Bits) : Bits := { r with pos := (r.pos + 7) / 8 * 8 }

end Codecs
