// Port of ts/components/ToastManager.dom.tsx: the toast for each ToastType (text, timeout,
// action), shown at the bottom of the window (`ToastManagerContainer`). Donation and backup
// toasts are omitted with those features.

import SignalI18n
import SwiftUI

/// `AnyToast`: a toast type with its parameters.
public enum ToastType: Sendable {
    case addingUserToGroup(contact: String)
    case addedUsersToCall(count: Int)
    case alreadyGroupMember, alreadyRequestedToJoin, attachmentDownloadFailed
    case attachmentDownloadStillInProgress(count: Int)
    case blocked, blockedGroup, callHistoryCleared
    case callQualitySurveyFailed(canRetry: Bool)
    case callQualitySurveySuccess, cannotEditMessage, cannotForwardEmptyMessage, cannotMixMultiAndNonMultiAttachments
    case captchaFailed, captchaSolved, cannotStartGroupCall
    case chatFolderAddedChat(chatFolderName: String), chatFolderRemovedChat(chatFolderName: String), chatFolderCreated(chatFolderName: String)
    case conversationArchived(conversationId: String, wasPinned: Bool)
    case conversationMarkedUnread
    case conversationRemoved(title: String)
    case conversationUnarchived, copiedCallLink, copiedStickerPackLink, copiedUsername, copiedUsernameLink
    case dangerousFileType, debugLogError, deleteForEveryoneFailed
    case error, expired, failedToDeleteUsername, failedToFetchPhoneNumber, failedToFetchUsername, invalidStorageServiceHeaders
    case fileSaved(fullPath: String, countOfFiles: Int)
    case fileSize(limit: Int, units: String), videoFileSize(limit: Int, units: String)
    case groupLinkCopied
    case decryptionError(name: String, deviceId: Int)
    case invalidConversation, leftGroup, linkCopied, loadingFullLogs, maxAttachments, mediaNoLongerAvailable, messageBodyTooLong, messageLoop
    case notificationProfileUpdate(name: String, enabled: Bool)
    case originalMessageNotFound, pinnedMessageNotFound, pollNotFound
    case internalHeapSizeWarning
    case pinnedConversationsFull(maxPinnedConversations: Int)
    case pinChangeCompleted, pinReminderCompleted, reactionFailed
    case receiptSaved(fullPath: String)
    case receiptSaveFailed
    case remoteConfigChanged(changes: [(name: String, from: String, to: String)])
    case reportedSpam, reportedSpamAndBlocked, stickerPackInstallFailed, sqlError
    case storyMuted, storyReact, storyReply, storyVideoError, storyVideoUnsupported
    case tapToViewExpiredIncoming, tapToViewExpiredOutgoing
    case tooManyMessagesToDeleteForEveryone(count: Int)
    case tooManyMessagesToForward, transportError, unableToLoadAttachment, unsupportedMultiAttachment
    case unsupportedOS
    case usernameRecovered(username: String)
    case userAddedToGroup(contact: String, group: String)
    case voiceNoteLimit, voiceNoteMustBeTheOnlyAttachment, whoCanFindMeReadOnly, viewOnceEnabled, viewOnceDisabled
}

/// The callbacks toasts' actions use.
public struct ToastManagerActions {
    public var hideToast: () -> Void = {}
    public var onShowDebugLog: () -> Void = {}
    public var onUndoArchive: (_ conversationId: String, _ wasPinned: Bool) -> Void = { _, _ in }
    public var openFileInFolder: (String) -> Void = { _ in }
    public var retryCallQualitySurvey: () -> Void = {}
    public var saveHeapSnapshot: () -> Void = {}
    public init() {}
}

public struct ToastManager: View {
    let toast: ToastType?
    let os: String
    let centerToast: Bool
    let actions: ToastManagerActions
    /// `renderMegaphone`: the megaphone below the toasts (`.ToastManager--megaphones`).
    var megaphone: AnyView?
    /// The container's width (`width: inherit`: the left pane's); nil shrinks to fit.
    var containerWidth: CGFloat?
    @Environment(\.i18n) var i18n

    static let shortTimeout: Duration = .seconds(3)
    static let defaultTimeout: Duration = .seconds(8)

