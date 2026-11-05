// Port of ts/components/conversation/conversation-details/ConversationDetailsActions.dom.tsx and
// ts/components/DeleteMessagesConfirmationDialog.dom.tsx: the destructive rows at the bottom of
// conversation details (leave, block / unblock, archive / unarchive and delete for an ended
// group, report spam) in one AxoList, "End group" in a second. Each row confirms on the
// window's modal stack.

import SignalI18n
import SwiftUI

public struct ConversationDetailsActions: View {
    public struct Callbacks {
        public var acceptConversation: () -> Void = {}
        public var blockConversation: () -> Void = {}
        public var onArchive: () -> Void = {}
        public var onUnarchive: () -> Void = {}
        public var onDelete: () -> Void = {}
        public var onLeave: () -> Void = {}
        public var onReportSpam: () -> Void = {}
        public var onReportSpamAndBlock: () -> Void = {}
        public var onTerminateGroup: () -> Void = {}
        public init() {}
    }

    let conversationId: String
    let conversationTitle: String
    let cannotLeaveBecauseYouAreLastAdmin: Bool
    let canTerminateGroup: Bool
    let isArchived: Bool
    let isBlocked: Bool
    let isGroup: Bool
    let isGroupTerminated: Bool
    let isSignalConversation: Bool
    let left: Bool
    let callbacks: Callbacks
    @Environment(\.i18n) var i18n
    @Environment(\.axoModalStack) var modals

    public init(conversationId: String, conversationTitle: String, cannotLeaveBecauseYouAreLastAdmin: Bool = false, canTerminateGroup: Bool = false,
                isArchived: Bool = false, isBlocked: Bool = false, isGroup: Bool, isGroupTerminated: Bool = false, isSignalConversation: Bool = false,
                left: Bool = false, callbacks: Callbacks = Callbacks()) {
        self.conversationId = conversationId
        self.conversationTitle = conversationTitle
        self.cannotLeaveBecauseYouAreLastAdmin = cannotLeaveBecauseYouAreLastAdmin
        self.canTerminateGroup = canTerminateGroup
        self.isArchived = isArchived
        self.isBlocked = isBlocked
        self.isGroup = isGroup
        self.isGroupTerminated = isGroupTerminated
        self.isSignalConversation = isSignalConversation
        self.left = left
        self.callbacks = callbacks
    }

    /// Presents an AxoConfirmDialog: Cancel, then the actions (label, variant, callback).
    func confirm(_ key: String, title: String?, description: String?, actions: [(String, AxoDialog.ActionVariant, () -> Void)]) {
        guard let modals else { return }
        let id = "conversation-details-\(conversationId)-\(key)"
        modals.present(id: id) {
            AxoConfirmDialog.Root(title: title, description: description) {
                AxoConfirmDialog.Cancel(i18n("icu:cancel")) { modals.dismiss(id: id) }
                ForEach(actions.indices, id: \.self) { i in
                    AxoConfirmDialog.Action(actions[i].0, variant: actions[i].1) {
                        modals.dismiss(id: id)
                        actions[i].2()
                    }
                }
            }
        }
    }

    var mustChooseNewAdmin: String? {
        cannotLeaveBecauseYouAreLastAdmin ? i18n("icu:ConversationDetailsActions--leave-group-must-choose-new-admin") : nil
    }

    @ViewBuilder var leaveRow: some View {
        if isGroup && !left && !isGroupTerminated {
            AxoClickableItem.Root(variant: .destructive, symbol: "leave", label: i18n("icu:ConversationDetailsActions--leave-group"),
                                  disabled: cannotLeaveBecauseYouAreLastAdmin, tooltip: mustChooseNewAdmin) {
                confirm("leave", title: i18n("icu:ConversationDetailsActions--leave-group-modal-title"),
                        description: i18n("icu:ConversationDetailsActions--leave-group-modal-content"),
                        actions: [(i18n("icu:ConversationDetailsActions--leave-group-modal-confirm"), .strongDestructive, callbacks.onLeave)])
            } accessory: { EmptyView() }
        }
    }

    @ViewBuilder var blockRow: some View {
        if isGroup && !isBlocked && !isGroupTerminated {
            AxoClickableItem.Root(variant: .destructive, symbol: "block", label: i18n("icu:ConversationDetailsActions--block-group"),
                                  disabled: cannotLeaveBecauseYouAreLastAdmin, tooltip: mustChooseNewAdmin) {
                confirm("block", title: i18n("icu:ConversationDetailsActions--block-group-modal-title", ["groupName": .string(conversationTitle)]),
                        description: i18n("icu:ConversationDetailsActions--block-group-modal-content"),
                        actions: [(i18n("icu:ConversationDetailsActions--block-group-modal-confirm"), .strongDestructive, callbacks.blockConversation)])
            } accessory: { EmptyView() }
        } else if isGroup && isBlocked && !isGroupTerminated {
            AxoClickableItem.Root(variant: .destructive, symbol: "block", label: i18n("icu:ConversationDetailsActions--unblock-group")) {
                confirm("unblock", title: i18n("icu:ConversationDetailsActions--unblock-group-modal-title", ["groupName": .string(conversationTitle)]),
                        description: i18n("icu:ConversationDetailsActions--unblock-group-modal-body"),
                        actions: [(i18n("icu:ConversationDetailsActions--unblock-group-modal-confirm"), .strongDestructive, callbacks.acceptConversation)])
            } accessory: { EmptyView() }
        } else if !isGroup {
            AxoClickableItem.Root(variant: .destructive, symbol: "block", label: i18n(isBlocked ? "icu:MessageRequests--unblock" : "icu:MessageRequests--block")) {
                if isBlocked {
                    confirm("unblock", title: i18n("icu:MessageRequests--unblock-direct-confirm-title", ["name": .string(conversationTitle)]),
                            description: i18n("icu:MessageRequests--unblock-direct-confirm-body"),
                            actions: [(i18n("icu:MessageRequests--unblock"), .strongPrimary, callbacks.acceptConversation)])
                } else {
                    confirm("block", title: i18n("icu:MessageRequests--block-direct-confirm-title", ["title": .string(conversationTitle)]),
                            description: i18n("icu:MessageRequests--block-direct-confirm-body"),
                            actions: [(i18n("icu:MessageRequests--block"), .strongDestructive, callbacks.blockConversation)])
                }
            } accessory: { EmptyView() }
        }
    }

