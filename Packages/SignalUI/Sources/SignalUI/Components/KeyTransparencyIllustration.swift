// images/key-transparency-light.svg and -dark.svg (KeyTransparencyOnboardingDialog), drawn from
// their shapes: two tilted phones (rounded rects with a 2.797 stroke), each with a clipped
// shield-check glyph, and (light) the dashes between them. The light image is 113×110 shown at
// 110×110, and Tailwind's `img { height: auto }` keeps
// its aspect ratio (110×107.08).

import AppKit
import SignalI18n
import SwiftUI

struct KeyTransparencyIllustration: View {
    @Environment(\.colorScheme) var scheme

    struct Phone {
        let x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, angle: Double
    }

    struct Variant {
        let size: CGSize
        let phones: [Phone]
        let phoneFill: RGBA, phoneStroke: RGBA, glyph: RGBA
        /// (clip, paths) per phone, with even-odd flags.
        let glyphs: [(clip: String, paths: [(String, Bool)])]
        let dashes: String?
    }

    static let light = Variant(
        size: CGSize(width: 113, height: 110),
        phones: [Phone(x: 70.637, y: 11.268, width: 45.833, height: 78.81, angle: 25), Phone(x: 0, y: 30.497, width: 45.833, height: 79.121, angle: -25)],
        phoneFill: RGBA(hex: 0xffffff), phoneStroke: RGBA(hex: 0x757575), glyph: RGBA(hex: 0x4655ff),
        glyphs: [
            ("m71.344 31.666 24.923 11.622-11.622 24.923L59.722 56.59z", [
                ("M84.751 48.175a1.29 1.29 0 0 0-1.365-2.187l-7.159 4.47-.688-3.012a1.289 1.289 0 1 0-2.513.575l1.091 4.776a1.29 1.29 0 0 0 1.94.806z", false),
                ("M70.836 59.522a3.87 3.87 0 0 0 4.42 2.061l5.208-1.307a11.6 11.6 0 0 0 7.202-5.418l3.152-5.417a3.87 3.87 0 0 0-.684-4.753l-4.746-4.494a8.16 8.16 0 0 0-4.68-2.182l-6.494-.748a3.87 3.87 0 0 0-4.08 2.532l-2.124 5.896a11.6 11.6 0 0 0 .48 9zm3.792-.44a1.29 1.29 0 0 1-1.473-.687l-2.346-4.83a9.02 9.02 0 0 1-.373-7l2.123-5.896a1.29 1.29 0 0 1 1.36-.844l6.494.748a5.6 5.6 0 0 1 3.202 1.493l4.747 4.494a1.29 1.29 0 0 1 .228 1.584l-3.152 5.417a9.02 9.02 0 0 1-5.602 4.214z", true),
            ]),
            ("M16.057 43.122 40.98 31.5l11.622 24.924L27.68 68.046z", [
                ("M37.321 43.463a1.289 1.289 0 1 0-2.553-.36L33.59 51.46l-2.749-1.409a1.29 1.29 0 1 0-1.175 2.295l4.36 2.234a1.29 1.29 0 0 0 1.864-.968z", false),
                ("M37.069 61.416a3.87 3.87 0 0 0 4.42-2.06l2.346-4.83a11.6 11.6 0 0 0 .48-9l-2.124-5.897a3.87 3.87 0 0 0-4.08-2.531l-6.495.747a8.16 8.16 0 0 0-4.68 2.182l-4.746 4.494a3.87 3.87 0 0 0-.684 4.753l3.153 5.417a11.6 11.6 0 0 0 7.202 5.418zm2.1-3.187a1.29 1.29 0 0 1-1.473.687l-5.207-1.308a9.02 9.02 0 0 1-5.602-4.213l-3.152-5.417a1.29 1.29 0 0 1 .228-1.585l4.746-4.494a5.6 5.6 0 0 1 3.202-1.493l6.494-.747a1.29 1.29 0 0 1 1.36.844l2.124 5.896a9.02 9.02 0 0 1-.373 7z", true),
            ]),
        ],
        dashes: "m57.449 61.24 4.154 1.936m3.325 9.137 4.154 1.936M54.544 67.47l4.153 1.937m3.326 9.136 4.154 1.937M51.638 73.7l4.154 1.937")

