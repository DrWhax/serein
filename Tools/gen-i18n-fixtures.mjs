#!/usr/bin/env node
// Expected outputs for Packages/SignalI18n's tests, produced once by the formatter Signal
// Desktop itself uses: @formatjs/intl 4.1.4 → intl-messageformat 11.2.0 →
// @formatjs/icu-messageformat-parser 3.5.3, from upstream Storybook's node_modules.
//
//   .cache/node-v24.22.0-darwin-arm64/bin/node Tools/gen-i18n-fixtures.mjs
//
// Writes Packages/SignalI18n/Tests/SignalI18nTests/Fixtures/:
//   messages-<locale>.json  every message of en, de, ar, ja, ru, pl, he (and a sample of
//                           every other locale) formatted on generated argument values:
//                           plain-string mode exactly as ts/util/setupI18nMain.std.ts
//                           `i18n()` (bidi-isolated strings, `<emojify>` default element;
//                           other tags flattened), and rich mode as `<I18n>` does it
//                           (components passed as given, every tag supplied).
//   plurals.json            Intl.PluralRules select() for every locale, cardinal + ordinal
//   numbers.json            Intl.NumberFormat default decimal and percent for every locale
//   syntax.json             malformed messages with formatjs' error kind and offset, and
//                           edge-case messages (quotes, offset:, selectordinal, …) with output
//   js.json                 String(number) and Number(string) samples
import { readFileSync, writeFileSync, mkdirSync, readdirSync, rmSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const pnpm = join(root, '.cache/storybook-desktop/node_modules/.pnpm');
const find = (prefix, sub) => {
  const dir = readdirSync(pnpm).find((d) => d.startsWith(prefix));
  if (!dir) throw new Error(`${prefix} not found in ${pnpm}`);
  return pathToFileURL(join(pnpm, dir, 'node_modules', sub, 'index.js')).href;
};
const { createIntl, createIntlCache } = await import(find('@formatjs+intl@4.1.4', '@formatjs/intl'));
const { IntlMessageFormat } = await import(find('intl-messageformat@11.2.0', 'intl-messageformat'));
const { parse, TYPE } = await import(find('@formatjs+icu-messageformat-parser@3.5.3', '@formatjs/icu-messageformat-parser'));

const out = join(root, 'Packages/SignalI18n/Tests/SignalI18nTests/Fixtures');
rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });

const upstream = join(root, 'Signal-Desktop');
const locales = JSON.parse(readFileSync(join(upstream, 'build/available-locales.json'), 'utf8'));
const load = (loc) => {
  const json = JSON.parse(readFileSync(join(upstream, '_locales', loc, 'messages.json'), 'utf8'));
  const m = {};
  for (const [k, v] of Object.entries(json)) if (v && typeof v.messageformat === 'string') m[k] = v.messageformat;
  return m;
};
const en = load('en');
const FULL = ['en', 'de', 'ar', 'ja', 'ru', 'pl', 'he'];

// --- ts/util/unicodeBidi.std.ts (production, i.e. not the test environment) ---------
const CONTROLS = /⁦|⁧|⁨|⁩|‪|‫|‬|‭|‮/g;
function balance(input) {
  if (!input.match(CONTROLS)) return input;
  let result = '', formatting = 0, isolates = 0;
  for (const ch of input) {
    if ('‪‫‭‮'.includes(ch)) { formatting++; result += ch; }
    else if (ch === '‬') { if (formatting > 0) { formatting--; result += ch; } }
    else if ('⁦⁧⁨'.includes(ch)) { isolates++; result += ch; }
    else if (ch === '⁩') { if (isolates > 0) { isolates--; result += ch; } }
    else result += ch;
  }
  return result + '‬'.repeat(formatting) + '⁩'.repeat(isolates);
}
const bidiIsolate = (s) => '⁨' + balance(s) + '⁩';
// setupI18nMain.std.ts normalizeSubstitutions (default bidi)
function normalize(values) {
  const n = {};
  for (const [k, v] of Object.entries(values)) n[k] = typeof v === 'string' ? bidiIsolate(v) : v;
  return n;
}

