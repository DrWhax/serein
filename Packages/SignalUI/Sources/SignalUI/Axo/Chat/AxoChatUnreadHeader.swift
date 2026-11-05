// Port of ts/axo/chat/AxoChatUnreadHeader.dom.tsx: a separator with a centred
// "N Unread Messages" pill between two hairlines.

import SwiftUI

public enum AxoChatUnreadHeader {
    /// `<AxoChatUnreadHeader.Root>`: flex items-center gap-3 px-4 py-2.5
    public struct Root: View {
        let label: String

        public init(_ label: String) {
            self.label = label
        }

        /// `flex-1 border-t border-secondary`, centred on the 24pt pill: (24 − 1) / 2 = 11.5,
        /// which Chromium paints snapped to whole CSS pixels (12).
        var line: some View {
            Rectangle().fill(AxoColor.borderSecondary).frame(height: 1)
                .padding(.top, 12).frame(height: 24, alignment: .top)
                .flexItem(grow: 1, basis: 0)
        }

        public var body: some View {
            CSSFlex(.row, gap: 12, align: .center) {
                line
                // px-3 py-1 type-body-small font-medium text-primary rounded-full bg-surface-card
                // shadow-elevation-0 shadow-no-outline truncate
                CSSText(label, type: AxoType.bodySmall.weight(500), wrap: .truncate, color: .labelPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(AxoColor.surfaceCard))
                    .axoShadow(.baseShadowElevation0, in: Capsule())
                line
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityElement()
            .accessibilityLabel(label)
        }
    }
}
