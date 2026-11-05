// LeftPaneConversationListItemContextMenu (ts/components/leftPane/
// LeftPaneConversationListItemContextMenu.dom.tsx): a chat row's right-click menu — mark
// read / unread, pin, mute, add to / remove from chat folders, archive, delete, and the
// internal copy-ID items. (No upstream story: covered by unit tests.)

import AppKit
import SignalI18n
import SwiftUI

/// The conversation fields and actions the menu needs.
public struct ConversationContextMenuModel {
    public var conversationId: String
    public var isUnread: Bool
    public var markedUnread: Bool
    public var isPinned: Bool
    public var isMuted: Bool
    public var isArchived: Bool
    public var isActivelySearching = false
    /// nil or the All folder: the add-to-folder submenu; a custom folder: "Remove from folder".
    public var selectedCustomChatFolderId: String?
    public var customChatFolders: [ChatFolder] = []
    public var foldersContainingChat: Set<String> = []
    public var internalIds: [(String, String)] = []    // (label, value) when internal features are on

    public var onMarkRead: () -> Void = {}
    public var onMarkUnread: () -> Void = {}
    public var onPin: () -> Void = {}
    public var onUnpin: () -> Void = {}
    public var onUnmute: () -> Void = {}
    public var onMute: (MuteOption) -> Void = { _ in }
    public var onChatFolderToggleChat: (String, Bool) -> Void = { _, _ in }
    public var onChatFolderCreateNew: () -> Void = {}
    public var onChatFolderRemoveChat: () -> Void = {}
    public var onArchive: () -> Void = {}
    public var onUnarchive: () -> Void = {}
    public var onDelete: () -> Void = {}

    public init(conversationId: String, isUnread: Bool, markedUnread: Bool, isPinned: Bool, isMuted: Bool, isArchived: Bool) {
        self.conversationId = conversationId
        self.isUnread = isUnread
        self.markedUnread = markedUnread
        self.isPinned = isPinned
        self.isMuted = isMuted
        self.isArchived = isArchived
    }

    /// The menu's entries in order (used by the view and the tests).
    public enum Entry: Equatable { case item(String, symbol: String), sub(String, symbol: String), separator, label(String) }

    @MainActor public func entries(_ i18n: Localizer) -> [Entry] {
        var out: [Entry] = []
        if isUnread { out.append(.item(i18n("icu:markRead"), symbol: "message-check")) }
        if !isUnread && !markedUnread { out.append(.item(i18n("icu:markUnread"), symbol: "message-badge")) }
        out.append(isPinned ? .item(i18n("icu:unpinConversation"), symbol: "pin-slash") : .item(i18n("icu:pinConversation"), symbol: "pin"))
        out.append(isMuted ? .item(i18n("icu:unmute"), symbol: "bell") : .sub(i18n("icu:muteNotificationsTitle"), symbol: "bell-slash"))
        if !isActivelySearching && selectedCustomChatFolderId == nil && !customChatFolders.isEmpty {
            out.append(.sub(i18n("icu:LeftPane__ConversationListItem__ContextMenu__ChatFolderToggleChatsItem"), symbol: "folder-plus"))
        }
        if !isActivelySearching && selectedCustomChatFolderId != nil {
            out.append(.item(i18n("icu:LeftPane__ConversationListItem__ContextMenu__ChatFolderRemoveChatItem"), symbol: "folder-minus"))
        }
        out.append(isArchived ? .item(i18n("icu:moveConversationToInbox"), symbol: "archive-up") : .item(i18n("icu:archiveConversation"), symbol: "archive"))
        out.append(.item(i18n("icu:deleteConversation"), symbol: "trash"))
        if !internalIds.isEmpty {
            out.append(.separator)
            out.append(.label("Internal"))
            out += internalIds.map { .item($0.0, symbol: "copy") }
        }
        return out
    }
}

public struct LeftPaneConversationListItemContextMenu<Row: View>: View {
    let model: ConversationContextMenuModel
    let row: Row
    @Environment(\.i18n) var i18n
    @State private var location: CGPoint?

    public init(model: ConversationContextMenuModel, @ViewBuilder row: () -> Row) {
        self.model = model
        self.row = row()
    }

    public var body: some View {
        let m = model
        AxoContextMenu.Root(location: $location) {
            row
        } items: {
            if m.isUnread { AxoContextMenu.Item(i18n("icu:markRead"), symbol: "message-check", action: m.onMarkRead) }
            if !m.isUnread && !m.markedUnread { AxoContextMenu.Item(i18n("icu:markUnread"), symbol: "message-badge", action: m.onMarkUnread) }
            if m.isPinned {
                AxoContextMenu.Item(i18n("icu:unpinConversation"), symbol: "pin-slash", action: m.onUnpin)
            } else {
                AxoContextMenu.Item(i18n("icu:pinConversation"), symbol: "pin", action: m.onPin)
            }
            if m.isMuted {
                AxoContextMenu.Item(i18n("icu:unmute"), symbol: "bell", action: m.onUnmute)
            } else {
                AxoContextMenu.Sub(AxoContextMenu.SubTrigger(i18n("icu:muteNotificationsTitle"), symbol: "bell-slash")) {
                    ForEach(MuteOption.values(i18n), id: \.1) { name, option in AxoContextMenu.Item(name) { m.onMute(option) } }
                }
            }
            if !m.isActivelySearching && m.selectedCustomChatFolderId == nil && !m.customChatFolders.isEmpty {
                AxoContextMenu.Sub(AxoContextMenu.SubTrigger(i18n("icu:LeftPane__ConversationListItem__ContextMenu__ChatFolderToggleChatsItem"),
                                                             symbol: "folder-plus")) {
                    ForEach(m.customChatFolders.sorted { $0.position < $1.position }) { folder in
                        let inFolder = m.foldersContainingChat.contains(folder.id)
                        AxoContextMenu.CheckboxItem(folder.name, checked: Binding(get: { inFolder }, set: { m.onChatFolderToggleChat(folder.id, $0) }))
                    }
                    AxoContextMenu.Item(i18n("icu:LeftPane__ConversationListItem__ContextMenu__ChatFolderToggleChatsMenu__CreateFolderItem"),
                                        symbol: "plus", action: m.onChatFolderCreateNew)
                }
            }
            if !m.isActivelySearching && m.selectedCustomChatFolderId != nil {
                AxoContextMenu.Item(i18n("icu:LeftPane__ConversationListItem__ContextMenu__ChatFolderRemoveChatItem"), symbol: "folder-minus",
                                    action: m.onChatFolderRemoveChat)
            }
            if m.isArchived {
                AxoContextMenu.Item(i18n("icu:moveConversationToInbox"), symbol: "archive-up", action: m.onUnarchive)
            } else {
                AxoContextMenu.Item(i18n("icu:archiveConversation"), symbol: "archive", action: m.onArchive)
            }
            AxoContextMenu.Item(i18n("icu:deleteConversation"), symbol: "trash", action: m.onDelete)
            if !m.internalIds.isEmpty {
                AxoContextMenu.Separator()
                AxoContextMenu.Label("Internal")
                ForEach(m.internalIds, id: \.0) { label, value in
                    AxoContextMenu.Item(label, symbol: "copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(value, forType: .string)
                    }
                }
            }
        }
    }
}