// --- argument values -------------------------------------------------------------------
function params(message) {
  const p = new Map();
  const visit = (els) => {
    for (const el of els) {
      switch (el.type) {
        case TYPE.argument: if (!p.has(el.value)) p.set(el.value, { type: 'string' }); break;
        case TYPE.number: p.set(el.value, { type: 'number' }); break;
        case TYPE.plural: p.set(el.value, { type: 'number' }); Object.values(el.options).forEach((o) => visit(o.value)); break;
        case TYPE.select: p.set(el.value, { type: 'select', options: Object.keys(el.options).filter((k) => k !== 'other') }); Object.values(el.options).forEach((o) => visit(o.value)); break;
        case TYPE.tag: p.set(el.value, { type: 'tag' }); visit(el.children); break;
        case TYPE.date: case TYPE.time: p.set(el.value, { type: 'date' }); break;
        default: break;
      }
    }
  };
  visit(parse(message));
  return p;
}
const NUMS = [0, 1, 2, 3, 4, 5, 7, 11, 12, 14, 21, 22, 25, 100, 101, 102, 111, 1000, 1001, 10000, 123456, 1000000, 1.5, 0.25, 2.75, -1, -3, 1234567.891, 0.001];
const NUMS_SAMPLE = [0, 1, 2, 3, 5, 11, 22, 1.5];
const STRS = ['Alice', 'שלום', 'Bob ‮evil', '', 'Zoë 🙂', 'x⁩y', '1000'];

function cases(p, full) {
  const nums = full ? NUMS : NUMS_SAMPLE;
  const entries = [...p.entries()].filter(([, t]) => t.type !== 'tag');
  const hasNumber = entries.some(([, t]) => t.type === 'number');
  const maxOpts = Math.max(0, ...entries.filter(([, t]) => t.type === 'select').map(([, t]) => t.options.length + 1));
  const count = hasNumber ? nums.length : Math.max(full ? 2 : 1, maxOpts);
  const out = [];
  for (let c = 0; c < count; c++) {
    const a = {};
    entries.forEach(([name, t], j) => {
      if (t.type === 'number') a[name] = nums[(c + 5 * j) % nums.length];
      else if (t.type === 'select') a[name] = c % (t.options.length + 1) < t.options.length ? t.options[c % (t.options.length + 1)] : 'unlisted-value';
      else a[name] = STRS[(c + j) % STRS.length];
    });
    out.push(a);
  }
  return out;
}

// --- serialisation of formatjs output ---------------------------------------------------
// Rich output → runs [text|element, tags]; empty text dropped (see RichText.runs).
function runs(value, tags = [], acc = []) {
  if (value == null) return acc;
  if (typeof value === 'string') { if (value !== '') acc.push(['t', value, tags]); return acc; }
  if (Array.isArray(value)) { for (const v of value) runs(v, tags, acc); return acc; }
  if (value.el != null) { acc.push(['e', value.el, tags]); return acc; }
  if (value.tag != null) return runs(value.children, [...tags, value.tag], acc);
  throw new Error(`unexpected part ${JSON.stringify(value)}`);
}

function tagNames(message) {
  return [...params(message).entries()].filter(([, t]) => t.type === 'tag').map(([n]) => n);
}

