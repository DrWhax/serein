// Timeline notification rows (ts/components/conversation/*Notification.dom.stories.tsx).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct NotificationTests {
    /// Two variants with the story's `<div style={{ padding: '1em' }} />` (28px) between.
    static func pair(_ a: some View, _ b: some View) -> some View {
        VStack(spacing: 0) { a; Color.clear.frame(height: 28); b }
    }

    @Test(arguments: ["light", "dark"])
    func timer(theme: String) throws {
        let cases: [(String, TimerNotification.Source, String)] = [
            ("set-by-other", .fromOther, "Mr. Fire"), ("set-by-other-with-a-long-name", .fromOther, String(repeating: "🦴🧩📴", count: 50)),
            ("set-by-you", .fromMe, "Mr. Fire"), ("set-by-sync", .fromSync, "Mr. Fire"), ("set-by-unknown-contact", .fromMember, "Unknown contact"),
        ]
        for (name, type, title) in cases {
            try Snapshot.assertMatches(Self.pair(TimerNotification(type: type, title: title, expireTimer: 3600),
                                                 TimerNotification(type: type, title: title, expireTimer: nil)),
                                       story: "components-conversation-timernotification--\(name)", theme: theme)
        }
    }

    @Test(arguments: ["light", "dark"])
    func safetyNumber(theme: String) throws {
        try Snapshot.assertMatches(SafetyNumberNotification(contactTitle: "Mr. Fire") {},
                                   story: "components-conversation-safetynumbernotification--default", theme: theme)
        try Snapshot.assertMatches(SafetyNumberNotification(contactTitle: String(repeating: "🐈‍⬛🍕🎂", count: 50)) {},
                                   story: "components-conversation-safetynumbernotification--long-name", theme: theme)
    }

    static func london(_ v: some View) -> some View {
        v.environment(\.conversationListNow, Date(timeIntervalSince1970: 1_793_793_600)).environment(\.timeZone, TimeZone(identifier: "Europe/London")!)
    }

    @Test(arguments: ["light", "dark"])
    func verification(theme: String) throws {
        let id = "components-conversation-verificationnotification--"
        try Snapshot.assertMatches(VerificationNotification(type: .markVerified, isLocal: true, contactTitle: "Mr. Fire"), story: id + "mark-as-verified", theme: theme)
        try Snapshot.assertMatches(VerificationNotification(type: .markNotVerified, isLocal: true, contactTitle: "Mr. Fire"), story: id + "mark-as-not-verified", theme: theme)
        try Snapshot.assertMatches(VerificationNotification(type: .markVerified, isLocal: false, contactTitle: "Mr. Fire"),
                                   story: id + "mark-as-verified-remotely", theme: theme)
        try Snapshot.assertMatches(VerificationNotification(type: .markNotVerified, isLocal: false, contactTitle: "Mr. Fire"),
                                   story: id + "mark-as-not-verified-remotely", theme: theme)
        try Snapshot.assertMatches(VerificationNotification(type: .markVerified, isLocal: true, contactTitle: String(repeating: "🎆🍬🏈", count: 50)),
                                   story: id + "long-name", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func profileChange(theme: String) throws {
        let id = "components-conversation-profilechangenotification--"
        try Snapshot.assertMatches(ProfileChangeNotification(oldName: "Mr. Fire 🔥 Old", newName: "Mr. Fire 🔥 New", contactTitle: "Mr. Fire 🔥",
                                                             contactName: "Mr. Fire 🔥"), story: id + "from-contact", theme: theme)
        try Snapshot.assertMatches(ProfileChangeNotification(oldName: "Mr. Fire 🔥 Old", newName: "Mr. Fire 🔥 New", contactTitle: "Mr. Fire 🔥"),
                                   story: id + "from-non-contact", theme: theme)
        try Snapshot.assertMatches(ProfileChangeNotification(oldName: String(repeating: "💅🤷🏽‍♀️🏯", count: 50), newName: String(repeating: "☎️🎉🏝", count: 50),
                                                             contactTitle: "Mr. Fire 🔥"),
                                   story: id + "from-contact-with-long-names-before-and-after", theme: theme)
        try Snapshot.assertMatches(ProfileChangeNotification(oldName: "Mr. Fire 🔥 Old", newName: "Mr. Fire 🔥 New", contactTitle: "Mr. Fire 🔥", hasNickname: true),
                                   story: id + "with-nickname", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func others(theme: String) throws {
        let april = Date(timeIntervalSince1970: 1_618_894_800)
        // getDefaultConversation's seeded title ("Mattie Grady") wins over the long first name.
        try Snapshot.assertMatches(Self.london(ChangeNumberNotification(senderTitle: "Mattie Grady", timestamp: april)),
                                   story: "components-conversation-changenumbernotification--default", theme: theme)
        try Snapshot.assertMatches(Self.london(ChangeNumberNotification(senderTitle: "Mattie Grady", timestamp: april)),
                                   story: "components-conversation-changenumbernotification--long-name", theme: theme)
        try Snapshot.assertMatches(Self.london(JoinedSignalNotification(timestamp: april)),
                                   story: "components-conversation-joinedsignalnotification--default", theme: theme)
        try Snapshot.assertMatches(ResetSessionNotification(), story: "components-conversation-resetsessionnotification--notification", theme: theme)
        try Snapshot.assertMatches(TitleTransitionNotification(oldTitle: "alice.01"),
                                   story: "components-conversation-titletransitionnotification--default", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func chatEvents(theme: String) throws {
        let c = "components-conversation-"
        try Snapshot.assertMatches(ChatSessionRefreshedNotification(), story: c + "chatsessionrefreshednotification--default", theme: theme)
        try Snapshot.assertMatches(DeliveryIssueNotification(senderName: "Mattie", inGroup: false), story: c + "deliveryissuenotification--default", theme: theme)
        try Snapshot.assertMatches(DeliveryIssueNotification(senderName: "Mattie", inGroup: true), story: c + "deliveryissuenotification--in-group", theme: theme)
        try Snapshot.assertMatches(DeliveryIssueNotification(senderName: String(repeating: "🤷🏽‍♀️❤️🐞", count: 50), inGroup: false),
                                   story: c + "deliveryissuenotification--with-a-long-name", theme: theme)
        try Snapshot.assertMatches(ConversationMergeNotification(conversationTitle: "John Fire", obsoleteConversationTitle: "John Obsolete",
                                                                 obsoleteConversationNumber: "(555) 333-1111"), story: c + "conversationmergenotification--basic", theme: theme)
        try Snapshot.assertMatches(ConversationMergeNotification(conversationTitle: "John Fire", obsoleteConversationTitle: "John Obsolete",
                                                                 obsoleteConversationNumber: nil),
                                   story: c + "conversationmergenotification--with-no-obsolete-number", theme: theme)
        try Snapshot.assertMatches(ConversationMergeNotification(conversationTitle: "John Fire", obsoleteConversationTitle: nil,
                                                                 obsoleteConversationNumber: "(555) 333-1111"),
                                   story: c + "conversationmergenotification--with-no-obsolete-title", theme: theme)
        try Snapshot.assertMatches(PhoneNumberDiscoveryNotification(conversationTitle: "John Fire", phoneNumber: "(555) 333-1111", sharedGroup: "Fun Times"),
                                   story: c + "phonenumberdiscoverynotification--with-shared-group", theme: theme)
        try Snapshot.assertMatches(PhoneNumberDiscoveryNotification(conversationTitle: "John Fire", phoneNumber: "(555) 333-1111", sharedGroup: nil),
                                   story: c + "phonenumberdiscoverynotification--without-shared-group", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func unsupported(theme: String) throws {
        let c = "components-conversation-unsupportedmessage--"
        try Snapshot.assertMatches(UnsupportedMessage(canProcessNow: false, contactTitle: "Alice", contactIsMe: false), story: c + "from-someone", theme: theme)
        try Snapshot.assertMatches(UnsupportedMessage(canProcessNow: true, contactTitle: "Alice", contactIsMe: false), story: c + "after-upgrade", theme: theme)
        try Snapshot.assertMatches(UnsupportedMessage(canProcessNow: false, contactTitle: "Alice", contactIsMe: true), story: c + "from-yourself", theme: theme)
        try Snapshot.assertMatches(UnsupportedMessage(canProcessNow: true, contactTitle: "Alice", contactIsMe: true),
                                   story: c + "from-yourself-after-upgrade", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func inlineNotificationWrapper(theme: String) throws {
        // children: <div className="p-2.5 text-center">This is the default contents</div>
        func contents() -> some View {
            CSSText("This is the default contents", style: CSSTextStyle(AxoType.bodyLarge), alignment: .center).frame(maxWidth: .infinity).padding(10)
        }
        let c = "components-conversation-inlinenotificationwrapper--"
        try Snapshot.assertMatches(InlineNotificationWrapper { contents() }, story: c + "default", theme: theme)
        try Snapshot.assertMatches(InlineNotificationWrapper(isSelectMode: true) { contents() }, story: c + "select-mode", theme: theme)
        try Snapshot.assertMatches(InlineNotificationWrapper(isSelectMode: true, isSelected: true) { contents() }, story: c + "select-mode-and-selected", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func groupV1Migration(theme: String) throws {
        let c = "components-conversation-groupv1migration--"
        let cases: [(String, GroupV1Migration)] = [
            ("you-were-invited", GroupV1Migration(areWeInvited: true, invitedMembers: ["Bob"], invitedMemberCount: 1, droppedMembers: ["Alice"], droppedMemberCount: 1)),
            ("single-dropped-and-single-invited-member", GroupV1Migration(areWeInvited: false, invitedMembers: ["Bob"], invitedMemberCount: 1,
                                                                          droppedMembers: ["Alice"], droppedMemberCount: 1)),
            ("multiple-dropped-and-invited-members", GroupV1Migration(areWeInvited: false, invitedMembers: ["Alice", "Bob"], invitedMemberCount: 3,
                                                                      droppedMembers: ["Alice", "Bob"], droppedMemberCount: 3)),
            ("just-invited-members", GroupV1Migration(areWeInvited: false, invitedMembers: ["Alice", "Alice", "Bob", "Bob"], invitedMemberCount: 4,
                                                      droppedMembers: [], droppedMemberCount: 0)),
            ("just-dropped-members", GroupV1Migration(areWeInvited: false, invitedMembers: [], invitedMemberCount: 0,
                                                      droppedMembers: ["Alice", "Alice", "Bob", "Bob"], droppedMemberCount: 4)),
            ("no-dropped-or-invited-members", GroupV1Migration(areWeInvited: false, invitedMembers: [], invitedMemberCount: 0, droppedMembers: [], droppedMemberCount: 0)),
            ("no-arrays-count-is-zero", GroupV1Migration(areWeInvited: false, invitedMembers: nil, invitedMemberCount: 0, droppedMembers: nil, droppedMemberCount: 0)),
            ("no-arrays-with-count", GroupV1Migration(areWeInvited: false, invitedMembers: nil, invitedMemberCount: 4, droppedMembers: nil, droppedMemberCount: 2)),
        ]
        for (name, view) in cases { try Snapshot.assertMatches(view, story: c + name, theme: theme) }
    }

    /// GroupNotification.dom.stories.tsx `_GroupNotification`: an `<h3>` per section, then one
    /// `.module-inline-notification-wrapper` per item.
    @Test(arguments: ["light", "dark"])
    func groupNotificationStory(theme: String) throws {
        typealias C = GroupNotification.Change.Contact
        let ice = C(id: "ice", title: "Mrs. Ice"), earth = C(id: "earth", title: "Ms. Earth"), fire = C(id: "fire", title: "Mr. Fire")
        let longName = String(repeating: "🍷🐓🥶", count: 50)
        let sections: [(String, [GroupNotification])] = [
            ("Combo", [GroupNotification(fromTitle: "Alice", changes: [.add([ice, earth]), .name("Fishing Stories"), .avatar]),
                       GroupNotification(fromTitle: "Alice", fromIsMe: true, changes: [.add([ice, earth]), .name("Fishing Stories"), .avatar])]),
            ("Joined group", [
                GroupNotification(fromTitle: "Alice", changes: [.add([C(id: "p", title: "(202) 555-1000"), ice, earth])]),
                GroupNotification(fromTitle: "Alice", changes: [.add([C(id: "p", title: "(202) 555-1000", isMe: true), ice, earth])]),
                GroupNotification(fromTitle: "Alice", changes: [.add([fire])]),
                GroupNotification(fromTitle: "Alice", fromIsMe: true, changes: [.add([fire])]),
                GroupNotification(fromTitle: "Alice", changes: [.add([C(id: "fire", title: "Mr. Fire", isMe: true)])]),
                GroupNotification(fromTitle: "Alice", changes: [.add([C(id: "fire", title: "Mr. Fire", isMe: true), ice])]),
            ]),
            ("Left group", [
                GroupNotification(fromTitle: "Alice", changes: [.remove([fire, ice, earth])]),
                GroupNotification(fromTitle: "Alice", changes: [.remove([fire])]),
                GroupNotification(fromTitle: "Alice", fromIsMe: true, changes: [.remove([C(id: "alice", title: "Alice", isMe: true)])]),
            ]),
            ("Title changed", [GroupNotification(fromTitle: "Alice", changes: [.name("New Group Name")]),
                               GroupNotification(fromTitle: "Alice", fromIsMe: true, changes: [.name("New Group Name")])]),
            ("Avatar changed", [GroupNotification(fromTitle: "Alice", changes: [.avatar]),
                                GroupNotification(fromTitle: "Alice", fromIsMe: true, changes: [.avatar])]),
            ("Generic group update", [GroupNotification(fromTitle: "Alice", changes: [.general])]),
            ("Long name", [GroupNotification(fromTitle: longName, changes: [.general])]),
        ]
        let view = VStack(spacing: 0) {
            ForEach(sections.indices, id: \.self) { i in
                CSSText(sections[i].0, style: CSSTextStyle(AxoType.bodyLarge), color: .labelPrimary).frame(maxWidth: .infinity, alignment: .leading)
                ForEach(sections[i].1.indices, id: \.self) { j in InlineNotificationWrapper { sections[i].1[j] } }
            }
        }
        try Snapshot.assertMatches(SmallComponentStoriesTests.top(view), story: "components-conversation--group-notification", theme: theme)
    }
}
