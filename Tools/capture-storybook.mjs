#!/usr/bin/env node
// Captures upstream Signal Desktop Storybook stories (built by Tools/build-storybook.sh)
// as the visual reference for SignalUI (plan.md Phase 3).
//
//   node Tools/capture-storybook.mjs                 stories listed in Packages/SignalUI/Tests/SignalUITests/stories.txt
//                                                    → Tests/SignalUITests/References/<id>.<theme>.{png,json}
//   node Tools/capture-storybook.mjs --all [regex]   every (matching) story → .cache/storybook-refs/ with a DOM/style dump
//   node Tools/capture-storybook.mjs --tokens        resolved --axo-* tokens (light + dark) → .cache/axo-tokens.json
//
// Rendering: Chromium (Playwright, from the Storybook workspace), deviceScaleFactor 2,
// sRGB colour profile, animations disabled via upstream's SignalContext._skipAnimation();
// the PNG is clipped to the story's root element.
import { createRequire } from 'node:module';
import { createServer } from 'node:http';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { existsSync, readFileSync, unlinkSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join, extname, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const work = join(root, '.cache/storybook-desktop');
const staticDir = join(work, 'storybook-static');
const require = createRequire(join(work, 'package.json'));
const { chromium } = require('playwright');

const args = process.argv.slice(2);
const mode = args.includes('--tokens') ? 'tokens' : args.includes('--all') ? 'all' : 'refs';
const pattern = args.find((a, i) => !a.startsWith('--') && args[i - 1] !== '--tests-dir');
const testsDirArg = args.indexOf('--tests-dir');
const testsDir = testsDirArg >= 0 ? args[testsDirArg + 1] : join(root, 'Packages/SignalUI/Tests/SignalUITests');

const types = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.json': 'application/json',
  '.svg': 'image/svg+xml', '.png': 'image/png', '.woff2': 'font/woff2', '.ttf': 'font/ttf', '.webp': 'image/webp', '.gif': 'image/gif',
  '.jpg': 'image/jpeg', '.mp4': 'video/mp4', '.wasm': 'application/wasm' };
