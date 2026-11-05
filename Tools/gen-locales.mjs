#!/usr/bin/env node
// Generates the SignalI18n package's data from upstream and from the CLDR data that
// Signal Desktop's own formatter (formatjs on top of V8's Intl / ICU) uses at runtime.
//
//   .cache/node-v24.22.0-darwin-arm64/bin/node Tools/gen-locales.mjs
//
// Inputs
//   Signal-Desktop/_locales/<locale>/messages.json   (68 locales, `icu:*` keys, `messageformat`)
//   Signal-Desktop/build/available-locales.json      (the locale list upstream ships)
//   Node's built-in ICU data (icudt78l, CLDR 48): `plurals.res` is read straight out of the
//     ICU common data embedded in the running node binary. No make-plural /
//     @formatjs/intl-pluralrules exists in either node_modules tree, and this is exactly
//     the rule data Intl.PluralRules (and therefore formatjs) evaluates.
//   Intl.NumberFormat / Intl.Locale of the same node, for number symbols and direction.
//
// Outputs (Packages/SignalI18n/Sources/SignalI18n/...)
//   Resources/Locales/keys.json          sorted union of message keys (upstream's
//                                        build/compact-locales layout)
//   Resources/Locales/<locale>.json      [string|null] aligned with keys.json; null = not
//                                        translated (the runtime falls back to en)
//   Generated/PluralRules.generated.swift   every CLDR cardinal + ordinal rule set used
//   Generated/LocaleData.generated.swift    per-locale plural sets, number symbols, direction
//   Generated/UnicodeSets.generated.swift   the code point sets the ICU grammar refers to
//
// Every extracted table is self-checked against Intl before anything is written.
import { readFileSync, writeFileSync, mkdirSync, readdirSync, rmSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const upstream = join(root, 'Signal-Desktop');
const pkg = join(root, 'Packages/SignalI18n/Sources/SignalI18n');
const resDir = join(pkg, 'Resources/Locales');
const genDir = join(pkg, 'Generated');

const fail = (msg) => { console.error(`gen-locales: ${msg}`); process.exit(1); };
if (!process.versions.icu) fail('node was built without ICU');

// ---------------------------------------------------------------------------
// 1. Messages → compact per-locale JSON
// ---------------------------------------------------------------------------
const locales = JSON.parse(readFileSync(join(upstream, 'build/available-locales.json'), 'utf8'));
const onDisk = readdirSync(join(upstream, '_locales')).filter((d) => existsSync(join(upstream, '_locales', d, 'messages.json')));
if (onDisk.length !== locales.length || !locales.every((l) => onDisk.includes(l))) {
  fail(`available-locales.json (${locales.length}) and _locales (${onDisk.length}) disagree`);
}
const isMessage = (v) => typeof v === 'object' && v != null && Object.hasOwn(v, 'messageformat') && typeof v.messageformat === 'string';
const messages = {};
for (const loc of locales) {
  messages[loc] = JSON.parse(readFileSync(join(upstream, '_locales', loc, 'messages.json'), 'utf8'));
}
// Same key set and order as upstream's scripts/generate-compact-locales.mjs.
const keys = Array.from(new Set(locales.flatMap((loc) => Object.entries(messages[loc]).filter(([, v]) => isMessage(v)).map(([k]) => k)))).sort();
rmSync(resDir, { recursive: true, force: true });
mkdirSync(resDir, { recursive: true });
writeFileSync(join(resDir, 'keys.json'), JSON.stringify(keys));
let totalStrings = 0;
for (const loc of locales) {
  const values = keys.map((k) => (isMessage(messages[loc][k]) ? messages[loc][k].messageformat : null));
  totalStrings += values.filter((v) => v != null).length;
  writeFileSync(join(resDir, `${loc}.json`), JSON.stringify(values));
}
const enMissing = keys.filter((k) => !isMessage(messages.en[k]));
if (enMissing.length) fail(`keys missing from en: ${enMissing.join(', ')}`);

// ---------------------------------------------------------------------------
// 2. ICU common data → plurals.res (CLDR plural rules)
// ---------------------------------------------------------------------------
function loadIcuPackage() {
  const b = readFileSync(process.execPath);
  const magic = Buffer.from('CmnD');
  for (let at = b.indexOf(magic); at >= 0; at = b.indexOf(magic, at + 1)) {
    const h = at - 12; // DataHeader: u16 headerSize, 0xda 0x27, UDataInfo{u16 size, u16, u8 x4, dataFormat[4]}
    if (h < 0 || b[h + 2] !== 0xda || b[h + 3] !== 0x27 || b[h + 8] !== 0 /* little endian */) continue;
    const toc = h + b.readUInt16LE(h);
    const count = b.readUInt32LE(toc);
    const items = new Map();
    for (let i = 0; i < count; i++) {
      let p = toc + b.readUInt32LE(toc + 4 + i * 8);
      let name = '';
      while (b[p]) name += String.fromCharCode(b[p++]);
      items.set(name.replace(/^icudt\d+[lb]\//, ''), toc + b.readUInt32LE(toc + 8 + i * 8));
    }
    return { b, items };
  }
  fail('ICU common data (CmnD) not found in the node binary');
}

// Minimal ICU resource bundle (ResB formatVersion 2/3) reader: strings and tables only,
// which is all plurals.res contains.
function readResourceBundle(b, start) {
  if (b.readUInt16LE(start + 2) !== 0x27da || b.toString('latin1', start + 12, start + 16) !== 'ResB') fail('not a ResB');
  if (b[start + 16] < 2) fail('ResB formatVersion < 2');
  const base = start + b.readUInt16LE(start);
  const u32 = (i) => b.readUInt32LE(base + i * 4);
  const keysTop = u32(2);
  const p16 = base + keysTop * 4;
  const key = (off) => { let p = base + off, s = ''; while (b[p]) s += String.fromCharCode(b[p++]); return s; };
  const string16 = (off) => {
    let p = p16 + off * 2;
    const u = b.readUInt16LE(p);
    let len = -1;
    if (u >= 0xdc00 && u < 0xdfef) { len = u & 0x3ff; p += 2; }
    else if (u >= 0xdfef && u < 0xdfff) { len = ((u - 0xdfef) << 16) | b.readUInt16LE(p + 2); p += 4; }
    else if (u === 0xdfff) { len = (b.readUInt16LE(p + 2) << 16) | b.readUInt16LE(p + 4); p += 6; }
    if (len < 0) { let e = p; while (b.readUInt16LE(e)) e += 2; return b.toString('utf16le', p, e); }
    return b.toString('utf16le', p, p + len * 2);
  };
  const resource = (r) => {
    const type = r >>> 28, off = r & 0x0fffffff;
    switch (type) {
      case 0: { if (!off) return ''; const p = base + off * 4; return b.toString('utf16le', p + 4, p + 4 + b.readInt32LE(p) * 2); }
      case 6: return string16(off);
      case 2: { // TABLE: u16 count, u16 keys[count], pad, u32 items[count]
        const o = {}; if (!off) return o;
        const p = base + off * 4, n = b.readUInt16LE(p), items = p + 2 + n * 2 + ((n + 1) % 2) * 2;
        for (let i = 0; i < n; i++) o[key(b.readUInt16LE(p + 2 + i * 2))] = resource(b.readUInt32LE(items + i * 4));
        return o;
      }
      case 5: { // TABLE16: u16 count, u16 keys[count], u16 string16 items[count]
        const o = {}, p = p16 + off * 2, n = b.readUInt16LE(p);
        for (let i = 0; i < n; i++) o[key(b.readUInt16LE(p + 2 + i * 2))] = string16(b.readUInt16LE(p + 2 + n * 2 + i * 2));
        return o;
      }
      case 4: { // TABLE32
        const o = {}, p = base + off * 4, n = b.readInt32LE(p);
        for (let i = 0; i < n; i++) o[key(b.readInt32LE(p + 4 + i * 4))] = resource(b.readUInt32LE(p + 4 + n * 4 + i * 4));
        return o;
      }
      default: fail(`unsupported resource type ${type} in plurals.res`);
    }
  };
  return resource(u32(0));
}

const icu = loadIcuPackage();
if (!icu.items.has('plurals.res')) fail('plurals.res not in ICU data');
const plurals = readResourceBundle(icu.b, icu.items.get('plurals.res'));

// CLDR plural rule grammar (UTS #35 Part 3 §5.1, the subset CLDR 48 uses):
//   condition     = and_condition ('or' and_condition)*
//   and_condition = relation ('and' relation)*
//   relation      = operand ('%' value)? ('=' | '!=') range_list
//   range_list    = (value | value '..' value) (',' range_list)*
//   operand       = 'n' | 'i' | 'v' | 'w' | 'f' | 't' | 'c' | 'e'
// Samples (@integer / @decimal ...) are dropped.
function parseRule(text) {
  const src = text.split('@')[0].trim();
  if (src === '') return [];
  const toks = src.match(/\.\.|!=|[=%,]|[a-z]+|\d+/g);
  if (toks.join('') !== src.replace(/\s+/g, '')) fail(`bad plural rule: ${text}`);
  let p = 0;
  const peek = () => toks[p];
  const take = (t) => { if (t && toks[p] !== t) fail(`expected ${t} in ${text}`); return toks[p++]; };
  const num = () => { const t = take(); if (!/^\d+$/.test(t)) fail(`expected number in ${text}`); return Number(t); };
  const relation = () => {
    const operand = take();
    if (!/^[niwvftce]$/.test(operand)) fail(`bad operand ${operand} in ${text}`);
    let mod = 0;
    if (peek() === '%') { take('%'); mod = num(); }
    const op = take();
    if (op !== '=' && op !== '!=') fail(`bad operator ${op} in ${text}`);
    const ranges = [];
    do {
      if (peek() === ',') take(',');
      const lo = num();
      let hi = lo;
      if (peek() === '..') { take('..'); hi = num(); }
      ranges.push([lo, hi]);
    } while (peek() === ',');
    return { operand, mod, negated: op === '!=', ranges };
  };
  const or = [];
  do {
    if (peek() === 'or') take('or');
    const and = [relation()];
    while (peek() === 'and') { take('and'); and.push(relation()); }
    or.push(and);
  } while (peek() === 'or');
  if (p !== toks.length) fail(`trailing tokens in ${text}`);
  return or;
}

const CATEGORY_ORDER = ['zero', 'one', 'two', 'few', 'many', 'other'];
const ruleSets = new Map(); // ICU set name -> [[category, ast, text]] in ICU's evaluation (resource) order
for (const [name, table] of Object.entries(plurals.rules)) {
  const entries = Object.entries(table);
  for (const [cat] of entries) if (!CATEGORY_ORDER.includes(cat)) fail(`unknown plural category ${cat}`);
  ruleSets.set(name, entries.map(([cat, text]) => [cat, parseRule(text), text.split('@')[0].trim()]));
}

// Operands exactly as ICU computes them for Intl.PluralRules.select(x) with the default
// options (minimumFractionDigits 0, maximumFractionDigits 3, roundingMode halfExpand):
// the shortest round-trip decimal of x is rounded to 3 fraction digits; n = |value| as a
// double, i = the low 18 integer digits (DecimalQuantity::toLong(true)) as a double.
function shortestDigits(x) {
  // -> { digits: '123', exp } meaning 0.123 × 10^exp; digits has no leading/trailing zeros
  const s = Math.abs(x).toExponential().split('e'); // shortest round-trip mantissa
  let digits = s[0].replace('.', '');
  let exp = Number(s[1]) + 1;
  digits = digits.replace(/0+$/, '');
  if (digits === '') return { digits: '', exp: 0 };
  return { digits, exp };
}
function roundDigits({ digits, exp }, maxFrac) {
  const keep = exp + maxFrac; // number of digits to keep
  if (digits.length <= keep) return { digits, exp };
  if (keep < 0) return { digits: '', exp: 0 };
  let kept = digits.slice(0, keep).split('').map(Number);
  if (Number(digits[keep]) >= 5) {
    let i = kept.length - 1;
    while (i >= 0 && kept[i] === 9) { kept[i] = 0; i--; }
    if (i < 0) { kept.unshift(1); exp++; } else kept[i]++;
  }
  const out = kept.join('').replace(/0+$/, '');
  return out === '' ? { digits: '', exp: 0 } : { digits: out, exp };
}
function operands(x) {
  const r = roundDigits(shortestDigits(x), 3);
  const intDigits = r.exp > 0 ? (r.digits.slice(0, r.exp).padEnd(r.exp, '0')) : '0';
  const frac = r.exp >= 0 ? r.digits.slice(r.exp) : '0'.repeat(-r.exp) + r.digits;
  const n = Number(`${intDigits}.${frac || '0'}`);
  return { n, i: Number(intDigits.slice(-18)), v: frac.length, w: frac.length, f: Number(frac || '0'), t: Number(frac || '0'), c: 0, e: 0 };
}
function evalRule(or, o) {
  return or.some((and) => and.every(({ operand, mod, negated, ranges }) => {
    let x = o[operand];
    let ok;
    if (x !== Math.floor(x)) ok = false;
    else {
      if (mod) x = x % mod;
      ok = ranges.some(([lo, hi]) => lo <= x && x <= hi);
    }
    return negated ? !ok : ok;
  }));
}
function selectWith(setName, x) {
  if (!Number.isFinite(x)) return 'other';
  const o = operands(x);
  for (const [cat, ast] of ruleSets.get(setName)) {
    if (cat === 'other') continue;
    if (ast.length && evalRule(ast, o)) return cat;
  }
  return 'other';
}

// Locale → rule set: the locale Intl.PluralRules resolves to, looked up the way ICU's
// PluralRules::forLocale does (full name, then parents).
function setFor(table, loc, type) {
  const resolved = new Intl.PluralRules(loc, { type }).resolvedOptions().locale;
  for (let id = resolved.replace(/-/g, '_'); id; id = id.includes('_') ? id.slice(0, id.lastIndexOf('_')) : '') {
    if (table[id]) return table[id];
  }
  return table.root ?? fail(`no plural rules for ${loc}`);
}

const samples = [];
for (let k = 0; k <= 1200; k++) samples.push(k, -k);
for (let k = 0; k <= 300; k++) samples.push(k / 10, k / 100, k / 1000 + 1, k * 0.37);
for (let e = 3; e <= 25; e++) samples.push(10 ** e, 10 ** e + 1, 3 * 10 ** e, 10 ** e + 0.5, 1 / 10 ** e);
samples.push(1.0001, 1.0004, 1.0005, 0.9995, 2.0005, 1234567.891, 123456789012345680, 1.5e300, 5e-324, NaN, Infinity, -Infinity);

const localeInfo = [];
for (const loc of locales) {
  const cardinal = setFor(plurals.locales, loc, 'cardinal');
  const ordinal = setFor(plurals.locales_ordinals, loc, 'ordinal');
  for (const [type, set] of [['cardinal', cardinal], ['ordinal', ordinal]]) {
    const pr = new Intl.PluralRules(loc, { type });
    const cats = new Set(ruleSets.get(set).map(([c]) => c));
    for (const c of pr.resolvedOptions().pluralCategories) if (!cats.has(c)) fail(`${loc} ${type}: Intl has category ${c} not in ${set}`);
    for (const x of samples) {
      const want = pr.select(x), got = selectWith(set, x);
      if (want !== got) fail(`${loc} ${type} ${set}: select(${x}) = ${want}, CLDR rules give ${got}`);
    }
  }
  localeInfo.push({ loc, cardinal, ordinal });
}

// ---------------------------------------------------------------------------
// 3. Number symbols (Intl.NumberFormat default decimal + percent) and direction
// ---------------------------------------------------------------------------
function affixes(parts) {
  const first = parts.findIndex((p) => p.type === 'integer');
  let last = -1;
  parts.forEach((p, i) => { if (['integer', 'group', 'decimal', 'fraction'].includes(p.type)) last = i; });
  return [parts.slice(0, first).map((p) => p.value).join(''), parts.slice(last + 1).map((p) => p.value).join('')];
}
function numberSymbols(loc) {
  const dec = new Intl.NumberFormat(loc);
  const pct = new Intl.NumberFormat(loc, { style: 'percent' });
  const digits = Array.from({ length: 10 }, (_, d) => dec.format(d));
  const parts = dec.formatToParts(-1234567.891);
  const val = (t) => parts.find((p) => p.type === t)?.value;
  const grouping = (f, scale) => {
    const g = f.formatToParts(1234567890123 / scale).filter((p) => p.type === 'integer').map((p) => p.value.length);
    const primary = g.length > 1 ? g[g.length - 1] : 0;
    const secondary = g.length > 2 ? g[g.length - 2] : primary;
    let min = 1;
    while (primary && !f.formatToParts(10 ** (primary + min - 1) / scale).some((p) => p.type === 'group')) min++;
    return { primary, secondary, min };
  };
  const dg = grouping(dec, 1), pg = grouping(pct, 100);
  const pctParts = pct.formatToParts(12345.678);
  const s = {
    digits,
    decimal: val('decimal'),
    group: val('group') ?? dec.formatToParts(1234567).find((p) => p.type === 'group')?.value ?? '',
    decimalGrouping: dg, percentGrouping: pg,
    decimalPos: affixes(dec.formatToParts(1234567.891)),
    decimalNeg: affixes(parts),
    percentPos: affixes(pctParts),
    percentNeg: affixes(pct.formatToParts(-12345.678)),
    percentGroup: pctParts.find((p) => p.type === 'group')?.value ?? '',
    nan: dec.format(NaN),
    infinity: dec.format(Infinity).replace(/^.*?(\S+)$/u, '$1'),
  };
  if (s.percentGroup !== s.group) fail(`${loc}: percent group separator differs`);
  if (dec.format(Infinity) !== s.decimalPos[0] + s.infinity + s.decimalPos[1]) fail(`${loc}: unexpected infinity layout`);
  return s;
}
// Reference re-implementation of the formatting the Swift runtime does, checked against Intl.
function formatWith(s, x, percent) {
  if (Number.isNaN(x)) return s.nan;
  const neg = x < 0 || Object.is(x, -0);
  const [pre, suf] = percent ? (neg ? s.percentNeg : s.percentPos) : (neg ? s.decimalNeg : s.decimalPos);
  if (!Number.isFinite(x)) return pre + s.infinity + suf;
  let d = shortestDigits(x);
  if (percent && d.digits) d = { digits: d.digits, exp: d.exp + 2 };
  d = roundDigits(d, percent ? 0 : 3);
  let int = d.exp > 0 ? d.digits.slice(0, d.exp).padEnd(d.exp, '0') : '0';
  const frac = d.exp >= 0 ? d.digits.slice(d.exp) : '0'.repeat(-d.exp) + d.digits;
  const map = (str) => str.split('').map((c) => s.digits[Number(c)]).join('');
  let grouped = map(int);
  const g = percent ? s.percentGrouping : s.decimalGrouping;
  if (g.primary && int.length >= g.primary + g.min) {
    const groups = [int.slice(-g.primary)];
    let rest = int.slice(0, -g.primary);
    while (rest.length > g.secondary) { groups.unshift(rest.slice(-g.secondary)); rest = rest.slice(0, -g.secondary); }
    if (rest) groups.unshift(rest);
    grouped = groups.map(map).join(s.group);
  }
  return pre + grouped + (frac ? s.decimal + map(frac) : '') + suf;
}
const numberSamples = [...samples.filter((x) => Math.abs(x) < 1e22), -0, 0.285, 0.0005, 0.12345, -0.004, 999.9995, 99999.5];
for (const info of localeInfo) {
  const s = numberSymbols(info.loc);
  const dec = new Intl.NumberFormat(info.loc), pct = new Intl.NumberFormat(info.loc, { style: 'percent' });
  for (const x of numberSamples) {
    if (dec.format(x) !== formatWith(s, x, false)) fail(`${info.loc}: format(${x}) = ${dec.format(x)}, symbols give ${formatWith(s, x, false)}`);
    if (pct.format(x) !== formatWith(s, x, true)) fail(`${info.loc}: percent(${x}) = ${pct.format(x)}, symbols give ${formatWith(s, x, true)}`);
  }
  info.symbols = s;
  info.direction = new Intl.Locale(info.loc).getTextInfo().direction ?? 'ltr';
  info.intlLocale = new Intl.NumberFormat(info.loc).resolvedOptions().locale;
}

// ---------------------------------------------------------------------------
// 4. Unicode sets the message grammar refers to (from this node's Unicode tables)
// ---------------------------------------------------------------------------
function ranges(re) {
  const out = [];
  let start = -1;
  for (let c = 0; c <= 0x110000; c++) {
    const m = c <= 0x10ffff && !(c >= 0xd800 && c <= 0xdfff) && re.test(String.fromCodePoint(c));
    if (m && start < 0) start = c;
    if (!m && start >= 0) { out.push([start, c - 1]); start = -1; }
  }
  return out;
}
const identifierStop = ranges(/[\p{White_Space}\p{Pattern_Syntax}]/u); // IDENTIFIER_PREFIX_RE complement
const jsWhiteSpace = ranges(/\s/u); // String.prototype.trimStart / trimEnd

// ---------------------------------------------------------------------------
// 5. Emit Swift
// ---------------------------------------------------------------------------
const hex = (c) => `0x${c.toString(16).toUpperCase().padStart(4, '0')}`;
const swiftString = (s) => JSON.stringify(s).replace(/[\u0080-￿]/g, (c) => `\\u{${c.charCodeAt(0).toString(16).toUpperCase()}}`);
const header = (what) => [
  `// Generated by Tools/gen-locales.mjs (node ${process.version}, ICU ${process.versions.icu}, CLDR ${process.versions.cldr}). Do not edit.`,
  `// ${what}`,
  '',
];
mkdirSync(genDir, { recursive: true });

const setIndex = new Map();
const usedSets = [...new Set(localeInfo.flatMap((l) => [l.cardinal, l.ordinal]))].sort((a, b) => Number(a.slice(3)) - Number(b.slice(3)));
const rel = ({ operand, mod, negated, ranges: rs }) =>
  `${negated ? '!' : ''}o.test(.${operand}, mod: ${mod}, ${rs.map(([lo, hi]) => `${lo}...${hi}`).join(', ')})`;
const pr = header('CLDR plural rules, transcribed from ICU plurals.res; evaluated in ICU\'s order.');
pr.push('extension PluralRuleSet {');
pr.push('    /// Evaluates rule set `id` (ICU `setN`) on `o`; categories not matched fall through to `other`.');
pr.push('    static func evaluate(_ id: Int, _ o: PluralOperands) -> PluralCategory {');
pr.push('        switch id {');
for (const name of usedSets) {
  setIndex.set(name, Number(name.slice(3)));
  const usedBy = localeInfo.filter((l) => l.cardinal === name || l.ordinal === name).map((l) => `${l.loc}${l.ordinal === name && l.cardinal !== name ? ' (ordinal)' : l.ordinal === name ? ' (+ordinal)' : ''}`);
  pr.push(`        case ${Number(name.slice(3))}: // ${name}: ${usedBy.join(', ')}`);
  let any = false;
  for (const [cat, ast, text] of ruleSets.get(name)) {
    if (cat === 'other' || ast.length === 0) continue;
    any = true;
    pr.push(`            // ${cat}: ${text}`);
    pr.push(`            if ${ast.map((and) => and.map(rel).join(' && ')).map((s) => (ast.length > 1 && s.includes('&&') ? `(${s})` : s)).join(' || ')} { return .${cat} }`);
  }
  pr.push(any ? '            return .other' : '            return .other // no rules: everything is `other`');
}
pr.push('        default:');
pr.push('            return .other');
pr.push('        }');
pr.push('    }');
pr.push('}', '');
writeFileSync(join(genDir, 'PluralRules.generated.swift'), pr.join('\n'));

const ld = header('Per-locale data: the locales upstream ships, their CLDR plural rule sets, the number\n// symbols Intl.NumberFormat uses (default decimal and percent styles) and text direction.');
ld.push('extension LocaleData {');
ld.push(`    /// The ${locales.length} locales of Signal-Desktop/build/available-locales.json, in that order.`);
ld.push('    static let all: [LocaleData] = [');
for (const l of localeInfo) {
  const s = l.symbols;
  const aff = ([p, q]) => `.init(prefix: ${swiftString(p)}, suffix: ${swiftString(q)})`;
  ld.push(`        LocaleData(`);
  ld.push(`            identifier: ${swiftString(l.loc)}, intlIdentifier: ${swiftString(l.intlLocale)}, direction: .${l.direction === 'rtl' ? 'rightToLeft' : 'leftToRight'},`);
  ld.push(`            cardinalRules: ${setIndex.get(l.cardinal)}, ordinalRules: ${setIndex.get(l.ordinal)},`);
  ld.push(`            numbers: NumberSymbols(`);
  ld.push(`                digits: [${s.digits.map(swiftString).join(', ')}],`);
  ld.push(`                decimal: ${swiftString(s.decimal)}, group: ${swiftString(s.group)},`);
  const grp = (g) => `.init(primary: ${g.primary}, secondary: ${g.secondary}, minimum: ${g.min})`;
  ld.push(`                decimalGrouping: ${grp(s.decimalGrouping)}, percentGrouping: ${grp(s.percentGrouping)},`);
  ld.push(`                decimalPositive: ${aff(s.decimalPos)}, decimalNegative: ${aff(s.decimalNeg)},`);
  ld.push(`                percentPositive: ${aff(s.percentPos)}, percentNegative: ${aff(s.percentNeg)},`);
  ld.push(`                nan: ${swiftString(s.nan)}, infinity: ${swiftString(s.infinity)})),`);
}
ld.push('    ]');
ld.push('}', '');
writeFileSync(join(genDir, 'LocaleData.generated.swift'), ld.join('\n'));

const us = header('Code point sets of the ICU MessageFormat grammar, computed from node\'s Unicode tables.');
us.push('enum UnicodeSets {');
us.push('    /// `[\\p{White_Space}\\p{Pattern_Syntax}]`: code points that end an argument identifier.');
us.push(`    static let identifierStop: [ClosedRange<UInt32>] = [${identifierStop.map(([a, b]) => `${hex(a)}...${hex(b)}`).join(', ')}]`);
us.push('    /// ECMAScript WhiteSpace + LineTerminator (`String.prototype.trim*`).');
us.push(`    static let ecmaWhiteSpace: [ClosedRange<UInt32>] = [${jsWhiteSpace.map(([a, b]) => `${hex(a)}...${hex(b)}`).join(', ')}]`);
us.push('}', '');
writeFileSync(join(genDir, 'UnicodeSets.generated.swift'), us.join('\n'));

console.log(`gen-locales: ${locales.length} locales, ${keys.length} keys, ${totalStrings} strings; ${usedSets.length} CLDR rule sets; ` +
  `plural rules and number symbols verified against Intl on ${samples.length} / ${numberSamples.length} values per locale`);
