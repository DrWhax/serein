// LeftPaneInboxHelper (ts/components/leftPane/LeftPaneInboxHelper.dom.tsx): pinned chats under
// a "Pinned" header, the rest under "Chats" (headers only when there are pinned chats), then
// the Archived Chats button; the search input with the unread filter; chat folders above.

import SignalI18n
import SwiftUI

public struct LeftPaneInboxHelper: LeftPaneHelper {
    public var conversations: [ConversationListItemData]
    public var archivedConversations: [ConversationListItemData]
    public var pinnedConversations: [ConversationListItemData]
    public var searchDisabled: Bool
    public var searchTerm: String
    public var isSearchingGlobally: Bool
    public var searchConversation: SearchConversation?
    public var filterByUnread: Bool
    /// `selectedChatFolder` is a custom folder (hides the archive button, changes the empty view).
    public var selectedCustomChatFolder: Bool

    public init(conversations: [ConversationListItemData], archivedConversations: [ConversationListItemData] = [],
                pinnedConversations: [ConversationListItemData] = [], searchDisabled: Bool = false, searchTerm: String = "",
                isSearchingGlobally: Bool = false,
                searchConversation: SearchConversation? = nil, filterByUnread: Bool = false, selectedCustomChatFolder: Bool = false) {
        self.conversations = conversations
        self.archivedConversations = archivedConversations
        self.pinnedConversations = pinnedConversations
        self.searchDisabled = searchDisabled
        self.searchTerm = searchTerm
        self.isSearchingGlobally = isSearchingGlobally
        self.searchConversation = searchConversation
        self.filterByUnread = filterByUnread
        self.selectedCustomChatFolder = selectedCustomChatFolder
    }

    public var hidesHeader: Bool { false }
    public var isInbox: Bool { true }
    public var requiresFullWidth: Bool { false }

    var shouldShowArchiveButton: Bool { !archivedConversations.isEmpty && !selectedCustomChatFolder }

    public func rows(_ i18n: Localizer) -> [ConversationListRow] {
        var out: [ConversationListRow] = []
        if !pinnedConversations.isEmpty {
            out.append(.header(i18n("icu:LeftPane--pinned")))
            out += pinnedConversations.map { .conversation($0) }
            if !conversations.isEmpty { out.append(.header(i18n("icu:LeftPane--chats"))) }
        }
        out += conversations.map { .conversation($0) }
        if shouldShowArchiveButton { out.append(.archiveButton(archivedConversationsCount: archivedConversations.count)) }
        return out
    }

    public func searchInput(_ ctx: LeftPaneContext) -> AnyView? {
        AnyView(LeftPaneSearchInput(searchTerm: .constant(searchTerm), searchConversation: searchConversation, disabled: searchDisabled,
                                    isSearchingGlobally: isSearchingGlobally, filterButtonEnabled: searchConversation == nil, filterPressed: filterByUnread,
                                    onFilterClick: ctx.updateFilterByUnread, clearSearchQuery: ctx.clearSearchQuery,
                                    endConversationSearch: ctx.endConversationSearch, endSearch: ctx.endSearch))
    }

    public func preRows(_ ctx: LeftPaneContext) -> AnyView? { ctx.renderLeftPaneChatFolders() }

    public func emptyView(_ ctx: LeftPaneContext) -> AnyView? {
        let i18n = ctx.i18n
        guard rows(i18n).isEmpty else { return nil }
        if selectedCustomChatFolder {
            return AnyView(LeftPaneEmptyView {
                CSSText(i18n("icu:LeftPane__EmptyView--WithSelectedChatFolder"), type: .bodyLarge, color: .labelPrimary)
                AxoButton.Root(i18n("icu:LeftPane__EmptyView--WithSelectedChatFolder__FolderSettings"), variant: .elevatedSecondary, size: .md)
            })
        }
        return AnyView(LeftPaneEmptyView {
            CSSText(i18n("icu:emptyInbox__title"), type: .titleMedium, color: .labelSecondary)
            CSSText(i18n("icu:emptyInbox__subtitle"), type: .bodyMedium, color: .labelSecondary)
        })
    }
}
