#!/usr/bin/env python3 -I
"""Generate Packages/SignalCodecs/Sources/VideoAV1/AV1Tables.generated.swift from the AV1
specification's own source (github.com/AOMediaCodec/av1-spec, the Markdown the published
specification is built from): every constant table the intra (key-frame) decoding process
uses — scan orders, block / transform geometry, default CDFs, quantiser lookups and matrices,
intra prediction, loop filter / CDEF / loop restoration / superres / film grain constants.

Symbolic values (BLOCK_*, TX_*, DCT_DCT, …) and dimensions resolve through the constants of
03.symbols.md and the enumerations of 07.bitstream.semantics.md. Tables are flattened in C
(row-major) order; the dimensions are kept as `<name>Dims`. Large tables are stored as hex
strings decoded once on first use, which keeps the Swift type checker out of the way.

Usage: Tools/gen-av1-tables.py <av1-spec checkout>
"""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Packages/SignalCodecs/Sources/VideoAV1/AV1Tables.generated.swift")
SPEC = sys.argv[1]

def read(name):
    return open(os.path.join(SPEC, name), encoding="utf-8").read()

consts = {}
ambiguous = set()
def define(name, value):
    if name in consts and consts[name] != value: ambiguous.add(name)
    consts.setdefault(name, value)
symbolRows = re.findall(r"^\|\s*`([A-Z][A-Z0-9_]*)`\s*\|\s*([^|]*?)\s*\|", read("03.symbols.md"), re.M)
# Enumerations: "| value | NAME" rows in the semantics.
for m in re.finditer(r"^\|\s*(\d+)\s*\|\s*([A-Z][A-Z0-9_]+)[ \t]*(?:\||$)", read("07.bitstream.semantics.md"), re.M):
    define(m.group(2), int(m.group(1)))
# "| coded | value | NAME" rows (lr_type → FrameRestorationType).
for m in re.finditer(r"^\|\s*\d+\s*\|\s*(\d+)\s*\|\s*([A-Z][A-Z0-9_]+)[ \t]*(?:\||$)", read("07.bitstream.semantics.md"), re.M):
    define(m.group(2), int(m.group(1)))
consts.setdefault("NONE", -1)

def evaluate(expr):
    expr = expr.strip()
    if not expr:
        raise ValueError("empty")
    for name in re.findall(r"\b[A-Z][A-Z0-9_]*\b", expr):
        # A name whose semantics rows disagree (the CFL_SIGN_* columns of cfl_alpha_signs) is never guessed.
        if name in ambiguous: raise KeyError(f"ambiguous {name}")
    py = re.sub(r"\b([A-Z][A-Z0-9_]*)\b", lambda m: str(consts[m.group(1)]) if m.group(1) in consts else m.group(1), expr)
    if re.search(r"[A-Za-z_]", py):
        raise KeyError(expr)
    return int(eval(" ".join(py.split()), {"__builtins__": {}}))

# Symbols may be defined in terms of earlier ones (e.g. 1 << 6).
for _ in range(4):
    for name, value in symbolRows:
        if name not in consts:
            try: consts[name] = evaluate(value.replace("\\", ""))
            except (KeyError, SyntaxError, ValueError): pass

skip = re.compile(r"^(Obmc_|Wedge_|Ii_Weights|Quant_Dist|Warped_Filters|Div_Lut|Div_Mult|Ref_Frame_List|Compound_Mode_Ctx_Map|"
                  r"Default_(Inter_Intra|Wedge|Use_Obmc|Comp|Compound|Uni_Comp|Motion_Mode|Interp_Filter|New_Mv|Zero_Mv|Ref_Mv|Drl_Mode|"
                  r"Is_Inter|Skip_Mode|Single_Ref|Y_Mode)|T$|CurrFrame)")