const server = createServer(async (req, res) => {
  const path = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  const file = join(staticDir, path.endsWith('/') ? path + 'index.html' : path);
  if (!file.startsWith(staticDir) || !existsSync(file)) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { 'content-type': types[extname(file)] ?? 'application/octet-stream' });
  res.end(await readFile(file));
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const base = `http://127.0.0.1:${server.address().port}`;

const browser = await chromium.launch({ args: ['--force-color-profile=srgb', '--disable-lcd-text'] });
const context = await browser.newContext({ deviceScaleFactor: 2, viewport: { width: 1200, height: 900 }, reducedMotion: 'reduce' });
// Stories built on test-helpers (casual names, lodash `sample` colours and avatars, random
// timestamps) are random per load. Every load gets the same seeded Math.random and a frozen
// clock (casual's Mersenne Twister seeds itself from Date.now()), so captures are
// reproducible and the Swift tests can use the same values. Timers still run.
export const FIXED_NOW = Date.parse('2026-11-04T12:00:00Z');
await context.addInitScript(() => {
  let s = 0x5eed5eed;
  Math.random = () => {
    s = (s + 0x6d2b79f5) | 0;
    let t = Math.imul(s ^ (s >>> 15), 1 | s);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
});
// Storybook loads the large emoji font from updates.signal.org: serve the pinned copy from
// .cache (Tools/gen-fonts.sh) so captures never depend on the network.
const largeEmojiFont = join(root, '.cache/emoji-font/desktop-32-64-v2.0.4.woff2');
await context.route('https://updates.signal.org/static/android/emoji/font/**', (route) =>
  existsSync(largeEmojiFont) ? route.fulfill({ path: largeEmojiFont, contentType: 'font/woff2' }) : route.abort());
// The app loads some fonts from asset:/// (avatarDataToBytes' Inter): the static Storybook
// serves the same files from /.
await context.addInitScript(() => {
  const Native = window.FontFace;
  window.FontFace = function FontFace(family, source, descriptors) {
    return new Native(family, typeof source === 'string' ? source.replaceAll('asset:///', '/') : source, descriptors);
  };
  window.FontFace.prototype = Native.prototype;
});
// CAPTURE_PAUSE_MEDIA=1: media never starts playing, so a video shows its first frame (the
// frame a capture otherwise lands on depends on timing).
if (process.env.CAPTURE_PAUSE_MEDIA) {
  await context.addInitScript(() => { HTMLMediaElement.prototype.play = function play() { return Promise.resolve(); }; });
}
const page = await context.newPage();
if (process.env.CAPTURE_DEBUG) { page.on('pageerror', (e) => console.error('pageerror', e.message.split('\n')[0])); page.on('console', (m) => { if (m.type() === 'error') console.error('console', m.text().slice(0, 300)); }); }   // CAPTURE_DEBUG=1: print story errors
await page.clock.setFixedTime(FIXED_NOW);

async function openStory(id, theme) {
  await page.goto(`${base}/iframe.html?id=${encodeURIComponent(id)}&viewMode=story&globals=theme:${theme}`, { waitUntil: 'load' });
  await page.waitForFunction(() => document.querySelector('#storybook-root')?.childElementCount > 0, null, { timeout: 15000 });
  await page.evaluate(() => window.SignalContext?._skipAnimation?.());
  await page.evaluate(() => document.fonts.ready);
  // Audio stories keep a media request open: networkidle never comes, so don't wait forever.
  await page.waitForLoadState('networkidle', { timeout: 8000 }).catch(() => {});
  // CAPTURE_REMOUNT=1: stories that measure text on mount (Message's metadata spacer keeps the
  // max width it saw) measured the fallback font on a cold page; remount with fonts loaded, as
  // in the app.
  if (process.env.CAPTURE_REMOUNT) {
    // As in the app, where the UI's text has loaded Inter (a canvas only gets faces in use).
    await page.evaluate(() => Promise.all(['400', '500', '600', '700'].map((w) => document.fonts.load(`${w} 16px Inter`))));
    await page.evaluate((storyId) => window.__STORYBOOK_ADDONS_CHANNEL__.emit('forceRemount', { storyId }), id);
    await page.waitForTimeout(300);
    await page.waitForFunction(() => document.querySelector('#storybook-root')?.childElementCount > 0, null, { timeout: 15000 });
    await page.evaluate(() => window.SignalContext?._skipAnimation?.());
  }
  // CAPTURE_CLICK=<text>: stories behind a harness button ("Activate"): press it first.
  // CAPTURE_CLICK_PAGE=1: the target is in a portal (a popover), outside the story root.
  if (process.env.CAPTURE_CLICK) {
    const scope = process.env.CAPTURE_CLICK_PAGE ? page : page.locator('#storybook-root');
    await scope.getByText(process.env.CAPTURE_CLICK, { exact: true }).first().click();
  }
  // CAPTURE_FOCUS=<selector>: then focus this element (where the panel's autofocus would be).
  if (process.env.CAPTURE_FOCUS) {
    await page.waitForSelector(process.env.CAPTURE_FOCUS);
    await page.focus(process.env.CAPTURE_FOCUS);
  }
  await page.waitForTimeout(Number(process.env.CAPTURE_SETTLE_MS ?? 150));   // CAPTURE_SETTLE_MS: stories that render asynchronously
}

// Union of the story root's children (the rendered component). Stories that open a
// portal (Radix dialog / alert dialog / popper: menus, popovers, tooltips) are captured
// as the whole viewport, with the portal elements' rects recorded.
async function componentBox() {
  return page.evaluate((viewport) => {
    // CAPTURE_VIEWPORT=1: full-window components portalled outside the root (MediaEditor).
    if (viewport) {
      const bg = getComputedStyle(document.body).backgroundColor.match(/[\d.]+/g).map(Number);
      return { x: 0, y: 0, width: innerWidth, height: innerHeight, background: bg.length === 3 ? [...bg, 1] : bg, portals: [[0, 0, innerWidth, innerHeight]] };
    }
    const portals = [...document.querySelectorAll('[role=dialog],[role=alertdialog],[data-radix-popper-content-wrapper],[role=tooltip],.module-modal-host__width-container,#lightbox')]
      .filter((e) => !document.querySelector('#storybook-root').contains(e))
      .map((e) => e.getBoundingClientRect()).filter((r) => r.width > 0 && r.height > 0);
    if (portals.length) {
      const bg = getComputedStyle(document.body).backgroundColor.match(/[\d.]+/g).map(Number);
      return { x: 0, y: 0, width: innerWidth, height: innerHeight, background: bg.length === 3 ? [...bg, 1] : bg,
        portals: portals.map((r) => [r.x, r.y, r.width, r.height].map((v) => Math.round(v * 100) / 100)) };
    }
    const root = document.querySelector('#storybook-root');
    let rects = [...root.children].map((c) => c.getBoundingClientRect()).filter((r) => r.width > 0 && r.height > 0);
    // Zero-size wrappers around absolutely positioned content (e.g. AttachmentDetailPill):
    // the union of the sized descendants.
    if (!rects.length) rects = [...root.querySelectorAll('*')].map((c) => c.getBoundingClientRect()).filter((r) => r.width > 0 && r.height > 0);
    // position: fixed descendants (ToastManager's toasts) lie outside their parents' boxes.
    rects.push(...[...root.querySelectorAll('*')].filter((e) => getComputedStyle(e).position === 'fixed')
      .map((e) => e.getBoundingClientRect()).filter((r) => r.width > 0 && r.height > 0));
    if (!rects.length) return null;
    const x = Math.min(...rects.map((r) => r.left)), y = Math.min(...rects.map((r) => r.top));
    const w = Math.max(...rects.map((r) => r.right)) - x, h = Math.max(...rects.map((r) => r.bottom)) - y;
    const bg = getComputedStyle(document.body).backgroundColor.match(/[\d.]+/g).map(Number);
    return { x, y, width: w, height: h, background: bg.length === 3 ? [...bg, 1] : bg };
  }, !!process.env.CAPTURE_VIEWPORT);
}

// Compact DOM + computed style dump for porting.
async function domDump() {
  return page.evaluate(() => {
    const keep = ['display', 'position', 'color', 'backgroundColor', 'backgroundImage', 'borderRadius', 'borderTopWidth', 'borderTopColor',
      'borderBottomWidth', 'borderBottomColor', 'boxShadow', 'fontFamily', 'fontSize', 'fontWeight', 'lineHeight', 'letterSpacing',
      'paddingTop', 'paddingRight', 'paddingBottom', 'paddingLeft', 'gap', 'opacity', 'textAlign', 'whiteSpace', 'textOverflow',
      'fontVariationSettings', 'outlineWidth', 'outlineColor'];
    const walk = (el) => {
      const r = el.getBoundingClientRect(), cs = getComputedStyle(el);
      const style = {};
      for (const k of keep) style[k] = cs[k];
      const node = { tag: el.tagName.toLowerCase(), cls: el.className?.baseVal ?? el.className, rect: [r.left, r.top, r.width, r.height].map((v) => Math.round(v * 100) / 100), style };
      const text = [...el.childNodes].filter((n) => n.nodeType === 3).map((n) => n.textContent).join('').trim();
      if (text) node.text = text;
      for (const a of ['role', 'aria-label', 'data-axo-symbol-glyph', 'data-testid']) if (el.getAttribute?.(a)) node[a] = el.getAttribute(a);
      // An img's src (blurhash previews are data: URLs of the decoded pixels; fixtures are paths).
      if (el.tagName === 'IMG' && el.getAttribute('src')) node.src = el.getAttribute('src');
      const kids = [...el.children].map(walk);
      if (kids.length) node.children = kids;
      return node;
    };
    const root = document.querySelector('#storybook-root');
    const portalHosts = [...document.body.children].filter((c) => c !== root && c.tagName === 'DIV' && !c.className.toString().includes('sb-')
      && c.querySelector('[role=dialog],[role=alertdialog],[data-radix-popper-content-wrapper],[role=tooltip],.module-modal-host__width-container,#lightbox'));
    return [...root.children, ...portalHosts].map(walk);
  });
}

async function capture(id, theme, outDir, withDom) {
  await page.setViewportSize({ width: 1200, height: 900 });
  await openStory(id, theme);
  let box = await componentBox();
  if (!box && process.env.CAPTURE_DEBUG) {
    console.error('debug', await page.evaluate(() => JSON.stringify([...document.querySelectorAll('[role=dialog], .module-modal-host, #storybook-root > *')]
      .map((e) => [e.tagName, e.className.toString().slice(0, 60), e.getAttribute('role'), JSON.stringify(e.getBoundingClientRect())]))));
  }
  if (!box) throw new Error('empty story');
  // Content taller than the viewport: grow the viewport (screenshots clip to it) and re-measure.
  if (!box.portals && box.y + box.height > 900) {
    await page.setViewportSize({ width: 1200, height: Math.ceil(box.y + box.height + 16) });
    await page.waitForTimeout(100);
    box = await componentBox();
    // 100vh content grows with the viewport: keep the clip (and the JSON size) inside it.
    const vh = page.viewportSize().height;
    if (box.y + box.height > vh) box.height = vh - box.y;
  }
  // Screenshots clip to the page: content off its edges (AnimatedEmojiGalore) is not painted.
  const vp = page.viewportSize();
  const x0 = Math.max(0, Math.floor(box.x)), y0 = Math.max(0, Math.floor(box.y));
  const x1 = Math.min(vp.width, Math.ceil(box.x + box.width)), y1 = Math.min(vp.height, Math.ceil(box.y + box.height));
  const clip = { x: x0, y: y0, width: x1 - x0, height: y1 - y0 };
  // Chromium can't paint one screenshot much taller than ~16k device pixels (taller ones come
  // back stitched wrong): capture tall clips in 4000px bands and join them.
  const out = join(outDir, `${id}.${theme}.png`);
  if (clip.height <= 4000) {
    await page.screenshot({ path: out, clip, animations: 'disabled', caret: 'hide' });
  } else {
    const bands = [];
    for (let y = clip.y; y < clip.y + clip.height; y += 4000) {
      const band = `${out}.band${bands.length}.png`;
      await page.screenshot({ path: band, clip: { ...clip, y, height: Math.min(4000, clip.y + clip.height - y) }, animations: 'disabled', caret: 'hide' });
      bands.push(band);
    }
    execFileSync('python3', ['-c', `import sys
from PIL import Image
ims = [Image.open(f) for f in sys.argv[2:]]
out = Image.new('RGBA', (ims[0].width, sum(i.height for i in ims)))
y = 0
for i in ims:
    out.paste(i, (0, y)); y += i.height
out.save(sys.argv[1])`, out, ...bands]);
    for (const b of bands) unlinkSync(b);
  }
  const info = { id, theme, width: clip.width, height: clip.height, scale: 2, background: box.background, offset: [clip.x, clip.y] };
  if (box.portals) info.portals = box.portals;
  await writeFile(join(outDir, `${id}.${theme}.json`), JSON.stringify(info, null, 1) + '\n');
  if (withDom) await writeFile(join(outDir, `${id}.${theme}.dom.json`), JSON.stringify(await domDump()));
}

const index = JSON.parse(await readFile(join(staticDir, 'index.json'), 'utf8'));
const stories = Object.values(index.entries).filter((e) => e.type === 'story');

if (mode === 'tokens') {
  const first = stories.find((s) => s.id.startsWith('axo-axobutton')) ?? stories[0];
  const result = {};
  for (const theme of ['light', 'dark']) {
    await openStory(first.id, theme);
    result[theme] = await page.evaluate(() => {
      const names = new Set();
      const visit = (rules) => { for (const r of rules) { if (r.style) for (const p of r.style) if (p.startsWith('--')) names.add(p); if (r.cssRules) visit(r.cssRules); } };
      for (const sheet of document.styleSheets) { try { visit(sheet.cssRules); } catch {} }
      const probe = document.createElement('div');
      document.body.appendChild(probe);
      const out = {};
      const parse = (c) => {
        // "color(srgb r g b / a)" (0…1 floats) or "rgb(r, g, b)" / "rgba(r, g, b, a)" (0…255)
        let m = c.match(/^color\(srgb ([-\d.e]+) ([-\d.e]+) ([-\d.e]+)(?: \/ ([-\d.e]+))?\)$/);
        if (m) return [+m[1], +m[2], +m[3], m[4] === undefined ? 1 : +m[4]];
        m = c.match(/^rgba?\(([-\d.]+), ([-\d.]+), ([-\d.]+)(?:, ([-\d.]+))?\)$/);
        if (m) return [+m[1] / 255, +m[2] / 255, +m[3] / 255, m[4] === undefined ? 1 : +m[4]];
        return null;
      };
      for (const name of [...names].sort()) {
        const raw = getComputedStyle(probe).getPropertyValue(name).trim();
        if (!raw || raw === 'initial') continue;
        probe.style.color = '';
        probe.style.color = `color-mix(in srgb, var(${name}) 100%, transparent)`;
        const resolved = probe.style.color ? getComputedStyle(probe).color : '';
        out[name] = { raw, srgb: parse(resolved) };
        if (/shadow/.test(name) && !name.startsWith('--tw-')) {
          probe.style.boxShadow = `var(${name})`;
          const computed = getComputedStyle(probe).boxShadow;
          probe.style.boxShadow = '';
          // Layers are comma-separated outside parentheses; each is "<color> x y blur spread [inset]".
          const layers = [];
          let depth = 0, cur = '';
          for (const ch of computed) {
            if (ch === '(') depth++;
            if (ch === ')') depth--;
            if (ch === ',' && depth === 0) { layers.push(cur.trim()); cur = ''; } else cur += ch;
          }
          if (cur.trim() && computed !== 'none') layers.push(cur.trim());
          out[name].shadow = layers.map((layer) => {
            const colorMatch = layer.match(/^((?:rgba?|color|oklab|oklch|lab|lch)\([^)]*\))/);
            const rest = layer.slice(colorMatch ? colorMatch[0].length : 0).trim().split(/\s+/);
            probe.style.color = `color-mix(in srgb, ${colorMatch ? colorMatch[1] : 'transparent'} 100%, transparent)`;
            const srgb = parse(getComputedStyle(probe).color);
            const nums = rest.filter((t) => t !== 'inset').map((t) => parseFloat(t));
            return { inset: rest.includes('inset'), x: nums[0] ?? 0, y: nums[1] ?? 0, blur: nums[2] ?? 0, spread: nums[3] ?? 0, srgb };
          });
        }
      }
      probe.remove();
      return out;
    });
  }
  await writeFile(join(root, '.cache/axo-tokens.json'), JSON.stringify(result, null, 1));
  console.log('tokens:', Object.keys(result.light).length);
} else {
  let ids;
  let outDir;
  if (mode === 'all') {
    const re = pattern ? new RegExp(pattern) : null;
    ids = stories.map((s) => s.id).filter((id) => !re || re.test(id));
    outDir = join(root, '.cache/storybook-refs');
  } else {
    ids = readFileSync(join(testsDir, 'stories.txt'), 'utf8').split('\n').map((l) => l.replace(/#.*/, '').trim()).filter(Boolean);
    outDir = join(testsDir, 'References');
  }
  await mkdir(outDir, { recursive: true });
  let failed = 0;
  for (const id of ids) {
    if (!index.entries[id]) { console.error('unknown story', id); failed++; continue; }
    for (const theme of ['light', 'dark']) {
      try { await capture(id, theme, outDir, mode === 'all'); } catch (e) { console.error('failed', id, theme, e.message.split('\n')[0]); failed++; }
    }
  }
  console.log(`captured ${ids.length} stories × 2 themes into ${outDir}${failed ? `, ${failed} failures` : ''}`);
}
await browser.close();
server.close();
