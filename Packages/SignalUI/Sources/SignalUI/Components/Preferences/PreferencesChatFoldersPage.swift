// Port of ts/components/preferences/chatFolders/PreferencesChatFoldersPage.dom.tsx (and
// DeleteChatFolderDialog.dom.tsx): the folder list (create, reorder by drag, edit and delete
// from a context menu) and the suggested folders not yet added.

import SwiftUI

/// `ChatFolderPresetId`
public enum ChatFolderPresetId: String, Sendable, CaseIterable { case unreadChats = "UnreadChats", directChats = "DirectChats", groupChats = "GroupChats" }

public struct PreferencesChatFoldersPage: View {
    let chatFolders: [ChatFolder]
    let onBack: () -> Void
    /// nil: create a folder.
    let onOpenEditChatFoldersPage: (String?) -> Void
    /// `onCreateChatFolder(params, showToastOnSuccess: true)`: the preset's name and filter.
    let onCreateChatFolder: (String, ChatFolderPreset) -> Void
    let onDeleteChatFolder: (String) -> Void
    let onUpdateChatFoldersPositions: ([String]) -> Void
    @State private var firstFocused = true
    @State private var confirmDelete: ChatFolder?
    @State private var dragging: String?
    @Environment(\.i18n) var i18n

    public init(chatFolders: [ChatFolder], onBack: @escaping () -> Void = {}, onOpenEditChatFoldersPage: @escaping (String?) -> Void = { _ in },
                onCreateChatFolder: @escaping (String, ChatFolderPreset) -> Void = { _, _ in }, onDeleteChatFolder: @escaping (String) -> Void = { _ in },
                onUpdateChatFoldersPositions: @escaping ([String]) -> Void = { _ in }) {
        self.chatFolders = chatFolders
        self.onBack = onBack
        self.onOpenEditChatFoldersPage = onOpenEditChatFoldersPage
        self.onCreateChatFolder = onCreateChatFolder
        self.onDeleteChatFolder = onDeleteChatFolder
        self.onUpdateChatFoldersPositions = onUpdateChatFoldersPositions
    }

    var sorted: [ChatFolder] { chatFolders.sorted { $0.position < $1.position } }

    struct PresetConfig {
        let id: ChatFolderPresetId
        let title: String
        let description: String
        let preset: ChatFolderPreset
        var avatar: ChatFolderItemAvatarKind {
            switch id {
            case .unreadChats: .unreadChats
            case .directChats: .directChats
            case .groupChats: .groupChats
            }
        }
    }

    var presets: [PresetConfig] {
        let p = "icu:Preferences__ChatFoldersPage__SuggestedFoldersSection__"
        let all = [
            PresetConfig(id: .unreadChats, title: i18n(p + "UnreadFolder__Title"), description: i18n(p + "UnreadFolder__Description"), preset: .unreadChats),
            PresetConfig(id: .directChats, title: i18n(p + "DirectChatsFolder__Title"), description: i18n(p + "DirectChatsFolder__Description"),
                         preset: .individualChats),
            PresetConfig(id: .groupChats, title: i18n(p + "GroupChatsFolder__Title"), description: i18n(p + "GroupChatsFolder__Description"), preset: .groupChats),
        ]
        return all.filter { c in !sorted.contains { $0.folderType == .custom && $0.preset.matches(c.preset) } }
    }

    /// `moveChatFolders` for a drop of `moving` before `target`.
    func move(_ moving: String, before target: String) {
        var ids = sorted.map(\.id)
        guard moving != target, let from = ids.firstIndex(of: moving) else { return }
        ids.remove(at: from)
        guard let to = ids.firstIndex(of: target) else { return }
        ids.insert(moving, at: to)
        if ids != sorted.map(\.id) { onUpdateChatFoldersPositions(ids) }
    }

    @ViewBuilder func folderRow(_ folder: ChatFolder) -> some View {
        let title = folder.folderType == .all ? i18n("icu:Preferences__ChatFoldersPage__FoldersSection__AllChatsFolder__Title") : folder.name
        let row = ChatFolderItemContent(title: title) { ChatFolderItemAvatar(kind: .folder) } trailing: {
            AxoSymbol.Icon("draghandle-alt", size: 24, label: i18n("icu:Preferences__ChatFoldersPage__FoldersSection__DragHandle__Label"))
                .opacity(dragging == folder.id ? 1 : 0)
        }
        .onDrag { dragging = folder.id; return NSItemProvider(object: folder.id as NSString) }
        .onDrop(of: [.text], isTargeted: nil) { _ in
            if let d = dragging { move(d, before: folder.id) }
            dragging = nil
            return true
        }
        if folder.folderType == .custom {
            ChatFolderCustomRow(row: row, onEdit: { onOpenEditChatFoldersPage(folder.id) }, onDelete: { confirmDelete = folder })
        } else {
            row
        }
    }

