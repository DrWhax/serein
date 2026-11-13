// Port of ts/components/preferences/chatFolders/PreferencesEditChatFoldersPage.dom.tsx: create
// or edit a chat folder (name with emoji picker, included chats and chat types, exceptions,
// unread-only and muted switches, delete), with Cancel / Save in the page actions.
//
// Upstream's nav blocker asks to save or discard when leaving with unsaved changes. Here the
// page's own back button asks; `onChangedStateChange` reports unsaved changes so the shell can
// block sidebar navigation the same way. An emoji is appended to the name (the legacy Input
// does not expose its caret).

import SignalI18n
import SwiftUI

/// `ChatFolderParams`: a folder's name and filter.
public struct ChatFolderParams: Sendable, Hashable {
    public var name: String
    public var preset: ChatFolderPreset
    public init(name: String = "", preset: ChatFolderPreset = .defaults) {
        self.name = name
        self.preset = preset
    }

    /// `CHAT_FOLDER_NAME_MAX_CHAR_LENGTH`
    public static let nameMaxLength = 32

    /// `ChatFolderParamsSchema`: the name NFC-normalised and trimmed.
    public var normalized: ChatFolderParams {
        ChatFolderParams(name: name.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines), preset: preset)
    }

    /// `validateChatFolderParams` (grapheme count).
    public var isValid: Bool { !name.isEmpty && name.count <= Self.nameMaxLength }

    /// `isSameChatFolderParams`
    public func isSame(_ other: ChatFolderParams) -> Bool { name == other.name && preset.matches(other.preset) }
}

public struct PreferencesEditChatFolderPage: View {
    let existingChatFolderId: String?
    let initChatFolderParams: ChatFolderParams
    let conversations: [SearchableConversation]
    let conversationSelector: (String) -> SelectedChatPill
    let onBack: () -> Void
    let onCreateChatFolder: (ChatFolderParams) -> Void
    let onUpdateChatFolder: (String, ChatFolderParams) -> Void
    let onDeleteChatFolder: (String) -> Void
    let onChangedStateChange: (Bool) -> Void
    @State private var params: ChatFolderParams
    @State private var emojiPickerOpen = false
    @State private var showInclusionsDialog = false
    @State private var showExclusionsDialog = false
    @State private var confirmDelete = false
    @State private var confirmLeave = false
    @Environment(\.i18n) var i18n

    public init(existingChatFolderId: String? = nil, initChatFolderParams: ChatFolderParams = ChatFolderParams(),
                conversations: [SearchableConversation] = [], conversationSelector: @escaping (String) -> SelectedChatPill,
                onBack: @escaping () -> Void = {}, onCreateChatFolder: @escaping (ChatFolderParams) -> Void = { _ in },
                onUpdateChatFolder: @escaping (String, ChatFolderParams) -> Void = { _, _ in }, onDeleteChatFolder: @escaping (String) -> Void = { _ in },
                onChangedStateChange: @escaping (Bool) -> Void = { _ in }) {
        self.existingChatFolderId = existingChatFolderId
        self.initChatFolderParams = initChatFolderParams
        self.conversations = conversations
        self.conversationSelector = conversationSelector
        self.onBack = onBack
        self.onCreateChatFolder = onCreateChatFolder
        self.onUpdateChatFolder = onUpdateChatFolder
        self.onDeleteChatFolder = onDeleteChatFolder
        self.onChangedStateChange = onChangedStateChange
        _params = State(initialValue: initChatFolderParams)
    }

    var normalized: ChatFolderParams { params.normalized }
    var isChanged: Bool { !initChatFolderParams.isSame(normalized) }
    var isValid: Bool { normalized.isValid }

    func save() {
        guard isChanged, isValid else { return }
        if let existingChatFolderId { onUpdateChatFolder(existingChatFolderId, normalized) } else { onCreateChatFolder(normalized) }
    }

    func back() {
        if isChanged { confirmLeave = true } else { onBack() }
    }

    @ViewBuilder func conversationRow(_ id: String) -> some View {
        let c = conversationSelector(id)
        ChatFolderItemContent(title: c.data.title) {
            Avatar(strings: AvatarStrings(i18n: i18n), title: c.data.title, size: 36, conversationType: c.data.type, color: c.data.avatar.color ?? "A200",
                   image: c.data.avatar.image.map { AnyView(PixelImage($0, fit: .cover)) }, hasAvatar: c.data.avatar.image != nil)
        }
    }

    var emojiPicker: AnyView {
        AnyView(FunEmojiPicker(panel: FunPanelEmojis(recentEmojis: [], onSelectEmoji: { emoji in
            params.name += emoji
            emojiPickerOpen = false
        })))
    }

