// ts/components/conversation/TimelineItem.dom.stories.tsx. The Notification story's four
// payment rows are cut out of its capture (Tools/splice-reference.py, CSS rows 596–772):
// payments are out of scope. Its 19 call-history rows pass legacy call data with no
// `callHistory`, so they render nothing, as upstream.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct TimelineItemTests {
    static let story = "components-conversation-timelineitem--"

    @Test(arguments: ["light", "dark"])
    func plainMessage(theme: String) throws {
        var p = TimelineMessageTests.props("🔥", author: "(202) 555-2001")
        p.status = nil
        try Snapshot.assertMatches(TimelineMessageTests.stage(TimelineItem(item: .message(p))), story: Self.story + "plain-message", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func unknownType(theme: String) throws {
        try Snapshot.assertMatches(TimelineItem(item: .unknown("random")), story: Self.story + "unknown-type", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func errorBoundary(theme: String) throws {
        try Snapshot.assertMatches(ErrorBoundaryNotification(), story: "components-conversation-errorboundary--error-state", theme: theme)
    }

    static var notifications: [TimelineItemType] {
        let now = TimelineMessageTests.now
        let calls = (0..<19).map { _ in
            TimelineItemType.callHistory(CallingNotification(callHistory: nil, callCreator: nil, conversationId: "abc123", groupCallEnded: nil,
                                                             deviceCount: 0, maxDevices: 16))
        }
        return [
            .messageRequestResponse(MessageRequestResponseNotification(event: .accept, isGroup: false, isBlocked: false,
                                                                       renderedContact: CSSTextRun("Contact name"))),
            .timerNotification(TimerNotification(type: .fromOther, title: "Mattie Grady", expireTimer: 60)),
            .timerNotification(TimerNotification(type: .fromOther, title: "Bernadine Feil", expireTimer: nil)),
            .universalTimerNotification(UniversalTimerNotification(expireTimer: 3600)),
            .chatSessionRefreshed(ChatSessionRefreshedNotification()),
            .contactRemovedNotification,
            .safetyNumberNotification(SafetyNumberNotification(contactTitle: "Regan Murazik") {}),
            .deliveryIssue(DeliveryIssueNotification(senderName: "Nyah", inGroup: false)),
            .changeNumberNotification(ChangeNumberNotification(senderTitle: "Arvid Smitham", timestamp: now)),
            .titleTransitionNotification(TitleTransitionNotification(oldTitle: "alice.01")),
        ] + calls + [
            .profileChange(ProfileChangeNotification(oldName: "Fred", newName: "John", contactTitle: "Fred")),
            .pinnedMessage(PinnedMessageNotification(senderTitle: "You", senderIsMe: true)),
            .pinnedMessage(PinnedMessageNotification(senderTitle: "Janice Dach", senderIsMe: false)),
            .resetSessionNotification,
            .unsupportedMessage(UnsupportedMessage(canProcessNow: true, contactTitle: "Kaylee Bruen", contactIsMe: false)),
            .unsupportedMessage(UnsupportedMessage(canProcessNow: false, contactTitle: "Arielle Kozey", contactIsMe: false)),
            .verificationNotification(VerificationNotification(type: .markVerified, isLocal: false, contactTitle: "Hilbert Keebler")),
            .verificationNotification(VerificationNotification(type: .markVerified, isLocal: true, contactTitle: "Ruthe Bahringer")),
            .verificationNotification(VerificationNotification(type: .markNotVerified, isLocal: false, contactTitle: "Oren Rosenbaum")),
            .verificationNotification(VerificationNotification(type: .markNotVerified, isLocal: true, contactTitle: "Eugene Kuhlman")),
            .conversationMerge(ConversationMergeNotification(conversationTitle: "Alice", obsoleteConversationTitle: "Nancy",
                                                             obsoleteConversationNumber: "+121255501234")),
        ]
    }

    @Test(arguments: ["light", "dark"])
    func notification(theme: String) throws {
        let list = VStack(spacing: 0) {
            ForEach(Array(Self.notifications.enumerated()), id: \.offset) { _, item in TimelineItem(item: item) }
        }
        try Snapshot.assertMatches(TimelineMessageTests.stage(list), story: Self.story + "notification-without-payments", theme: theme)
    }
}
