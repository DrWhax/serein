// ChatSessionRefreshedDialog and DeliveryIssueDialog (ts/components/conversation/*Dialog.dom.tsx):
// AxoDialog md panels with a floating header (only the close button, over the body), a
// 200×110 illustration, the title (type-title-medium), the explanation, and "Contact
// Support" / "Learn More" (external link) + OK. Present them in AxoBaseDialog.Host.

import SignalI18n
import SwiftUI

/// The shared layout of the timeline explainer dialogs.
struct TimelineExplainerDialog: View {
    let image: String
    let title: String
    let description: [CSSTextRun]
    let linkLabel: String
    let onLink: () -> Void
    let onClose: () -> Void
    @Environment(\.i18n) var i18n

    var body: some View {
        // A floating header does not count as a header: the body keeps its full top padding.
        AxoDialog.Content(size: .md, hasHeader: false) {
            AxoDialog.Body {
                HStack {
                    if let img = BundledImage.named(image) { PixelImage(img).frame(width: 200, height: 110) }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 10)
                // <AxoDialog.Title> outside a header: mb-2.5, here holding a type-title-medium span.
                CSSText(title, type: .titleMedium, color: .labelPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 10)
                    .accessibilityAddTraits(.isHeader)
                CSSText(runs: description, style: CSSTextStyle(AxoType.bodyMedium), color: .labelSecondary)
            }
            AxoDialog.Footer {
                AxoDialog.Actions {
                    AxoDialog.Action(linkLabel, variant: .subtleSecondary, arrow: .externalLink, action: onLink)
                    AxoDialog.Action(i18n("icu:ok"), variant: .strongPrimary, autoFocus: true, action: onClose)
                }
            }
        }
        .overlay(alignment: .top) {
            AxoDialog.Header(floating: true, focusesClose: false) { AxoDialog.Close(action: onClose) }
        }
    }
}

public struct ChatSessionRefreshedDialog: View {
    let onClose: () -> Void
    @Environment(\.i18n) var i18n
    @Environment(\.openURL) var openURL

    public init(onClose: @escaping () -> Void) { self.onClose = onClose }

    public var body: some View {
        TimelineExplainerDialog(image: "chat-session-refresh", title: i18n("icu:ChatRefresh--notification"),
                                description: [CSSTextRun(i18n("icu:ChatRefresh--summary"))], linkLabel: i18n("icu:ChatRefresh--contactSupport"),
                                onLink: {
                                    if let url = URL(string: "https://support.signal.org/hc/requests/new?desktop&chat_refreshed") { openURL(url) }
                                    onClose()
                                }, onClose: onClose)
    }
}

public struct DeliveryIssueDialog: View {
    let senderTitle: String
    let inGroup: Bool
    let onClose: () -> Void
    @Environment(\.i18n) var i18n
    @Environment(\.openURL) var openURL

    public init(senderTitle: String, inGroup: Bool, onClose: @escaping () -> Void) {
        self.senderTitle = senderTitle
        self.inGroup = inGroup
        self.onClose = onClose
    }

    public var body: some View {
        var sender = CSSTextRun(senderTitle)
        sender.emojify = true
        let summary = CSSTextRun.runs(i18n.richText(inGroup ? "icu:DeliveryIssue--summary--group" : "icu:DeliveryIssue--summary",
                                                    ["sender": .element("sender")]), elements: ["sender": sender])
        return TimelineExplainerDialog(image: "delivery-issue", title: i18n("icu:DeliveryIssue--title"), description: summary,
                                       linkLabel: i18n("icu:DeliveryIssue--learnMore"),
                                       onLink: { if let url = URL(string: "https://support.signal.org/hc/articles/4404859745690") { openURL(url) } },
                                       onClose: onClose)
    }
}
