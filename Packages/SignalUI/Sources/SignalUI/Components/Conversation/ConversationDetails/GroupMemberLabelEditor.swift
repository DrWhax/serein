// Port of ts/components/conversation/conversation-details/GroupMemberLabelEditor.dom.tsx: your
// member label for a group. The label input (emoji button inside, clearable, 24 characters /
// 96 bytes), its description, a preview message from you with the label, and the other members'
// labels; Cancel / Save under a 680px column. Without permission it says so and closes.

import SignalI18n
import SwiftUI

/// A member shown in the editor's list.
public struct LabelledGroupMember: Identifiable {
    public var id: String
    public var avatar: ConversationAvatarData
    public var isMe = false
    public var isAdmin = false
    public var label: ContactLabel
    public var contactNameColor: String
    public init(id: String, avatar: ConversationAvatarData, isMe: Bool = false, isAdmin: Bool = false, label: ContactLabel, contactNameColor: String) {
        self.id = id
        self.avatar = avatar
        self.isMe = isMe
        self.isAdmin = isAdmin
        self.label = label
        self.contactNameColor = contactNameColor
    }
}

public struct GroupMemberLabelEditor: View {
    static let graphemeLimit = 24
    static let byteLimit = 96

    let me: MessageProps.Author
    let ourColor: String
    let bubbleColor: BubbleColor
    let canAddLabel: Bool
    let isActive: Bool
    let existingLabelEmoji: String?
    let existingLabelString: String?
    let membersWithLabel: [LabelledGroupMember]
    let emojiPicker: AnyView?
    let popPanel: () -> Void
    /// Saves (emoji, string); call the completion with false on failure.
    let updateGroupMemberLabel: (String?, String?, @escaping (Bool) -> Void) -> Void
    @State private var labelEmoji: String?
    @State private var labelString: String
    @State private var emojiPickerOpen = false
    @State private var isSaving = false
    @Environment(\.i18n) var i18n
    @Environment(\.axoModalStack) var modals
    @Environment(\.axoStaticRendering) var staticRendering
    @Environment(\.conversationListNow) var fixedNow

    public init(me: MessageProps.Author, ourColor: String, bubbleColor: BubbleColor = .default, canAddLabel: Bool = true, isActive: Bool = true,
                existingLabelEmoji: String? = nil, existingLabelString: String? = nil, membersWithLabel: [LabelledGroupMember] = [],
                emojiPicker: AnyView? = nil, popPanel: @escaping () -> Void = {},
                updateGroupMemberLabel: @escaping (String?, String?, @escaping (Bool) -> Void) -> Void = { _, _, done in done(true) }) {
        self.me = me
        self.ourColor = ourColor
        self.bubbleColor = bubbleColor
        self.canAddLabel = canAddLabel
        self.isActive = isActive
        self.existingLabelEmoji = existingLabelEmoji
        self.existingLabelString = existingLabelString
        self.membersWithLabel = membersWithLabel
        self.emojiPicker = emojiPicker
        self.popPanel = popPanel
        self.updateGroupMemberLabel = updateGroupMemberLabel
        _labelEmoji = State(initialValue: existingLabelEmoji)
        _labelString = State(initialValue: existingLabelString ?? "")
    }

    var labelStringForSave: String? {
        let t = labelString.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }
    var isDirty: Bool { labelEmoji != existingLabelEmoji || labelStringForSave != (existingLabelString.flatMap { $0.isEmpty ? nil : $0 }) }
    var canSave: Bool { isDirty && ((labelEmoji == nil && labelStringForSave == nil) || labelStringForSave != nil) }

    func alert(_ id: String, _ description: String, then: @escaping () -> Void = {}) {
        guard let modals else { return }
        modals.present(id: id) {
            GroupMemberLabelEditorAlert(description: description) {
                modals.dismiss(id: id)
                then()
            }
        }
    }

    var input: some View {
        let text = Binding(get: { labelString }, set: { v in
            if v.isEmpty { labelEmoji = nil }
            labelString = String(v.map { $0.isWhitespace ? " " : $0 })
        })
        let shouldShowClear = labelEmoji != nil || !labelString.isEmpty
        return Input(value: text, placeholder: i18n("icu:ConversationDetails--member-label--placeholder"), clearLabel: i18n("icu:cancel"),
                     hasClearButton: true, shouldShowClearButton: shouldShowClear, maxByteCount: Self.byteLimit, maxLengthCount: Self.graphemeLimit,
                     whenToShowRemainingCount: 20, autoFocus: true,
                     icon: AnyView(FunEmojiPickerButton(isOpen: $emojiPickerOpen, selectedEmoji: labelEmoji, picker: emojiPicker)))
    }

