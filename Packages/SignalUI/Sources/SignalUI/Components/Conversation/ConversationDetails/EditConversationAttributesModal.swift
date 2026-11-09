// Port of ts/components/conversation/conversation-details/EditConversationAttributesModal.dom.tsx
// (stylesheets/components/EditConversationAttributesModal.scss): "Edit group": the 96px avatar
// (opens the AvatarEditor in the dialog), the title and description inputs, the visibility
// note and the error; Save sends only what changed.

import SignalI18n
import SwiftUI

/// `RequestState` (conversation-details/util.std.ts)
public enum RequestState: Sendable { case inactive, inactiveWithError, active }

public struct EditConversationAttributesModal: View {
    public struct Request: Sendable {
        public var avatar: AvatarData??
        public var title: String?
        public var description: String?
    }

    let avatarColor: String?
    let avatarImage: RGBAImage?
    let title: String
    let groupDescription: String
    let initiallyFocusDescription: Bool
    let requestState: RequestState
    let userAvatarData: [AvatarData]
    let makeRequest: (Request) -> Void
    let onClose: () -> Void
    @State private var rawTitle: String
    @State private var rawDescription: String
    @State private var editingAvatar = false
    @State private var avatar: AvatarData?
    /// Decodes a picked photo (the app's media service); nil leaves the photo button inert.
    var loadPhoto: ((URL) async -> RGBAImage?)?
    @State private var hasAvatarChanged = false
    @Environment(\.i18n) var i18n

    public init(avatarColor: String? = nil, avatarImage: RGBAImage? = nil, title: String, groupDescription: String = "",
                initiallyFocusDescription: Bool = false, initiallyEditingAvatar: Bool = false, requestState: RequestState = .inactive, userAvatarData: [AvatarData] = [],
                makeRequest: @escaping (Request) -> Void = { _ in }, onClose: @escaping () -> Void = {}) {
        self.avatarColor = avatarColor
        self.avatarImage = avatarImage
        self.title = title
        self.groupDescription = groupDescription
        self.initiallyFocusDescription = initiallyFocusDescription
        _editingAvatar = State(initialValue: initiallyEditingAvatar)
        self.requestState = requestState
        self.userAvatarData = userAvatarData
        self.makeRequest = makeRequest
        self.onClose = onClose
        _rawTitle = State(initialValue: title)
        _rawDescription = State(initialValue: groupDescription)
    }

    var trimmedTitle: String { rawTitle.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedDescription: String { rawDescription.trimmingCharacters(in: .whitespacesAndNewlines) }
    var hasTitleChanged: Bool { trimmedTitle != title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var hasDescriptionChanged: Bool { trimmedDescription != groupDescription.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isRequestActive: Bool { requestState == .active }
    var canSubmit: Bool { !isRequestActive && (hasTitleChanged || hasAvatarChanged || hasDescriptionChanged) && !trimmedTitle.isEmpty }

    func submit() {
        var r = Request()
        if hasAvatarChanged { r.avatar = .some(avatar) }
        if hasTitleChanged { r.title = trimmedTitle }
        if hasDescriptionChanged { r.description = trimmedDescription }
        makeRequest(r)
    }

    var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            AvatarPreview(avatarColor: avatarColor, avatarData: avatar, avatarImage: hasAvatarChanged ? nil : avatarImage, isGroup: true,
                          showUploadButton: true, size: 96, autoFocus: isRequestActive, onClick: { editingAvatar = true })
            GroupTitleInput(value: $rawTitle, disabled: isRequestActive, autoFocus: !isRequestActive && !initiallyFocusDescription).padding(.top, 16)
            GroupDescriptionInput(value: $rawDescription, disabled: isRequestActive, autoFocus: !isRequestActive && initiallyFocusDescription).padding(.top, 16)
            CSSText(i18n("icu:EditConversationAttributesModal__description-warning"), style: LegacyType.subtitle(), color: AxoColor(LegacyColor.gray45))
                .padding(.top, 16)
            if requestState == .inactiveWithError {
                CSSText(i18n("icu:updateGroupAttributes__error-message"), style: LegacyType.body1(), color: .labelPrimary)
                    .padding(.vertical, 16)
            }
        }
    }

    public var body: some View {
        AxoDialog.Content(size: .md) {
            AxoDialog.Header {
                AxoDialog.Title(i18n("icu:updateGroupAttributes__title"))
            }
            if editingAvatar {
                AvatarEditor(avatarColor: avatarColor, avatarImage: hasAvatarChanged ? nil : avatarImage, conversationTitle: nil, isGroup: true,
                             isInsideDialog: true, userAvatarData: userAvatarData, callbacks: {
                    var c = AvatarEditor.Callbacks()
                    c.onCancel = {
                        hasAvatarChanged = false
                        editingAvatar = false
                    }
                    c.onSave = { new in
                        avatar = new
                        hasAvatarChanged = true
                        editingAvatar = false
                    }
                    if let loadPhoto {
                        c.onPhotoPicked = { url in
                            Task { @MainActor in
                                guard let image = await loadPhoto(url) else { return }
                                avatar = AvatarData(id: url.path, image: image)
                                hasAvatarChanged = true
                                editingAvatar = false
                            }
                        }
                    }
                    return c
                }())
            } else {
                AxoDialog.Body { form }
                AxoDialog.Footer {
                    AxoDialog.Actions {
                        AxoDialog.Action(i18n("icu:cancel"), variant: .subtleSecondary, disabled: isRequestActive, action: onClose)
                        AxoDialog.Action(i18n("icu:save"), variant: .strongPrimary, pending: isRequestActive, disabled: !canSubmit, action: submit)
                    }
                }
            }
        }
    }
}

extension EditConversationAttributesModal {
    /// With photo upload: `load` decodes the picked file for the preview.
    public func photoLoader(_ load: @escaping (URL) async -> RGBAImage?) -> EditConversationAttributesModal {
        var c = self
        c.loadPhoto = load
        return c
    }
}
