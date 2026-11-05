// Port of ts/components/DeleteMessagesModal.dom.tsx: delete for me / for everyone (Note to
// Self: delete everywhere), and, for an admin deleting others' messages the first time, the
// admin-delete confirmation.

import SignalI18n
import SwiftUI

public struct DeleteMessagesModal: View {
    let isMe: Bool
    let canDeleteForEveryone: Bool
    let needsAdminDelete: Bool
    let isDeletingOwnMessages: Bool
    let hasSeenAdminDeleteEducationDialog: Bool
    let messageCount: Int
    let onClose: () -> Void
    let onDeleteForMe: () -> Void
    let onDeleteForEveryone: () -> Void
    let onSeenAdminDeleteEducationDialog: () -> Void
    /// `ToastType.TooManyMessagesToDeleteForEveryone` with the limit.
    let showTooManyMessagesToast: (Int) -> Void
    @State private var confirmingAdminDelete = false
    @Environment(\.i18n) var i18n

    static let maxDeleteForEveryone = 30

    public init(isMe: Bool = false, canDeleteForEveryone: Bool = false, needsAdminDelete: Bool = false, isDeletingOwnMessages: Bool = false,
                hasSeenAdminDeleteEducationDialog: Bool = false, messageCount: Int = 1, onClose: @escaping () -> Void = {},
                onDeleteForMe: @escaping () -> Void = {}, onDeleteForEveryone: @escaping () -> Void = {},
                onSeenAdminDeleteEducationDialog: @escaping () -> Void = {}, showTooManyMessagesToast: @escaping (Int) -> Void = { _ in }) {
        self.isMe = isMe
        self.canDeleteForEveryone = canDeleteForEveryone
        self.needsAdminDelete = needsAdminDelete
        self.isDeletingOwnMessages = isDeletingOwnMessages
        self.hasSeenAdminDeleteEducationDialog = hasSeenAdminDeleteEducationDialog
        self.messageCount = messageCount
        self.onClose = onClose
        self.onDeleteForMe = onDeleteForMe
        self.onDeleteForEveryone = onDeleteForEveryone
        self.onSeenAdminDeleteEducationDialog = onSeenAdminDeleteEducationDialog
        self.showTooManyMessagesToast = showTooManyMessagesToast
    }

    var count: [String: I18nArgument] { ["count": .number(Double(messageCount))] }

    func selectDeleteForEveryone() {
        if messageCount > Self.maxDeleteForEveryone { return showTooManyMessagesToast(Self.maxDeleteForEveryone) }
        if needsAdminDelete && !isDeletingOwnMessages && !hasSeenAdminDeleteEducationDialog {
            confirmingAdminDelete = true
            return
        }
        onDeleteForEveryone()
        onClose()
    }

    public var body: some View {
        if confirmingAdminDelete {
            // DeleteMessagesConfirmAdminDeleteDialog
            AxoAlertDialog.Content {
                AxoAlertDialog.Body {
                    AxoAlertDialog.Title(i18n("icu:DeleteMessagesModal--adminDeleteConfirmation--title"))
                    AxoAlertDialog.Description(i18n("icu:DeleteMessagesModal--adminDeleteConfirmation--description__rollout", count))
                }
                AxoAlertDialog.Footer {
                    AxoAlertDialog.Action(i18n("icu:cancel"), variant: .subtleSecondary) { confirmingAdminDelete = false }
                    AxoAlertDialog.Action(i18n("icu:DeleteMessagesModal--deleteForEveryone"), variant: .subtleDestructive) {
                        onSeenAdminDeleteEducationDialog()
                        onDeleteForEveryone()
                        onClose()
                    }
                }
            }
        } else {
            // DeleteMessagesSelectDeleteTypeDialog
            AxoAlertDialog.Content {
                AxoAlertDialog.Body {
                    AxoAlertDialog.Title(i18n("icu:DeleteMessagesModal--title-2", count))
                    AxoAlertDialog.Description(isMe ? i18n("icu:DeleteMessagesModal--description--noteToSelf--deleteSync", count)
                        : i18n("icu:DeleteMessagesModal--description", count))
                }
                AxoAlertDialog.Footer {
                    AxoAlertDialog.Cancel(i18n("icu:cancel"), action: onClose)
                    AxoAlertDialog.Action(i18n(isMe ? "icu:DeleteMessagesModal--noteToSelf--deleteSync" : "icu:DeleteMessagesModal--deleteForMe"),
                                          variant: .subtleDestructive) {
                        onDeleteForMe()
                        onClose()
                    }
                    if canDeleteForEveryone && !isMe {
                        AxoAlertDialog.Action(i18n("icu:DeleteMessagesModal--deleteForEveryone"), variant: .subtleDestructive, action: selectDeleteForEveryone)
                    }
                }
            }
        }
    }
}
