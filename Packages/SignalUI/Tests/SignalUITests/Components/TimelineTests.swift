// ts/components/conversation/Timeline.dom.stories.tsx and TimelineFloatingHeader.dom.stories.tsx.
// The Timeline stories end with four payment notifications and a payment message (id-15 to
// id-19); those rows are cut out of the captures (Tools/splice-reference.py), payments being
// out of scope. WithActiveMessageRequest, WithoutNewestMessageActiveMessageRequest,
// WithoutOldestMessage and TargetIndexToTop capture the same pixels as WithoutNewestMessage.
//
// The stories' floating header is positioned against the Storybook page (16px above the
// timeline); in the app the timeline is its containing block, which is what is drawn here.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct TimelineTests {
    static let now = TimelineMessageTests.now

    @Test(arguments: ["light", "dark"])
    func floatingHeader(theme: String) throws {
        let id = "components-timelinefloatingheader--"
        func stage(_ v: some View) -> some View { TimelineMessageTests.stage(v.padding(.top, -10)) }
        try Snapshot.assertMatches(stage(TimelineFloatingHeader(timestamp: Self.now, visible: false)), story: id + "default", theme: theme)
        try Snapshot.assertMatches(stage(TimelineFloatingHeader(timestamp: Self.now, visible: true)), story: id + "visible", theme: theme)
        try Snapshot.assertMatches(stage(TimelineFloatingHeader(timestamp: Self.now, visible: true, isLoading: true)), story: id + "loading", theme: theme)
    }

    static let ids = ["id-1", "id-2", "id-2.5", "id-3", "id-4", "id-5", "id-6", "id-7", "id-8", "id-9", "id-10", "id-11", "id-12", "id-13", "id-14"]

    static func message(_ id: String, _ text: String, direction: MessageDirection = .incoming, author: String = "Mattie Grady",
                        avatar: String = "kitten-2-64-64.jpg", status: MessageStatus = .sent, color: String = "crimson") -> TimelineItemType {
        var a = MessageProps.Author(id: author, title: author)
        a.avatar = fixtureImage(avatar)
        var p = MessageProps(id: id, direction: direction, author: a, text: text, timestamp: now)
        p.conversationType = .group
        p.status = direction == .outgoing ? status : nil
        p.bubbleColor = .preset(color)
        return .message(p)
    }

    static let hello = "Hello there from the new world!"
    static let lines = "Hello there from the new world! And this is multiple lines of text. Lines and lines and lines."

    static func item(_ id: String) -> TimelineItemType? {
        switch id {
        case "id-1": message(id, "🔥", color: "forest")
        case "id-2": message(id, hello + " http://somewhere.com", author: "Regan Murazik", color: "forest")
        case "id-2.5": .unsupportedMessage(UnsupportedMessage(canProcessNow: false, contactTitle: "Mr. Pig", contactIsMe: false))
        case "id-3": message(id, hello, author: "Nyah Stroman", avatar: "kitten-3-64-64.jpg")
        case "id-4": .timerNotification(TimerNotification(type: .fromMe, title: "It's Me", expireTimer: 7200))
        case "id-5": .timerNotification(TimerNotification(type: .fromOther, title: "(202) 555-0000", expireTimer: 7200))
        case "id-6": .safetyNumberNotification(SafetyNumberNotification(contactTitle: "Mr. Fire") {})
        case "id-7": .verificationNotification(VerificationNotification(type: .markVerified, isLocal: true, contactTitle: "Mrs. Ice"))
        case "id-8": .groupNotification(GroupNotification(fromTitle: "Mrs. Ice", changes: [
            .name("Squirrels and their uses"),
            .add([.init(id: "2", title: "Mr. Fire"), .init(id: "3", title: "Ms. Water")]),
        ]))
        case "id-9": .resetSessionNotification
        case "id-10": message(id, "🔥", direction: .outgoing, color: "plum")
        case "id-11": message(id, hello + " http://somewhere.com", direction: .outgoing, status: .read)
        case "id-12": message(id, hello + " 🔥", direction: .outgoing)
        case "id-13": message(id, lines, direction: .outgoing)
        case "id-14": message(id, lines, direction: .outgoing, status: .read)
        default: nil
        }
    }

    static func timeline(items: [String] = ids, haveNewest: Bool = false, haveOldest: Bool = false, oldestUnseenIndex: Int = 0,
                         totalUnseen: Int = 0) -> some View {
        Timeline(id: "conversation", items: items, haveNewest: haveNewest, haveOldest: haveOldest, oldestUnseenIndex: oldestUnseenIndex,
                 totalUnseen: totalUnseen, getTimestampForMessage: { _ in now }) { props in
            TimelineItem(item: item(props.id))
        } renderHeroRow: {
            ConversationHero(conversationType: .direct, title: "Cayce Bollard",
                             avatar: ConversationAvatarData(title: "Cayce Bollard", image: fixtureImage("kitten-4-112-112.jpg")),
                             acceptedMessageRequest: true, hasProfileName: true, isInSystemContacts: false,
                             sharedGroupNames: ["NYC Rock Climbers", "Dinner Party"])
        } renderTypingBubble: {
            TypingBubble(conversationType: .direct, typingContacts: [TypingContact(id: "t", title: "Typist", color: "A100")])
        }
    }

    static func stage(_ v: some View, height: CGFloat) -> some View {
        TimelineMessageTests.stage(v.frame(width: 1168, height: height), storyHeight: height).environment(\.viewportWidth, 1200)
    }

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        let c = "components-conversation-timeline--"
        try Snapshot.assertMatches(Self.stage(Self.timeline(haveNewest: true, haveOldest: true), height: 1311),
                                   story: c + "oldest-and-newest-without-payments", theme: theme)
        try Snapshot.assertMatches(Self.stage(Self.timeline(), height: 1072), story: c + "without-newest-message-without-payments", theme: theme)
        try Snapshot.assertMatches(Self.stage(Self.timeline(oldestUnseenIndex: 13, totalUnseen: 2), height: 1072),
                                   story: c + "last-seen-without-payments", theme: theme)
        try Snapshot.assertMatches(Self.stage(Self.timeline(items: []), height: 7), story: c + "empty-just-hero", theme: theme)
        // These capture the same pixels as WithoutNewestMessage (the message-request flag is the
        // composer's; the scroll targets don't move a timeline that isn't scrollable).
        for s in ["with-active-message-request", "without-newest-message-active-message-request", "without-oldest-message", "target-index-to-top"] {
            try Snapshot.assertMatches(Self.stage(Self.timeline(), height: 1072), story: c + s + "-without-payments", theme: theme)
        }
        // The invited-contacts dialog over the timeline: a viewport capture, whose payment rows
        // (y ≥ 1091) are below the fold, so nothing is spliced. Captured with
        // CAPTURE_SETTLE_MS=3000: before the scrollbar-gutter variable is measured, the dialog
        // body is briefly inset by an uncompensated 11px gutter. Avatars read off the capture.
        let invited: [NewlyCreatedGroupInvitedContactsDialog.Contact] = [("abc123", "John Bon Bon Jovi", 2), ("def456", "Bon John Bon Jovi", 1)]
            .map { .init(id: $0.0, title: $0.1, avatar: fixtureByURL("/fixtures/kitten-\($0.2)-64-64.jpg")) }
        try Snapshot.assertMatches(PortalStage { Self.stage(Self.timeline(), height: 1072) } modal: {
            AxoBaseDialog.Host { NewlyCreatedGroupInvitedContactsDialog(contacts: invited) }
        }, story: c + "with-invited-contacts-for-a-newly-created-group", theme: theme)
    }
}
