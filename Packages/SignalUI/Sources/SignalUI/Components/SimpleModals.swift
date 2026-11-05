// Ports of ts/components/ProgressModal.dom.tsx, ConfirmDiscardDialog.dom.tsx and
// DebugLogErrorModal.dom.tsx: small modal dialogs (present inside AxoBaseDialog.Host).

import SignalI18n
import SwiftUI

/// `ProgressModal`: a brand spinner over the description; it cannot be dismissed.
public struct ProgressModal: View {
    let description: String?
    @Environment(\.i18n) var i18n
    public init(description: String? = nil) { self.description = description }
    public var body: some View {
        // Nothing in it is focusable, so the panel itself has the focus (and its ring).
        AxoDialog.Content(size: .sm, hasHeader: false, hasFooter: false, focused: true) {
            AxoDialog.Body {
                VStack(spacing: 0) {
                    SpinnerV2(variant: .brand, size: 58, strokeWidth: 4).padding(.bottom, 10)
                    // <AxoDialog.Title> in a text-center div (h2 mb-2.5).
                    CSSText(description ?? i18n("icu:updating"), type: AxoType.bodyMedium.weight(600), alignment: .center, color: .labelPrimary)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.bottom, 10)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .interactiveDismissDisabled()
    }
}

/// `ConfirmDiscardDialog` (deprecated upstream, still used).
public struct ConfirmDiscardDialog: View {
    let title: String?
    let description: String?
    let cancelLabel: String?
    let discardLabel: String?
    let onClose: () -> Void
    let onDiscard: () -> Void
    @Environment(\.i18n) var i18n
    public init(title: String? = nil, description: String? = nil, cancelLabel: String? = nil, discardLabel: String? = nil,
                onClose: @escaping () -> Void = {}, onDiscard: @escaping () -> Void = {}) {
        self.title = title
        self.description = description
        self.cancelLabel = cancelLabel
        self.discardLabel = discardLabel
        self.onClose = onClose
        self.onDiscard = onDiscard
    }
    public var body: some View {
        AxoConfirmDialog.Root(title: title, description: description ?? i18n("icu:ConfirmDiscardDialog--discard")) {
            AxoConfirmDialog.Cancel(cancelLabel ?? i18n("icu:cancel"), action: onClose)
            AxoConfirmDialog.Action(discardLabel ?? i18n("icu:discard"), variant: .strongDestructive, action: onDiscard)
        }
    }
}

/// `DebugLogErrorModal`: the submit action takes the focus.
public struct DebugLogErrorModal: View {
    let description: String?
    let onClose: () -> Void
    let onSubmitDebugLog: () -> Void
    @Environment(\.i18n) var i18n
    public init(description: String? = nil, onClose: @escaping () -> Void = {}, onSubmitDebugLog: @escaping () -> Void = {}) {
        self.description = description
        self.onClose = onClose
        self.onSubmitDebugLog = onSubmitDebugLog
    }
    public var body: some View {
        let text = description.flatMap { $0.isEmpty ? nil : $0 } ?? i18n("icu:ErrorModal--description")
        AxoConfirmDialog.Root(title: i18n("icu:DebugLogErrorModal__UnexpectedError"), description: text) {
            AxoConfirmDialog.Cancel(i18n("icu:DebugLogErrorModal__SubmitDebugLog__Cancel"), autoFocus: false, action: onClose)
            AxoConfirmDialog.Action(i18n("icu:DebugLogErrorModal__SubmitDebugLog"), variant: .strongPrimary, autoFocus: true, action: onSubmitDebugLog)
        }
    }
}
