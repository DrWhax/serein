// Port of ts/components/IdenticonSVG.dom.tsx: the 100×100 identicons drawn for notifications —
// an r40 circle in the avatar colour with the initials (sans-serif 24px, centred, baseline
// 8px below the middle), the group glyph, or the call-link glyph.

import CoreText
import SwiftUI

public struct IdenticonSVG: View {
    public enum Kind: Sendable { case contact(text: String), group, callLink }
    let kind: Kind
    let background: RGBA
    let foreground: RGBA

    public init(_ kind: Kind, background: RGBA, foreground: RGBA) {
        self.kind = kind
        self.background = background
        self.foreground = foreground
    }

    static let groupPaths: [(String, Bool)] = [
        ("M10.833 5.957c0-1.778 1.195-3.353 2.917-3.353 1.722 0 2.917 1.575 2.917 3.353 0 .902-.294 1.759-.794 2.404-.499.645-1.242 1.118-2.123 1.118-.88 0-1.624-.473-2.123-1.118-.5-.645-.794-1.502-.794-2.404Zm2.917-1.895c-.694 0-1.458.681-1.458 1.895 0 .594.196 1.134.488 1.511.292.378.643.553.97.553.327 0 .678-.175.97-.553.292-.377.488-.917.488-1.511 0-1.214-.764-1.895-1.458-1.895Z", true),
        ("M6.25 10.52c.93 0 1.821.202 2.613.564a6.44 6.44 0 0 0-1.03 1.152 4.905 4.905 0 0 0-1.583-.257c-2.23 0-3.934 1.421-4.226 3.125h4.769a6.113 6.113 0 0 0 .05 1.459H1.464a.94.94 0 0 1-.943-.938c0-2.907 2.66-5.104 5.729-5.104Z", false),
        ("M13.75 10.52c-3.07 0-5.73 2.198-5.73 5.105 0 .545.45.938.944.938h9.572a.94.94 0 0 0 .943-.938c0-2.907-2.66-5.104-5.729-5.104Zm0 1.46c2.23 0 3.934 1.42 4.226 3.124H9.524c.292-1.704 1.997-3.125 4.226-3.125Zm-7.5-9.376c-1.722 0-2.917 1.575-2.917 3.353 0 .902.294 1.759.794 2.404.499.645 1.242 1.118 2.123 1.118.881 0 1.624-.473 2.123-1.118.5-.645.794-1.502.794-2.404 0-1.778-1.195-3.353-2.917-3.353ZM4.792 5.957c0-1.214.764-1.895 1.458-1.895.695 0 1.458.681 1.458 1.895 0 .594-.195 1.134-.488 1.511-.292.378-.643.553-.97.553-.327 0-.678-.175-.97-.553-.292-.377-.488-.917-.488-1.511Z", true),
    ]
    static let callLinkPath = "M10.302 5.625c-1.22 0-2.203 0-3 .065-.82.067-1.54.209-2.206.548a5.625 5.625 0 0 0-2.458 2.458c-.34.667-.481 1.387-.548 2.207-.065.796-.065 1.78-.065 2.999v8.196c0 1.22 0 2.203.065 3 .067.82.208 1.54.548 2.206a5.625 5.625 0 0 0 2.458 2.458c.667.34 1.387.481 2.207.548.796.065 1.78.065 2.999.065h7.296c1.22 0 2.203 0 3-.065.82-.067 1.54-.209 2.206-.548a5.625 5.625 0 0 0 2.458-2.458c.34-.667.48-1.387.548-2.207.065-.796.065-1.78.065-2.999v-.032l4.775 4.775c1.559 1.56 4.225.455 4.225-1.75V10.909c0-2.205-2.666-3.31-4.225-1.75l-4.775 4.775v-.032c0-1.22 0-2.203-.065-3-.067-.82-.209-1.54-.548-2.206a5.625 5.625 0 0 0-2.458-2.458c-.667-.34-1.387-.481-2.207-.548-.796-.065-1.78-.065-2.999-.065h-7.296Zm13.323 8.325c0-1.279-.001-2.17-.058-2.864-.055-.68-.159-1.072-.31-1.368a3.374 3.374 0 0 0-1.475-1.475c-.296-.151-.687-.255-1.368-.31-.694-.057-1.585-.058-2.864-.058h-7.2c-1.279 0-2.17 0-2.864.058-.68.055-1.072.159-1.368.31a3.375 3.375 0 0 0-1.475 1.475c-.151.296-.255.687-.31 1.368-.057.694-.058 1.585-.058 2.864v8.1c0 1.279 0 2.17.057 2.864.056.68.16 1.072.31 1.368.324.635.84 1.152 1.476 1.475.296.151.687.255 1.368.31.694.057 1.585.058 2.864.058h7.2c1.279 0 2.17 0 2.864-.058.68-.055 1.072-.159 1.368-.31a3.374 3.374 0 0 0 1.475-1.475c.151-.296.255-.687.31-1.368.057-.694.058-1.585.058-2.864v-8.1Zm2.25 4.05c0 .566.225 1.109.625 1.51l5.74 5.74a.21.21 0 0 0 .116.066.24.24 0 0 0 .13-.017.239.239 0 0 0 .104-.08.21.21 0 0 0 .035-.128V10.909a.21.21 0 0 0-.035-.128.238.238 0 0 0-.104-.08.24.24 0 0 0-.13-.017.21.21 0 0 0-.115.066L26.5 16.49c-.4.401-.625.944-.625 1.51Z"

    public var body: some View {
        Canvas { ctx, _ in
            ctx.fill(Path(ellipseIn: CGRect(x: 10, y: 10, width: 80, height: 80)), with: .color(background.color))
            switch kind {
            case .contact(let text):
                // Chromium's sans-serif on macOS: Helvetica.
                let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: foreground.r, green: foreground.g, blue: foreground.b, alpha: foreground.a),
                ]))
                let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                ctx.withCGContext { cg in
                    cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                    cg.textPosition = CGPoint(x: 50 - width / 2, y: 58)
                    CTLineDraw(line, cg)
                }
            case .group:
                // viewBox 0 0 20 20 in 60×45 at (20, 27.5): scale 2.25, centred (x 27.5).
                let t = CGAffineTransform(translationX: 27.5, y: 27.5).scaledBy(x: 2.25, y: 2.25)
                for (d, eo) in Self.groupPaths {
                    ctx.fill((SVGPathData.parse(d) ?? Path()).applying(t), with: .color(foreground.color), style: FillStyle(eoFill: eo))
                }
            case .callLink:
                // viewBox 0 0 36 36 in 50×50 at (25, 26).
                let t = CGAffineTransform(translationX: 25, y: 26).scaledBy(x: 50.0 / 36, y: 50.0 / 36)
                ctx.fill((SVGPathData.parse(Self.callLinkPath) ?? Path()).applying(t), with: .color(foreground.color), style: FillStyle(eoFill: true))
            }
        }
        .frame(width: 100, height: 100)
        .accessibilityHidden(true)
    }
}