    @ViewBuilder var archiveRow: some View {
        if isGroupTerminated {
            AxoClickableItem.Root(symbol: "archive", label: i18n(isArchived ? "icu:ConversationDetailsActions--unarchive" : "icu:ConversationDetailsActions--archive"),
                                  onClick: isArchived ? callbacks.onUnarchive : callbacks.onArchive) { EmptyView() }
        }
    }

    @ViewBuilder var deleteRow: some View {
        if isGroupTerminated {
            AxoClickableItem.Root(variant: .destructive, symbol: "trash", label: i18n("icu:ConversationDetailsActions--delete")) {
                guard let modals else { return }
                let id = "conversation-details-\(conversationId)-delete"
                modals.present(id: id) {
                    DeleteMessagesConfirmationDialog(areWeMember: !left && !isGroupTerminated, onDestroyMessages: {
                        modals.dismiss(id: id)
                        callbacks.onDelete()
                    }, onClose: { modals.dismiss(id: id) })
                }
            } accessory: { EmptyView() }
        }
    }

    @ViewBuilder var reportSpamRow: some View {
        if !isSignalConversation {
            AxoClickableItem.Root(variant: .destructive, symbol: "error-octagon", label: i18n("icu:ConversationDetailsActions--report-spam")) {
                var actions: [(String, AxoDialog.ActionVariant, () -> Void)] = [
                    (i18n("icu:ConversationDetailsActions--report-spam-modal-report-spam"), .strongDestructive, callbacks.onReportSpam),
                ]
                if !isBlocked {
                    actions.append((i18n("icu:ConversationDetailsActions--report-spam-modal-report-and-block"), .strongDestructive,
                                    callbacks.onReportSpamAndBlock))
                }
                confirm("report", title: i18n("icu:MessageRequests--ReportAndMaybeBlockModal-title"),
                        description: i18n(isGroup ? "icu:ConversationDetailsActions--report-spam-modal-content-group"
                                          : "icu:ConversationDetailsActions--report-spam-modal-content-direct"),
                        actions: actions)
            } accessory: { EmptyView() }
        }
    }

    /// Ending a group asks twice.
    func promptTerminateGroup() {
        confirm("terminate-prompt", title: i18n("icu:ConversationDetailsActions--prompt-terminate-group-modal-title", ["groupName": .string(conversationTitle)]),
                description: i18n("icu:ConversationDetailsActions--prompt-terminate-group-modal-content"),
                actions: [(i18n("icu:ConversationDetailsActions--terminate-group-modal-confirm"), .strongDestructive, {
                    confirm("terminate", title: nil, description: i18n("icu:ConversationDetailsActions--confirm-terminate-group-confirm-modal-content"),
                            actions: [(i18n("icu:ConversationDetailsActions--terminate-group-modal-confirm"), .strongDestructive, callbacks.onTerminateGroup)])
                })])
    }

    public var body: some View {
        VStack(spacing: 0) {
            ConversationDetailsList {
                leaveRow
                blockRow
                archiveRow
                deleteRow
                reportSpamRow
            }
            if canTerminateGroup {
                ConversationDetailsList {
                    AxoClickableItem.Root(variant: .destructive, symbol: "x-circle", label: i18n("icu:ConversationDetailsActions--terminate-group"),
                                          onClick: promptTerminateGroup) { EmptyView() }
                }
            }
        }
    }
}

/// The file-local `List`: an AxoList with an optional header label around an item group.
struct ConversationDetailsList<Content: View>: View {
    let label: String?
    let content: Content
    init(label: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }
    var body: some View {
        AxoList.Root {
            if let label { AxoList.Header { AxoList.Label(label) } }
            AxoList.Body { AxoItem.Group { content } }
        }
    }
}

/// `DeleteMessagesConfirmationDialog`: "Delete chat?" with the sync wording for members and
/// non-members.
public struct DeleteMessagesConfirmationDialog: View {
    let areWeMember: Bool
    let onDestroyMessages: () -> Void
    let onClose: () -> Void
    @Environment(\.i18n) var i18n
    public init(areWeMember: Bool, onDestroyMessages: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.areWeMember = areWeMember
        self.onDestroyMessages = onDestroyMessages
        self.onClose = onClose
    }
    public var body: some View {
        let body = i18n(areWeMember ? "icu:ConversationHeader__DeleteConversationConfirmation__description-with-sync--still-member"
                        : "icu:ConversationHeader__DeleteConversationConfirmation__description-with-sync")
        AxoConfirmDialog.Root(title: i18n("icu:ConversationHeader__DeleteConversationConfirmation__title"), description: body) {
            AxoConfirmDialog.Cancel(i18n("icu:cancel"), action: onClose)
            AxoConfirmDialog.Action(i18n("icu:delete"), variant: .strongDestructive, action: onDestroyMessages)
        }
    }
}
