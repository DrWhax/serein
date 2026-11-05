// ts/components/preferences/PreferencesBlocked.dom.stories.tsx (PreferencesBlockedFixtures:
// the seeded conversations read off the captures).

import Foundation
import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct PreferencesBlockedTests {
    static func rows(_ rows: [PreferencesBlockedFixtures.Row], group: Bool) -> [BlockedConversation] {
        rows.enumerated().map { i, r in
            // "Blocked on Nov 3, 2026" → the date part.
            let on = r.description.map { String($0.dropFirst("Blocked on ".count)) }
            return BlockedConversation(id: "\(group)-\(i)", title: r.title, isGroup: group, avatar: r.kitten > 0 ? fixtureImage("kitten-\(r.kitten)-64-64.jpg") : nil,
                                       blockedOn: on)
        }
    }

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        for name in ["default", "no-blocked", "with-1-both-with-blocked-at", "with-1-contact", "with-1-group", "with-many-both", "with-many-contacts", "with-many-groups"] {
            let story = "components-preferences-preferencesblocked--\(name)"
            let f = try #require(PreferencesBlockedFixtures.stories[name])
            let url = try #require(Bundle.module.url(forResource: "References/\(story).light", withExtension: "json"))
            let height = try #require((try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])?["height"] as? Double)
            let view = PreferencesBlocked(blockedContacts: Self.rows(f.contacts, group: false), blockedGroups: Self.rows(f.groups, group: true))
                .frame(width: 1168, height: height)
            try Snapshot.assertMatches(view, story: story, theme: theme)
        }
    }

    @Test(arguments: ["light", "dark"])
    func linkedDevicesOnboarding(theme: String) throws {
        try Snapshot.assertMatches(PortalStage { EmptyView() } modal: { AxoBaseDialog.Host { LinkedDevicesOnboardingDialog() } },
                                   story: "components-preferences-linkeddevicesonboarding--default", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func languageDialog(theme: String) throws {
        let stories: [(String, PreferencesLanguageDialog)] = [
            ("system-language", PreferencesLanguageDialog(resolvedLocale: "en", preferredSystemLocales: ["en-US"], localeOverride: nil)),
            ("language-override", PreferencesLanguageDialog(resolvedLocale: "de", preferredSystemLocales: ["en-US"], localeOverride: "de")),
        ]
        for (name, view) in stories {
            try Snapshot.assertMatches(PortalStage { EmptyView() } modal: { AxoBaseDialog.Host { view } },
                                       story: "components-preferences-preferenceslanguagedialog--\(name)", theme: theme)
        }
    }

    /// 25 seeded conversations (16 contacts, 9 groups) with no activeAt: sorted by title; the
    /// visible rows' kittens read off the capture.
    static let chooserRows: [(String, Int)] = [("Arvid Smitham", 3), ("Bernadine Feil", 1), ("Carmine Hane", 1), ("Casandra Renner", 1), ("Franco Adams", 2),
                                               ("Harum iste et", 1), ("Janice Dach", 1), ("Laboriosam aut et", 1), ("Lon VonRueden", 1), ("Lucinda Veum", 3)]

    @Test(arguments: ["light", "dark"])
    func blockChooser(theme: String) throws {
        let conversations = Self.chooserRows.map { t, k in
            SearchableConversation(listItem: ContactListItemData(id: t, title: t, avatar: ConversationAvatarData(title: t, image: fixtureImage("kitten-\(k)-64-64.jpg"))))
        }
        let view = PreferencesBlockChooserDialog(title: "Default", conversations: conversations)
        try Snapshot.assertMatches(PortalStage { EmptyView() } modal: { AxoBaseDialog.Host { view } },
                                   story: "components-preferences-preferencesblockchooserdialog--default", theme: theme)
    }
}

// ts/components/preferences/PreferencesSelectChatsDialog.dom.stories.tsx: the rows are the
// seeded conversations of the block chooser; the pills come from the story's random selector.
@MainActor
@Suite struct PreferencesSelectChatsDialogTests {
    static let pills: [(String, String, Int)] = [("Amely", "Amely Hand", 2), ("Deborah", "Deborah Fay", 1), ("Lukas", "Lukas Pacocha", 3),
                                                 ("Shanel", "Shanel Rowe", 1), ("Estel", "Estel Nader", 1)]

    static func dialog(_ title: String = "Title for Stories", selection: ChatFolderSelection = ChatFolderSelection(),
                       showChatTypes: Bool = false) -> some View {
        let conversations = PreferencesBlockedTests.chooserRows.map { t, k in
            SearchableConversation(listItem: ContactListItemData(id: t, title: t, avatar: ConversationAvatarData(title: t, image: fixtureImage("kitten-\(k)-64-64.jpg"))))
        }
        var pillIndex: [String: Int] = [:]
        for (i, id) in selection.selectedRecipientIds.enumerated() { pillIndex[id] = i }
        let view = PreferencesSelectChatsDialog(title: title, conversations: conversations, conversationSelector: { id in
            let (first, full, k) = pills[(pillIndex[id] ?? 0) % pills.count]
            return SelectedChatPill(data: ContactListItemData(id: id, title: full, avatar: ConversationAvatarData(title: full, image: fixtureImage("kitten-\(k)-64-64.jpg"))),
                                    firstName: first)
        }, initialSelection: selection, showChatTypes: showChatTypes)
        return PortalStage { EmptyView() } modal: { AxoBaseDialog.Host { view } }
    }

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        let s = "components-preferences-preferencesselectchatsdialog--"
        try Snapshot.assertMatches(Self.dialog("Default"), story: s + "default", theme: theme)
        try Snapshot.assertMatches(Self.dialog(showChatTypes: true), story: s + "showing-chat-types", theme: theme)
        // conversations.slice(0, 5) of the unsorted list: two of them sort into view.
        let ids = ["Arvid Smitham", "Bernadine Feil", "Laboriosam aut et", "Lon VonRueden", "Lucinda Veum"]
        try Snapshot.assertMatches(Self.dialog(selection: ChatFolderSelection(selectedRecipientIds: ids)), story: s + "with-initial-selection-recipient-ids", theme: theme)
        try Snapshot.assertMatches(Self.dialog(selection: ChatFolderSelection(selectAllIndividualChats: true), showChatTypes: true),
                                   story: s + "with-initial-selection-all-individual", theme: theme)
        try Snapshot.assertMatches(Self.dialog(selection: ChatFolderSelection(selectAllGroupChats: true), showChatTypes: true),
                                   story: s + "with-initial-selection-all-group", theme: theme)
    }
}

@MainActor
@Suite struct NotificationProfilesOnboardingDialogTests {
    @Test(arguments: ["light", "dark"])
    func story(theme: String) throws {
        try Snapshot.assertMatches(PortalStage { EmptyView() } modal: { AxoBaseDialog.Host { NotificationProfilesOnboardingDialog {} } },
                                   story: "components-preferences-notificationprofiles--default", theme: theme)
    }
}
