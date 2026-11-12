// Port of ts/components/CompositionArea.dom.tsx (stylesheets/components/CompositionArea.scss):
// the bar below the timeline. In upstream's order it is one of:
//  - nothing (the Signal release-notes chat),
//  - the "group has ended" line,
//  - MessageRequestActions (blocked, pending, or not yet accepted),
//  - the SMS-only notice (or a spinner while the service id is being fetched),
//  - MandatoryProfileSharingActions, GroupV1DisabledActions, GroupV2PendingApprovalActions,
//  - AnnouncementsOnlyGroupBanner,
//  - the voice-note recorder or draft (render props, as upstream),
//  - the composer: the quote and the attachment rail above a row of the Fun picker button, the
//    media-quality selector, CompositionInput, the mic, edit-message buttons and the "+" menu.
//    Large mode moves the buttons to a control row under the input.
//
// Not ported: SelectModeActions (select mode), MediaEditor, the poll and share-contact dialogs,
// and the hidden file inputs. Their entry points are callbacks.

import SignalI18n
import SwiftUI

/// The props of `<CompositionArea>` that pick the branch and shape the composer.
public struct CompositionAreaModel {
    public enum ConversationType: Sendable { case direct, group }
    public var conversationId: String
    public var conversationType: ConversationType = .direct
    public var isSignalConversation = false
    public var terminated = false
    /// MessageRequestActions' fields; shown when blocked, pending or not accepted.
    public var messageRequest: MessageRequestModel
    public var acceptedMessageRequest = true
    public var isBlocked = false
    public var areWePending = false
    /// `removalStage === 'justNotification'`
    public var removalStageJustNotification = false
    public var isSmsOnlyOrUnregistered = false
    public var isFetchingUUID = false
    public var left = false
    public var groupVersion: Int?
    public var isMissingMandatoryProfileSharing = false
    public var isGroupV1AndDisabled = false
    public var areWePendingApproval = false
    public var announcementsOnly = false
    public var areWeAdmin = false
    public var groupAdmins: [GroupAdmin] = []
    public var isRecording = false
    /// A finished, uploaded voice note waiting to be sent (CompositionRecordingDraft).
    public var hasVoiceNoteDraft = false

    public var draftAttachments: [MessageAttachment] = []
    public var quote: QuoteModel?
    public var quotedMessageId: String?
    public var isViewOnce = false
    public var shouldSendHighQualityAttachments = false
    public var isEditingMessage = false
    public var canSend = true
    public var hasLinkPreview = false
    /// `linkPreviewLoading` / `linkPreviewResult`: the staged preview (no domain while loading).
    public var linkPreviewLoading = false
    public var linkPreviewResult: LinkPreview?
    /// The group members matching the "@query" being typed (MentionSuggestions).
    public var mentionSuggestions: [ComposerController.Mention] = []
    public var isDisabled = false
    public var isActive = true
    public var isPollSend1to1Enabled = true
    public var isShareContactEnabled = true
    /// Whether the app can send view-once media (the toggle on a lone photo or video).
    public var isViewOnceSendEnabled = true

    public init(conversationId: String, messageRequest: MessageRequestModel) {
        self.conversationId = conversationId
        self.messageRequest = messageRequest
    }

    /// `isViewOnceEligible`: exactly one image or video and no quote.
    var showViewOnceToggle: Bool {
        isViewOnceSendEnabled && draftAttachments.count == 1 && (draftAttachments[0].isImage || draftAttachments[0].isVideo) && quotedMessageId == nil && quote == nil
    }
    var isViewOnceActive: Bool { isViewOnce && showViewOnceToggle }
    var showMediaQualitySelector: Bool { draftAttachments.contains { $0.isImage } }
}

