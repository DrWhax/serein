// Port of ts/components/ForwardMessagesModal.dom.tsx (stylesheets/components/
// ForwardMessageModal.scss): choose up to five conversations to forward to (search, a checkbox
// list, the chosen names in the footer), then, for a single editable draft, edit it before
// sending. Announcement-only groups where we are not an admin cannot be chosen.

import SignalI18n
import SwiftUI

/// `MessageForwardDraft` (the parts the modal needs).
public struct MessageForwardDraft: Sendable {
    public var messageBody: String
    public var isSticker = false
    public var hasContact = false
    public var hasVoiceMessage = false
    /// Attachments, and whether all are downloaded.
    public var attachmentCount = 0
    public var attachmentsDownloaded = true
    public init(messageBody: String = "", isSticker: Bool = false, hasContact: Bool = false, hasVoiceMessage: Bool = false, attachmentCount: Int = 0,
                attachmentsDownloaded: Bool = true) {
        self.messageBody = messageBody
        self.isSticker = isSticker
        self.hasContact = hasContact
        self.hasVoiceMessage = hasVoiceMessage
        self.attachmentCount = attachmentCount
        self.attachmentsDownloaded = attachmentsDownloaded
    }

    /// `isDraftEditable`
    public var isEditable: Bool { !isSticker && !hasContact && !hasVoiceMessage }
    /// `isDraftEmpty` / `isDraftForwardable`
    public var isForwardable: Bool {
        let empty = !isSticker && !hasContact && attachmentCount == 0 && messageBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !empty && (attachmentCount == 0 || attachmentsDownloaded)
    }
}

public enum ForwardMessagesModalType: Sendable { case forward, forwardAttachment, shareCallLink }

public struct ForwardMessagesModal: View {
    let type: ForwardMessagesModalType
    let drafts: [MessageForwardDraft]
    let candidateConversations: [SearchableConversation]
    let regionCode: String?
    let doForwardMessages: ([String], [MessageForwardDraft]) -> Void
    let onChange: ([MessageForwardDraft]) -> Void
    let onClose: () -> Void
    /// `ToastType.CannotForwardEmptyMessage`
    let showCannotForwardEmptyToast: () -> Void
    @State private var selected: [SearchableConversation] = []
    @State private var searchTerm = ""
    @State private var filtered: [SearchableConversation]
    @State private var isEditingMessage = false
    @State private var cannotMessage = false
    @State private var editedBody: String
    @Environment(\.i18n) var i18n

    static let maxForward = 5

    public init(type: ForwardMessagesModalType = .forward, drafts: [MessageForwardDraft], candidateConversations: [SearchableConversation],
                regionCode: String? = "US", doForwardMessages: @escaping ([String], [MessageForwardDraft]) -> Void = { _, _ in },
                onChange: @escaping ([MessageForwardDraft]) -> Void = { _ in }, onClose: @escaping () -> Void = {},
                showCannotForwardEmptyToast: @escaping () -> Void = {}) {
        self.type = type
        self.drafts = drafts
        self.candidateConversations = candidateConversations
        self.regionCode = regionCode
        self.doForwardMessages = doForwardMessages
        self.onChange = onChange
        self.onClose = onClose
        self.showCannotForwardEmptyToast = showCannotForwardEmptyToast
        _filtered = State(initialValue: ConversationSearch.filterAndSort(candidateConversations, searchTerm: "", regionCode: regionCode))
        _editedBody = State(initialValue: drafts.count == 1 ? drafts[0].messageBody : "")
    }

    var lonelyDraft: MessageForwardDraft? { drafts.count == 1 ? drafts[0] : nil }
    var currentDrafts: [MessageForwardDraft] {
        guard var draft = lonelyDraft else { return drafts }
        draft.messageBody = editedBody
        return [draft]
    }
    var canForward: Bool { !selected.isEmpty && currentDrafts.allSatisfy(\.isForwardable) }

    func forward() {
        guard canForward else { return showCannotForwardEmptyToast() }
        doForwardMessages(selected.map(\.id), currentDrafts)
    }

    func toggle(_ id: String) {
        if let i = selected.firstIndex(where: { $0.id == id }) {
            selected.remove(at: i)
            return
        }
        guard let contact = candidateConversations.first(where: { $0.id == id }) else { return }
        if contact.announcementsOnly && !contact.areWeAdmin {
            cannotMessage = true
        } else {
            selected.append(contact)
        }
    }

