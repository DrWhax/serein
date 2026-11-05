// The Axo type scale (ts/axo/_tailwind-theme/fonts.css `type-*` presets) and a modifier
// that lays text out the way CSS does: font-size, font-weight, letter-spacing (em), and a
// fixed line-height whose extra space (half-leading) is split above and below each line.

import CoreText
import SwiftUI

public struct AxoType: Sendable, Hashable {
    public var size: CGFloat
    public var lineHeight: CGFloat
    public var weight: Int
    /// letter-spacing in em
    public var tracking: CGFloat

    public init(size: CGFloat, lineHeight: CGFloat, weight: Int, tracking: CGFloat) {
        self.size = size
        self.lineHeight = lineHeight
        self.weight = weight
        self.tracking = tracking
    }

    public static let titleLarge = AxoType(size: 24, lineHeight: 32, weight: 600, tracking: -0.019)
    public static let titleMedium = AxoType(size: 18, lineHeight: 24, weight: 600, tracking: -0.014)
    public static let titleSmall = AxoType(size: 14, lineHeight: 20, weight: 600, tracking: -0.006)
    public static let bodyLarge = AxoType(size: 14, lineHeight: 20, weight: 400, tracking: -0.006)
    public static let bodyMedium = AxoType(size: 13, lineHeight: 18, weight: 400, tracking: -0.003)
    public static let bodySmall = AxoType(size: 12, lineHeight: 16, weight: 400, tracking: 0)
    public static let caption = AxoType(size: 11, lineHeight: 14, weight: 400, tracking: 0.005)

    public func weight(_ w: Int) -> AxoType {
        var t = self
        t.weight = w
        return t
    }

    public var font: Font { AxoFonts.inter(size: size, weight: weight) }

    /// Inter's content-area height at this size (hhea ascent 2728 + descent 680 over 2816 units).
    public var contentHeight: CGFloat { size * (2728 + 680) / 2816 }
}

struct AxoTypeModifier: ViewModifier {
    let type: AxoType
    func body(content: Content) -> some View {
        let leading = max(0, type.lineHeight - type.contentHeight)
        content
            .font(type.font)
            .tracking(type.tracking * type.size)
            .lineSpacing(leading)
            .padding(.vertical, leading / 2)
    }
}

extension View {
    /// Applies an Axo type preset (`type-body-large` etc.).
    public func axoType(_ type: AxoType) -> some View { modifier(AxoTypeModifier(type: type)) }
}