/// The callbacks of `<CompositionArea>`.
public struct CompositionAreaActions {
    public var onSubmit: () -> Void = {}
    public var onToggleViewOnce: () -> Void = {}
    public var setMediaQualitySetting: (Bool) -> Void = { _ in }
    public var onCloseQuote: () -> Void = {}
    public var onCloseLinkPreview: () -> Void = {}
    public var onPickMention: (ComposerController.Mention) -> Void = { _ in }
    /// ⌘V in the input: files or an image on the pasteboard become attachments (true: taken).
    public var onPaste: ((NSPasteboard) -> Bool)?
    public var onClickQuote: (() -> Void)?
    public var onAddAttachment: () -> Void = {}
    public var onClickAttachment: (Int) -> Void = { _ in }
    public var onCloseAttachment: (Int) -> Void = { _ in }
    public var onClearAttachments: () -> Void = {}
    public var launchMediaPicker: () -> Void = {}
    public var launchFilePicker: () -> Void = {}
    public var openPollModal: () -> Void = {}
    public var openShareContactDialog: () -> Void = {}
    public var startRecording: () -> Void = {}
    public var discardEditMessage: () -> Void = {}
    /// `maybeEditMessage` (↑ in an empty composer): returns whether editing started.
    public var onEditLastMessage: (() -> Bool)?
    public var showGV2MigrationDialog: () -> Void = {}
    public var cancelJoinRequest: () -> Void = {}
    public var showConversation: (String) -> Void = { _ in }
    public init() {}
}

public struct CompositionArea: View {
    @Binding var text: String
    let model: CompositionAreaModel
    let actions: CompositionAreaActions
    let funPicker: AnyView?
    let renderSmartCompositionRecording: (() -> AnyView)?
    let renderSmartCompositionRecordingDraft: (() -> AnyView)?
    @State private var large = false
    @State private var hovered = false
    @State private var funPickerOpen = false
    @Environment(\.i18n) var i18n

    public init(text: Binding<String>, model: CompositionAreaModel, actions: CompositionAreaActions = CompositionAreaActions(),
                funPicker: AnyView? = nil, renderSmartCompositionRecording: (() -> AnyView)? = nil,
                renderSmartCompositionRecordingDraft: (() -> AnyView)? = nil) {
        _text = text
        self.model = model
        self.actions = actions
        self.funPicker = funPicker
        self.renderSmartCompositionRecording = renderSmartCompositionRecording
        self.renderSmartCompositionRecordingDraft = renderSmartCompositionRecordingDraft
    }

    /// `dirty`: the input has text.
    var dirty: Bool { !text.isEmpty }

    /// `shouldShowMicrophone`: not large, not editing, and no draft (quotes are ignored).
    var shouldShowMicrophone: Bool { !large && !model.isEditingMessage && text.isEmpty && model.draftAttachments.isEmpty }