    var title: String {
        switch type {
        case .forward, .forwardAttachment: i18n("icu:ForwardMessageModal__title")
        case .shareCallLink: i18n("icu:ForwardMessageModal__ShareCallLink")
        }
    }

    public var body: some View {
        ModalHost(onClose: onClose) {
            ModalPage(modalName: "ForwardMessageModal", strings: ModalStrings(back: i18n("icu:back"), close: i18n("icu:close")), title: title,
                      hasXButton: true, padded: false, onBackButtonClick: isEditingMessage ? { isEditingMessage = false } : nil, onClose: onClose) {
                if isEditingMessage, lonelyDraft != nil {
                    // ForwardMessageEditor (staged link preview / attachments are shown by the caller's draft UI).
                    CompositionTextArea(text: $editedBody, isActive: true, onSubmit: forward)
                        .onChange(of: editedBody) { _, _ in onChange(currentDrafts) }
                        .frame(minHeight: 300, alignment: .top)
                } else {
                    mainBody
                }
            } footer: {
                footer
            }
            .contentTakesFocus(!isEditingMessage)
            .frame(width: 342)    // width: 95% of the 360px container
        }
        .viewportPortal {
            if cannotMessage {
                AxoBaseDialog.Host {
                    AxoConfirmDialog.Root(title: nil, description: i18n("icu:GroupV2--cannot-send")) {
                        AxoConfirmDialog.Ok(i18n("icu:Confirmation--confirm")) { cannotMessage = false }
                    }
                }
            }
        }
        .task(id: searchTerm) {
            // Filtering is debounced by 200ms, as upstream.
            try? await Task.sleep(for: .milliseconds(searchTerm.isEmpty ? 0 : 200))
            guard !Task.isCancelled else { return }
            filtered = ConversationSearch.filterAndSort(candidateConversations, searchTerm: searchTerm.trimmingCharacters(in: .whitespaces),
                                                        regionCode: regionCode)
        }
    }

    /// `__main-body`: min-height 300, the search input over the list. The virtualised list
    /// sizes itself from its wrapper, so the body stays at that height.
    var mainBody: some View {
        VStack(spacing: 0) {
            SearchInput(value: $searchTerm, placeholder: i18n("icu:contactSearchPlaceholder"), disabled: candidateConversations.isEmpty,
                        focusesOnAppear: true) { EmptyView() }
            if candidateConversations.isEmpty {
                CSSText(i18n("icu:noContactsFound"), style: LegacyType.body1(), color: .labelPrimary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .frame(height: 300)
    }

    /// The virtualised conversation list: 52px ContactCheckbox rows, scrolling in the wrapper.
    var list: some View {
        AxoDialog.AxoScrollContainer {
            VStack(spacing: 0) {
                ForEach(filtered, id: \.id) { contact in
                    let isSelected = selected.contains { $0.id == contact.id }
                    let reason: ContactCheckboxDisabledReason? = selected.count >= Self.maxForward && !isSelected ? .maximumContactsSelected : nil
                    ContactCheckbox(contact.listItem, isChecked: isSelected, disabledReason: reason) { id, reason in
                        if reason != .maximumContactsSelected { toggle(id) }
                    }
                    .frame(height: 52, alignment: .top)
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
    }

    /// `__footer`: the chosen conversations' titles, then next (or send).
    var footer: some View {
        HStack(spacing: 0) {
            CSSText(runs: selected.enumerated().flatMap { i, c in [Emojify.run(c.title)] + (i < selected.count - 1 ? [CSSTextRun(", ")] : []) },
                    style: LegacyType.body2())
                .frame(maxWidth: .infinity, alignment: .leading)
            if isEditingMessage || !(lonelyDraft?.isEditable ?? false) {
                AxoIconButton.Root(label: i18n("icu:ForwardMessageModal--continue"), variant: .strongPrimary, size: .md, symbol: "send-fill",
                                   disabled: !canForward, action: forward)
            } else {
                AxoIconButton.Root(label: i18n("icu:forwardMessage"), variant: .strongPrimary, size: .md, symbol: "arrow-[end]",
                                   disabled: selected.isEmpty) { isEditingMessage = true }
            }
        }
        .frame(maxWidth: .infinity)
    }
}
