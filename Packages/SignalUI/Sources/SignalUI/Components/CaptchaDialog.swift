// CaptchaDialog (ts/components/CaptchaDialog.dom.tsx) and CrashReportDialog
// (ts/components/CrashReportDialog.dom.tsx): the left pane's verification and crash-report
// alert dialogs (present inside AxoBaseDialog.Host).

import SignalI18n
import SwiftUI

public struct CaptchaDialog: View {
    let pending: Bool
    let onContinue: () -> Void
    let onSkip: () -> Void
    @Environment(\.i18n) var i18n
    @State private var closing = false

    public init(pending: Bool = false, onContinue: @escaping () -> Void = {}, onSkip: @escaping () -> Void = {}) {
        self.pending = pending
        self.onContinue = onContinue
        self.onSkip = onSkip
    }

    public var body: some View {
        if closing {
            AxoConfirmDialog.Root(title: i18n("icu:CaptchaDialog--can-close__title"), description: i18n("icu:CaptchaDialog--can-close__body")) {
                AxoConfirmDialog.Cancel { closing = false }
                AxoConfirmDialog.Action(i18n("icu:CaptchaDialog--can_close__skip-verification"), variant: .strongDestructive, action: onSkip)
            }
        } else {
            AxoConfirmDialog.Root(title: i18n("icu:CaptchaDialog__title")) {
                // One Description with two paragraphs (<p mb-2>, <p>).
                VStack(alignment: .leading, spacing: 8) {
                    AxoAlertDialog.Description(i18n("icu:CaptchaDialog__first-paragraph"))
                    AxoAlertDialog.Description(i18n("icu:CaptchaDialog__second-paragraph"))
                }
            } actions: {
                AxoConfirmDialog.Cancel(i18n("icu:CaptchaDialog--can_close__skip-verification"), autoFocus: false) { closing = true }
                AxoConfirmDialog.Action(i18n("icu:CaptchaDialog__continue"), variant: .strongPrimary, pending: pending, autoFocus: true,
                                        action: onContinue)
            }
        }
    }
}

public struct CrashReportDialog: View {
    let isPending: Bool
    let onSend: () -> Void
    let onErase: () -> Void
    @Environment(\.i18n) var i18n

    public init(isPending: Bool = false, onSend: @escaping () -> Void = {}, onErase: @escaping () -> Void = {}) {
        self.isPending = isPending
        self.onSend = onSend
        self.onErase = onErase
    }

    public var body: some View {
        AxoAlertDialog.Content {
            AxoAlertDialog.Body {
                AxoAlertDialog.Title(i18n("icu:CrashReportDialog__title"))
                AxoAlertDialog.Description(i18n("icu:CrashReportDialog__body"))
            }
            AxoAlertDialog.Footer {
                AxoAlertDialog.Action(i18n("icu:CrashReportDialog__erase"), variant: .subtleSecondary, disabled: isPending, action: onErase)
                AxoAlertDialog.Action(i18n("icu:CrashReportDialog__submit"), variant: .strongPrimary, disabled: isPending, autoFocus: true,
                                      action: onSend)
            }
        }
    }
}
