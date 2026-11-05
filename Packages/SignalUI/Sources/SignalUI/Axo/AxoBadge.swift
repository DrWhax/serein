// Port of ts/axo/AxoBadge.dom.tsx: unread / mention / error / count badge.

import Foundation
import SwiftUI

public enum AxoBadge {
    public enum Variant: String, CaseIterable, Sendable { case primary, secondary, destructive }
    public enum Size: String, CaseIterable, Sendable {
        case dot, sm, md, lg
        var minSize: CGFloat {
            switch self {
            case .dot: 6
            case .sm: 14
            case .md: 16
            case .lg: 18
            }
        }
        var fontSize: CGFloat { self == .sm ? 8 : 11 }
        var countPadding: CGFloat {
            switch self {
            case .dot: 0
            case .sm: 3
            case .md: 4
            case .lg: 5
            }
        }
    }
    public enum Value: Sendable, Equatable { case count(Int), mention, unread, error }

    /// `formatBadgeCount`: grouped digits, or "<max>+" (AxoBadge.MaxOverflow) above `max`.
    public static func format(_ value: Int, max: Int?, locale: Locale = Locale(identifier: "en-US")) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        if let max, value > max { return (f.string(from: NSNumber(value: max)) ?? "\(max)") + "+" }
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// `<AxoBadge.Root>`
    public struct Root: View {
        let variant: Variant
        let size: Size
        let value: Value
        let max: Int?
        let label: String?
        /// Inherited `letter-spacing` (absolute, e.g. -0.084px under type-body-large).
        let letterSpacing: CGFloat

        public init(variant: Variant, size: Size, value: Value, max: Int?, label: String?, letterSpacing: CGFloat = -0.084) {
            self.variant = variant
            self.size = size
            self.value = value
            self.max = max
            self.label = label
            self.letterSpacing = letterSpacing
        }

        var colors: (AxoColor, AxoColor) {
            switch variant {
            case .primary: (.fillAccent, .labelPrimaryOncolor)
            case .secondary: (.fillPrimary, .labelSecondary)
            case .destructive: (.fillDestructive, .labelPrimaryOncolor)
            }
        }

        public var body: some View {
            let (bg, fg) = colors
            let lineHeight = size.minSize
            ZStack {
                if size != .dot {
                    switch value {
                    case .unread: EmptyView()
                    case .error: AxoSymbol.InlineGlyph("error", size: size.fontSize, weight: 600)
                    case .mention: AxoSymbol.InlineGlyph("at", size: size.fontSize, weight: 600)
                    case .count(let n):
                        CSSText(AxoBadge.format(n, max: max),
                                style: CSSTextStyle(fontName: AxoFonts.interName(weight: 600), size: size.fontSize, lineHeight: lineHeight,
                                                    letterSpacing: letterSpacing), wrap: .nowrap)
                            .padding(.horizontal, size.countPadding)
                    }
                }
            }
            .frame(minWidth: size.minSize, minHeight: size.minSize)
            .fixedSize()
            .cssTextColor(fg)
            .background(Capsule().fill(bg))
            .clipShape(Capsule())
            .accessibilityElement()
            .accessibilityLabel(label ?? "")
            .accessibilityHidden(label == nil)
        }
    }
}
