// Bundled images for SignalUI (Packages/SignalUI/Sources/SignalUI/Resources/Images): SVGs
// too rich for SignalIcon paths (filters, masks, clip paths, strokes) are rasterised by the
// same Chromium that renders the Storybook references, at 2× their intrinsic size, to
// `<name>@2x.png`; raster images are copied as shipped. SignalUI decodes them with the Swift
// PNG decoder (no ImageIO).
//
//   node Tools/gen-images.mjs

import { createRequire } from 'node:module';
import { copyFile, mkdir, readFile, writeFile } from 'node:fs/promises';
import { join, dirname, basename } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const work = join(root, '.cache/storybook-desktop');
const require = createRequire(join(work, 'package.json'));
const { chromium } = require('playwright');

const images = join(root, 'Signal-Desktop/images');
const out = join(root, 'Packages/SignalUI/Sources/SignalUI/Resources/Images');

/// Upstream image paths used by ported components.
const RASTERISE = [
  'pin-reminder.svg',
  'usernames_40_color.svg',
  'usernames_40_color_dark.svg',
  'chat-session-refresh.svg',
  'delivery-issue.svg',
  'merged-chat.svg',
  'profile-avatar.svg',
  'generic-file.svg',
  'generic-file-dangerous.svg',
  'caption-shadow.svg',
];
/// Intrinsic sizes for SVGs that only have a viewBox (the size they are drawn at).
const SIZES = {};
const COPY = ['donate-heart.png', 'giphy-attribution.png'];

await mkdir(out, { recursive: true });
const browser = await chromium.launch({ args: ['--force-color-profile=srgb', '--disable-lcd-text'] });
const page = await browser.newPage({ deviceScaleFactor: 2 });
for (const file of RASTERISE) {
  let svg = await readFile(join(images, file), 'utf8');
  if (SIZES[file]) svg = svg.replace('<svg ', `<svg width="${SIZES[file][0]}" height="${SIZES[file][1]}" `);
  const src = `data:image/svg+xml;base64,${Buffer.from(svg).toString('base64')}`;
  await page.setContent(`<html><body style="margin:0;background:transparent"><img id="i" src="${src}"></body></html>`);
  await page.waitForFunction(() => document.getElementById('i').complete);
  const png = await page.locator('#i').screenshot({ omitBackground: true, animations: 'disabled' });
  await writeFile(join(out, basename(file, '.svg') + '@2x.png'), png);
  console.log('rasterised', file);
}
for (const file of COPY) {
  await copyFile(join(images, file), join(out, file));
  console.log('copied', file);
}
// Test-only fixtures (Signal-Desktop/fixtures SVGs at their drawn size), for SignalUI's tests.
const FIXTURES = [];
const fixturesOut = join(root, 'Packages/SignalUI/Tests/SignalUITests/Fixtures');
for (const [file, size] of FIXTURES) {
  let svg = await readFile(join(root, 'Signal-Desktop/fixtures', file), 'utf8');
  svg = svg.replace(/\s(width|height)="[^"]*"/g, '').replace('<svg ', `<svg width="${size}" height="${size}" `);
  const src = `data:image/svg+xml;base64,${Buffer.from(svg).toString('base64')}`;
  await page.setContent(`<html><body style="margin:0;background:transparent"><img id="i" src="${src}"></body></html>`);
  await page.waitForFunction(() => document.getElementById('i').complete);
  const png = await page.locator('#i').screenshot({ omitBackground: true, animations: 'disabled' });
  await writeFile(join(fixturesOut, basename(file, '.svg') + `-${size}@2x.png`), png);
  console.log('fixture', file);
}
await browser.close();
