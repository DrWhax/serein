// ScrollDownButton (ts/components/conversation/ScrollDownButton.dom.tsx +
// stylesheets/components/ScrollDownButton.scss): a 36px round button (white / gray-75, two
// soft shadows) with a chevron-down (20px) or "@" (17px) in gray-75 / gray-15, and an
// ultramarine count badge 8px above it ("99+" from 100).

import SignalI18n
import SwiftUI

public struct ScrollDownButton: View {
    public enum Variant: Sendable { case unreadMessages, unreadMentions }
    let variant: Variant
    let count: Int?
    let onClick: () -> Void
    @Environment(\.i18n) var i18n

    public init(variant: Variant, count: Int? = nil, onClick: @escaping () -> Void) {
        self.variant = variant
        self.count = count
        self.onClick = onClick
    }

    var badgeText: String? {
        guard let count, count > 0 else { return nil }
        return count < 100 ? String(count) : "99+"
    }

    var altText: String {
        switch variant {
        case .unreadMessages: (count ?? 0) > 0 ? i18n("icu:messagesBelow") : i18n("icu:scrollDown")
        case .unreadMentions: i18n("icu:mentionsBelow")
        }
    }

    public var body: some View {
        let iconColor = AxoColor(light: LegacyColor.gray75, dark: LegacyColor.gray15)
        SwiftUI.Button(action: onClick) {
            Group {
                switch variant {
                case .unreadMessages: SignalIcon("v3/chevron/chevron-down", size: 20, color: iconColor)
                case .unreadMentions: SignalIcon("v3/at/at", size: 17, color: iconColor)
                }
            }
            .frame(width: 36, height: 36)
            .background(Circle().fill(AxoColor(light: LegacyColor.white, dark: LegacyColor.gray75)))
            .cssBoxShadow([AxoShadowLayer(inset: false, x: 0, y: 0, blur: 2, spread: 0, color: LegacyColor.blackAlpha20),
                           AxoShadowLayer(inset: false, x: 0, y: 2, blur: 6, spread: 0, color: LegacyColor.blackAlpha12)], in: Circle())
            .overlay(alignment: .top) {
                if let badgeText {
                    CSSText(badgeText, style: CSSTextStyle(fontName: AxoFonts.interName(weight: 400), size: 10, lineHeight: 14), wrap: .nowrap,
                            color: AxoColor(LegacyColor.white))
                        .padding(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Capsule().fill(AxoColor(LegacyColor.ultramarine)))
                        .cssBoxShadow([AxoShadowLayer(inset: false, x: 0, y: 1, blur: 4, spread: 0, color: LegacyColor.blackAlpha24)], in: Capsule())
                        .fixedSize()
                        .offset(y: -8)
                }
            }
        }
        .buttonStyle(.plain)
        .focusable(interactions: .activate)
        .help(altText)
        .accessibilityLabel(altText)
    }
}