let totalCases = 0;
for (const loc of locales) {
  const full = FULL.includes(loc);
  const messages = { ...en, ...load(loc) }; // app/locale.node.ts: merge(englishMessages, matchedLocaleMessages)
  let lastError = null;
  const intl = createIntl({
    locale: loc.replace('_', '-'),
    messages,
    defaultRichTextElements: { emojify: (parts) => parts },
    onError: (e) => { lastError = e; },
    onWarn: () => {},
  }, createIntlCache());
  const list = [];
  for (const key of Object.keys(en).sort()) {
    const enParams = params(en[key]);
    const tags = [...new Set([...tagNames(en[key]), ...tagNames(messages[key])])];
    const argSets = cases(enParams, full);
    if (!full) {
      // sample: every message with any ICU syntax or quoting once (plain literals are
      // their own output), every plural / number message on NUMS_SAMPLE
      const ast = parse(messages[key]);
      if (ast.length === 1 && ast[0].type === TYPE.literal && !messages[key].includes("'")) continue;
      if (![...enParams.values()].some((t) => t.type === 'number')) argSets.splice(1);
    }
    argSets.forEach((args, c) => {
      const entry = { k: key, a: args };
      // plain string: i18n(key, substitutions)
      const flat = Object.fromEntries(tags.filter((t) => t !== 'emojify').map((t) => [t, (parts) => parts]));
      lastError = null;
      const s = intl.formatMessage({ id: key }, { ...normalize(args), ...flat });
      if (lastError) entry.se = String(lastError.code ?? lastError.message).split(':')[0];
      else entry.s = Array.isArray(s) ? s.join('') : s;
      // rich text: <I18n id={key} components={…} />
      if (tags.length) {
        const ra = { ...args };
        const firstString = [...enParams.entries()].find(([, t]) => t.type === 'string');
        if (firstString && c % 2 === 1) ra[firstString[0]] = { el: firstString[0] };
        const comp = Object.fromEntries(tags.map((t) => [t, (children) => ({ tag: t, children })]));
        lastError = null;
        const r = intl.formatMessage({ id: key }, { ...ra, ...comp }, {});
        if (JSON.stringify(ra) !== JSON.stringify(args)) entry.ra = ra;
        if (lastError) entry.re = String(lastError.code ?? lastError.message).split(':')[0];
        else entry.r = runs(r);
      }
      list.push(entry);
    });
  }
  totalCases += list.length;
  writeFileSync(join(out, `messages-${loc}.json`), JSON.stringify({ locale: loc, full, cases: list }));
}

// --- plural rules and numbers for every locale -------------------------------------------
const pluralValues = [];
for (let k = 0; k <= 250; k++) pluralValues.push(k);
pluralValues.push(1000, 1001, 10000, 100000, 1000000, 1000001, 2000000, 1e7, 1e9, 1e12, 1e15, 1e18, 1e21, 123456789012345680);
pluralValues.push(0.1, 0.5, 1.5, 2.5, 0.01, 1.01, 1.1, 2.1, 3.3, 5.5, 11.1, 21.21, 0.001, 1.0001, 1.0005, 1.9995, 102.4, -1, -2, -5, -21, -1.5, 3.14159);
const plurals = {};
for (const loc of locales) {
  const c = new Intl.PluralRules(loc), o = new Intl.PluralRules(loc, { type: 'ordinal' });
  plurals[loc] = { cardinal: pluralValues.map((x) => c.select(x)), ordinal: pluralValues.map((x) => o.select(x)) };
}
writeFileSync(join(out, 'plurals.json'), JSON.stringify({ values: pluralValues, locales: plurals }));

const numberValues = [0, 1, -1, 5, 12, 123, 999, 1000, 1234, 9999, 10000, 12345, 99999, 100000, 123456, 1234567, 12345678, 123456789,
  1e21, 1.5, 0.5, 0.25, 0.001, 0.0005, 0.0004, 1.0005, 2.0005, 999.9995, 1234567.891, -1234567.891, 0.285, 0.12345, 3.14159, 1e-7, 2.5e-5, -0.004];
const numbers = {};
for (const loc of locales) {
  const d = new Intl.NumberFormat(loc), p = new Intl.NumberFormat(loc, { style: 'percent' }), i = new Intl.NumberFormat(loc, { maximumFractionDigits: 0 });
  numbers[loc] = { decimal: numberValues.map((x) => d.format(x)), percent: numberValues.map((x) => p.format(x)), integer: numberValues.map((x) => i.format(x)),
    special: [d.format(NaN), d.format(Infinity), d.format(-Infinity), d.format(-0)] };
}
writeFileSync(join(out, 'numbers.json'), JSON.stringify({ values: numberValues, locales: numbers }));