tables = {}
src = "".join(read(f) for f in sorted(os.listdir(SPEC)) if re.match(r"\d\d\..*\.md$", f))
for block in re.findall(r"~~~~*\s*c\s*\n(.*?)\n\s*~~~~*", src, re.S):
    for m in re.finditer(r"\b([A-Z][A-Za-z0-9_]*)\s*((?:\[[^\]=]*\]\s*)+)=\s*\{", block):
        name = m.group(1)
        if skip.match(name): continue
        dims = [evaluate(d) for d in re.findall(r"\[([^\]]*)\]", m.group(2))]
        i, depth, start = m.end() - 1, 0, m.end() - 1
        while True:
            if block[i] == "{": depth += 1
            elif block[i] == "}":
                depth -= 1
                if depth == 0: break
            i += 1
        body = re.sub(r"//[^\n]*", "", block[start + 1:i])
        body = re.sub(r"/\*.*?\*/", "", body, flags=re.S)
        try:
            tokens = []
            for v in body.replace("{", ",").replace("}", ",").split(","):
                parts = v.split()
                # The spec source misses a comma in Split_Tx_Size ("TX_32X32 TX_4X8"): operator-free
                # whitespace-separated words are separate values.
                if len(parts) > 1 and all(re.fullmatch(r"-?[A-Za-z0-9_]+", q) for q in parts): tokens += parts
                elif v.strip(): tokens.append(v)
            vals = [evaluate(v) for v in tokens]
        except Exception as e:
            raise SystemExit(f"{name}: {e!r}")
        n = 1
        for d in dims: n *= d
        if len(vals) != n:
            raise SystemExit(f"{name}: {len(vals)} values for dims {dims}")
        if name in tables and tables[name] != (dims, vals):
            raise SystemExit(f"{name}: defined twice, differently")
        tables[name] = (dims, vals)

def swift_type(vals):
    lo, hi = min(vals), max(vals)
    for t, a, b, w in (("UInt8", 0, 255, 2), ("Int8", -128, 127, 2), ("UInt16", 0, 65535, 4), ("Int16", -32768, 32767, 4)):
        if lo >= a and hi <= b: return t, w
    return "Int32", 8

def camel(name):
    parts = name.split("_")
    return parts[0][0].lower() + parts[0][1:] + "".join(p[:1].upper() + p[1:] for p in parts[1:])

out = ["// Generated by Tools/gen-av1-tables.py from the AV1 specification source (av1-spec);",
       "// do not edit. Multi-dimensional tables are flattened row-major; `…Dims` gives their shape.",
       "", "enum AV1Tables {"]
for name in sorted(tables):
    if skip.match(name): continue
    dims, vals = tables[name]
    t, w = swift_type(vals)
    ident = camel(name)
    out.append(f"    /// {name}{''.join(f'[{d}]' for d in dims)}")
    if len(dims) > 1:
        out.append(f"    static let {ident}Dims = [{', '.join(map(str, dims))}]")
    if len(vals) > 1024:
        mask = (1 << (w * 4)) - 1
        hexs = "".join(format(v & mask, f"0{w}x") for v in vals)
        lines = [hexs[i:i + 160] for i in range(0, len(hexs), 160)]
        out.append(f"    static let {ident}: [{t}] = hex(\"\"\"")
        out += [f"        {l}" for l in lines]
        out.append(f"        \"\"\", width: {w}).map {{ {t}(truncatingIfNeeded: $0) }}")
    else:
        rows = [", ".join(map(str, vals[i:i + 24])) for i in range(0, len(vals), 24)]
        out.append(f"    static let {ident}: [{t}] = [")
        out += [f"        {r}," for r in rows]
        out.append("    ]")
out += ["",
        "    /// Fixed-width hex digits (whitespace ignored) → values, sign-extended from `width` digits.",
        "    static func hex(_ s: String, width: Int) -> [Int32] {",
        "        var out: [Int32] = []",
        "        var acc: UInt32 = 0, n = 0",
        "        for c in s.utf8 {",
        "            let d: UInt32",
        "            switch c {",
        "            case 48...57: d = UInt32(c - 48)",
        "            case 97...102: d = UInt32(c - 87)",
        "            default: continue",
        "            }",
        "            acc = acc << 4 | d",
        "            n += 1",
        "            if n == width {",
        "                let bits = UInt32(width * 4)",
        "                let v = bits == 32 ? Int32(bitPattern: acc) : (acc >= 1 << (bits - 1) ? Int32(acc) - Int32(1 << bits) : Int32(acc))",
        "                out.append(v)",
        "                acc = 0",
        "                n = 0",
        "            }",
        "        }",
        "        return out",
        "    }",
        "}", ""]
open(OUT, "w").write("\n".join(out))
print(f"wrote {OUT}: {sum(1 for n in tables if not skip.match(n))} tables")
