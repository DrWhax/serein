# Porting an upstream component to SignalUI

SignalUI (`Packages/SignalUI`) is a 1:1 SwiftUI port of Signal Desktop's UI. Each upstream
component (`Signal-Desktop/ts/axo/*`, `ts/components/*`) gets a SwiftUI twin **with the same
name and structure**. Each Storybook story gets a screenshot test that must differ from the
Chromium capture by **≤ 1%** of pixels (pixelmatch, threshold 0.1, anti-alias aware).

## Tools (all already set up; run from the repo root)

| What | Command |
|---|---|
| Node used by the tools | `export PATH=$PWD/.cache/node-v24.22.0-darwin-arm64/bin:$PATH` |
| Explore stories (PNG + DOM/computed-style dump) | `node Tools/capture-storybook.mjs --all '<id regex>'` → `.cache/storybook-refs/<id>.<theme>.{png,json,dom.json}` |
| Capture references for the stories in `stories.txt` | `node Tools/capture-storybook.mjs [--tests-dir <dir>]` |
| Story ids | `.cache/storybook-desktop/storybook-static/index.json` (`entries`, `type: story`) |
| Run the snapshot tests (**release**; debug is ~100× slower) | `cd Packages/SignalUI && swift test -c release --filter <Suite>` |
| Failure images | `Packages/SignalUI/.build/snapshot-failures/<id>.<theme>.{expected,actual,diff}.png` |
| Crop helper | `.cache/pyenv/bin/python -I .cache/crop.py <failure base> x y w h out.png` (stacks expected / actual / diff) |
| DOM dump as a tree (rects, class, text) | `python3 .cache/dom.py .cache/storybook-refs/<id>.<theme>.dom.json [depth]` |
| Bundled images (rasterised SVGs, PNGs) | `node Tools/gen-images.mjs` → `Sources/SignalUI/Resources/Images` (add new upstream image paths to its lists) |
| Regenerate tokens / symbols / tables / fonts | `node Tools/gen-tokens.mjs`, `node Tools/gen-symbols.mjs`, `node Tools/gen-axo-tables.mjs`, `Tools/gen-fonts.sh` |

Every run prints `SNAPSHOT <id>.<theme> <x>% differing`.

Captures are deterministic: every story load gets the same seeded `Math.random` and a clock frozen at 2026-11-04T12:00:00Z (`FIXED_NOW` in capture-storybook.mjs). Stories built on `test-helpers` (casual names, random colours, kitten avatars, random timestamps) therefore render the same values on every capture and in both themes; read them from the dom.json (text, computed `backgroundColor` / `backgroundImage`) and hardcode them in the test. Stories that use `Date.now()` see `FIXED_NOW`.

## Workflow per component

1. Read the upstream `.dom.tsx`, its CSS (`ts/axo/*.css` or `stylesheets/components/*.scss`) and its `.dom.stories.tsx`.
2. Run `--all '^<story-id-prefix>'` and study the PNGs and `dom.json`. The DOM dump gives every element's rect, font, line height, letter spacing, colours, padding and shadow, so you can see exact sizes.
3. Write `Sources/SignalUI/Axo/<Name>.swift` (or `Sources/SignalUI/Components/...`). Use a `public enum <Name>` namespace with nested views named like upstream's parts (`Root`, `Item`, `Content`, …). Keep the upstream variant names and order.
4. Write `Tests/SignalUITests/<Name>Tests.swift` with a SwiftUI twin of **each story's markup**, including its wrappers (`flex gap-4`, `p-4`, `<h1 type-title-large>`, `<code>`…), then `Snapshot.assertMatches(view, story: id, theme: theme)` for light and dark. Add the ids to `stories.txt` and capture the references.
5. Iterate until every story is ≤1% in both themes. Typical numbers are 0.0–0.4%.

## Rules learned so far (follow them; they are why tests pass)

- **Text:** never use SwiftUI `Text` for visible text. Use `CSSText(string, type: .bodyLarge)` or `CSSText(string, style: CSSTextStyle(...), wrap: .wrap | .truncate | .nowrap)`.
  - It measures and draws with CoreText at fractional widths, the way Chromium does. `Text` rounds to the pixel grid and drifts.
  - The colour is inherited via `.cssTextColor(AxoColor)`, or passed as `color:`.
  - Empty text is 0-height, as in CSS.
- **Type scale:** `AxoType.titleLarge` … `.caption`, with `.weight(500)` for `font-medium`.
  - Storybook's body text is `type-body-large`: 14px/20px with letter-spacing −0.084px. Descendants **inherit that absolute letter-spacing** unless a `type-*` class resets it.
  - Font weights map 600 and 700 → Inter-SemiBold, 500 → Inter-Medium (`AxoFonts.interName`).
