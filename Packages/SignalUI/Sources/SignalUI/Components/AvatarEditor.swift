// Port of ts/components/AvatarEditor.dom.tsx: the avatar editor. Main mode is the preview
// (with clear), Photo / Text buttons, and the saved avatars (presets first) to pick from;
// picking the selected one again edits it (AvatarTextEditor or AvatarIconEditor).
//
// Saving and deleting avatars on disk are callbacks (`saveAvatarToDisk`, `deleteAvatarFromDisk`,
// `replaceAvatar`); a picked photo arrives as a file URL for the media service to decode.

import SignalI18n
import SwiftUI

public struct AvatarEditor: View {
    public struct Callbacks {
        public var onCancel: () -> Void = {}
        /// The new avatar (nil: cleared).
        public var onSave: (AvatarData?) -> Void = { _ in }
        public var onPhotoPicked: (URL) -> Void = { _ in }
        public var replaceAvatar: (AvatarData, AvatarData?) -> Void = { _, _ in }
        public var deleteAvatarFromDisk: (AvatarData) -> Void = { _ in }
        public init() {}
    }

    enum EditMode { case main, text, custom }

    let avatarColor: String?
    let avatarImage: RGBAImage?
    let conversationTitle: String?
    let isGroup: Bool
    let isInsideDialog: Bool
    let callbacks: Callbacks
    @State private var localAvatarData: [AvatarData]
    @State private var selectedId: String?
    @State private var preview: AvatarData?
    @State private var pendingClear = false
    @State private var editMode = EditMode.main
    @Environment(\.i18n) var i18n

    public init(avatarColor: String? = nil, avatarImage: RGBAImage? = nil, conversationTitle: String?, isGroup: Bool, isInsideDialog: Bool = false,
                userAvatarData: [AvatarData], callbacks: Callbacks = Callbacks()) {
        self.avatarColor = avatarColor
        self.avatarImage = avatarImage
        self.conversationTitle = conversationTitle
        self.isGroup = isGroup
        self.isInsideDialog = isInsideDialog
        self.callbacks = callbacks
        _localAvatarData = State(initialValue: userAvatarData)
    }

    /// `getDefaultAvatars(isGroup)`
    public static func defaultAvatars(isGroup: Bool) -> [AvatarData] {
        (isGroup ? AxoTokensTables.groupPresets : AxoTokensTables.contactPresets).enumerated().map { i, p in
            AvatarData(id: "\(i)", color: p.color, icon: p.name)
        }
    }

    var selected: AvatarData? { localAvatarData.first { $0.id == selectedId } }
    var hasChanges: Bool { preview != nil || (pendingClear && avatarImage != nil) }

    /// `.AvatarEditor__button`: 60×44 min, radius 8, an 18px icon over 9px / 14px text.
    func topButton(_ label: String, icon: String) -> some View {
        VStack(spacing: 0) {
            SignalIcon(icon, size: 18, color: AxoColor(light: LegacyColor.black, dark: LegacyColor.gray05), mask: true)
            CSSText(label, style: CSSTextStyle(fontName: AxoFonts.interName(weight: 400), size: 9, lineHeight: 14, letterSpacing: -0.084), wrap: .nowrap,
                    color: AxoColor(light: LegacyColor.black, dark: LegacyColor.gray05))
        }
        .padding(.horizontal, 8)
        .frame(minWidth: 60, minHeight: 44)
        .background(AxoColor(light: LegacyColor.gray05, dark: LegacyColor.gray65), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 8)
    }

    var main: some View {
        VStack(spacing: 0) {
            AvatarPreview(avatarColor: avatarColor, avatarData: preview, avatarImage: pendingClear ? nil : avatarImage,
                          conversationTitle: conversationTitle, isGroup: isGroup, onClear: {
                pendingClear = true
                preview = nil
                selectedId = nil
            })
            HStack(spacing: 0) {
                AvatarUploadButton(onChange: callbacks.onPhotoPicked) { topButton($0, icon: "v3/album/album-tilt") }
                SwiftUI.Button {
                    selectedId = nil
                    editMode = .text
                } label: { topButton(i18n("icu:text"), icon: "v2/text-24") }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
            AvatarEditorDivider()
            AvatarSelectorTitle(text: i18n("icu:AvatarEditor--choose"))
            AvatarBubbleRow {
                ForEach(localAvatarData) { data in
                    BetterAvatar(avatarData: data, isSelected: data.id == selectedId, onClick: {
                        if data.id == selectedId {
                            if data.text != nil { editMode = .text } else if data.icon != nil { editMode = .custom }
                        } else {
                            preview = data
                            selectedId = data.id
                        }
                    }, onDelete: {
                        localAvatarData.removeAll { $0.id == data.id }
                        if selectedId == data.id {
                            preview = nil
                            selectedId = nil
                        }
                        callbacks.deleteAvatarFromDisk(data)
                    })
                }
            }
        }
    }

    var mainButtons: some View {
        AvatarModalButtons(isInsideDialog: isInsideDialog, hasChanges: hasChanges, onCancel: {
            preview = nil
            pendingClear = false
            callbacks.onCancel()
        }, onSave: {
            if let selected { callbacks.replaceAvatar(selected, selected) }
            pendingClear = false
            callbacks.onSave(preview)
        })
    }

    /// Replaces `stale` with `new` (or prepends it) and selects it.
    func update(_ new: AvatarData, replacing stale: AvatarData?) {
        localAvatarData.removeAll { $0.id == stale?.id }
        localAvatarData.insert(new, at: 0)
        preview = new
        selectedId = new.id
        callbacks.replaceAvatar(new, stale)
    }

    public var body: some View {
        switch editMode {
        case .main:
            if isInsideDialog {
                AxoDialog.Body(forceMaxHeight: true) { main }
                AxoDialog.Footer { mainButtons }
            } else {
                VStack(spacing: 0) {
                    main
                    mainButtons
                }
            }
        case .text:
            AvatarTextEditor(avatarData: selected, isInsideDialog: isInsideDialog, onCancel: { editMode = .main }, onDone: { data in
                update(data, replacing: selected)
                editMode = .main
            })
        case .custom:
            if let selected {
                AvatarIconEditor(avatarData: selected, isInsideDialog: isInsideDialog) { data in
                    if let data { update(data, replacing: selected) }
                    editMode = .main
                }
            }
        }
    }
}