// --- syntax: malformed messages and edge cases ---------------------------------------------
const malformed = [
  '{', '{ ', '{}', '{ }', '{name', '{name ', '{name,', '{name, }', '{name foo}', '{,}', '{name,,}',
  '{name, foo}', '{name, number,}', '{name, number, }', "{name, number, 'percent}", '{name, number, ::}',
  '{name, number, ::currency/}', '{name, date, ::}', '{n, plural}', '{n, plural one {a}}', '{n, plural,}',
  '{n, plural, one {a}}', '{n, plural, other {a} other {b}}', '{n, plural, =1 {a} =1 {b} other {c}}',
  '{n, plural, one a}', '{n, plural, one {a} other {b}', '{n, plural, other {a}', '{n, plural, offset 1 other {a}}',
  '{n, plural, offset: other {a}}', '{n, plural, offset:x other {a}}', '{n, plural, offset:99999999999999999 other {a}}',
  '{n, plural, = {a} other {b}}', '{n, plural, =99999999999999999 {a} other {b}}', '{n, select, =1 {a} other {b}}',
  '{n, select, a {x}}', '{n, select, a {x} a {y} other {z}}', '{n, select,}', '{n, selectordinal, one {a}}',
  '<b>', '<b>text', '<b>text</i>', '<b>text</b', '<b>text</ b>', '</b>', 'a </b> c', '<b>x</b>y</i>', '<b x>y</b>',
  '<b>{n}</b', '<b>{n, plural, other {x}}', '{n, plural, other {<b>x}}', '{n, plural, other {x</b>}}',
  '<b>a}</b>', '{n, plural, other {{m, select, other {x}}}', '{n, number, a{b}c}', '{n, plural, one {a} other {b}} {', '{😀}',
];
const syntaxErrors = malformed.map((m) => {
  try { parse(m); return { m, ok: true }; } catch (e) { return { m, kind: e.message, offset: e.location?.start?.offset ?? -1 }; }
});
const edge = [
  ["It''s {name}'s", { name: 'Ann' }], ["'{literal}' and '{'", {}], ["a '<b>' c", {}], ["x'y", {}], ["'", {}], ["''", {}],
  ["{n, plural, other {'#' is #}}", { n: 3 }], ["# outside", {}], ["{n, plural, one {# '{x}'} other {#}}", { n: 1 }],
  ["{n, plural, offset:1 =0 {nobody} =1 {only {name}} one {{name} and # other} other {{name} and # others}}", { n: 0, name: 'Al' }],
  ["{n, plural, offset:1 =0 {nobody} =1 {only {name}} one {{name} and # other} other {{name} and # others}}", { n: 1, name: 'Al' }],
  ["{n, plural, offset:1 =0 {nobody} =1 {only {name}} one {{name} and # other} other {{name} and # others}}", { n: 2, name: 'Al' }],
  ["{n, plural, offset:1 =0 {nobody} =1 {only {name}} one {{name} and # other} other {{name} and # others}}", { n: 5, name: 'Al' }],
  ["{n, selectordinal, one {#st} two {#nd} few {#rd} other {#th}}", { n: 1 }], ["{n, selectordinal, one {#st} two {#nd} few {#rd} other {#th}}", { n: 22 }],
  ["{n, selectordinal, one {#st} two {#nd} few {#rd} other {#th}}", { n: 13 }], ["{n, selectordinal, one {#st} two {#nd} few {#rd} other {#th}}", { n: 103 }],
  ["{n, plural, =0 {none} =1 {one exactly} one {one-ish} other {# many}}", { n: 1 }], ["{n, plural, =+1 {plus} other {#}}", { n: 1 }],
  ["{n, plural, =01 {zero-one} other {#}}", { n: 1 }], ["{n, plural, =-1 {minus} other {#}}", { n: -1 }],
  ["{n, plural, one {a} other {b}}", { n: '1' }], ["{n, plural, one {a} other {#}}", { n: 'abc' }], ["{n, number}", { n: '12.5' }],
  ["{n}", { n: 1e21 }], ["{n}", { n: 0.000001 }], ["{n}", { n: 1e-7 }], ["{n}", { n: 123.456 }], ["{n}", { n: -0 }], ["{n}", { n: 0 }],
  ["{a} {b}", { a: 1.5, b: 'x' }], ["{n, number, percent}", { n: 0.5 }], ["{n, number, integer}", { n: 2.5 }], ["{n, number, foo}", { n: 1234.5678 }],
  ["{x, select, a {A} b {B {n, plural, one {# one} other {# other}}} other {O}}", { x: 'b', n: 1 }],
  ["{x, select, a {A} other {O}}", { x: 5 }], ["{x, select, 5 {five} other {O}}", { x: 5 }], ["{n, plural, other {<b>#</b> items}}", { n: 1234 }],
  ["{n, plural, one {{m, plural, one {# inner} other {# inners}} outer #} other {x}}", { n: 1, m: 3 }],
  ["a <b>bold <i>both</i></b> c", {}], ["<b></b>", {}], ["<b>x</b><b>y</b>", {}], ["<br/> and <br />", {}], ["a < b and c<1", {}],
  ["<a-b.c_d1>x</a-b.c_d1>", {}], ["{ name }", { name: 'spaced' }], ["{\tname\n}", { name: 'tabbed' }], ["{name‎}", { 'name‎': 'lrm' }],
  ["{n, plural, one {a}other{b}}", { n: 2 }], ["{n,plural,one{a}other{b}}", { n: 1 }], ["}", {}], ["a}b", {}], ["{n, number, ::percent}", { n: 1 }],
  ["{n, plural, other {}}", { n: 1 }], ["{v}", { v: '' }], ["😀 {n} 😀", { n: 'é' }],
];
const edgeCases = edge.map(([m, args]) => {
  const tags = (() => { try { return tagNames(m); } catch { return []; } })();
  const entry = { m, a: args };
  try {
    const f = new IntlMessageFormat(m, 'en');
    const s = f.format({ ...args, ...Object.fromEntries(tags.map((t) => [t, (p) => p])) });
    entry.s = Array.isArray(s) ? s.join('') : s;
    const r = f.format({ ...args, ...Object.fromEntries(tags.map((t) => [t, (children) => ({ tag: t, children })])) });
    entry.r = runs(r);
  } catch (e) {
    entry.err = e.code ?? e.message;
  }
  return entry;
});
writeFileSync(join(out, 'syntax.json'), JSON.stringify({ errors: syntaxErrors, cases: edgeCases }, null, 1));

