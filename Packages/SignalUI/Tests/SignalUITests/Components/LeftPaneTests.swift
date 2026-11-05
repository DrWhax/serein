// LeftPane stories (ts/components/LeftPane.dom.stories.tsx). Fixtures come from
// getDefaultConversation with the seeded randomness (colours, kittens, and `lastUpdated:
// casual.unix_time`, seconds used as milliseconds: dates in January 1970).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct LeftPaneTests {
    static func day(_ d: Double) -> Date { Date(timeIntervalSince1970: (d - 1) * 86_400 + 43_200) }    // Jan d, 1970, noon GMT

    static func convo(_ id: String, _ title: String, _ color: String, _ kitten: String, _ day: Double, selected: Bool = false) -> ConversationListItemData {
        ConversationListItemData(id: id, title: title, isSelected: selected,
                                 avatar: ConversationAvatarData(title: title, color: color, image: fixtureImage("kitten-\(kitten)-64-64.jpg")),
                                 lastUpdated: Self.day(day))
    }

    static let defaultConversations = [convo("fred-convo", "Fred Willard", "A130", "2", 17),
                                       convo("marc-convo", "Marc Barraca", "A110", "1", 16, selected: true)]
    static let pinnedConversations = [convo("philly-convo", "Philip Glass", "A100", "2", 7), convo("robbo-convo", "Robert Moog", "A160", "1", 13)]
    static let archivedConversations = [convo("michelle-archive-convo", "Michelle Mercure", "A170", "1", 1)]

    func leftPane(_ helper: any LeftPaneHelper, dialogs: LeftPaneDialogs = LeftPaneDialogs()) -> some View {
        var actions = ConversationListActions()
        // useProps' renderMessageSearchResult: Fred → Marc, "Lorem ipsum wow".
        actions.renderMessageSearchResult = { id in
            let fred = Self.defaultConversations[0], marc = Self.defaultConversations[1]
            return AnyView(MessageSearchResult(id: id, conversationId: "marc-convo", from: MessageSearchResultPerson(title: fred.title, avatar: fred.avatar),
                                               to: MessageSearchResultPerson(title: marc.title, avatar: marc.avatar),
                                               sentAt: Date(timeIntervalSince1970: 1_587_358_800), snippet: "Lorem <<left>>ipsum<<right>> wow",
                                               body: "Lorem ipsum wow"))
        }
        return LeftPane(helper: helper, context: LeftPaneContext(i18n: DefaultLocalizer.english), dialogs: dialogs, listActions: actions)
            .frame(height: 600)
            .environment(\.conversationListNow, fixedNow)
            .environment(\.timeZone, TimeZone(identifier: "GMT")!)
    }

    /// `defaultSearchProps`: searchTerm "hello", isSearchingGlobally (the input is focused with its text selected).
    func inbox(pinned: [ConversationListItemData], conversations: [ConversationListItemData], archived: [ConversationListItemData]) -> LeftPaneInboxHelper {
        LeftPaneInboxHelper(conversations: conversations, archivedConversations: archived, pinnedConversations: pinned, searchTerm: "hello",
                            isSearchingGlobally: true)
    }

    static let inboxCases: [(String, Bool, Bool, Bool)] = [    // story, pinned, conversations, archived
        ("inbox-no-conversations", false, false, false), ("inbox-only-pinned-conversations", true, false, false),
        ("inbox-only-non-pinned-conversations", false, true, false), ("inbox-only-archived-conversations", false, false, true),
        ("inbox-pinned-and-archived-conversations", true, false, true), ("inbox-non-pinned-and-archived-conversations", false, true, true),
        ("inbox-pinned-and-non-pinned-conversations", true, true, false), ("inbox-pinned-non-pinned-and-archived-conversations", true, true, true),
    ]

    @Test(arguments: ["light", "dark"], 0..<8)
    func inboxStory(theme: String, index: Int) throws {
        let (name, p, c, a) = Self.inboxCases[index]
        let helper = inbox(pinned: p ? Self.pinnedConversations : [], conversations: c ? Self.defaultConversations : [],
                           archived: a ? Self.archivedConversations : [])
        try Snapshot.assertMatches(leftPane(helper), story: "components-leftpane--\(name)", theme: theme)
    }

    @Test(arguments: ["light", "dark"], [false, true])
    func usernameCorrupted(theme: String, link: Bool) throws {
        var dialogs = LeftPaneDialogs()
        if link { dialogs.usernameLinkCorrupted = true } else { dialogs.usernameCorrupted = true }
        try Snapshot.assertMatches(leftPane(inbox(pinned: [], conversations: [], archived: []), dialogs: dialogs),
                                   story: "components-leftpane--inbox-username-\(link ? "link-" : "")corrupted", theme: theme)
    }

    func search(_ conversations: SearchResults<ConversationListItemData>, _ contacts: SearchResults<ConversationListItemData>,
                _ messages: SearchResults<String>, term: String = "hello", unread: Bool = false, inConversation: String? = nil) -> LeftPaneSearchHelper {
        LeftPaneSearchHelper(conversationResults: conversations, contactResults: contacts, messageResults: messages, searchTerm: term,
                             searchConversationName: inConversation, filterByUnread: unread)
    }

    @Test(arguments: ["light", "dark"], 0..<9)
    func searchStory(theme: String, index: Int) throws {
        let c = Self.defaultConversations
        let cases: [(String, LeftPaneSearchHelper)] = [
            ("search-no-results-when-searching-everywhere", search(.loaded([]), .loaded([]), .loaded([]))),
            ("search-no-results-when-searching-in-a-conversation", search(.loaded([]), .loaded([]), .loaded([]), inConversation: "Bing Bong")),
            ("search-no-results-unread-filter-and-query", search(.loaded([]), .loaded([]), .loaded([]), unread: true)),
            ("search-no-results-unread-filter-without-query", search(.loaded([]), .loaded([]), .loaded([]), term: "", unread: true)),
            ("search-all-results-loading", search(.loading, .loading, .loading)),
            ("search-some-results-loading", search(.loaded(c), .loading, .loading)),
            ("search-has-conversations-and-contacts-but-not-messages", search(.loaded(c), .loaded(c), .loaded([]))),
            ("search-all-results", search(.loaded(c), .loaded(c), .loaded(["msg1", "msg2"]))),
            ("search-all-results-unread-filter", search(.loaded(c), .loaded([]), .loaded([]), unread: true)),
        ]
        let (name, helper) = cases[index]
        try Snapshot.assertMatches(leftPane(helper), story: "components-leftpane--\(name)", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func searchingConversation(theme: String) throws {
        let pill = SearchConversation(id: "x", avatar: ConversationAvatarData(title: "X", color: "A130", image: fixtureImage("kitten-2-64-64.jpg")))
        let helper = LeftPaneInboxHelper(conversations: Self.defaultConversations, isSearchingGlobally: true, searchConversation: pill)
        try Snapshot.assertMatches(leftPane(helper), story: "components-leftpane--searching-conversation", theme: theme)
    }

    @Test(arguments: ["light", "dark"], 0..<3)
    func archive(theme: String, index: Int) throws {
        let cases: [(String, [ConversationListItemData])] = [("archive-no-archived-conversations", []),
                                                              ("archive-archived-conversations", Self.defaultConversations),
                                                              ("archive-searching-a-conversation", Self.defaultConversations)]
        let (name, archived) = cases[index]
        try Snapshot.assertMatches(leftPane(LeftPaneArchiveHelper(archivedConversations: archived)), story: "components-leftpane--\(name)", theme: theme)
    }

    static func contactRow(_ c: ConversationListItemData) -> ContactListItemData {
        ContactListItemData(id: c.id, title: c.title, avatar: c.avatar)
    }
    static let defaultContacts = defaultConversations.map { contactRow($0) }
    static let defaultGroups = [
        GroupListItemData(id: "biking-group", title: "Mtn Biking Arizona 🚵☀️⛰", membersCount: 24,
                          avatar: ConversationAvatarData(title: "Mtn Biking Arizona 🚵☀️⛰", conversationType: .group, color: "A170",
                                                         image: fixtureImage("kitten-2-64-64.jpg"))),
        GroupListItemData(id: "dance-group", title: "Are we dancers? 💃", membersCount: 24,
                          avatar: ConversationAvatarData(title: "Are we dancers? 💃", conversationType: .group, color: "A100",
                                                         image: fixtureImage("kitten-3-64-64.jpg"))),
    ]

    @Test(arguments: ["light", "dark"], 0..<11)
    func compose(theme: String, index: Int) throws {
        let c = Self.defaultContacts, g = Self.defaultGroups
        let cases: [(String, LeftPaneComposeHelper)] = [
            ("compose-no-results", LeftPaneComposeHelper(composeContacts: [])),
            ("compose-some-contacts-no-search-term", LeftPaneComposeHelper(composeContacts: c)),
            ("compose-some-contacts-with-a-search-term", LeftPaneComposeHelper(composeContacts: c, searchTerm: "ar")),
            ("compose-some-groups-no-search-term", LeftPaneComposeHelper(composeContacts: [], composeGroups: g)),
            ("compose-some-groups-with-search-term", LeftPaneComposeHelper(composeContacts: [], composeGroups: g, searchTerm: "ar")),
            ("compose-search-is-valid-username", LeftPaneComposeHelper(composeContacts: [], searchTerm: "someone", username: "someone")),
            ("compose-search-is-valid-username-fetching-username",
             LeftPaneComposeHelper(composeContacts: [], searchTerm: "someone", username: "someone", uuidFetchState: ["username:someone"])),
            ("compose-search-is-valid-phone-number", LeftPaneComposeHelper(composeContacts: [], searchTerm: "2125555454")),
            ("compose-search-is-valid-phone-number-fetching-phone-number",
             LeftPaneComposeHelper(composeContacts: [], searchTerm: "(212)5555454", uuidFetchState: ["e164:+12125555454"])),
            ("compose-all-kinds-of-results-no-search-term", LeftPaneComposeHelper(composeContacts: c, composeGroups: g)),
            ("compose-all-kinds-of-results-with-a-search-term",
             LeftPaneComposeHelper(composeContacts: c, composeGroups: g, searchTerm: "someone", username: "someone")),
        ]
        let (name, helper) = cases[index]
        try Snapshot.assertMatches(leftPane(helper), story: "components-leftpane--\(name)", theme: theme)
    }

    @Test(arguments: ["light", "dark"], 0..<3)
    func chooseGroupMembers(theme: String, index: Int) throws {
        let cases: [(String, LeftPaneChooseGroupMembersHelper)] = [
            ("choose-group-members-partial-phone-number", LeftPaneChooseGroupMembersHelper(candidateContacts: [], searchTerm: "+1(212) 555")),
            ("choose-group-members-valid-phone-number", LeftPaneChooseGroupMembersHelper(candidateContacts: [], searchTerm: "+1(212) 555 5454")),
            ("choose-group-members-username", LeftPaneChooseGroupMembersHelper(candidateContacts: [], searchTerm: "signal.01", username: "signal.01")),
        ]
        let (name, helper) = cases[index]
        try Snapshot.assertMatches(leftPane(helper), story: "components-leftpane--\(name)", theme: theme)
    }

    @Test(arguments: ["light", "dark"], 0..<3)
    func groupMetadata(theme: String, index: Int) throws {
        let cases: [(String, Int)] = [("group-metadata-no-timer", 0), ("group-metadata-regular-timer", 86_400), ("group-metadata-custom-timer", 7 * 3600)]
        let (name, timer) = cases[index]
        let helper = LeftPaneSetGroupMetadataHelper(groupName: "Group 1", groupExpireTimer: timer, selectedContacts: Self.defaultContacts)
        try Snapshot.assertMatches(leftPane(helper), story: "components-leftpane--\(name)", theme: theme)
    }

    @Test(arguments: ["light", "dark"], 0..<3)
    func serverAlerts(theme: String, index: Int) throws {
        let names = ["inbox-critical-idle-primary-device-alert", "inbox-idle-primary-device-alert", "inbox-idle-primary-device-alert-non-dismissable"]
        var dialogs = LeftPaneDialogs()
        dialogs.serverAlert = switch index {
        case 0: AnyView(CriticalIdlePrimaryDeviceDialog(containerWidthBreakpoint: .wide))
        case 1: AnyView(WarningIdlePrimaryDeviceDialog(containerWidthBreakpoint: .wide, handleClose: {}))
        default: AnyView(WarningIdlePrimaryDeviceDialog(containerWidthBreakpoint: .wide))
        }
        let helper = inbox(pinned: Self.pinnedConversations, conversations: Self.defaultConversations, archived: Self.archivedConversations)
        try Snapshot.assertMatches(leftPane(helper, dialogs: dialogs), story: "components-leftpane--\(names[index])", theme: theme)
    }

    @Test(arguments: ["light", "dark"], [false, true])
    func captchaDialog(theme: String, pending: Bool) throws {
        // The dialog holds focus, so the search input is not focused.
        let helper = LeftPaneInboxHelper(conversations: Self.defaultConversations, pinnedConversations: Self.pinnedConversations)
        let view = PortalStage { leftPane(helper) } modal: { AxoBaseDialog.Host { CaptchaDialog(pending: pending) } }
        try Snapshot.assertMatches(view, story: "components-leftpane--captcha-dialog-\(pending ? "pending" : "required")", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func crashReportDialog(theme: String) throws {
        let helper = LeftPaneInboxHelper(conversations: Self.defaultConversations, pinnedConversations: Self.pinnedConversations)
        let view = PortalStage { leftPane(helper) } modal: { AxoBaseDialog.Host { CrashReportDialog() } }
        try Snapshot.assertMatches(view, story: "components-leftpane--crash-report-dialog-example", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func captchaDialogStory(theme: String) throws {
        let view = PortalStage { EmptyView() } modal: { AxoBaseDialog.Host { CaptchaDialog() } }
        try Snapshot.assertMatches(view, story: "components-captchadialog--basic", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func crashReportDialogStory(theme: String) throws {
        let view = PortalStage { EmptyView() } modal: { AxoBaseDialog.Host { CrashReportDialog() } }
        try Snapshot.assertMatches(view, story: "components-crashreportdialog--basic", theme: theme)
    }
}
