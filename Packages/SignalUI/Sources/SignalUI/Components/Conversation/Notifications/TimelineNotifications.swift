// The remaining timeline notification rows that TimelineItem dispatches to:
// ts/components/conversation/UniversalTimerNotification.dom.tsx,
// MessageRequestResponseNotification.dom.tsx, pinned-messages/PinnedMessageNotification.dom.tsx,
// and ErrorBoundary.dom.tsx's fallback (`.module-error-boundary-notification`).

import SignalI18n
import SwiftUI

/// "The disappearing message time will be set to {timeValue} when you message them."
/// Renders nothing without a timer.
public struct UniversalTimerNotification: View {
    let expireTimer: Int?
    @Environment(\.i18n) var i18n
    public init(expireTimer: Int?) { self.expireTimer = expireTimer }
    public var body: some View {
        if let expireTimer, expireTimer > 0 {
            SystemMessage(.icon("v3/timer/timer-compact"),
                          text: i18n("icu:UniversalTimerNotification__text", ["timeValue": .string(ExpirationTimer.format(i18n, expireTimer))]))
        }
    }
}

/// `MessageRequestResponseEvent`
public enum MessageRequestResponseEvent: String, Sendable, Hashable {
    case accept = "ACCEPT", block = "BLOCK", unblock = "UNBLOCK", spam = "SPAM"
}

public struct MessageRequestResponseNotification: View {
    let event: MessageRequestResponseEvent
    let isGroup: Bool
    let isBlocked: Bool
    /// `renderContact(conversationId)` for 1:1 chats (upstream passes null in groups).
    let renderedContact: CSSTextRun?
    let onBlockOrReport: () -> Void
    let onLearnMore: () -> Void
    @Environment(\.i18n) var i18n

    public init(event: MessageRequestResponseEvent, isGroup: Bool, isBlocked: Bool, renderedContact: CSSTextRun?,
                onBlockOrReport: @escaping () -> Void = {}, onLearnMore: @escaping () -> Void = {}) {
        self.event = event
        self.isGroup = isGroup
        self.isBlocked = isBlocked
        self.renderedContact = renderedContact
        self.onBlockOrReport = onBlockOrReport
        self.onLearnMore = onLearnMore
    }

    public var body: some View {
        switch event {
        case .accept:
            let contents: [CSSTextRun] = if !isGroup, let renderedContact {
                CSSTextRun.runs(i18n.richText("icu:MessageRequestResponseNotification__Message--Accepted-Contact-Title",
                                              ["userProfileName": .element("userProfileName")]),
                                elements: ["userProfileName": renderedContact])
            } else {
                [CSSTextRun(i18n("icu:MessageRequestResponseNotification__Message--Accepted"))]
            }
            SystemMessage(.icon("v3/thread/thread"), contents: contents) {
                if !isBlocked {
                    LegacyButton(i18n("icu:MessageRequestResponseNotification__Button--block-or-report"), size: .small, variant: .systemMessage,
                                 action: onBlockOrReport)
                }
            }
        case .block:
            SystemMessage(.icon("v3/block/block"), text: i18n(isGroup ? "icu:MessageRequestResponseNotification__Message--Blocked--Group"
                                                               : "icu:MessageRequestResponseNotification__Message--Blocked"))
        case .unblock:
            SystemMessage(.icon("v3/thread/thread"), text: i18n(isGroup ? "icu:MessageRequestResponseNotification__Message--Unblocked--Group"
                                                                 : "icu:MessageRequestResponseNotification__Message--Unblocked"))
        case .spam:
            // The Learn More button opens SafetyTipsModal (ported with the modals).
            SystemMessage(.icon("v3/spam/spam"), contents: [CSSTextRun(i18n("icu:MessageRequestResponseNotification__Message--Reported"))]) {
                LegacyButton(i18n("icu:MessageRequestResponseNotification__Button--LearnMore"), size: .small, variant: .systemMessage,
                             action: onLearnMore)
            }
        }
    }
}

/// "You pinned a message" / "{sender} pinned a message", with "Go to message".
public struct PinnedMessageNotification: View {
    let senderTitle: String
    let senderIsMe: Bool
    let expireTimer: (length: TimeInterval, expiration: Date)?
    let onScrollToPinnedMessage: () -> Void
    @Environment(\.i18n) var i18n

    public init(senderTitle: String, senderIsMe: Bool, expireTimer: (length: TimeInterval, expiration: Date)? = nil,
                onScrollToPinnedMessage: @escaping () -> Void = {}) {
        self.senderTitle = senderTitle
        self.senderIsMe = senderIsMe
        self.expireTimer = expireTimer
        self.onScrollToPinnedMessage = onScrollToPinnedMessage
    }

    public var body: some View {
        let contents: [CSSTextRun] = senderIsMe ? [CSSTextRun(i18n("icu:PinnedMessageNotification__Message--You"))]
            : CSSTextRun.runs(i18n.richText("icu:PinnedMessageNotification__Message--SomeoneElse", ["sender": .element("sender")]),
                              elements: ["sender": Emojify.run(senderTitle)])
        SystemMessage(.symbol("pin"), contents: contents, expireTimer: expireTimer) {
            LegacyButton(i18n("icu:PinnedMessageNotification__Button"), size: .small, variant: .systemMessage, action: onScrollToPinnedMessage)
        }
    }
}

/// ErrorBoundary's fallback: a 20px error icon (60%) 8px above "Couldn't display this
/// message. Click to submit a debug log." (80%), centred, gray-60 / gray-05; Enter, Space or a
/// click opens the debug log.
public struct ErrorBoundaryNotification: View {
    let showDebugLog: () -> Void
    @Environment(\.i18n) var i18n
    public init(showDebugLog: @escaping () -> Void = {}) { self.showDebugLog = showDebugLog }

    public var body: some View {
        let color = AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray05)
        VStack(spacing: 8) {
            SignalIcon("v2/error-solid-24", size: 20, color: color).opacity(0.6)
            CSSText(i18n("icu:ErrorBoundaryNotification__text"), style: LegacyType.body1(), alignment: .center, color: color)
                .opacity(0.8)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: showDebugLog)
        .focusable(interactions: .activate)
        .onKeyPress(keys: [.return, .space]) { _ in showDebugLog(); return .handled }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
