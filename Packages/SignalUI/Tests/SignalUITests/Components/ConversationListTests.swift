// ConversationList stories (ts/components/ConversationList.dom.stories.tsx): Wrapper is a
// 300×350 ConversationList. Captures run at FIXED_NOW (2026-11-04T12:00:00Z, GMT) with seeded
// randomness, so `Date.now() - 5 min` renders "5m".

import Foundation
import ImageJPEG
import SwiftUI
import Testing
@testable import SignalUI

@MainActor let fixedNow = Date(timeIntervalSince1970: 1_793_793_600)    // 2026-11-04T12:00:00Z

/// Upstream's `fixtures/` image, decoded with the Swift JPEG decoder.
func fixtureImage(_ name: String) -> RGBAImage? {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Signal-Desktop/fixtures/\(name)")
    guard let data = try? Data(contentsOf: url), let image = try? JPEGDecoder.decode([UInt8](data)) else { return nil }
    return RGBAImage(image)
}

@MainActor
@Suite struct ConversationListTests {
    func wrapper(_ rows: [ConversationListRow]) -> some View {
        ConversationList(width: 300, height: 350, rows: rows)
            .environment(\.conversationListNow, fixedNow)
            .environment(\.timeZone, TimeZone(identifier: "GMT")!)
    }

    /// `createConversation(overrideProps)`
    func conversation(_ change: (inout ConversationListItemData) -> Void = { _ in }) -> ConversationListRow {
        var c = ConversationListItemData(id: "", title: "Some Person",
                                         lastMessage: .init(text: "Hi there!", status: .read),
                                         lastUpdated: fixedNow.addingTimeInterval(-5 * 60))
        change(&c)
        c.avatar.title = c.title
        c.avatar.conversationType = c.type
        c.avatar.noteToSelf = c.isMe
        return .conversation(c)
    }

