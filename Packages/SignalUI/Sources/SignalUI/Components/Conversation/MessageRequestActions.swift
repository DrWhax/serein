// MessageRequestActions (ts/components/conversation/MessageRequestActions.dom.tsx): below the
// timeline of an unaccepted chat — "Review requests carefully" (safety colour), the request
// text, then Block / Delete / Report… / Unblock / Accept as an AxoButton group. Each opens its
// MessageRequestActionsConfirmation dialog (Accept goes straight through for a direct chat
// that shares more than one group), presented on the window's modal stack.

import SignalI18n
import SwiftUI

/// `MessageRequestState`
public enum MessageRequestState: Sendable, Hashable {
    case `default`, accepting, blocking, deleting, reportingAndMaybeBlocking, unblocking, acceptedOptions
}

/// The fields and callbacks the request actions and their confirmations share.
public struct MessageRequestModel {
    public enum Kind: Sendable { case direct, group }
    public var conversationId: String
    public var conversationType: Kind
    /// `ContactName … preferFirstName` of the conversation / of who added us (groups).
    public var conversationName: String
    public var addedByName: String?
    public var isSignalConversation = false
    public var isBlocked = false
    public var isHidden = false
    public var isReported = false
    public var sharedGroupCount = 0
    public var acceptConversation: () -> Void = {}
    public var blockAndReportSpam: () -> Void = {}
    public var blockConversation: () -> Void = {}
    public var reportSpam: () -> Void = {}
    public var deleteConversation: () -> Void = {}

    public init(conversationId: String, conversationType: Kind, conversationName: String, addedByName: String? = nil) {
        self.conversationId = conversationId
        self.conversationType = conversationType
        self.conversationName = conversationName
        self.addedByName = addedByName
    }
}

public struct MessageRequestActions: View {
    let model: MessageRequestModel
    @Environment(\.i18n) var i18n
    @Environment(\.axoModalStack) var modals

    public init(model: MessageRequestModel) { self.model = model }

    var message: [CSSTextRun] {
        var name = CSSTextRun(model.conversationName, fontName: AxoFonts.interName(weight: 600))   // <strong class="font-semibold">
        name.emojify = true
        switch model.conversationType {
        case .direct:
            let key = model.isBlocked ? "icu:MessageRequests--message-direct-blocked"
                : model.isHidden ? "icu:MessageRequests--message-direct-hidden" : "icu:MessageRequests--message-direct"
            return CSSTextRun.runs(i18n.richText(key, ["name": .element("name")]), elements: ["name": name])
        case .group:
            return CSSTextRun.runs(i18n.richText(model.isBlocked ? "icu:MessageRequests--message-group-blocked" : "icu:MessageRequests--message-group"))
        }
    }

    func open(_ state: MessageRequestState) {
        let id = "message-request-\(model.conversationId)"
        guard let modals else { return }
        modals.present(id: id) {
            MessageRequestActionsConfirmation(model: model, state: state) { next in
                if next == .default { modals.dismiss(id: id) } else { open(next) }
            }
        }
    }

    public var body: some View {
        let style = CSSTextStyle(AxoType.bodyMedium)
        VStack(spacing: 0) {
            AxoInlineFlowText(pieces: [.glyph(AxoSymbol.inlineGlyph("error-triangle", rtl: false)), .text("\u{00A0}" + i18n("icu:MessageRequestWarning__review-carefully"))],
                              style: style, alignment: .center, maxLines: nil) { _ in }
                .cssTextColor(.labelSafety)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
            CSSText(runs: message, style: style, alignment: .center, color: .labelSecondary)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)
            // AxoButton.Group: the wrap detector's p-1.
            AxoButton.Group {
                Group {
                    if !model.isBlocked {
                        AxoButton.Root(i18n("icu:MessageRequests--block"), variant: .subtleDestructive, size: .md) { open(.blocking) }
                    }
                    if model.isReported || model.isBlocked {
                        AxoButton.Root(i18n("icu:MessageRequests--delete"), variant: .subtleDestructive, size: .md) { open(.deleting) }
                    }
                    if !model.isReported {
                        AxoButton.Root(i18n("icu:MessageRequests--reportAndMaybeBlock"), variant: .subtleDestructive, size: .md) {
                            open(.reportingAndMaybeBlocking)
                        }
                    }
                    if model.isBlocked {
                        AxoButton.Root(i18n("icu:MessageRequests--unblock"), variant: .subtleSecondary, size: .md) { open(.unblocking) }
                    } else {
                        AxoButton.Root(i18n("icu:MessageRequests--accept"), variant: .subtleSecondary, size: .md) {
                            if model.conversationType == .direct && model.sharedGroupCount > 1 { model.acceptConversation() } else { open(.accepting) }
                        }
                    }
                }
                .environment(\.axoButtonMinWidthFit, true)
            }
            .padding(4)
        }
        .padding(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
    }
}

