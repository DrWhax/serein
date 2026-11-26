#if os(Linux)
import SwiftUI

/// The centered, two-line caption below an Axo stacked button.
struct LineClampText: View {
    let string: String
    let style: CSSTextStyle
    let maxLines: Int
    @Environment(\.cssTextColor) private var color

    init(_ string: String, style: CSSTextStyle, maxLines: Int) {
        self.string = string
        self.style = style
        self.maxLines = maxLines
    }

    var body: some View {
        let metrics = style.fontMetrics
        let leading = max(0, style.lineHeight - metrics.ascent - metrics.descent)
        Text(verbatim: string)
            .font(.custom(style.fontName, fixedSize: style.size))
            .tracking(style.letterSpacing)
            .foregroundStyle(color)
            .lineSpacing(leading)
            .lineLimit(maxLines)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, leading / 2)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(string)
    }
}
#endif