    public var body: some View {
        let p = "icu:Preferences__EditChatFolderPage__"
        PreferencesContent(title: i18n(existingChatFolderId != nil ? p + "Title--EditingExistingChatFolder" : p + "Title"),
                           backButton: AnyView(PreferencesBackButton(label: i18n("icu:goBack"), action: back))) {
            SettingsRow(title: i18n(p + "FolderNameField__Label")) {
                Input(value: $params.name, placeholder: i18n(p + "FolderNameField__Placeholder"), clearLabel: i18n("icu:cancel"),
                      maxLengthCount: ChatFolderParams.nameMaxLength, whenToShowRemainingCount: ChatFolderParams.nameMaxLength - 10, autoFocus: true,
                      children: AnyView(FunEmojiPickerButton(isOpen: $emojiPickerOpen, picker: emojiPicker)))
                    .padding(.vertical, 16)                 // .Input__container margin-block
                    .padding(.horizontal, 24)
            }
            SettingsRow(title: i18n(p + "IncludedChatsSection__Title")) {
                ChatFolderItemButton(title: i18n(p + "IncludedChatsSection__AddChatsButton"), action: { showInclusionsDialog = true }) {
                    ChatFolderItemAvatar(kind: .add)
                }
                if params.preset.includeAllIndividualChats {
                    ChatFolderItemContent(title: i18n(p + "IncludedChatsSection__DirectChats")) { ChatFolderItemAvatar(kind: .directChats) }
                }
                if params.preset.includeAllGroupChats {
                    ChatFolderItemContent(title: i18n(p + "IncludedChatsSection__GroupChats")) { ChatFolderItemAvatar(kind: .groupChats) }
                }
                ForEach(params.preset.includedConversationIds, id: \.self) { conversationRow($0) }
                PreferencesDescription(text: i18n(p + "IncludedChatsSection__Help"))
            }
            SettingsRow(title: i18n(p + "ExceptionsSection__Title")) {
                ChatFolderItemButton(title: i18n(p + "ExceptionsSection__ExcludeChatsButton"), action: { showExclusionsDialog = true }) {
                    ChatFolderItemAvatar(kind: .add)
                }
                ForEach(params.preset.excludedConversationIds, id: \.self) { conversationRow($0) }
                PreferencesDescription(text: i18n(p + "ExceptionsSection__Help"))
            }
            SettingsRow(isLast: existingChatFolderId == nil) {
                SettingsControl(left: i18n(p + "OnlyShowUnreadChatsCheckbox__Label"), description: i18n(p + "OnlyShowUnreadChatsCheckbox__Description")) {
                    AxoSwitch.Root(checked: $params.preset.showOnlyUnread, label: i18n(p + "OnlyShowUnreadChatsCheckbox__Label"))
                }
                SettingsControl(left: i18n(p + "IncludeMutedChatsCheckbox__Label")) {
                    AxoSwitch.Root(checked: $params.preset.showMutedChats, label: i18n(p + "IncludeMutedChatsCheckbox__Label"))
                }
            }
            if existingChatFolderId != nil {
                SettingsRow(isLast: true) {
                    SwiftUI.Button { confirmDelete = true } label: {
                        CSSText(i18n(p + "DeleteFolderButton"), style: LegacyType.body1(), color: .labelDestructive)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 24)
                }
            }
        } actions: {
            AxoButton.Root(i18n(p + "CancelButton"), variant: .strongSecondary, size: .lg, action: onBack)
            AxoButton.Root(i18n(p + "SaveButton"), variant: .strongPrimary, size: .lg, disabled: !(isChanged && isValid)) {
                save()
                onBack()
            }
        }
        .onChange(of: isChanged, initial: true) { _, changed in onChangedStateChange(changed) }
        .viewportPortal {
            if showInclusionsDialog {
                AxoBaseDialog.Host {
                    PreferencesSelectChatsDialog(title: i18n(p + "SelectChatsDialog--IncludedChats__Title"), conversations: conversations,
                                                 conversationSelector: conversationSelector,
                                                 initialSelection: ChatFolderSelection(selectedRecipientIds: params.preset.includedConversationIds,
                                                                                       selectAllIndividualChats: params.preset.includeAllIndividualChats,
                                                                                       selectAllGroupChats: params.preset.includeAllGroupChats),
                                                 showChatTypes: true) { s in
                        params.preset.includeAllIndividualChats = s.selectAllIndividualChats
                        params.preset.includeAllGroupChats = s.selectAllGroupChats
                        params.preset.includedConversationIds = s.selectedRecipientIds
                        showInclusionsDialog = false
                    }
                }
            } else if showExclusionsDialog {
                AxoBaseDialog.Host {
                    PreferencesSelectChatsDialog(title: i18n(p + "SelectChatsDialog--ExcludedChats__Title"), conversations: conversations,
                                                 conversationSelector: conversationSelector,
                                                 initialSelection: ChatFolderSelection(selectedRecipientIds: params.preset.excludedConversationIds,
                                                                                       selectAllIndividualChats: !params.preset.includeAllIndividualChats,
                                                                                       selectAllGroupChats: !params.preset.includeAllGroupChats)) { s in
                        params.preset.includeAllIndividualChats = !s.selectAllIndividualChats
                        params.preset.includeAllGroupChats = !s.selectAllGroupChats
                        params.preset.excludedConversationIds = s.selectedRecipientIds
                        showExclusionsDialog = false
                    }
                }
            } else if confirmDelete, let id = existingChatFolderId {
                AxoBaseDialog.Host {
                    DeleteChatFolderDialog(title: i18n(p + "DeleteChatFolderDialog__Title"), description: i18n(p + "DeleteChatFolderDialog__Description"),
                                           deleteText: i18n(p + "DeleteChatFolderDialog__DeleteButton"), onCancel: { confirmDelete = false },
                                           onConfirm: {
                                               confirmDelete = false
                                               onDeleteChatFolder(id)
                                               onBack()
                                           })
                }
            } else if confirmLeave {
                AxoBaseDialog.Host {
                    // SaveChangesFolderDialog
                    AxoConfirmDialog.Root(title: i18n(p + "SaveChangesFolderDialog__Title"), description: i18n(p + "SaveChangesFolderDialog__Description")) {
                        AxoConfirmDialog.Action(i18n(p + "SaveChangesFolderDialog__DiscardButton"), variant: .subtleSecondary) {
                            confirmLeave = false
                            onBack()
                        }
                        AxoConfirmDialog.Action(i18n(p + "SaveChangesFolderDialog__SaveButton"), variant: .strongPrimary) {
                            confirmLeave = false
                            save()
                            onBack()
                        }
                    }
                }
            }
        }
    }
}