    var preview: some View {
        var p = MessageProps(id: "fake-id", direction: .incoming, author: MessageProps.Author(id: me.id, title: me.title), text: i18n("icu:ConversationDetails--member-label--hello"),
                             timestamp: fixedNow ?? Date())
        p.author.avatar = me.avatar
        p.author.color = me.color
        p.conversationType = .group
        p.bubbleColor = bubbleColor
        p.contactNameColor = ourColor
        p.contactLabel = labelStringForSave.map { ContactLabel(labelString: $0, labelEmoji: labelEmoji) }
        return Message(props: p).environment(\.messageContainerMaxWidth, 600)
    }

    var memberList: some View {
        AxoList.Root {
            AxoList.Header { AxoList.Label(i18n("icu:ConversationDetails--member-label--list-header")) }
            AxoList.Body {
                if membersWithLabel.isEmpty {
                    CSSText(i18n("icu:ConversationDetails--member-label--no-members"), type: .bodyMedium, color: .labelSecondary)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    AxoItem.Group {
                        ForEach(membersWithLabel) { m in
                            AxoItem.Root {
                                AxoItem.Leading { ListAvatar(data: m.avatar, size: 36) }
                                AxoItem.Content {
                                    AxoItem.Label { CSSText(runs: [Emojify.run(m.isMe ? i18n("icu:you") : m.avatar.title)], style: CSSTextStyle(AxoType.bodyMedium)) }
                                    if m.isAdmin { AxoItem.Value(i18n("icu:GroupV2--admin")) }
                                    // The inline pill in the description's 16px line: a 22px line box.
                                    AxoItem.Description {
                                        GroupMemberLabel(contactLabel: m.label, contactNameColor: m.contactNameColor, context: .list)
                                            .frame(height: 22, alignment: .top)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            input
            CSSText(i18n("icu:ConversationDetails--member-label--description"), type: .bodySmall, color: .labelSecondary)
                .padding(.top, 8).padding(.bottom, 16)
            AxoList.Group {
                AxoList.Root {
                    AxoList.Header { AxoList.Label(i18n("icu:ConversationDetails--member-label--preview")) }
                    AxoList.Body { preview }
                }
                memberList
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
    }

    public var body: some View {
        VStack(spacing: 0) {
            if staticRendering { column } else { ScrollView { column } }
            HStack(spacing: 8) {
                AxoButton.Root(i18n("icu:cancel"), variant: .strongSecondary, size: .md, action: popPanel)
                AxoButton.Root(i18n("icu:save"), variant: .strongPrimary, size: .md, pending: isSaving, disabled: !canSave) {
                    isSaving = true
                    updateGroupMemberLabel(labelEmoji, labelStringForSave) { ok in
                        isSaving = false
                        if ok { popPanel() } else { alert("member-label-error", i18n("icu:ConversationDetails--member-label--error-generic")) }
                    }
                }
            }
            .padding(.leading, 20).padding(.trailing, 26).padding(.vertical, 12)
            .frame(maxWidth: 680, alignment: .trailing)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            if !canAddLabel && isActive {
                alert("member-label-permissions", i18n("icu:ConversationDetails--member-label--error-permissions"), then: popPanel)
            }
        }
    }
}

/// The editor's "Can’t save member label" alert.
public struct GroupMemberLabelEditorAlert: View {
    let description: String
    let onOk: () -> Void
    @Environment(\.i18n) var i18n
    public init(description: String, onOk: @escaping () -> Void) {
        self.description = description
        self.onOk = onOk
    }
    public var body: some View {
        AxoAlertDialog.Content {
            AxoAlertDialog.Body {
                AxoAlertDialog.Title(i18n("icu:ConversationDetails--member-label--error-title"))
                AxoAlertDialog.Description(description)
            }
            AxoAlertDialog.Footer {
                AxoAlertDialog.Action(i18n("icu:ok"), variant: .strongPrimary, action: onOk)
            }
        }
    }
}
