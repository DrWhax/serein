// LeftPaneChatFolders (ts/components/leftPane/LeftPaneChatFolders.dom.tsx): the chat folder bar
// above the list: a no-track segmented control of folders with unread badges (a select in a
// narrow sidebar), each with a context menu (mark all read, mute / unmute, folder settings).
// Hidden unless there are custom folders. (No upstream story: covered by unit tests.)

import SignalI18n
import SwiftUI

/// `ChatFolder` (ts/types/ChatFolder.std.ts), as the bar needs it.
public struct ChatFolder: Sendable, Hashable, Identifiable {
    public enum FolderType: Sendable, Hashable { case all, custom }
    public var id: String
    public var folderType: FolderType
    public var name: String
    public var position: Int
    /// The folder's filter (`ChatFolderPreset`); `name` and `folderType` live above.
    public var preset: ChatFolderPreset
    public init(id: String, folderType: FolderType, name: String = "", position: Int, preset: ChatFolderPreset? = nil) {
        self.id = id
        self.folderType = folderType
        self.name = name
        self.position = position
        self.preset = preset ?? (folderType == .all ? .allChats : .defaults)
    }
}

/// `ChatFolderPreset` (ts/types/ChatFolder.std.ts) without `folderType`, which presets fix to CUSTOM.
public struct ChatFolderPreset: Sendable, Hashable {
    public var showOnlyUnread = false
    public var showMutedChats = true
    public var includeAllIndividualChats = false
    public var includeAllGroupChats = false
    public var includedConversationIds: [String] = []
    public var excludedConversationIds: [String] = []

    public init(showOnlyUnread: Bool = false, showMutedChats: Bool = true, includeAllIndividualChats: Bool = false, includeAllGroupChats: Bool = false,
                includedConversationIds: [String] = [], excludedConversationIds: [String] = []) {
        self.showOnlyUnread = showOnlyUnread
        self.showMutedChats = showMutedChats
        self.includeAllIndividualChats = includeAllIndividualChats
        self.includeAllGroupChats = includeAllGroupChats
        self.includedConversationIds = includedConversationIds
        self.excludedConversationIds = excludedConversationIds
    }

    /// `CHAT_FOLDER_DEFAULTS`
    public static let defaults = ChatFolderPreset()
    /// `ALL_CHATS_FOLDER_REQUIRED_PARAMS`
    public static let allChats = ChatFolderPreset(includeAllIndividualChats: true, includeAllGroupChats: true)
    /// `CHAT_FOLDER_PRESETS`
    public static let unreadChats = ChatFolderPreset(showOnlyUnread: true, includeAllIndividualChats: true, includeAllGroupChats: true)
    public static let individualChats = ChatFolderPreset(includeAllIndividualChats: true)
    public static let groupChats = ChatFolderPreset(includeAllGroupChats: true)

    /// `matchesChatFolderPreset`: conversation ids compare as sets.
    public func matches(_ other: ChatFolderPreset) -> Bool {
        showOnlyUnread == other.showOnlyUnread && showMutedChats == other.showMutedChats
            && includeAllIndividualChats == other.includeAllIndividualChats && includeAllGroupChats == other.includeAllGroupChats
            && Set(includedConversationIds) == Set(other.includedConversationIds) && Set(excludedConversationIds) == Set(other.excludedConversationIds)
    }
}

/// `UnreadStats` (ts/util/countUnreadStats.std.ts)
public struct UnreadStats: Sendable, Hashable {
    public var unreadCount = 0
    public var unreadChatsCount = 0
    public var unreadMentionsCount = 0
    public var readChatsMarkedUnreadCount = 0
    public init(unreadCount: Int = 0, unreadChatsCount: Int = 0, unreadMentionsCount: Int = 0, readChatsMarkedUnreadCount: Int = 0) {
        self.unreadCount = unreadCount
        self.unreadChatsCount = unreadChatsCount
        self.unreadMentionsCount = unreadMentionsCount
        self.readChatsMarkedUnreadCount = readChatsMarkedUnreadCount
    }

    /// `UnreadCountBadgeType`
    public enum BadgeType: Sendable { case unreadMessages, unreadChats }

    /// `getUnreadCountForBadge`
    public func badgeCount(_ type: BadgeType) -> Int {
        (type == .unreadChats ? unreadChatsCount : unreadCount) + readChatsMarkedUnreadCount
    }
}

