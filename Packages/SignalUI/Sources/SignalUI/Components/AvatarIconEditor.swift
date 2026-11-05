// Port of ts/components/AvatarIconEditor.dom.tsx: a preset icon avatar's preview over the
// colour picker, with Cancel / Save (Save returns the avatar with its new colour).

import SignalI18n
import SwiftUI

/// `.AvatarEditor__divider`: a 1px gray-15 / gray-75 rule, 20px above and 24px below.
struct AvatarEditorDivider: View {
    var body: some View {
        Rectangle().fill(AxoColor(light: LegacyColor.gray15, dark: LegacyColor.gray75)).frame(height: 1)
            .padding(.top, 20).padding(.bottom, 24)
    }
}

public struct AvatarIconEditor: View {
    let initialAvatarData: AvatarData
    let isInsideDialog: Bool
    /// nil: cancelled.
    let onClose: (AvatarData?) -> Void
    @State private var avatarData: AvatarData
    @State private var changed = false

    public init(avatarData: AvatarData, isInsideDialog: Bool = false, onClose: @escaping (AvatarData?) -> Void = { _ in }) {
        initialAvatarData = avatarData
        self.isInsideDialog = isInsideDialog
        self.onClose = onClose
        _avatarData = State(initialValue: avatarData)
    }

    var content: some View {
        VStack(spacing: 0) {
            AvatarPreview(avatarColor: avatarData.color, avatarData: avatarData, conversationTitle: avatarData.text)
            AvatarEditorDivider()
            AvatarColorPicker(selectedColor: avatarData.color) { color in
                avatarData.color = color
                changed = true
            }
        }
    }

    var buttons: some View {
        AvatarModalButtons(isInsideDialog: isInsideDialog, hasChanges: changed, onCancel: { onClose(nil) }, onSave: { onClose(avatarData) })
    }

    public var body: some View {
        if isInsideDialog {
            AxoDialog.Body(forceMaxHeight: true) { content }
            AxoDialog.Footer { buttons }
        } else {
            VStack(spacing: 0) {
                content
                buttons
            }
        }
    }
}
