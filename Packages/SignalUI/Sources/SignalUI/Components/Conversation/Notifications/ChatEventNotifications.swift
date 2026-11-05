// Timeline notifications built on AxoChatEvent (secondary variant) and the remaining
// SystemMessage ones: ChatSessionRefreshedNotification, DeliveryIssueNotification,
// ConversationMergeNotification, PhoneNumberDiscoveryNotification, UnsupportedMessage.
// The "Learn More" actions open their dialogs through `onLearnMore` (the dialogs are separate
// components: ChatSessionRefreshedDialog, DeliveryIssueDialog, the merge explainer).

import SignalI18n
import SwiftUI

extension RichText {
    /// The rich text as plain text, elements replaced by `elements[id]`.
    func plain(_ elements: [String: String]) -> String {
        runs.map { run in
            switch run.content {
            case .text(let s): s
            case .element(let id): elements[id] ?? ""
            }
        }.joined()
    }
}

/// ts/components/conversation/ChatSessionRefreshedNotification.dom.tsx
public struct ChatSessionRefreshedNotification: View {
    let onLearnMore: () -> Void
    @Environment(\.i18n) var i18n
    public init(onLearnMore: @escaping () -> Void = {}) { self.onLearnMore = onLearnMore }
    public var body: some View {
        AxoChatEvent.Root(variant: .secondary) {
            AxoChatEvent.Body(symbol: "arrow-clockwise") { i18n("icu:ChatRefresh--notification") }
            AxoChatEvent.Action(i18n("icu:ChatRefresh--learnMore"), onClick: onLearnMore)
        }
    }
}

/// ts/components/conversation/DeliveryIssueNotification.dom.tsx (nothing without a sender).
public struct DeliveryIssueNotification: View {
    /// `sender.firstName || sender.title`
    let senderName: String?
    let inGroup: Bool
    let onLearnMore: () -> Void
    @Environment(\.i18n) var i18n
    public init(senderName: String?, inGroup: Bool, onLearnMore: @escaping () -> Void = {}) {
        self.senderName = senderName
        self.inGroup = inGroup
        self.onLearnMore = onLearnMore
    }
    public var body: some View {
        if let senderName {
            AxoChatEvent.Root(variant: .secondary) {
                AxoChatEvent.Body(symbol: "info-circle") {
                    i18n.richText("icu:DeliveryIssue--notification", ["sender": .element("sender")]).plain(["sender": senderName])
                }
                AxoChatEvent.Action(i18n("icu:DeliveryIssue--learnMore"), onClick: onLearnMore)
            }
        }
    }
}

/// ts/components/conversation/ConversationMergeNotification.dom.tsx (+ getStringForConversationMerge)
public struct ConversationMergeNotification: View {
    let conversationTitle: String
    let obsoleteConversationTitle: String?
    let obsoleteConversationNumber: String?
    let onLearnMore: () -> Void
    @Environment(\.i18n) var i18n

    public init(conversationTitle: String, obsoleteConversationTitle: String?, obsoleteConversationNumber: String?,
                onLearnMore: @escaping () -> Void = {}) {
        self.conversationTitle = conversationTitle
        self.obsoleteConversationTitle = obsoleteConversationTitle
        self.obsoleteConversationNumber = obsoleteConversationNumber
        self.onLearnMore = onLearnMore
    }

    var message: String {
        guard let obsolete = obsoleteConversationTitle, !obsolete.isEmpty else {
            return i18n("icu:ConversationMerge--notification--no-title", ["conversationTitle": .string(conversationTitle)])
        }
        if let number = obsoleteConversationNumber, !number.isEmpty {
            return i18n("icu:ConversationMerge--notification--with-e164",
                        ["conversationTitle": .string(conversationTitle), "obsoleteConversationNumber": .string(number)])
        }
        return i18n("icu:ConversationMerge--notification",
                    ["obsoleteConversationTitle": .string(obsolete), "conversationTitle": .string(conversationTitle)])
    }

    public var body: some View {
        AxoChatEvent.Root(variant: .secondary) {
            AxoChatEvent.Body(symbol: "merge") { message }
            if let t = obsoleteConversationTitle, !t.isEmpty {
                AxoChatEvent.Action(i18n("icu:ConversationMerge--learn-more"), onClick: onLearnMore)
            }
        }
    }
}

/// ts/components/conversation/PhoneNumberDiscoveryNotification.dom.tsx (+ getStringForPhoneNumberDiscovery)
public struct PhoneNumberDiscoveryNotification: View {
    let conversationTitle: String
    let phoneNumber: String
    /// The first shared group's name (`getSharedGroupNames` on mount).
    let sharedGroup: String?
    @Environment(\.i18n) var i18n

    public init(conversationTitle: String, phoneNumber: String, sharedGroup: String?) {
        self.conversationTitle = conversationTitle
        self.phoneNumber = phoneNumber
        self.sharedGroup = sharedGroup
    }

    var message: String {
        if let sharedGroup, !sharedGroup.isEmpty {
            return i18n("icu:PhoneNumberDiscovery--notification--withSharedGroup",
                        ["phoneNumber": .string(phoneNumber), "conversationTitle": .string(conversationTitle), "sharedGroup": .string(sharedGroup)])
        }
        return i18n("icu:PhoneNumberDiscovery--notification--noSharedGroup",
                    ["phoneNumber": .string(phoneNumber), "conversationTitle": .string(conversationTitle)])
    }

    public var body: some View { SystemMessage(.icon("v3/info/info-compact"), contents: [Emojify.run(message)]) }
}

/// ts/components/conversation/UnsupportedMessage.dom.tsx
public struct UnsupportedMessage: View {
    let canProcessNow: Bool
    let contactTitle: String
    let contactIsMe: Bool
    @Environment(\.i18n) var i18n
    @Environment(\.openURL) var openURL

    public init(canProcessNow: Bool, contactTitle: String, contactIsMe: Bool) {
        self.canProcessNow = canProcessNow
        self.contactTitle = contactTitle
        self.contactIsMe = contactIsMe
    }

    var contents: [CSSTextRun] {
        let contact = ["contact": Emojify.run(contactTitle)]
        switch (contactIsMe, canProcessNow) {
        case (true, true): return CSSTextRun.runs(i18n.richText("icu:Message--unsupported-message-ask-to-resend", ["contact": .element("contact")]), elements: contact)
        case (true, false): return CSSTextRun.runs(i18n.richText("icu:Message--from-me-unsupported-message"))
        case (false, true): return CSSTextRun.runs(i18n.richText("icu:Message--from-me-unsupported-message-ask-to-resend"))
        case (false, false): return CSSTextRun.runs(i18n.richText("icu:Message--unsupported-message", ["contact": .element("contact")]), elements: contact)
        }
    }

    public var body: some View {
        SystemMessage(.icon(canProcessNow ? "v3/check/check-circle-compact" : "v3/error/error-circle-compact"), contents: contents) {
            if !canProcessNow {
                LegacyButton(i18n("icu:Message--update-signal"), size: .small, variant: .systemMessage) {
                    if let url = URL(string: "https://signal.org/download") { openURL(url) }
                }
            }
        }
    }
}