/// `MutedStats`
public struct MutedStats: Sendable, Hashable {
    public var chatsMutedCount = 0
    public var chatsUnmutedCount = 0
    public init(chatsMutedCount: Int = 0, chatsUnmutedCount: Int = 0) {
        self.chatsMutedCount = chatsMutedCount
        self.chatsUnmutedCount = chatsUnmutedCount
    }
}

public struct LeftPaneChatFolders: View {
    static let unreadBadgeMaxCount = 999
    let folders: [ChatFolder]
    let selectedChatFolderId: String?
    let unreadStats: [String: UnreadStats]
    let mutedStats: [String: MutedStats]
    let badgeType: UnreadStats.BadgeType
    let onSelectedChatFolderIdChange: (String) -> Void
    let onChatFolderMarkRead: (String) -> Void
    let onChatFolderUpdateMute: (String, MuteOption?) -> Void
    let onChatFolderOpenSettings: (String) -> Void
    @Environment(\.i18n) var i18n
    @Environment(\.navSidebarWidthBreakpoint) var breakpoint

    public init(folders: [ChatFolder], selectedChatFolderId: String?, unreadStats: [String: UnreadStats] = [:],
                mutedStats: [String: MutedStats] = [:], badgeType: UnreadStats.BadgeType = .unreadMessages,
                onSelectedChatFolderIdChange: @escaping (String) -> Void = { _ in }, onChatFolderMarkRead: @escaping (String) -> Void = { _ in },
                onChatFolderUpdateMute: @escaping (String, MuteOption?) -> Void = { _, _ in }, onChatFolderOpenSettings: @escaping (String) -> Void = { _ in }) {
        self.folders = folders
        self.selectedChatFolderId = selectedChatFolderId
        self.unreadStats = unreadStats
        self.mutedStats = mutedStats
        self.badgeType = badgeType
        self.onSelectedChatFolderIdChange = onSelectedChatFolderIdChange
        self.onChatFolderMarkRead = onChatFolderMarkRead
        self.onChatFolderUpdateMute = onChatFolderUpdateMute
        self.onChatFolderOpenSettings = onChatFolderOpenSettings
    }

    /// `CurrentChatFolders.toSortedArray`
    var sorted: [ChatFolder] { folders.sorted { $0.position < $1.position } }
    var hasAnyCustomFolders: Bool { folders.contains { $0.folderType == .custom } }

    static func label(_ i18n: Localizer, _ folder: ChatFolder, preferShort: Bool) -> String {
        switch folder.folderType {
        case .all: i18n(preferShort ? "icu:LeftPaneChatFolders__ItemLabel--All--Short" : "icu:LeftPaneChatFolders__ItemLabel--All")
        case .custom: folder.name
        }
    }

    static func iconName(_ folder: ChatFolder?) -> AxoSymbol.Name { folder?.folderType == .custom ? "folder" : "message" }

    func badge(_ folder: ChatFolder) -> Int? {
        guard let stats = unreadStats[folder.id] else { return nil }
        let n = stats.badgeCount(badgeType)
        return n > 0 ? n : nil
    }