    func check(_ rows: [ConversationListRow], _ story: String, _ theme: String) throws {
        try Snapshot.assertMatches(wrapper(rows), story: "components-conversationlist--\(story)", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func archiveButton(theme: String) throws { try check([.archiveButton(archivedConversationsCount: 123)], "archive-button", theme) }

    @Test(arguments: ["light", "dark"])
    func conversationName(theme: String) throws { try check([conversation()], "conversation-name", theme) }

    @Test(arguments: ["light", "dark"])
    func conversationNameAndAvatar(theme: String) throws {
        try check([conversation { $0.avatar.image = fixtureImage("kitten-1-64-64.jpg") }], "conversation-name-and-avatar", theme)
    }

    @Test(arguments: ["light", "dark"])
    func conversationWithYourself(theme: String) throws {
        try check([conversation {
            $0.lastMessage = .init(text: "Just a second", status: .read)
            $0.title = "Myself"
            $0.isMe = true
        }], "conversation-with-yourself", theme)
    }

    @Test(arguments: ["light", "dark"])
    func messageStatuses(theme: String) throws {
        let statuses: [LastMessageStatus] = [.delivered, .error, .paused, .partialSent, .read, .sending, .sent, .viewed]
        try check(statuses.map { s in conversation { $0.lastMessage = .init(text: s.rawValue, status: s) } }, "conversations-message-statuses", theme)
    }

    @Test(arguments: ["light", "dark"])
    func typingStatus(theme: String) throws { try check([conversation { $0.isSomeoneTyping = true }], "conversation-typing-status", theme) }

    @Test(arguments: ["light", "dark"])
    func deletedForEveryone(theme: String) throws {
        try check([conversation { $0.lastMessage = .init(text: "", deletedForEveryone: true) }], "conversation-deleted-for-everyone", theme)
    }

    @Test(arguments: ["light", "dark"])
    func messageRequest(theme: String) throws {
        try check([conversation {
            $0.acceptedMessageRequest = false
            $0.lastMessage = .init(text: "A Message", status: .delivered)
        }], "conversation-message-request", theme)
    }

    @Test(arguments: ["light", "dark"])
    func unreadCount(theme: String) throws {
        let counts = [4, 10, 34, 250, 2048, 9_007_199_254_740_991]
        try check(counts.map { n in conversation {
            $0.lastMessage = .init(text: "Hey there!", status: .delivered)
            $0.unreadCount = n
        } }, "conversations-unread-count", theme)
    }

    @Test(arguments: ["light", "dark"])
    func markedUnread(theme: String) throws { try check([conversation { $0.markedUnread = true }], "conversation-marked-unread", theme) }

    @Test(arguments: ["light", "dark"])
    func selected(theme: String) throws {
        try check([conversation {
            $0.lastMessage = .init(text: "Hey there!", status: .read)
            $0.isSelected = true
        }], "conversation-selected", theme)
    }

    @Test(arguments: ["light", "dark"])
    func linkInMessage(theme: String) throws {
        try check([conversation { $0.lastMessage = .init(text: "Download at http://signal.org", status: .read) }], "conversation-link-in-message", theme)
    }

    @Test(arguments: ["light", "dark"])
    func longName(theme: String) throws {
        try check([conversation { $0.title = "Long contact name. Esquire. The third. And stuff. And more! And more!" }], "conversation-long-name", theme)
    }

    @Test(arguments: ["light", "dark"])
    func longMessage(theme: String) throws {
        let messages = [
            "Long line. This is a really really really long line. Really really long. Because that's just how it is",
            "Many lines. This is a many-line message.\nLine 2 is really exciting but it shouldn't be seen.\nLine three is even better.\nLine 4, well.",
        ]
        try check(messages.map { m in conversation { $0.lastMessage = .init(text: m, status: .read) } }, "conversation-long-message", theme)
    }

    @Test(arguments: ["light", "dark"])
    func variousTimes(theme: String) throws {
        let pairs: [(TimeInterval, String)] = [(5 * 3600, "Five hours ago"), (86_400, "One day ago"), (7 * 86_400, "One week ago"),
                                               (365 * 86_400, "One year ago")]
        try check(pairs.map { ago, text in conversation {
            $0.lastUpdated = fixedNow.addingTimeInterval(-ago)
            $0.lastMessage = .init(text: text, status: .read)
        } }, "conversations-various-times", theme)
    }

    @Test(arguments: ["light", "dark"])
    func missingDate(theme: String) throws { try check([conversation { $0.lastUpdated = nil }], "conversation-missing-date", theme) }

    @Test(arguments: ["light", "dark"])
    func missingMessage(theme: String) throws { try check([conversation { $0.lastMessage = nil }], "conversation-missing-message", theme) }

    @Test(arguments: ["light", "dark"])
    func missingText(theme: String) throws {
        try check([conversation { $0.lastMessage = .init(text: "", status: .sent) }], "conversation-missing-text", theme)
    }

    @Test(arguments: ["light", "dark"])
    func muted(theme: String) throws {
        try check([conversation { $0.muteExpiresAt = fixedNow.addingTimeInterval(3600) }], "conversation-muted-conversation", theme)
    }

    @Test(arguments: ["light", "dark"])
    func atMention(theme: String) throws {
        try check([conversation {
            $0.title = "The Rebellion"
            $0.type = .group
            $0.lastMessage = .init(text: "@Leia Organa I know", status: .read)
        }], "conversation-at-mention", theme)
    }

    @Test(arguments: ["light", "dark"])
    func emojiInMessage(theme: String) throws {
        try check([conversation { $0.lastMessage = .init(text: "🔥", status: .read) }], "conversation-emoji-in-message", theme)
    }

    @Test(arguments: ["light", "dark"])
    func withDraft(theme: String) throws {
        try check([conversation {
            $0.shouldShowDraft = true
            $0.draftPreview = "I'm in the middle of typing this..."
            $0.draftPrefix = "🎤"
        }], "conversation-with-draft", theme)
    }

    // defaultConversations (getDefaultConversation with the seeded randomness): colours and
    // kitten avatars as in the capture.
    static let fred = ("Fred Willard", "A180", "kitten-2-64-64.jpg")
    static let marc = ("Marc Barraca", "A130", "kitten-2-64-64.jpg")
    static let pablo = ("Pablo Diego José Francisco de Paula Juan Nepomuceno María de los Remedios Cipriano de la Santísima Trinidad Ruiz y Picasso",
                        "A110", "kitten-1-64-64.jpg")
    static let nyah = ("Nyah Stroman", "A170", "kitten-2-64-64.jpg")

    func contact(_ c: (String, String, String), type: AvatarConversationType = .direct, isMe: Bool = false, about: String? = nil,
                 inSystemContacts: Bool = false) -> ContactListItemData {
        ContactListItemData(id: c.0, title: c.0, type: type, isMe: isMe, about: about, isInSystemContacts: inSystemContacts,
                            avatar: ConversationAvatarData(title: c.0, conversationType: type, color: c.1, image: fixtureImage(c.2), noteToSelf: isMe))
    }

    @Test(arguments: ["light", "dark"])
    func contactNoteToSelf(theme: String) throws {
        try check([.contact(contact(Self.fred, isMe: true, about: "🤠 should be ignored"))], "contact-note-to-self", theme)
    }

    @Test(arguments: ["light", "dark"])
    func contactDirect(theme: String) throws { try check([.contact(contact(Self.fred))], "contact-direct", theme) }

    @Test(arguments: ["light", "dark"])
    func contactInSystemContacts(theme: String) throws {
        try check([.contact(contact(Self.fred, inSystemContacts: true))], "contact-in-system-contacts", theme)
    }

    @Test(arguments: ["light", "dark"])
    func contactWithContextMenu(theme: String) throws {
        try check([.contact(contact(Self.fred), hasContextMenu: true)], "contact-direct-with-context-menu", theme)
    }

    @Test(arguments: ["light", "dark"])
    func contactShortAbout(theme: String) throws {
        try check([.contact(contact(Self.fred, about: "🤠 yee haw"))], "contact-direct-with-short-about", theme)
    }

    @Test(arguments: ["light", "dark"])
    func contactLongAbout(theme: String) throws {
        let about = "🤠 Lorem ipsum dolor sit amet, consectetur adipiscing elit. Donec a diam lectus. Sed sit amet ipsum mauris. Maecenas congue ligula ac quam viverra nec consectetur ante hendrerit. Donec et mollis dolor. Praesent et diam eget libero egestas mattis sit amet vitae augue."
        try check([.contact(contact(Self.fred, about: about))], "contact-direct-with-long-about", theme)
    }

    @Test(arguments: ["light", "dark"])
    func contactGroup(theme: String) throws { try check([.contact(contact(Self.fred, type: .group))], "contact-group", theme) }

    @Test(arguments: ["light", "dark"])
    func contactCheckboxes(theme: String) throws {
        try check([.contactCheckbox(contact(Self.fred), isChecked: true), .contactCheckbox(contact(Self.marc), isChecked: false),
                   .contactCheckbox(contact(Self.pablo, about: "😃 Hola"), isChecked: true)], "contact-checkboxes", theme)
    }

    @Test(arguments: ["light", "dark"])
    func contactCheckboxesDisabled(theme: String) throws {
        try check([.contactCheckbox(contact(Self.fred), isChecked: false, disabledReason: .maximumContactsSelected),
                   .contactCheckbox(contact(Self.pablo), isChecked: true, disabledReason: .maximumContactsSelected),
                   .contactCheckbox(contact(Self.nyah), isChecked: true, disabledReason: .alreadyAdded)], "contact-checkboxes-disabled", theme)
    }

    @Test(arguments: ["light", "dark"])
    func findByPhoneNumber(theme: String) throws {
        try check([.header(DefaultLocalizer.english("icu:findByPhoneNumberHeader")),
                   .startNewConversation(ParsedPhoneNumber(isValid: true, userInput: "+1(234)555 98 76", e164: "+12345559876"), isFetching: false),
                   .startNewConversation(ParsedPhoneNumber(isValid: true, userInput: "+1(234)555 98 76", e164: "+12345559876"), isFetching: true),
                   .startNewConversation(ParsedPhoneNumber(isValid: true, userInput: "+1(234)555", e164: "+1234555"), isFetching: false)],
                  "find-by-phone-number", theme)
    }

    @Test(arguments: ["light", "dark"])
    func findByUsername(theme: String) throws {
        try check([.header(DefaultLocalizer.english("icu:findByUsernameHeader")),
                   .usernameSearchResult("jowerty", isFetchingUsername: false), .usernameSearchResult("jowerty", isFetchingUsername: true)],
                  "find-by-username", theme)
    }

    @Test(arguments: ["light", "dark"])
    func searchResultsLoadingSkeleton(theme: String) throws {
        try check([.searchResultsLoadingFakeHeader] + Array(repeating: .searchResultsLoadingFakeRow, count: 99), "search-results-loading-skeleton", theme)
    }

    @Test(arguments: ["light", "dark"])
    func kitchenSink(theme: String) throws {
        let i18n = DefaultLocalizer.english
        let valid = ParsedPhoneNumber(isValid: true, userInput: "+1(234)555 98 76", e164: "+12345559876")
        var marc = ConversationListItemData(id: "marc-convo", title: Self.marc.0, isSelected: true,
                                            avatar: ConversationAvatarData(title: Self.marc.0, color: Self.marc.1, image: fixtureImage(Self.marc.2)),
                                            lastMessage: .init(text: "Lorem ipsum dolor sit amet, consectetur adipiscing elit."),
                                            lastUpdated: Date(timeIntervalSince1970: 15 * 86_400 + 43_200), unreadCount: 12)
        marc.isSelected = true
        var actions = ConversationListActions()
        actions.renderMessageSearchResult = { _ in
            AnyView(MessageSearchResult(id: "123", conversationId: "marc-convo", from: MessageSearchResultPerson(title: Self.fred.0),
                                        to: MessageSearchResultPerson(title: Self.marc.0), sentAt: Date(timeIntervalSince1970: 1_587_358_800),
                                        snippet: "Lorem <<left>>ipsum<<right>> wow", body: "Lorem ipsum wow"))
        }
        let rows: [ConversationListRow] = [
            .startNewConversation(valid, isFetching: false), .startNewConversation(valid, isFetching: true),
            .startNewConversation(ParsedPhoneNumber(isValid: false, userInput: "+1(234)555 98", e164: "+123455598"), isFetching: true),
            .header(i18n("icu:contactsHeader")), .contact(contact(Self.fred)), .header(i18n("icu:messagesHeader")), .conversation(marc),
            .messageSearchResult(messageId: "123"), .header(i18n("icu:findByUsernameHeader")),
            .usernameSearchResult("jowerty", isFetchingUsername: false), .archiveButton(archivedConversationsCount: 123),
        ]
        let view = ConversationList(width: 300, height: 350, rows: rows, actions: actions)
            .environment(\.conversationListNow, fixedNow).environment(\.timeZone, TimeZone(identifier: "GMT")!)
        try Snapshot.assertMatches(view, story: "components-conversationlist--kitchen-sink", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func headers(theme: String) throws {
        let i18n = DefaultLocalizer.english
        try check(["icu:conversationsHeader", "icu:messagesHeader", "icu:findByUsernameHeader", "icu:findByPhoneNumberHeader"].map {
            .header(i18n($0))
        }, "headers", theme)
    }
}
