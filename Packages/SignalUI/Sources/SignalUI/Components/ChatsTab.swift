// Port of ts/components/ChatsTab.dom.tsx (stylesheets/components/Inbox.scss): the left pane
// beside the conversation stack, which shows the selected conversation or, with none open,
// the splash: the 96px logo, "Welcome to Signal", the what's-new link and the nonprofit line.

import SwiftUI

public struct ChatsTab<LeftPaneView: View, ConversationView: View, MiniPlayer: View>: View {
    let isStaging: Bool
    let selectedConversationId: String?
    let showWhatsNewModal: () -> Void
    let renderLeftPane: () -> LeftPaneView
    let renderConversationView: (String) -> ConversationView
    let renderMiniPlayer: () -> MiniPlayer
    @Environment(\.i18n) var i18n

    public init(isStaging: Bool = false, selectedConversationId: String?, showWhatsNewModal: @escaping () -> Void = {},
                @ViewBuilder renderLeftPane: @escaping () -> LeftPaneView,
                @ViewBuilder renderConversationView: @escaping (String) -> ConversationView,
                @ViewBuilder renderMiniPlayer: @escaping () -> MiniPlayer) {
        self.isStaging = isStaging
        self.selectedConversationId = selectedConversationId
        self.showWhatsNewModal = showWhatsNewModal
        self.renderLeftPane = renderLeftPane
        self.renderConversationView = renderConversationView
        self.renderMiniPlayer = renderMiniPlayer
    }

    public var body: some View {
        HStack(spacing: 0) {
            renderLeftPane()
            // .Inbox__conversation-stack
            ZStack {
                if let selectedConversationId {
                    renderConversationView(selectedConversationId).id(selectedConversationId)
                } else {
                    noConversationOpen
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
    }

    static var welcomeStyle: CSSTextStyle {
        var s = LegacyType.titleMedium()
        s.lineHeight = 24
        return s
    }

    /// `.Inbox__no-conversation-open`: a centred column; `.Inbox__padding` (grow, ≤28px) lifts it
    /// a little above centre.
    var noConversationOpen: some View {
        VStack(spacing: 0) {
            renderMiniPlayer()
            SignalIcon("signal-logo", size: 96, color: AxoColor(light: LegacyColor.ultramarineLogo, dark: LegacyColor.white), mask: true)
            CSSText(isStaging ? "THIS IS A STAGING DESKTOP" : i18n("icu:welcomeToSignal"), style: Self.welcomeStyle, wrap: .nowrap,
                    color: .labelPrimary)
                .padding(.top, 20).padding(.bottom, 6)
            WhatsNewLink(showWhatsNewModal: showWhatsNewModal)
            Color.clear.frame(width: 0, height: 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            CSSText(i18n("icu:signalNonProfit"), style: CSSTextStyle(AxoType.bodyLarge), wrap: .nowrap, color: .labelSecondary)
                .padding(20)
        }
    }
}

/// `WhatsNewLink`: "See <what's new> in this update", the link a `.WhatsNew` button (label-accent).
public struct WhatsNewLink: View {
    let showWhatsNewModal: () -> Void
    public init(showWhatsNewModal: @escaping () -> Void) { self.showWhatsNewModal = showWhatsNewModal }
    @Environment(\.i18n) var i18n
    public var body: some View {
        I18n("icu:whatsNew", components: ["whatsNew": .run(CSSTextRun(i18n("icu:viewReleaseNotes"), color: .labelAccent, action: "whatsNew"))],
             style: CSSTextStyle(AxoType.bodyLarge)) { _ in showWhatsNewModal() }
            .fixedSize()
    }
}