- **Colours:** only `AxoColor.<token>` (generated, light and dark). Tailwind `bg-x` / `text-x` / `border-x` map to `fillX` / `labelX` / `borderX`. Look at the generated file for names.
- **Layout:** CSS flex is `CSSFlex(.row/.column, wrap:, gap:, justify:, align:)` with `.flexItem(grow:shrink:basis:minMain:alignSelf:)`. It implements the real flex algorithm (shrink to min-content and so on). CSS grid with explicit cells is `CSSGrid` with `.gridCell(row:column:)`. Use HStack/VStack only where no shrink or wrap can happen.
- **Margins:** vertical margins between block siblings collapse (`my-2` rows end up 8 apart).
- **Shadows:** `axoShadow(.shadowElevation1, in: shape)` or `cssBoxShadow([AxoShadowLayer], in:)`. Inset, spread and blur all follow CSS painting rules.
- **Symbols:** `AxoSymbol.InlineGlyph(name, size:, weight:)` (line-height 1) and `AxoSymbol.Icon(name, size:, label:)`.
- **Gradients:** `CSSLinearGradientFill(CSSLinearGradient(deg:start:end:))`, which interpolates in gamma sRGB as CSS does.
- **Animations:** honour `@Environment(\.axoAnimationsDisabled)`. Snapshots set it; infinite animations rest in their un-animated state.
- **ImageRenderer limits:** it does not draw ScrollView, List or any AppKit-backed view (NSViewRepresentable, TextField). Those render blank, and a test may still pass by luck. Under `@Environment(\.axoStaticRendering)`, which snapshots set, scroll containers render their content clipped at offset 0 (`AxoDialog.AxoScrollContainer`). Always look at the artifacts: `SNAPSHOT_ARTIFACTS=1 swift test …` writes expected/actual/diff images even on a pass.
- **Portals:** dialog, menu, popover and tooltip stories are captured as the whole 1200×900 viewport, with `portals` rects in the JSON. Render them with `PortalStage { story root at 16,16 } modal: { … }` (AxoDialogTests.swift).
- **Focus:** Radix auto-focuses a control when a dialog opens (Close, or AlertDialog Cancel). Pass `autoFocus: true`, which shows `axoFocusRing` until focus moves.
- **Auto margins:** `ms-auto` is `.flexItem(autoMarginStart: true)`. `min-content` / `ch` come from `CSSTextLayout.minContentWidth` / `.ch`.
- **`Group(subviews:)`:** container values (`.containerValue`) are visible only when set on a subview's top-level modifiers, not deeper inside its body. Environment values applied around the resolved subviews do **not** reach into them. To pass a computed value down, render the original `content` again with `.environment(…)` (AxoBaseMenu.Content, AxoDialog.Header).
- **Poppers:** menus, popovers and tooltips use `.axoPopper(id:isPresented:placement:)` on the trigger, and the window root (or `PopperStage` in tests) has `.axoLayerHost()`. `AxoPopper.place` mirrors Radix's side, align, sideOffset, flip and shift.
- **Rich text:** `CSSText(runs: [CSSTextRun(text, fontName:, color:, action:)], style:, onTap:)` lays runs out as one paragraph (bold links, inline buttons). `CSSTextRun.runs(i18n.richText(key, args), tags: ["tagName": I18nTagStyle(...)], elements: ["id": CSSTextRun(...)])` turns an `<I18n components={…}>` message into runs.
- **Line breaking:** CSSText breaks only where Chromium does (after spaces and hyphens, around CJK); a URL never breaks at "/" or ".". A word longer than the line overflows.
- **Inline-block after text:** `CSSInlineTail(text, style:) { button }` puts the box on the text's last line when it fits (LeftPaneDialog actions).
- **Shrink-to-fit:** `CSSShrinkToFit { … }` gives a child its max-content width capped at the proposal (a flex item in a `justify-end` row, abspos boxes).
- **Images:** never ImageIO / NSImage(data:) / CGImage(width:…provider:) (pointer API). `PixelImage(RGBAImage, fit: .cover)` draws an RGBA buffer through a Metal shader (area-filtered downscale, bilinear upscale). Bundled images: `BundledImage.named("pin-reminder")` (decoded by SignalCodecs' PNG decoder).
- **Dates:** Foundation's ICU writes U+202F before AM/PM where Chromium's Intl writes a space (`FormatTimestamp`).
- **Trailing closures:** when a generic view's init also has an optional closure parameter (e.g. `onClick`), a trailing content closure can bind to it once the generic is pinned (by a nested type like `X<EmptyView>.Kind`). Keep such enums top-level (`LeftPaneDialogType`).
- **Strict memory safety:** no `unsafe` anywhere, no `@unchecked Sendable`, no `String(format:)`, no `CGContext(data:)` / `CGGradient(…locations:)` (pointer APIs). The Package treats warnings as errors.

## Working in parallel

Use an isolated copy so that half-finished files never break someone else's build:
`Tools/agent-workspace.sh <name>` creates `.cache/agents/<name>/Packages/SignalUI` (a copy, with SignalCodecs symlinked). Inside it, run the capture tool with `--tests-dir` and `swift test`. When done, report the **new** files. Do not edit shared files (`Theme/*`, `Support/*`, `StoryKit.swift`, generated tokens) in the copy; propose such changes in your report.