    static let dark = Variant(
        size: CGSize(width: 110, height: 110),
        phones: [Phone(x: 69.636, y: 11.268, width: 45.833, height: 78.81, angle: 25), Phone(x: -1, y: 30.497, width: 45.833, height: 79.121, angle: -25)],
        phoneFill: RGBA(hex: 0x3b3b3b), phoneStroke: RGBA(hex: 0x949494), glyph: RGBA(hex: 0x99a1ff),
        glyphs: [
            ("m70.344 31.666 24.923 11.622-11.622 24.923L58.722 56.59z", [
                // The clip region filled with the phone colour (it covers the phone's stroke).
                ("m70.344 31.666 24.923 11.622-11.622 24.923L58.722 56.59z", false),
                ("M83.75 48.175a1.29 1.29 0 0 0-1.364-2.187l-7.159 4.47-.688-3.012a1.289 1.289 0 1 0-2.514.575l1.092 4.776a1.29 1.29 0 0 0 1.94.806z", false),
                ("M69.836 59.522a3.87 3.87 0 0 0 4.42 2.061l5.207-1.307a11.6 11.6 0 0 0 7.203-5.418l3.152-5.417a3.87 3.87 0 0 0-.684-4.753l-4.746-4.494a8.16 8.16 0 0 0-4.68-2.182l-6.494-.748a3.87 3.87 0 0 0-4.08 2.532l-2.124 5.896a11.6 11.6 0 0 0 .48 9zm3.792-.44a1.29 1.29 0 0 1-1.474-.687l-2.345-4.83a9.02 9.02 0 0 1-.373-7l2.123-5.896a1.29 1.29 0 0 1 1.36-.844l6.494.748c1.2.138 2.324.662 3.202 1.493l4.747 4.494a1.29 1.29 0 0 1 .228 1.584l-3.153 5.417a9.02 9.02 0 0 1-5.601 4.214z", true),
            ]),
            ("M15.057 43.122 39.98 31.5l11.622 24.924L26.68 68.046z", [
                ("M36.321 43.463a1.289 1.289 0 1 0-2.553-.36L32.59 51.46l-2.749-1.409a1.29 1.29 0 0 0-1.175 2.295l4.36 2.234a1.29 1.29 0 0 0 1.864-.968z", false),
                ("M36.068 61.416a3.87 3.87 0 0 0 4.42-2.06l2.347-4.83a11.6 11.6 0 0 0 .48-9l-2.124-5.897a3.87 3.87 0 0 0-4.08-2.531l-6.495.747a8.16 8.16 0 0 0-4.68 2.182l-4.746 4.494a3.87 3.87 0 0 0-.684 4.753l3.152 5.417a11.6 11.6 0 0 0 7.203 5.418zm2.102-3.187a1.29 1.29 0 0 1-1.474.687l-5.207-1.308a9.02 9.02 0 0 1-5.602-4.213l-3.152-5.417a1.29 1.29 0 0 1 .227-1.585L27.71 41.9a5.6 5.6 0 0 1 3.202-1.493l6.494-.747a1.29 1.29 0 0 1 1.36.844L40.89 46.4a9.02 9.02 0 0 1-.373 7z", true),
            ]),
        ],
        dashes: nil)