    public var body: some View {
        PreferencesContent(title: i18n("icu:Preferences__ChatFoldersPage__Title"),
                           backButton: AnyView(PreferencesBackButton(label: i18n("icu:goBack"), action: onBack))) {
            PreferencesDescription(text: i18n("icu:Preferences__ChatFoldersPage__Description"))
            SettingsRow(title: i18n("icu:Preferences__ChatFoldersPage__FoldersSection__Title")) {
                ChatFolderItemButton(title: i18n("icu:Preferences__ChatFoldersPage__FoldersSection__CreateAFolderButton"), focused: firstFocused) {
                    firstFocused = false
                    onOpenEditChatFoldersPage(nil)
                } leading: {
                    ChatFolderItemAvatar(kind: .add)
                }
                ForEach(sorted) { folderRow($0) }
            }
            .padding(.top, 16)                       // mt-4
            let presets = presets
            if !presets.isEmpty {
                SettingsRow(title: i18n("icu:Preferences__ChatFoldersPage__SuggestedFoldersSection__Title")) {
                    ForEach(presets, id: \.id) { c in
                        ChatFolderItemContent(title: c.title, description: c.description) {
                            ChatFolderItemAvatar(kind: c.avatar)
                        } trailing: {
                            AxoButton.Root(i18n("icu:Preferences__ChatFoldersPage__SuggestedFoldersSection__AddButton"), variant: .subtleSecondary, size: .md) {
                                onCreateChatFolder(c.title, c.preset)
                            }
                        }
                    }
                }
            }
        }
        .viewportPortal {
            if let folder = confirmDelete {
                AxoBaseDialog.Host {
                    DeleteChatFolderDialog(title: i18n("icu:Preferences__ChatsPage__DeleteChatFolderDialog__Title"),
                                           description: i18n("icu:Preferences__ChatsPage__DeleteChatFolderDialog__Description",
                                                             ["chatFolderTitle": .string(folder.name)]),
                                           deleteText: i18n("icu:Preferences__ChatsPage__DeleteChatFolderDialog__DeleteButton"),
                                           onCancel: { confirmDelete = nil },
                                           onConfirm: {
                                               onDeleteChatFolder(folder.id)
                                               confirmDelete = nil
                                           })
                }
            }
        }
    }
}

/// `ChatFolderListItem` for a custom folder: clickable (edit), with the edit / delete menu.
struct ChatFolderCustomRow<Row: View>: View {
    let row: Row
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var menuLocation: CGPoint?
    @State private var hovered = false
    @Environment(\.i18n) var i18n

    var body: some View {
        AxoContextMenu.Root(location: $menuLocation) {
            SwiftUI.Button(action: onEdit) {
                row.background { if hovered || menuLocation != nil { RoundedRectangle(cornerRadius: 8).fill(AxoColor.fillPrimary) } }
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
        } items: {
            AxoContextMenu.Item(i18n("icu:Preferences__ChatsPage__ChatFoldersSection__ChatFolderItem__ContextMenu__EditFolder"), symbol: "pencil", action: onEdit)
            AxoContextMenu.Item(i18n("icu:Preferences__ChatsPage__ChatFoldersSection__ChatFolderItem__ContextMenu__DeleteFolder"), symbol: "trash", action: onDelete)
        }
    }
}

/// `DeleteChatFolderDialog`
public struct DeleteChatFolderDialog: View {
    let title: String
    let description: String
    let deleteText: String
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @Environment(\.i18n) var i18n

    public init(title: String, description: String, deleteText: String, onCancel: @escaping () -> Void, onConfirm: @escaping () -> Void) {
        self.title = title
        self.description = description
        self.deleteText = deleteText
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    public var body: some View {
        AxoAlertDialog.Content {
            AxoAlertDialog.Body {
                AxoAlertDialog.Title(title)
                AxoAlertDialog.Description(description)
            }
            AxoAlertDialog.Footer {
                AxoAlertDialog.Cancel(i18n("icu:cancel"), action: onCancel)
                AxoAlertDialog.Action(deleteText, variant: .strongDestructive, action: onConfirm)
            }
        }
    }
}
