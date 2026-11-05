// LastSeenIndicator (ts/components/conversation/LastSeenIndicator.dom.tsx +
// `.module-last-seen-indicator`): a 1px gray-45 rule and "N Unread Messages" (body-2-bold,
// gray-90 / gray-05) 3px under it, with 25px above and 35px below.

import SignalI18n
import SwiftUI

public struct LastSeenIndicator: View {
    let count: Int
    @Environment(\.i18n) var i18n

    public init(count: Int) { self.count = count }

    public var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(AxoColor(LegacyColor.gray45)).frame(height: 1)
            CSSText(i18n("icu:unreadMessages", ["count": .number(Double(count))]), style: LegacyType.body2(weight: 600), alignment: .center,
                    color: AxoColor(light: LegacyColor.gray90, dark: LegacyColor.gray05))
                .frame(maxWidth: .infinity)
                .padding(.top, 3)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(EdgeInsets(top: 25, leading: 0, bottom: 35, trailing: 0))
    }
}