    public init(toast: ToastType?, os: String = "macOS", centerToast: Bool = false, actions: ToastManagerActions = ToastManagerActions(),
                megaphone: AnyView? = nil, containerWidth: CGFloat? = nil) {
        self.megaphone = megaphone
        self.containerWidth = containerWidth
        self.toast = toast
        self.os = os
        self.centerToast = centerToast
        self.actions = actions
    }

    /// A plain-text toast.
    func text(_ key: String, _ args: [String: I18nArgument] = [:], timeout: Duration = defaultTimeout, autoDismissDisabled: Bool = false,
              action: (label: String, run: () -> Void)? = nil) -> AnyView {
        AnyView(Toast(i18n(key, args), autoDismissDisabled: autoDismissDisabled, timeout: timeout,
                      toastAction: action.map { a in Toast.Action(label: a.label, onClick: { a.run() }) }, onClose: actions.hideToast))
    }

    func rich(_ key: String, element name: String, _ value: String) -> AnyView {
        AnyView(Toast(onClose: actions.hideToast) {
            CSSText(runs: CSSTextRun.runs(i18n.richText(key, [name: .element(name)]), elements: [name: Emojify.run(value)]), style: LegacyType.body2())
        })
    }

    func submitLog() -> (label: String, run: () -> Void) { (i18n("icu:Toast__ActionLabel--SubmitLog"), actions.onShowDebugLog) }