    public var body: some View {
        if hasAnyCustomFolders {
            let selection = Binding<String?>(get: { selectedChatFolderId }, set: { if let v = $0 { onSelectedChatFolderIdChange(v) } })
            if breakpoint == .narrow {
                AxoSelect.Root(label: nil, value: selection) {
                    AxoSelect.Trigger(variant: .elevated, width: .full, chevron: .onHover, placeholder: "")
                    AxoSelect.Content(position: .dropdown) {
                        ForEach(sorted) { folder in
                            AxoSelect.Item(value: folder.id, symbol: Self.iconName(folder)) {
                                AxoSelect.ItemText(Self.label(i18n, folder, preferShort: true))
                                if let n = badge(folder) {
                                    AxoSelect.ItemBadge(variant: .primary, value: .count(n), max: Self.unreadBadgeMaxCount,
                                                        label: i18n("icu:LeftPaneChatFolders__ItemUnreadBadge__AccessibleLabel", ["count": .number(Double(n))]))
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
            } else {
                // `scroll-px-[20%] scrollbar-width-none overflow-x-auto px-4 py-2`
                ScrollView(.horizontal) {
                    ExperimentalAxoSegmentedControl.Root(label: nil, width: .full, itemWidth: .fit, variant: .noTrack, value: selection) {
                        ForEach(sorted) { folder in item(folder) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.never)
            }
        }
    }

    func item(_ folder: ChatFolder) -> some View {
        ChatFolderSegmentedControlItem(folder: folder, label: Self.label(i18n, folder, preferShort: false), badge: badge(folder),
                                       unread: unreadStats[folder.id], muted: mutedStats[folder.id], onMarkRead: onChatFolderMarkRead,
                                       onUpdateMute: onChatFolderUpdateMute, onOpenSettings: onChatFolderOpenSettings)
    }
}

/// `getMuteValuesOptions` (ts/util/getMuteOptions.std.ts)
public enum MuteOption: Sendable, Hashable {
    case duration(seconds: Int), custom, always

    @MainActor static func values(_ i18n: Localizer) -> [(String, MuteOption)] {
        [(i18n("icu:MuteMenu__hour"), .duration(seconds: 3600)), (i18n("icu:MuteMenu__eightHours"), .duration(seconds: 8 * 3600)),
         (i18n("icu:MuteMenu__day"), .duration(seconds: 86_400)), (i18n("icu:MuteMenu__week"), .duration(seconds: 7 * 86_400)),
         (i18n("icu:MuteMenu__until"), .custom), (i18n("icu:MuteMenu__always"), .always)]
    }
}

/// One folder: the segmented item with its context menu.
struct ChatFolderSegmentedControlItem: View {
    let folder: ChatFolder
    let label: String
    let badge: Int?
    let unread: UnreadStats?
    let muted: MutedStats?
    let onMarkRead: (String) -> Void
    /// nil = unmute.
    let onUpdateMute: (String, MuteOption?) -> Void
    let onOpenSettings: (String) -> Void
    @Environment(\.i18n) var i18n
    @State private var menuLocation: CGPoint?

    var body: some View {
        let someUnread = (unread?.unreadCount ?? 0) > 0 || (unread?.readChatsMarkedUnreadCount ?? 0) > 0
        let someMuted = (muted?.chatsMutedCount ?? 0) > 0, someUnmuted = (muted?.chatsUnmutedCount ?? 0) > 0
        let onlyUnmuteAll = someMuted && !someUnmuted
        // maxWidth="12ch" in the item's body-medium 500.
        let maxWidth = CSSTextLayout.ch(CSSTextStyle(AxoType.bodyMedium.weight(500))) * 12
        AxoContextMenu.Root(location: $menuLocation) {
            ExperimentalAxoSegmentedControl.Item(value: folder.id) {
                ExperimentalAxoSegmentedControl.ItemText(label, maxWidth: maxWidth)
                if let badge {
                    ExperimentalAxoSegmentedControl.ItemBadge(variant: .primary, value: .count(badge), max: LeftPaneChatFolders.unreadBadgeMaxCount,
                                                              label: i18n("icu:LeftPaneChatFolders__ItemUnreadBadge__AccessibleLabel",
                                                                          ["count": .number(Double(badge))]))
                }
            }
        } items: {
            if someUnread {
                AxoContextMenu.Item(i18n("icu:LeftPaneChatFolders__Item__ContextMenu__MarkAllRead"), symbol: "message-check") { onMarkRead(folder.id) }
            }
            if !onlyUnmuteAll {
                AxoContextMenu.Sub(AxoContextMenu.SubTrigger(i18n("icu:LeftPaneChatFolders__Item__ContextMenu__MuteNotifications"), symbol: "bell-slash")) {
                    if someMuted {
                        AxoContextMenu.Item(i18n("icu:LeftPaneChatFolders__Item__ContextMenu__MuteNotifications__UnmuteAll")) {
                            onUpdateMute(folder.id, nil)
                        }
                    }
                    ForEach(MuteOption.values(i18n), id: \.1) { name, option in
                        AxoContextMenu.Item(name) { onUpdateMute(folder.id, option) }
                    }
                }
            } else {
                AxoContextMenu.Item(i18n("icu:LeftPaneChatFolders__Item__ContextMenu__UnmuteAll"), symbol: "bell") { onUpdateMute(folder.id, nil) }
            }
            if folder.folderType == .custom {
                AxoContextMenu.Item(i18n("icu:LeftPaneChatFolders__Item__ContextMenu__EditFolder"), symbol: "pencil") { onOpenSettings(folder.id) }
            }
        }
    }
}