/// MessageRequestActionsConfirmation (ts/components/conversation/MessageRequestActionsConfirmation.dom.tsx):
/// the confirm dialog for `state` (nothing for `.default`).
public struct MessageRequestActionsConfirmation: View {
    let model: MessageRequestModel
    let state: MessageRequestState
    let onChangeState: (MessageRequestState) -> Void
    @Environment(\.i18n) var i18n

    public init(model: MessageRequestModel, state: MessageRequestState, onChangeState: @escaping (MessageRequestState) -> Void) {
        self.model = model
        self.state = state
        self.onChangeState = onChangeState
    }

    func title(_ key: String, _ arg: String, _ name: String) -> String {
        i18n.richText(key, [arg: .element(arg)]).plain([arg: name])
    }

    var cancel: some View { AxoConfirmDialog.Cancel(i18n("icu:cancel")) { onChangeState(.default) } }

    func then(_ action: @escaping () -> Void) -> () -> Void {
        { onChangeState(.default); action() }
    }

    public var body: some View {
        let direct = model.conversationType == .direct
        let name = model.conversationName
        switch state {
        case .default:
            EmptyView()
        case .blocking:
            AxoConfirmDialog.Root(title: title(direct ? "icu:MessageRequests--block-direct-confirm-title" : "icu:MessageRequests--block-group-confirm-title",
                                               "title", name),
                                  description: i18n(direct ? (model.isSignalConversation ? "icu:MessageRequests--block-signal-confirm-body"
                                                              : "icu:MessageRequests--block-direct-confirm-body") : "icu:MessageRequests--block-group-confirm-body")) {
                cancel
                AxoConfirmDialog.Action(i18n("icu:MessageRequests--block"), variant: .strongDestructive, action: then(model.blockConversation))
            }
        case .reportingAndMaybeBlocking:
            let body: String = direct ? i18n("icu:MessageRequests--ReportAndMaybeBlockModal-body--direct")
                : model.addedByName.map { title("icu:MessageRequests--ReportAndMaybeBlockModal-body--group", "name", $0) }
                    ?? i18n("icu:MessageRequests--ReportAndMaybeBlockModal-body--group--unknown-contact")
            AxoConfirmDialog.Root(title: i18n("icu:MessageRequests--ReportAndMaybeBlockModal-title"), description: body) {
                cancel
                if !model.isBlocked {
                    AxoConfirmDialog.Action(i18n("icu:MessageRequests--ReportAndMaybeBlockModal-reportAndBlock"), variant: .strongDestructive,
                                            action: then(model.blockAndReportSpam))
                }
                AxoConfirmDialog.Action(i18n("icu:MessageRequests--ReportAndMaybeBlockModal-report"), variant: .strongDestructive, action: then(model.reportSpam))
            }
        case .unblocking:
            AxoConfirmDialog.Root(title: title("icu:MessageRequests--unblock-direct-confirm-title", "name", name),
                                  description: i18n(!direct ? "icu:MessageRequests--unblock-group-confirm-body"
                                                    : model.isSignalConversation ? "icu:MessageRequests--unblock-signal-confirm-body"
                                                    : "icu:MessageRequests--unblock-direct-confirm-body")) {
                cancel
                AxoConfirmDialog.Action(i18n("icu:MessageRequests--unblock"), variant: .strongPrimary, action: then(model.acceptConversation))
            }
        case .deleting:
            AxoConfirmDialog.Root(title: direct ? i18n("icu:MessageRequests--delete-direct-confirm-title")
                                    : title("icu:MessageRequests--delete-group-confirm-title", "title", name),
                                  description: i18n(direct ? "icu:MessageRequests--delete-direct-confirm-body" : "icu:MessageRequests--delete-group-confirm-body")) {
                cancel
                AxoConfirmDialog.Action(i18n(direct ? "icu:MessageRequests--delete-direct" : "icu:MessageRequests--delete-group"), variant: .strongDestructive,
                                        action: then(model.deleteConversation))
            }
        case .acceptedOptions:
            AxoConfirmDialog.Root(title: nil, description: title("icu:MessageRequests--AcceptedOptionsModal--body", "name", name)) {
                cancel
                AxoConfirmDialog.Action(i18n("icu:MessageRequests--reportAndMaybeBlock"), variant: .strongDestructive) { onChangeState(.reportingAndMaybeBlocking) }
                AxoConfirmDialog.Action(i18n("icu:MessageRequests--block"), variant: .strongDestructive) { onChangeState(.blocking) }
            }
        case .accepting:
            AxoConfirmDialog.Root(title: i18n("icu:MessageRequests--accept-confirm-title-v2")) {
                CSSText(runs: CSSTextRun.runs(i18n.richText("icu:MessageRequests--accept-confirm-body-v2"), tags: ["bold": .bold]),
                        style: CSSTextStyle(AxoType.bodyMedium))
            } actions: {
                cancel
                AxoConfirmDialog.Action(i18n("icu:MessageRequests--accept"), variant: .strongPrimary, action: then(model.acceptConversation))
            }
        }
    }
}
