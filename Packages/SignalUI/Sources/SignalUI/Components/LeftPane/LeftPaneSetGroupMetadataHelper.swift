// LeftPaneSetGroupMetadataHelper (ts/components/leftPane/LeftPaneSetGroupMetadataHelper.dom.tsx):
// "Name this group": avatar, group name, disappearing-messages timer, the members, and Create.

import SignalI18n
import SwiftUI

public struct LeftPaneSetGroupMetadataHelper: LeftPaneHelper {
    public var groupName: String
    public var groupExpireTimer: Int
    public var isCreating: Bool
    public var selectedContacts: [ContactListItemData]
    public var onChangeGroupName: @MainActor @Sendable (String) -> Void
    public var onChangeExpireTimer: (Int) -> Void
    public var onEditAvatar: () -> Void
    /// `groupAvatar`: the chosen avatar, shown in the preview.
    public var groupAvatar: RGBAImage?

    public init(groupName: String, groupExpireTimer: Int = 0, isCreating: Bool = false, selectedContacts: [ContactListItemData],
                onChangeGroupName: @escaping @MainActor @Sendable (String) -> Void = { _ in }, onChangeExpireTimer: @escaping (Int) -> Void = { _ in },
                onEditAvatar: @escaping () -> Void = {}, groupAvatar: RGBAImage? = nil) {
        self.groupAvatar = groupAvatar
        self.groupName = groupName
        self.groupExpireTimer = groupExpireTimer
        self.isCreating = isCreating
        self.selectedContacts = selectedContacts
        self.onChangeGroupName = onChangeGroupName
        self.onChangeExpireTimer = onChangeExpireTimer
        self.onEditAvatar = onEditAvatar
    }

    var canCreateGroup: Bool { !isCreating && !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public func headerContents(_ ctx: LeftPaneContext) -> AnyView? {
        AnyView(LeftPaneHeaderContents(backLabel: ctx.i18n("icu:setGroupMetadata__back-button"), back: ctx.showChooseGroupMembers,
                                       title: ctx.i18n("icu:setGroupMetadata__title")))
    }

    public func backAction(_ ctx: LeftPaneContext) -> (() -> Void)? { ctx.showChooseGroupMembers }

    public func preRows(_ ctx: LeftPaneContext) -> AnyView? {
        let i18n = ctx.i18n
        let name = Binding(get: { groupName }, set: onChangeGroupName)
        return AnyView(VStack(spacing: 0) {
            // AvatarPreview with style { height: 96, width: 96, margin: 0 }: the avatar colour is AvatarColors[0].
            AvatarPreview(avatarColor: AxoTokens.Avatar.allColorNames[0], avatarValue: groupAvatar, isGroup: true, showUploadButton: true, size: 96, margins: false,
                          onClick: onEditAvatar)
            // .module-GroupInput--container: margin 16
            Input(value: name, placeholder: i18n("icu:setGroupMetadata__group-name-placeholder"), clearLabel: i18n("icu:cancel"),
                  disabled: isCreating, maxLengthCount: 32, autoFocus: true)
                .padding(.vertical, 16)    // .Input__container margin-block
                .padding(16)
            // __form__expire-timer: row, centred, margin 0 16 16
            // The label shrinks (and wraps) beside the select at its max-content width.
            CSSFlex(.row, align: .center) {
                CSSText(i18n("icu:disappearingMessages"), style: LeftPaneMessageText.style,
                        color: AxoColor(light: LegacyColor.gray90, dark: LegacyColor.gray05))
                    .padding(.trailing, 12)
                    .flexItem(shrink: 1)
                DisappearingTimerSelect(value: groupExpireTimer, onChange: onChangeExpireTimer)
                    .flexItem(shrink: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        })
    }

    public func footer(_ ctx: LeftPaneContext) -> AnyView? {
        AnyView(LegacyButton(ctx.i18n("icu:setGroupMetadata__create-group"), disabled: !canCreateGroup, action: ctx.createGroup))
    }

    public func rows(_ i18n: Localizer) -> [ConversationListRow] {
        guard !selectedContacts.isEmpty else { return [] }
        return [.header(i18n("icu:setGroupMetadata__members-header"))] + selectedContacts.map { .contact($0, isClickable: false) } + [.blank]
    }
}
