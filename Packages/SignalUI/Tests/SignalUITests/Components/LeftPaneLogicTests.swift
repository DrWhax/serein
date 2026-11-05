// Left-pane parts without an upstream story (chat folders bar, row context menu, Find by
// username / phone number) and the helpers' logic, checked structurally.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct LeftPaneLogicTests {
    let i18n = DefaultLocalizer.english

    @Test func chatFoldersHiddenWithoutCustomFolders() {
        let bar = LeftPaneChatFolders(folders: [ChatFolder(id: "all", folderType: .all, position: 0)], selectedChatFolderId: "all")
        #expect(!bar.hasAnyCustomFolders)
        let withCustom = LeftPaneChatFolders(folders: [ChatFolder(id: "w", folderType: .custom, name: "Work", position: 1),
                                                       ChatFolder(id: "all", folderType: .all, position: 0)], selectedChatFolderId: "all",
                                             unreadStats: ["w": UnreadStats(unreadCount: 3, unreadChatsCount: 2, readChatsMarkedUnreadCount: 1)])
        #expect(withCustom.hasAnyCustomFolders)
        #expect(withCustom.sorted.map(\.id) == ["all", "w"])
        #expect(withCustom.badge(withCustom.sorted[1]) == 4)
        #expect(withCustom.badge(withCustom.sorted[0]) == nil)
        #expect(LeftPaneChatFolders.label(i18n, withCustom.sorted[0], preferShort: false) == i18n("icu:LeftPaneChatFolders__ItemLabel--All"))
        #expect(LeftPaneChatFolders.iconName(withCustom.sorted[1]) == "folder")
        #expect(UnreadStats(unreadCount: 3, unreadChatsCount: 2, readChatsMarkedUnreadCount: 1).badgeCount(.unreadChats) == 3)
    }

    @Test func contextMenuEntries() {
        var m = ConversationContextMenuModel(conversationId: "c", isUnread: true, markedUnread: false, isPinned: false, isMuted: false, isArchived: false)
        m.customChatFolders = [ChatFolder(id: "w", folderType: .custom, name: "Work", position: 1)]
        #expect(m.entries(i18n) == [
            .item(i18n("icu:markRead"), symbol: "message-check"), .item(i18n("icu:pinConversation"), symbol: "pin"),
            .sub(i18n("icu:muteNotificationsTitle"), symbol: "bell-slash"),
            .sub(i18n("icu:LeftPane__ConversationListItem__ContextMenu__ChatFolderToggleChatsItem"), symbol: "folder-plus"),
            .item(i18n("icu:archiveConversation"), symbol: "archive"), .item(i18n("icu:deleteConversation"), symbol: "trash"),
        ])
        m.isUnread = false
        m.isPinned = true
        m.isMuted = true
        m.isArchived = true
        m.selectedCustomChatFolderId = "w"
        #expect(m.entries(i18n) == [
            .item(i18n("icu:markUnread"), symbol: "message-badge"), .item(i18n("icu:unpinConversation"), symbol: "pin-slash"),
            .item(i18n("icu:unmute"), symbol: "bell"),
            .item(i18n("icu:LeftPane__ConversationListItem__ContextMenu__ChatFolderRemoveChatItem"), symbol: "folder-minus"),
            .item(i18n("icu:moveConversationToInbox"), symbol: "archive-up"), .item(i18n("icu:deleteConversation"), symbol: "trash"),
        ])
    }

    @Test func findHelpers() {
        #expect(LeftPaneFindByUsernameHelper(searchTerm: "").isLookupDisabled)
        #expect(!LeftPaneFindByUsernameHelper(searchTerm: "signal.01").isLookupDisabled)
        #expect(LeftPaneFindByUsernameHelper(searchTerm: "signal.01", isFetching: true).isLookupDisabled)
        #expect(!LeftPaneFindByPhoneNumberHelper(searchTerm: "(212) 555-5454").isLookupDisabled)
        #expect(LeftPaneFindByPhoneNumberHelper(searchTerm: "555").isLookupDisabled)
        #expect(LeftPaneFindByUsernameHelper(searchTerm: "x").rows(i18n).isEmpty)
    }

    @Test func phoneAndUsernameParsing() {
        #expect(PhoneNumberParsing.parse("2125555454", regionCode: "US")?.e164 == "+12125555454")
        #expect(PhoneNumberParsing.parse("(212)5555454", regionCode: "US")?.e164 == "+12125555454")
        #expect(PhoneNumberParsing.parse("+44 20 7946 0958", regionCode: "US")?.e164 == "+442079460958")
        #expect(PhoneNumberParsing.parse("someone", regionCode: "US") == nil)
        #expect(UsernameSearch.username(from: "@someone") == "someone")
        #expect(UsernameSearch.username(from: "12345") == nil)
        #expect(UsernameSearch.isProbablyAUsername("signal.01"))
        #expect(!UsernameSearch.isProbablyAUsername("someone"))
    }

    @Test func countries() {
        let list = CountryDataSource.countries(locale: "en")
        #expect(list.count > 240)
        #expect(list.first { $0.region == "US" }?.code == "+1")
        #expect(list.first { $0.region == "GB" }?.code == "+44")
        #expect(list.first { $0.region == "XK" }?.code == "+383")
        #expect(list.map(\.displayName) == list.map(\.displayName).sorted())
        #expect(CountryDataSource.countries(locale: "de").first { $0.region == "DE" }?.displayName == "Deutschland")
    }

    @Test func expirationTimerFormat() {
        #expect(ExpirationTimer.format(i18n, 0, capitalizeOff: true) == "Off")
        #expect(ExpirationTimer.format(i18n, 4 * 604_800) == "4 weeks")
        #expect(ExpirationTimer.format(i18n, 86_400) == "1 day")
        #expect(ExpirationTimer.format(i18n, 7 * 3600) == "7 hours")
        #expect(ExpirationTimer.format(i18n, 90_061) == "1 day, 1 hour, 1 minute, 1 second")
    }
}
