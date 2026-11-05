// Port of ts/components/conversation/pinned-messages/PinMessageDialog.dom.tsx: pinning a message.
// With the maximum pinned, "Replace oldest pin?" first; then the duration (24 hours, 7 days,
// 30 days, forever); for a disappearing message the warning (shown the first few times).

import SignalI18n
import SwiftUI

public struct PinMessageDialog: View {
    public enum Duration: String, Sendable, CaseIterable {
        case time24Hours = "TIME_24_HOURS", time7Days = "TIME_7_DAYS", time30Days = "TIME_30_DAYS", forever = "FOREVER"
        /// `DURATION_OPTIONS` in seconds (nil: forever).
        public var seconds: Int? {
            switch self {
            case .time24Hours: 86_400
            case .time7Days: 7 * 86_400
            case .time30Days: 30 * 86_400
            case .forever: nil
            }
        }
    }

    enum Step { case closed, confirmReplaceOldestPin, selectPinDuration, disappearingMessagesWarning }

    let hasMaxPinnedMessages: Bool
    let isPinningDisappearingMessage: Bool
    let seenWarningCount: Int
    let onSeenWarning: () -> Void
    let onPinnedMessageAdd: (Int?) -> Void
    let onClose: () -> Void
    @State private var confirmedReplace = false
    @State private var duration: Duration?
    @State private var pendingDuration = Duration.time7Days
    @Environment(\.i18n) var i18n

    public init(hasMaxPinnedMessages: Bool, isPinningDisappearingMessage: Bool, seenWarningCount: Int, onSeenWarning: @escaping () -> Void = {},
                onPinnedMessageAdd: @escaping (Int?) -> Void = { _ in }, onClose: @escaping () -> Void = {}) {
        self.hasMaxPinnedMessages = hasMaxPinnedMessages
        self.isPinningDisappearingMessage = isPinningDisappearingMessage
        self.seenWarningCount = seenWarningCount
        self.onSeenWarning = onSeenWarning
        self.onPinnedMessageAdd = onPinnedMessageAdd
        self.onClose = onClose
    }

    var needsDisappearingWarning: Bool { isPinningDisappearingMessage && seenWarningCount <= 3 }

    var step: Step {
        if hasMaxPinnedMessages && !confirmedReplace { return .confirmReplaceOldestPin }
        if duration == nil { return .selectPinDuration }
        if needsDisappearingWarning { return .disappearingMessagesWarning }
        return .closed
    }

    func submit(_ d: Duration) {
        onPinnedMessageAdd(d.seconds)
        onClose()
    }

    public var body: some View {
        switch step {
        case .closed:
            EmptyView()
        case .confirmReplaceOldestPin:
            AxoAlertDialog.Content {
                AxoAlertDialog.Body {
                    AxoAlertDialog.Title(i18n("icu:PinMessageDialog--HasMaxPinnedMessages__Title"))
                    AxoAlertDialog.Description(i18n("icu:PinMessageDialog--HasMaxPinnedMessages__Description"))
                }
                AxoAlertDialog.Footer {
                    AxoAlertDialog.Cancel(i18n("icu:cancel"), action: onClose)
                    AxoAlertDialog.Action(i18n("icu:PinMessageDialog--HasMaxPinnedMessages__Continue"), variant: .strongPrimary) {
                        confirmedReplace = true
                    }
                }
            }
        case .selectPinDuration:
            AxoDialog.Content(size: .sm) {
                AxoDialog.Header {
                    AxoDialog.Title(i18n("icu:PinMessageDialog__Title"))
                    AxoDialog.Close(action: onClose)
                }
                AxoDialog.Body {
                    AxoRadioGroup.Root(value: Binding(get: { pendingDuration.rawValue }, set: { if let v = $0, let d = Duration(rawValue: v) { pendingDuration = d } })) {
                        ForEach(Duration.allCases, id: \.self) { d in
                            AxoRadioGroup.Item(value: d.rawValue) { AxoRadioGroup.Label(i18n("icu:PinMessageDialog__Option--\(d.rawValue)")) }
                        }
                    }
                }
                AxoDialog.Footer {
                    AxoDialog.Actions {
                        AxoDialog.Action(i18n("icu:PinMessageDialog__Cancel"), variant: .subtleSecondary, action: onClose)
                        AxoDialog.Action(i18n("icu:PinMessageDialog__Pin"), variant: .strongPrimary) {
                            duration = pendingDuration
                            if !needsDisappearingWarning { submit(pendingDuration) }
                        }
                    }
                }
            }
        case .disappearingMessagesWarning:
            AxoAlertDialog.Content {
                AxoAlertDialog.Body {
                    AxoAlertDialog.Title(i18n("icu:PinMessageDisappearingMessagesWarningDialog__Title"))
                    AxoAlertDialog.Description(i18n("icu:PinMessageDisappearingMessagesWarningDialog__Description"))
                }
                AxoAlertDialog.Footer {
                    AxoAlertDialog.Action(i18n("icu:ok"), variant: .strongPrimary) {
                        onSeenWarning()
                        if let duration { submit(duration) }
                    }
                }
            }
        }
    }
}
