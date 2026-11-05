// Port of ts/components/SafetyTipsModal.dom.tsx: three safety tips with icons, and "View more"
// opening a six-card carousel (previous / next buttons and page dots).

import SwiftUI

public struct SafetyTipsModal: View {
    let onClose: () -> Void
    @State private var details = false
    @State private var pageIndex = 0
    @Environment(\.i18n) var i18n

    public init(onClose: @escaping () -> Void = {}) { self.onClose = onClose }

    static let summaryTips = [("SignalChat", "safety-tip-icon-chat-x"), ("NamesAndPhotos", "safety-tip-icon-person-question"), ("Scams", "safety-tip-icon-raised-hand")]
    static let detailTips = [("DontRespond", "DontRespond", "safety-tip-dont-respond"), ("ReviewNames", "ReviewNames", "safety-tip-review-names"),
                             ("Vague", "Vague", "safety-tip-vague"), ("Links-v2", "Links", "safety-tip-links"),
                             ("Crypto", "Crypto", "safety-tip-crypto"), ("Business", "Business", "safety-tip-business")]

    public var body: some View {
        AxoDialog.Content(size: .md) {
            if details { detailsPage } else { summary }
        }
    }

    @ViewBuilder var summary: some View {
        AxoDialog.Header {
            AxoDialog.Title(i18n("icu:SafetyTipsModal__Title-v2"))
            AxoDialog.Close(action: onClose)
        }
        AxoDialog.Body {
            // ul.mb-7.flex-col.gap-9 > li.flex.items-start.gap-4
            VStack(alignment: .leading, spacing: 36) {
                ForEach(Self.summaryTips, id: \.0) { key, icon in
                    HStack(alignment: .top, spacing: 16) {
                        SignalIcon("safety-tips/" + icon, size: 44).padding(.top, 4)
                        VStack(alignment: .leading, spacing: 4) {
                            CSSText(i18n("icu:SafetyTipsModal__TipTitle--\(key)"), type: .titleSmall, color: .labelPrimary)
                                .accessibilityAddTraits(.isHeader)
                            CSSText(i18n("icu:SafetyTipsModal__TipDescription--\(key)"), type: .bodyMedium, color: .labelSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.bottom, 28)
        }
        AxoDialog.Footer {
            AxoDialog.Actions(width: .fill) {
                AxoDialog.Action(i18n("icu:SafetyTipsModal__Button--ViewMore"), variant: .subtleSecondary) { details = true }
            }
        }
    }

    @ViewBuilder var detailsPage: some View {
        let tip = Self.detailTips[pageIndex]
        AxoDialog.Header {
            AxoDialog.Title(i18n("icu:SafetyTipsModal__Title-v2")).opacity(0).accessibilityHidden(false)
            AxoDialog.Close(action: onClose)
        }
        // A card: px-10, the 204px (w-51) image, title and description.
        VStack(alignment: .leading, spacing: 0) {
            SignalIcon("safety-tips/" + tip.2, size: nil).frame(width: 204, height: 136).frame(maxWidth: .infinity)
            CSSText(i18n("icu:SafetyTipsModal__TipTitle--\(tip.0)"), type: .titleSmall, color: .labelPrimary).padding(.top, 8)
                .accessibilityAddTraits(.isHeader)
            CSSText(i18n("icu:SafetyTipsModal__TipDescription--\(tip.1)"), type: .bodyMedium, color: .labelSecondary).padding(.top, 4)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(pageIndex)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(i18n("icu:Carousel__Slide--Role"))
        AxoDialog.Footer {
            HStack {
                AxoIconButton.Root(label: i18n("icu:previous"), tooltip: false, variant: .strongSecondary, size: .sm, symbol: "chevron-[start]",
                                   disabled: pageIndex == 0) { pageIndex = max(0, pageIndex - 1) }
                    .opacity(pageIndex == 0 ? 0 : 1)
                Spacer()
                HStack(spacing: 0) {
                    ForEach(Self.detailTips.indices, id: \.self) { i in
                        SwiftUI.Button { pageIndex = i } label: {
                            Circle().fill(AxoColor(light: RGBA(0, 0, 0, i == pageIndex ? 0.85 : 0.08), dark: RGBA(1, 1, 1, i == pageIndex ? 0.85 : 0.08)))
                                .frame(width: 8, height: 8).padding(4)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(i18n("icu:SafetyTipsModal__TipTitle--\(Self.detailTips[i].0)"))
                    }
                }
                Spacer()
                AxoIconButton.Root(label: i18n("icu:next"), tooltip: false, variant: .strongSecondary, size: .sm, symbol: "chevron-[end]",
                                   disabled: pageIndex == Self.detailTips.count - 1) { pageIndex = min(Self.detailTips.count - 1, pageIndex + 1) }
                    .opacity(pageIndex == Self.detailTips.count - 1 ? 0 : 1)
            }
            .frame(maxWidth: .infinity)
        }
    }
}