    /// `renderToast`
    func render(_ toast: ToastType) -> AnyView {
        switch toast {
        case .addingUserToGroup(let contact):
            text("icu:AddUserToAnotherGroupModal__toast--adding-user-to-group", ["contact": .string(contact)], timeout: Self.shortTimeout)
        case .addedUsersToCall(let count):
            text("icu:CallingPendingParticipants__Toast--added-users-to-call", ["count": .number(Double(count))], timeout: Self.shortTimeout)
        case .alreadyGroupMember: text("icu:GroupV2--join--already-in-group")
        case .alreadyRequestedToJoin: text("icu:GroupV2--join--already-awaiting-approval")
        case .attachmentDownloadFailed: text("icu:Toast--download-failed")
        case .attachmentDownloadStillInProgress(let count): text("icu:attachmentStillDownloading", ["count": .number(Double(count))])
        case .blocked: text("icu:unblockToSend")
        case .blockedGroup: text("icu:unblockGroupToSend")
        case .callHistoryCleared: text("icu:CallsTab__ToastCallHistoryCleared")
        case .callQualitySurveyFailed(let canRetry):
            text("icu:CallQualitySurvey__SubmissionFailed",
                 action: canRetry ? (i18n("icu:CallQualitySurvey__SubmissionFailed__Retry"), actions.retryCallQualitySurvey) : nil)
        case .callQualitySurveySuccess: text("icu:CallQualitySurvey__SubmissionSuccess")
        case .cannotEditMessage: text("icu:ToastManager__CannotEditMessage_24")
        case .cannotForwardEmptyMessage: text("icu:ForwardMessagesModal__toast--CannotForwardEmptyMessage")
        case .cannotMixMultiAndNonMultiAttachments: text("icu:cannotSelectPhotosAndVideosAlongWithFiles")
        case .captchaFailed: text("icu:verificationFailed")
        case .captchaSolved: text("icu:verificationComplete")
        case .cannotStartGroupCall: text("icu:GroupV2--cannot-start-group-call")
        case .chatFolderAddedChat(let name): rich("icu:Toast--ChatFolderAddedChat", element: "chatFolderName", name)
        case .chatFolderRemovedChat(let name): rich("icu:Toast--ChatFolderRemovedChat", element: "chatFolderName", name)
        case .chatFolderCreated(let name): rich("icu:Toast--ChatFolderCreated", element: "chatFolderName", name)
        case .conversationArchived(let id, let wasPinned):
            text("icu:conversationArchived", action: (i18n("icu:conversationArchivedUndo"), { actions.onUndoArchive(id, wasPinned) }))
        case .conversationMarkedUnread: text("icu:conversationMarkedUnread")
        case .conversationRemoved(let title): text("icu:Toast--ConversationRemoved", ["title": .string(title)])
        case .conversationUnarchived: text("icu:conversationReturnedToInbox")
        case .copiedCallLink: text("icu:calling__call-link-copied", timeout: Self.shortTimeout)
        case .copiedStickerPackLink: text("icu:stickers--StickerPreview--LinkCopied", timeout: Self.shortTimeout)
        case .copiedUsername: text("icu:ProfileEditor--username--copied-username", timeout: Self.shortTimeout)
        case .copiedUsernameLink: text("icu:ProfileEditor--username--copied-username-link", timeout: Self.shortTimeout)
        case .dangerousFileType: text("icu:dangerousFileType")
        case .debugLogError: text("icu:debugLogError")
        case .deleteForEveryoneFailed: text("icu:deleteForEveryoneFailed")
        case .error: text("icu:Toast--error", autoDismissDisabled: true, action: (i18n("icu:Toast--error--action"), actions.onShowDebugLog))
        case .expired: text("icu:expiredWarning")
        case .failedToDeleteUsername: text("icu:ProfileEditor--username--delete-general-error")
        case .failedToFetchPhoneNumber: text("icu:Toast--failed-to-fetch-phone-number")
        case .failedToFetchUsername: text("icu:Toast--failed-to-fetch-username")
        case .invalidStorageServiceHeaders: text("icu:Toast--InvalidStorageServiceHeaders", action: submitLog())
        case .fileSaved(let path, let count):
            text("icu:attachmentSavedPlural", ["count": .number(Double(count))], action: (i18n("icu:attachmentSavedShow"), { actions.openFileInFolder(path) }))
        case .fileSize(let limit, let units): text("icu:fileTooLargeWarning", ["limit": .number(Double(limit)), "units": .string(units)])
        case .videoFileSize(let limit, let units): text("icu:videoFileTooLargeWarning", ["limit": .number(Double(limit)), "units": .string(units)])
        case .groupLinkCopied: text("icu:GroupLinkManagement--clipboard")
        case .decryptionError(let name, let deviceId):
            // style={{ maxWidth: '500px' }}
            AnyView(Toast(autoDismissDisabled: true, toastAction: Toast.Action(label: i18n("icu:Toast__ActionLabel--SubmitLog"), onClick: { actions.onShowDebugLog() }),
                          onClose: actions.hideToast) {
                CSSText(i18n("icu:decryptionErrorToast", ["name": .string(name), "deviceId": .string(String(deviceId))]), style: LegacyType.body2())
            }.environment(\.toastMaxWidth, 500))
        case .invalidConversation: text("icu:invalidConversation")
        case .leftGroup: text("icu:youLeftTheGroup")
        case .linkCopied: text("icu:debugLogLinkCopied")
        case .loadingFullLogs: text("icu:loading")
        case .maxAttachments: text("icu:maximumAttachments")
        case .mediaNoLongerAvailable: text("icu:mediaNotAvailable")
        case .messageBodyTooLong: text("icu:messageBodyTooLong")
        case .messageLoop: text("icu:messageLoop", action: submitLog())
        case .notificationProfileUpdate(let name, let enabled):
            AnyView(Toast(onClose: actions.hideToast) {
                HStack(spacing: 0) {
                    AxoSymbol.Icon(enabled ? "moon-fill" : "moon-slash-fill", size: 12,
                                   label: i18n(enabled ? "icu:NotificationProfilesToast--enabled--label" : "icu:NotificationProfilesToast--disabled--label"))
                    CSSText(i18n(enabled ? "icu:NotificationProfilesToast--enabled" : "icu:NotificationProfilesToast--disabled", ["name": .string(name)]),
                            style: LegacyType.body2())
                        .padding(.horizontal, 10)
                }
            })
        case .originalMessageNotFound: text("icu:originalMessageNotFound")
        case .pinnedMessageNotFound: text("icu:Toast--PinnedMessageNotFound")
        case .pollNotFound: text("icu:Toast--PollNotFound")
        case .internalHeapSizeWarning:
            AnyView(Toast("[INTERNAL] Detected high memory usage. Please save heap snapshot locally, and submit log.",
                          toastAction: Toast.Action(label: "Save Heap Snapshot", onClick: { actions.saveHeapSnapshot() }), onClose: actions.hideToast))
        case .pinnedConversationsFull(let max): text("icu:pinnedConversations--max", ["maxPinnedConversations": .number(Double(max))])
        case .pinChangeCompleted: text("icu:PinChangeCompletedToast")
        case .pinReminderCompleted: text("icu:PinReminderCompletedToast")
        case .reactionFailed: text("icu:Reactions--error")
        case .receiptSaved(let path): text("icu:Toast--ReceiptSaved", action: (i18n("icu:attachmentSavedShow"), { actions.openFileInFolder(path) }))
        case .receiptSaveFailed: text("icu:Toast--ReceiptSaveFailed")
        case .remoteConfigChanged(let changes):
            AnyView(Toast(autoDismissDisabled: true, onClose: actions.hideToast) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        AxoSymbol.InlineGlyph("error-triangle", size: 13, weight: 700).cssTextColor(.labelWarning)
                        CSSText("\u{00A0}Remote Config changed:", style: LegacyType.body2(weight: 700))
                    }
                    ForEach(Array(changes.enumerated()), id: \.offset) { _, c in
                        CSSText("\(c.name): \(c.from) → \(c.to)", style: .mono(size: 12, lineHeight: 16))
                    }
                }
            }.environment(\.toastMaxWidth, 650))
        case .reportedSpam: text("icu:MessageRequests--report-spam-success-toast")
        case .reportedSpamAndBlocked: text("icu:MessageRequests--block-and-report-spam-success-toast")
        case .stickerPackInstallFailed: text("icu:stickers--toast--InstallFailed")
        case .sqlError: text("icu:Toast--SQLError", autoDismissDisabled: true, action: submitLog())
        case .storyMuted: text("icu:Stories__toast--hasNoSound", timeout: Self.shortTimeout)
        case .storyReact: text("icu:Stories__toast--sending-reaction", timeout: Self.shortTimeout)
        case .storyReply: text("icu:Stories__toast--sending-reply", timeout: Self.shortTimeout)
        case .storyVideoError: text("icu:StoryCreator__error--video-error")
        case .storyVideoUnsupported: text("icu:StoryCreator__error--video-unsupported")
        case .tapToViewExpiredIncoming: text("icu:Message--tap-to-view--incoming--expired-toast")
        case .tapToViewExpiredOutgoing: text("icu:Message--tap-to-view--outgoing--expired-toast-2")
        case .tooManyMessagesToDeleteForEveryone(let count):
            text("icu:DeleteMessagesModal__toast--TooManyMessagesToDeleteForEveryone", ["count": .number(Double(count))])
        case .tooManyMessagesToForward: text("icu:SelectModeActions__toast--TooManyMessagesToForward")
        case .transportError: text("icu:TransportError")
        case .unableToLoadAttachment: text("icu:unableToLoadAttachment")
        case .unsupportedMultiAttachment: text("icu:cannotSelectMultipleFileAttachments")
        case .unsupportedOS: text("icu:UnsupportedOSErrorToast", ["OS": .string(os)])
        case .usernameRecovered(let username): text("icu:EditUsernameModalBody__username-recovered__text", ["username": .string(username)])
        case .userAddedToGroup(let contact, let group):
            text("icu:AddUserToAnotherGroupModal__toast--user-added-to-group", ["contact": .string(contact), "group": .string(group)])
        case .voiceNoteLimit: text("icu:voiceNoteLimit")
        case .voiceNoteMustBeTheOnlyAttachment: text("icu:voiceNoteMustBeOnlyAttachment")
        case .whoCanFindMeReadOnly: text("icu:WhoCanFindMeReadOnlyToast")
        case .viewOnceEnabled: text("icu:Toast--viewOnceEnabled", timeout: Self.shortTimeout)
        case .viewOnceDisabled: text("icu:Toast--viewOnceDisabled", timeout: Self.shortTimeout)
        }
    }

    /// `ToastManagerContainer` / `.ToastManager`: at the bottom (inset 16px), start or centre.
    /// `.ToastManagerContainer` (fixed at the bottom): the toasts (`.ToastManager`, margin 16)
    /// over the megaphone (margin 12; the 16px between them is the collapsed margins).
    public var body: some View {
        if megaphone == nil || centerToast {
            if let toast {
                render(toast)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: centerToast ? .bottom : .bottomLeading)
            }
        }
        if let megaphone {
            VStack(alignment: .leading, spacing: 0) {
                if let toast, !centerToast { render(toast).padding(16) }
                megaphone.padding(.horizontal, 12).padding(.bottom, 12).padding(.top, toast == nil || centerToast ? 16 : 0)
                    .fixedSize(horizontal: containerWidth == nil, vertical: false)
                    .frame(width: containerWidth, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }
}

extension EnvironmentValues {
    /// A toast's `max-width` (280px unless a type widens it).
    @Entry var toastMaxWidth: CGFloat = 280
}