    public var body: some View {
        let m = model
        if m.isSignalConversation {
            EmptyView()
        } else if m.terminated {
            // border-t border-primary py-[16px] text-center type-body-small text-secondary
            CSSText(i18n("icu:CompositionArea--group-terminated"), type: AxoType.bodySmall, alignment: .center, color: .labelSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .overlay(alignment: .top) { Rectangle().fill(AxoColor.borderPrimary).frame(height: 1).offset(y: -1) }
                .padding(.top, 1)
        } else if m.isBlocked || m.areWePending || (!m.acceptedMessageRequest && !m.removalStageJustNotification) {
            MessageRequestActions(model: m.messageRequest)
        } else if m.conversationType == .direct && m.isSmsOnlyOrUnregistered {
            smsOnly
        } else if !m.left && (m.conversationType == .direct || (m.conversationType == .group && m.groupVersion == 1)) && m.isMissingMandatoryProfileSharing {
            MandatoryProfileSharingActions(model: m.messageRequest)
        } else if !m.left && m.isGroupV1AndDisabled {
            GroupV1DisabledActions(showGV2MigrationDialog: actions.showGV2MigrationDialog)
        } else if m.areWePendingApproval {
            GroupV2PendingApprovalActions(cancelJoinRequest: actions.cancelJoinRequest)
        } else if m.announcementsOnly && !m.areWeAdmin {
            AnnouncementsOnlyGroupBanner(groupAdmins: m.groupAdmins, showConversation: actions.showConversation)
        } else if m.isRecording, let renderSmartCompositionRecording {
            renderSmartCompositionRecording()
        } else if m.hasVoiceNoteDraft, let renderSmartCompositionRecordingDraft {
            renderSmartCompositionRecordingDraft()
        } else {
            composer
        }
    }

    /// `.CompositionArea--sms-only`: 14px / 18px padding, a 1px top border, centred.
    var smsOnly: some View {
        let color = AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray05)
        return VStack(spacing: 0) {
            if model.isFetchingUUID {
                Spinner(svgSize: .small, ariaLabel: i18n("icu:CompositionArea--sms-only__spinner-label"))
            } else {
                CSSText(i18n("icu:CompositionArea--sms-only__title"), style: LegacyType.body2(weight: 700), alignment: .center, color: color)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 2)
                CSSText(i18n("icu:CompositionArea--sms-only__body"), style: LegacyType.body2(), alignment: .center, color: color)
            }
        }
        .padding(.top, 14).padding(.bottom, 18).padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            Rectangle().fill(AxoColor(light: LegacyColor.gray05, dark: LegacyColor.gray75)).frame(height: 1).offset(y: -1)
        }
        .padding(.top, 1)
    }

    // MARK: the composer

    /// `.CompositionArea__button-cell`: 4px either side (12px at the row's ends), bottom-aligned.
    func cell<V: View>(first: Bool = false, last: Bool = false, @ViewBuilder _ content: () -> V) -> some View {
        content()
            .padding(.leading, first ? 12 : 4)
            .padding(.trailing, last ? 12 : 4)
    }

    /// The left-hand buttons: the Fun picker (hidden, still taking space, under view-once) and
    /// the media-quality selector when an image is staged.
    @ViewBuilder func leftHandSideButtons(first: Bool) -> some View {
        cell(first: first) {
            FunPickerButton(isOpen: $funPickerOpen, picker: funPicker)
        }
        .opacity(model.isViewOnceActive ? 0 : 1)
        .accessibilityHidden(model.isViewOnceActive)
        .allowsHitTesting(!model.isViewOnceActive)
        if model.showMediaQualitySelector {
            cell { MediaQualitySelector(isHighQuality: model.shouldSendHighQualityAttachments, onSelectQuality: actions.setMediaQualitySetting) }
        }
    }

    @ViewBuilder var micButton: some View {
        if shouldShowMicrophone {
            cell { AudioCapture(startRecording: actions.startRecording) }
        }
    }

    /// The discard / accept pair shown while editing a sent message.
    @ViewBuilder var editMessageButtons: some View {
        if model.isEditingMessage {
            if large { Spacer(minLength: 0).padding(.bottom, 6) }
            cell {
                HStack(spacing: 0) {
                    EditButton(icon: "v3/x/x", background: AxoColor(LegacyColor.gray45), label: i18n("icu:CompositionArea__edit-action--discard"),
                               action: actions.discardEditMessage)
                    EditButton(icon: "v3/check/check", background: AxoColor(LegacyColor.ultramarine), label: i18n("icu:CompositionArea__edit-action--send"),
                               disabled: !model.canSend, action: actions.onSubmit)
                        .padding(.leading, 16)
                }
            }
            .padding(.bottom, 4)
        }
    }

    /// The "+" menu: photos & videos, file, poll, contact. Hidden while editing, with a link
    /// preview, or recording.
    @ViewBuilder func addMenuButton(last: Bool) -> some View {
        if !(model.isEditingMessage || model.hasLinkPreview || model.isRecording) {
            cell(last: last) { ComposerAddMenu(model: model, actions: actions) }
        }
    }

    /// `handleForceSend`: the send button leaves the large editor and submits the input, as Enter does.
    func forceSend() {
        large = false
        actions.onSubmit()
    }

    @ViewBuilder var sendButton: some View {
        if !model.isEditingMessage {
            Spacer(minLength: 0)
            cell(last: true) {
                AxoIconButton.Root(label: i18n("icu:sendMessageToContact"), variant: .strongPrimary, size: .md, symbol: "send-fill",
                                   action: forceSend)
                    .frame(width: 32, height: 32)
            }
        }
    }

    /// The input's link preview (none while view-once is on).
    var stagedLinkPreview: AnyView? {
        guard !model.isViewOnceActive, model.linkPreviewLoading, let p = model.linkPreviewResult else { return nil }
        return AnyView(StagedLinkPreview(preview: p, image: p.image, isStickerPack: p.isStickerPack, placement: .compositionInput,
                                         onClose: actions.onCloseLinkPreview))
    }

    /// `handleEscape`: the link preview, else the quote, else the edit.
    var escapeAction: (() -> Bool)? {
        if model.linkPreviewResult != nil { return { actions.onCloseLinkPreview(); return true } }
        if model.quote != nil || model.quotedMessageId != nil { return { actions.onCloseQuote(); return true } }
        if model.isEditingMessage { return { actions.discardEditMessage(); return true } }
        return nil
    }

    var composer: some View {
        let m = model
        let viewOnce = m.isViewOnceActive
        return VStack(alignment: .leading, spacing: 0) {
            // CompositionArea__row--column
            VStack(alignment: .leading, spacing: 0) {
                if !viewOnce, let quote = m.quote {
                    Quote(quote, onClick: actions.onClickQuote, onClose: actions.onCloseQuote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !m.draftAttachments.isEmpty {
                    AttachmentList(attachments: m.draftAttachments, canEditImages: true, onAddAttachment: actions.launchFilePicker,
                                   onClickAttachment: actions.onClickAttachment, onCloseAttachment: actions.onCloseAttachment,
                                   onClose: actions.onClearAttachments)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !m.mentionSuggestions.isEmpty {
                MentionSuggestions(members: m.mentionSuggestions, onPick: actions.onPickMention)
                    .padding(.horizontal, 12)
            }
            HStack(alignment: .bottom, spacing: 0) {
                if !large { leftHandSideButtons(first: true) }
                CompositionInput(text: $text, large: large && !viewOnce, disabled: m.isDisabled, isActive: m.isActive,
                                 showViewOnceButton: m.showViewOnceToggle, isViewOnceActive: viewOnce,
                                 onToggleViewOnce: actions.onToggleViewOnce, onSubmit: actions.onSubmit)
                    .linkPreview(stagedLinkPreview)
                    .environment(\.composerKeys, ComposerKeys(
                        // `hasDraft` (text, attachments, a quote) keeps ↑ for the caret.
                        arrowUp: m.draftAttachments.isEmpty && m.quote == nil && !m.isEditingMessage ? actions.onEditLastMessage : nil,
                        escape: escapeAction, paste: actions.onPaste))
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)
                if viewOnce {
                    cell(last: true) {
                        AxoIconButton.Root(label: i18n("icu:sendMessageToContact"), variant: .strongPrimary, size: .md, symbol: "send-fill",
                                           action: forceSend)
                            .frame(width: 32, height: 32)
                    }
                }
                if !viewOnce && !large {
                    if !dirty { micButton }
                    editMessageButtons
                    addMenuButton(last: true)
                }
            }
            .padding(.horizontal, !viewOnce && large ? 12 : 0)
            if !viewOnce && large {
                // CompositionArea__row--control-row
                HStack(alignment: .bottom, spacing: 0) {
                    leftHandSideButtons(first: true)
                    addMenuButton(last: false)
                    if !dirty { micButton }
                    editMessageButtons
                    if dirty || !shouldShowMicrophone { sendButton }
                }
                .padding(.top, 12)
            }
        }
        .padding(.vertical, 10)
        .frame(minHeight: 42)
        .overlay(alignment: .top) { toggleLarge }
        .onHover { hovered = $0 }
    }

    /// `.CompositionArea__toggle-large`: a 48×24 tab centred 18px above the bar, shown on hover.
    @ViewBuilder var toggleLarge: some View {
        if !model.isViewOnceActive {
            SwiftUI.Button { large.toggle() } label: {
                SignalIcon(large ? "v3/chevron/chevron-shallow-down" : "v3/chevron/chevron-shallow-up", size: 24, color: AxoColor(LegacyColor.gray45))
                    .frame(width: 48, height: 24)
                    .background(AxoColor.surfacePrimary, in: UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(i18n("icu:CompositionArea--expand"))
            .opacity(hovered ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: hovered)
            .allowsHitTesting(hovered)
            .offset(y: -18)
        }
    }
}

/// `.CompositionArea__edit-button`: a 28px circle with a white 20px icon.
struct EditButton: View {
    let icon: String
    let background: AxoColor
    let label: String
    var disabled = false
    let action: () -> Void
    var body: some View {
        SwiftUI.Button(action: action) {
            SignalIcon(icon, size: 20, color: AxoColor(LegacyColor.white))
                .frame(width: 28, height: 28)
                .background(background, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .accessibilityLabel(label)
    }
}

/// The "+" AxoDropdownMenu of the composer.
struct ComposerAddMenu: View {
    let model: CompositionAreaModel
    let actions: CompositionAreaActions
    @State private var open = false
    @Environment(\.i18n) var i18n
    var body: some View {
        AxoDropdownMenu.Root(isOpen: $open) {
            AxoIconButton.Root(label: i18n("icu:CompositionArea--attach-plus"), tooltip: false, variant: .impliedSecondary, size: .md, symbol: "plus")
                .frame(width: 32, height: 32)
        } items: {
            AxoDropdownMenu.Item(i18n("icu:CompositionArea__AttachMenu__PhotosAndVideos"), symbol: "photo", action: actions.launchMediaPicker)
            AxoDropdownMenu.Item(i18n("icu:CompositionArea__AttachMenu__File"), symbol: "file", action: actions.launchFilePicker)
            if model.conversationType == .group || model.isPollSend1to1Enabled {
                AxoDropdownMenu.Item(i18n("icu:CompositionArea__AttachMenu__Poll"), symbol: "poll", action: actions.openPollModal)
            }
            if model.isShareContactEnabled {
                AxoDropdownMenu.Item(i18n("icu:CompositionArea__AttachMenu__Contact"), symbol: "person-circle", action: actions.openShareContactDialog)
            }
        }
    }
}

/// `FunPickerButton` (ts/components/fun/FunButton.dom.tsx): the smiley icon button that
/// opens the Fun picker above it (placement "top start").
public struct FunPickerButton: View {
    @Binding var isOpen: Bool
    let picker: AnyView?
    @State private var id = UUID().uuidString
    @Environment(\.i18n) var i18n

    public init(isOpen: Binding<Bool>, picker: AnyView? = nil) {
        _isOpen = isOpen
        self.picker = picker
    }

    public var body: some View {
        AxoIconButton.Root(label: i18n("icu:FunButton__Label--FunPicker"), tooltip: false, variant: .impliedSecondary, size: .md, symbol: "face-smiling") {
            isOpen.toggle()
        }
        .axoPopper(id: id, isPresented: isOpen && picker != nil,
                   placement: AxoPopper.Placement(side: .top, align: .start, sideOffset: 4, collisionPadding: 6), dismiss: { isOpen = false }) {
            // The picker closes itself after a pick (`\.axoMenuClose`).
            picker.environment(\.axoMenuClose, AxoMenuAction(run: { isOpen = false }))
        }
    }
}

/// `AudioCapture` (ts/components/conversation/AudioCapture.dom.tsx): the mic button.
public struct AudioCapture: View {
    let startRecording: () -> Void
    @Environment(\.i18n) var i18n
    public init(startRecording: @escaping () -> Void) { self.startRecording = startRecording }
    public var body: some View {
        AxoIconButton.Root(label: i18n("icu:voiceRecording--start"), tooltip: false, variant: .impliedSecondary, size: .md, symbol: "mic",
                           action: startRecording)
    }
}

/// `MediaQualitySelector` (ts/components/MediaQualitySelector.dom.tsx): the HD button and its
/// standard / high radio menu.
public struct MediaQualitySelector: View {
    let isHighQuality: Bool
    let onSelectQuality: (Bool) -> Void
    @State private var open = false
    @Environment(\.i18n) var i18n

    public init(isHighQuality: Bool, onSelectQuality: @escaping (Bool) -> Void) {
        self.isHighQuality = isHighQuality
        self.onSelectQuality = onSelectQuality
    }

    public var body: some View {
        let value = Binding<String?>(get: { isHighQuality ? "high" : "standard" }, set: { onSelectQuality($0 == "high") })
        AxoDropdownMenu.Root(isOpen: $open) {
            AxoIconButton.Root(label: i18n("icu:MediaQualitySelector--button"), tooltip: false, variant: .impliedSecondary, size: .md,
                               symbol: isHighQuality ? "hd" : "hd-slash")
        } items: {
            AxoDropdownMenu.RadioGroup(value: value) {
                AxoDropdownMenu.Label(i18n("icu:MediaQualitySelector--title"))
                AxoDropdownMenu.RadioItem(i18n("icu:MediaQualitySelector--standard-quality-title"), value: "standard", symbol: "hd-slash")
                AxoDropdownMenu.RadioItem(i18n("icu:MediaQualitySelector--high-quality-title"), value: "high", symbol: "hd")
            }
        }
    }
}

/// `AnnouncementsOnlyGroupBanner`: "Only admins can send messages" (font-subtitle, centred,
/// 16px padding, a gray-05 top border in both themes). "admins" opens
/// AnnouncementsOnlyGroupBannerAdminsDialog on the window's modal stack.
public struct AnnouncementsOnlyGroupBanner: View {
    let groupAdmins: [GroupAdmin]
    let showConversation: (String) -> Void
    @Environment(\.i18n) var i18n
    @Environment(\.axoModalStack) var modals
    public init(groupAdmins: [GroupAdmin], showConversation: @escaping (String) -> Void) {
        self.groupAdmins = groupAdmins
        self.showConversation = showConversation
    }

    func showAdmins() {
        guard let modals else { return }
        let id = "announcements-only-admins"
        modals.present(id: id) {
            AnnouncementsOnlyGroupBannerAdminsDialog(groupAdmins: groupAdmins, showConversation: { conversationId in
                modals.dismiss(id: id)
                showConversation(conversationId)
            }, onClose: { modals.dismiss(id: id) })
        }
    }

    public var body: some View {
        let admins = CSSTextRun(i18n("icu:AnnouncementsOnlyGroupBanner--admins"), color: AxoColor(LegacyColor.ultramarine), action: "admins")
        let runs = CSSTextRun.runs(i18n.richText("icu:AnnouncementsOnlyGroupBanner--announcements-only", ["admins": .element("admins")]),
                                   elements: ["admins": admins])
        CSSText(runs: runs, style: LegacyType.subtitle(), alignment: .center, color: AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray05),
                onTap: { _ in showAdmins() })
            .frame(maxWidth: .infinity)
            .padding(16)
            .overlay(alignment: .top) { Rectangle().fill(AxoColor(LegacyColor.gray05)).frame(height: 1).offset(y: -1) }
            .padding(.top, 1)
    }
}
