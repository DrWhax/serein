// Linkify view and body ranges; link detection is in SignalText (LinkifyIt, LinkPreviewRules).

import Foundation
import SignalText
import SwiftUI


/// `extractLinks` (MessageTextRenderer.dom.tsx): links found with emoji blanked to spaces,
/// only those fully visible within `displayedTextLength`.
public func extractLinks(_ originalMessageText: String, displayedTextLength: Int) -> [BodyRange] {
    var blanked = ""
    for ch in originalMessageText {
        blanked += CSSTextLayout.isEmoji(ch) ? String(repeating: " ", count: ch.utf16.count) : String(ch)
    }
    return LinkifyIt.match(blanked).filter { $0.lastIndex <= displayedTextLength }.map {
        BodyRange(start: $0.index, length: $0.lastIndex - $0.index, kind: .link(url: $0.url))
    }
}

/// Linkify (ts/components/conversation/Linkify.dom.tsx): text with its supported, non-sneaky
/// links as tappable runs (`<a>`: the inherited colour, underlined by the UA only on hover).
public struct Linkify: View {
    let text: String
    let style: CSSTextStyle
    @Environment(\.openURL) var openURL

    public init(_ text: String, style: CSSTextStyle) {
        self.text = text
        self.style = style
    }

    /// An unstyled `<a>` (Storybook / UA): underlined, in the UA link colour.
    public static let uaLinkColor = AxoColor(light: RGBA(3 / 255, 15 / 255, 252 / 255), dark: RGBA(153 / 255, 161 / 255, 1))

    /// The runs: emoji segments never contain links; links get the `action` of their URL.
    /// - Parameter emojify: `renderNonLink` is Emojify (MessageBody); the default is plain text.
    public static func runs(_ text: String, emojify: Bool = false) -> [CSSTextRun] {
        func plain(_ t: String) -> CSSTextRun { emojify ? Emojify.run(t) : CSSTextRun(t) }
        guard LinkPreviewRules.shouldLinkifyMessage(text) else { return [plain(text)] }
        var out: [CSSTextRun] = []
        var segment = ""
        func flush() {
            guard !segment.isEmpty else { return }
            let ns = segment as NSString
            var cursor = 0
            for m in LinkifyIt.match(segment) {
                if cursor < m.index { out.append(plain(ns.substring(with: NSRange(location: cursor, length: m.index - cursor)))) }
                var run = CSSTextRun(m.text)
                if LinkPreviewRules.isSupportedProtocol(m.url), LinkPreviewRules.isLinkSneaky(m.url) != .yes {
                    run.action = m.url
                    run.color = Linkify.uaLinkColor
                    run.underline = true
                }
                out.append(run)
                cursor = m.lastIndex
            }
            if cursor < ns.length { out.append(plain(ns.substring(from: cursor))) }
            segment = ""
        }
        for ch in text {
            if CSSTextLayout.isEmoji(ch) {
                flush()
                out.append(plain(String(ch)))
            } else {
                segment.append(ch)
            }
        }
        flush()
        return out
    }

    public var body: some View {
        CSSText(runs: Self.runs(text), style: style, onTap: { url in
            if let u = URL(string: url) { openURL(u) }
        })
    }
}
