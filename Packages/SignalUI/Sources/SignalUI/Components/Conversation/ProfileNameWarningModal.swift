// Port of ts/components/conversation/ProfileNameWarningModal.dom.tsx: why profile names
// can't be trusted. A small AxoDialog with a floating close, a 48px safety-tinted circle
// with person-question (group-question), then the description and a bulleted list
// (text-primary; list-disc ps-4, 12px between items).

import SignalI18n
import SwiftUI

public struct ProfileNameWarningModal: View {
    public enum ConversationType: Sendable { case direct, group }
    let conversationType: ConversationType
    let onClose: () -> Void
    @Environment(\.i18n) var i18n

    public init(conversationType: ConversationType, onClose: @escaping () -> Void = {}) {
        self.conversationType = conversationType
        self.onClose = onClose
    }

    public var body: some View {
        let direct = conversationType == .direct
        let items = direct
            ? ["icu:ProfileNameWarningModal__warning--signal-cant-verify", "icu:ProfileNameWarningModal__warning--signal-wont-contact",
               "icu:ProfileNameWarningModal__warning--be-cautious", "icu:ProfileNameWarningModal__warning--dont-share-info"]
            : ["icu:ProfileNameWarningModal__list--item1--group", "icu:ProfileNameWarningModal__list--item2--group",
               "icu:ProfileNameWarningModal__list--item3--group"]
        AxoDialog.Content(size: .sm, hasHeader: false, hasFooter: false) {
            AxoDialog.Body {
                AxoSymbol.Icon(direct ? "person-question" : "group-question", size: 24, label: nil)
                    .cssTextColor(.labelSafety)
                    .frame(width: 48, height: 48)
                    .background(RoundedRectangle(cornerRadius: 24).fill(AxoColor.fillSafetyTint))
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 12)
                VStack(alignment: .leading, spacing: 0) {
                    CSSText(i18n(direct ? "icu:ProfileNameWarningModal__description--direct" : "icu:ProfileNameWarningModal__description--group"),
                            type: .bodyMedium, color: .labelPrimary)
                    ForEach(items, id: \.self) { key in
                        DiscListItem(text: i18n(key), style: CSSTextStyle(AxoType.bodyMedium)).padding(.top, 12)
                    }
                }
                .cssTextColor(.labelPrimary)
            }
        }
        .overlay(alignment: .top) {
            AxoDialog.Header(floating: true) { AxoDialog.Close(action: onClose) }
        }
    }
}

/// `<li>` in `list-disc ps-4`: the content 16px in, the outside marker ("• ") ending where the
/// content starts, on the first line's baseline.
struct DiscListItem: View {
    let text: String
    let style: CSSTextStyle
    @Environment(\.cssTextColor) var color

    var body: some View {
        let marker = CSSTextLayout.make(runs: [CSSTextRun("• ")], style, wrap: .nowrap, maxWidth: nil, colors: nil).width
        CSSText(text, style: style, color: color)
            .overlay(alignment: .topLeading) {
                CSSText("• ", style: style, wrap: .nowrap, color: color).fixedSize().offset(x: -marker)
            }
            .padding(.leading, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