    var body: some View {
        let v = scheme == .dark ? Self.dark : Self.light
        let isDark = scheme == .dark
        Canvas { ctx, size in
            let scale = min(size.width / v.size.width, size.height / v.size.height)
            ctx.translateBy(x: (size.width - v.size.width * scale) / 2, y: (size.height - v.size.height * scale) / 2)
            ctx.scaleBy(x: scale, y: scale)
            // The dark image clips everything to its 110×110 box.
            if isDark { ctx.clip(to: Path(CGRect(origin: .zero, size: v.size))) }
            func phone(_ p: Phone) {
                let rect = Path(roundedRect: CGRect(x: p.x, y: p.y, width: p.width, height: p.height), cornerRadius: 9.167)
                    .applying(CGAffineTransform(translationX: -p.x, y: -p.y).concatenating(CGAffineTransform(rotationAngle: p.angle * .pi / 180))
                        .concatenating(CGAffineTransform(translationX: p.x, y: p.y)))
                ctx.fill(rect, with: .color(v.phoneFill.color))
                ctx.stroke(rect, with: .color(v.phoneStroke.color), lineWidth: 2.797)
            }
            func glyph(_ g: (clip: String, paths: [(String, Bool)]), firstIsBackground: Bool) {
                var c = ctx
                c.clip(to: SVGPathData.parse(g.clip) ?? Path())
                for (i, (d, eo)) in g.paths.enumerated() {
                    let color = firstIsBackground && i == 0 ? v.phoneFill : v.glyph
                    c.fill(SVGPathData.parse(d) ?? Path(), with: .color(color.color), style: FillStyle(eoFill: eo))
                }
            }
            phone(v.phones[0])
            glyph(v.glyphs[0], firstIsBackground: isDark)
            if let dashes = v.dashes {
                ctx.stroke(SVGPathData.parse(dashes) ?? Path(), with: .color(.white), style: StrokeStyle(lineWidth: 3.437, lineCap: .round))
            }
            phone(v.phones[1])
            glyph(v.glyphs[1], firstIsBackground: false)
        }
        // width="110" with preflight's `height: auto`: the SVG's own aspect ratio.
        .frame(width: 110, height: 110 * v.size.height / v.size.width)
        .accessibilityHidden(true)
    }
}

/// `KeyTransparencyOnboardingDialog`
public struct KeyTransparencyOnboardingDialog: View {
    static let url = URL(string: "https://support.signal.org/hc/articles/10223569377562")!
    let onClose: () -> Void
    let onContinue: () -> Void
    @Environment(\.i18n) var i18n
    public init(onClose: @escaping () -> Void = {}, onContinue: @escaping () -> Void = {}) {
        self.onClose = onClose
        self.onContinue = onContinue
    }
    public var body: some View {
        AxoDialog.Content(size: .md, hasHeader: false) {
            AxoDialog.Body {
                KeyTransparencyIllustration().frame(maxWidth: .infinity).padding(.bottom, 12)
                AxoDialog.BodyTitle(i18n("icu:KeyTransparencyOnboardingDialog__Title"), type: .titleMedium)
                // <paragraph>s in a flex column, gap 2.5 (text-pretty).
                VStack(alignment: .leading, spacing: 10) {
                    let rich = i18n.richText("icu:KeyTransparencyOnboardingDialog__Description-v2")
                    let paragraphs = rich.tagRanges.filter { $0.name == "paragraph" }.map { String(rich.plainText[$0.range]) }
                    ForEach(paragraphs, id: \.self) { p in
                        CSSText(p, type: .bodyMedium, wrap: .pretty)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            AxoDialog.Footer {
                AxoDialog.Actions {
                    AxoDialog.Action(i18n("icu:KeyTransparencyOnboardingDialog__LearnMore"), variant: .subtleSecondary, arrow: .externalLink) {
                        NSWorkspace.shared.open(Self.url)
                    }
                    AxoDialog.Action(i18n("icu:KeyTransparencyOnboardingDialog__Continue"), variant: .strongPrimary, action: onContinue)
                }
            }
        }
        .overlay(alignment: .top) { AxoDialog.Header(floating: true) { AxoDialog.Close(action: onClose) } }
    }
}
