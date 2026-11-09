// Port of ts/axo/message/AxoOutgoingStatus.dom.tsx: the delivery status glyph of an
// outgoing message (an inline glyph, preferring the wide symbol variant); "sending"
// spins (animate-spin), resting unrotated when animations are disabled.

import SwiftUI

public enum AxoOutgoingStatus {
    public enum Status: String, Sendable, CaseIterable {
        case sending, sent, delivered, read, paused, error

        var symbol: AxoSymbol.Name {
            switch self {
            case .sending: "ticks"
            case .sent: "check-circle"
            case .delivered: "check-circle-on-check-circle"
            case .read: "check-circle-on-check-circle-fill"
            case .paused, .error: "error-circle"
            }
        }

        var defaultLabel: String {
            switch self {
            case .sending: "Sending"
            case .sent: "Sent"
            case .delivered: "Delivered"
            case .read: "Read"
            case .paused: "Paused"
            case .error: "Failed to send"
            }
        }
    }

    /// `<AxoOutgoingStatus.Root>`
    public struct Root: View {
        let status: Status
        /// `.some(nil)` hides the status from assistive technologies; nil uses the default.
        let label: String??
        let type: AxoType
        @Environment(\.axoAnimationsDisabled) var animationsDisabled
        @Environment(\.layoutDirection) var direction

        /// - Parameter type: the surrounding text the glyph flows with (inherited font).
        public init(status: Status, label: String?? = nil, type: AxoType = .bodyLarge) {
            self.status = status
            self.label = label
            self.type = type
        }

        public var body: some View {
            let glyph = AxoInlineGlyphLine(glyph: AxoSymbol.icon(status.symbol, rtl: direction == .rightToLeft), type: type)
            let resolvedLabel: String? = label ?? status.defaultLabel
            Group {
                if status == .sending && !animationsDisabled {
                    glyph.caSpin(period: 1)   // animate-spin: 1s linear
                } else {
                    glyph
                }
            }
            .accessibilityElement()
            .accessibilityLabel(resolvedLabel ?? "")
            .accessibilityHidden(resolvedLabel == nil)
        }
    }
}
