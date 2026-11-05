// Emojify (ts/components/conversation/Emojify.dom.tsx): text with each emoji as a FunInlineEmoji
// box (Signal's emoji font at the box size; `fontSizeOverride` for jumbomoji).

import SwiftUI

public struct Emojify: View {
    let text: String
    let fontSizeOverride: CGFloat?
    let style: CSSTextStyle
    let wrap: CSSTextWrap

    public init(_ text: String, fontSizeOverride: CGFloat? = nil, style: CSSTextStyle, wrap: CSSTextWrap = .wrap) {
        self.text = text
        self.fontSizeOverride = fontSizeOverride
        self.style = style
        self.wrap = wrap
    }

    /// The run for `text` (to combine with other runs in one paragraph).
    public static func run(_ text: String, fontSizeOverride: CGFloat? = nil, topMargin: CGFloat? = nil) -> CSSTextRun {
        var r = CSSTextRun(text)
        r.emojify = true
        r.emojiSize = fontSizeOverride
        r.emojiTopMargin = topMargin
        return r
    }

    public var body: some View {
        CSSText(runs: [Self.run(text, fontSizeOverride: fontSizeOverride)], style: style, wrap: wrap)
    }
}