// --- JS number semantics --------------------------------------------------------------------
const doubles = [0, 1, -1, 0.1, 0.2 + 0.1, 1 / 3, 2 / 3, 123.456, 1e20, 1e21, 1.5e21, 123456789012345680000, 1e-6, 1e-7, 1.5e-7, 0.000001234,
  5e-324, 1.7976931348623157e308, 9007199254740993, 4.35, 100, 1000000, 0.5, 1234.5678, 2 ** 70, -2.5e-8, 299792458, 6.02214076e23];
const strings = ['', ' ', '  12  ', '12.5', '.5', '5.', '+5', '-5', '1e3', '1E-3', '0x1F', '0o17', '0b101', 'Infinity', '-Infinity', 'abc', '1,000', '١٢', '12abc', ' 7 ', 'NaN', 'inf', '0x', '1e', '--1'];
writeFileSync(join(out, 'js.json'), JSON.stringify({
  toString: doubles.map((x) => [x, String(x)]),
  toNumber: strings.map((s) => [s, Number.isNaN(Number(s)) ? 'NaN' : String(Number(s))]),
}));

console.log(`gen-i18n-fixtures: ${totalCases} message cases over ${locales.length} locales (${FULL.join(', ')} in full), ` +
  `${syntaxErrors.length} syntax error cases, ${edgeCases.length} edge cases`);
