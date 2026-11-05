// Port of ts/axo/AxoContactName.dom.tsx: the "in your system contacts" emblem shown after
// a contact's name — a round, line-height-1 button with the person-circle inline glyph and
// a tooltip.

import SwiftUI

public enum AxoContactName {
    /// `<AxoContactName.SystemContactEmblem>`: inline-flex size-fit rounded-full leading-none
    /// text-primary; the glyph takes the surrounding font size (`size`, 14 in body text).
    public struct SystemContactEmblem: View {
        let size: CGFloat
        let label: String

        public init(size: CGFloat = 14, label: String = "This person is in your contacts.") {
            self.size = size
            self.label = label
        }

        public var body: some View {
            Button {} label: {
                AxoSymbol.InlineGlyph("person-circle", size: size, weight: 400)
                    .cssTextColor(.labelPrimary)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(label)
            .accessibilityLabel(label)
        }
    }
}
