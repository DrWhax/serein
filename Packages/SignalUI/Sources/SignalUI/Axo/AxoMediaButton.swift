// Port of ts/axo/AxoMediaButton.dom.tsx: round play / pause / download button for media
// attachments, with a progress ring while downloading.

import SwiftUI

public enum AxoMediaButton {
    public enum Status: String, CaseIterable, Sendable {
        case paused, playing, undownloaded, downloading

        /// `Statuses`
        var symbol: AxoSymbol.Name {
            switch self {
            case .paused: "play-fill"
            case .playing: "pause-fill"
            case .undownloaded: "arrow-down"
            case .downloading: "x"
            }
        }

        /// `StatusLabels` (AxoIntl default messages)
        var defaultLabel: String {
            switch self {
            case .paused: "Play"
            case .playing: "Pause"
            case .undownloaded: "Download"
            case .downloading: "Cancel download"
            }
        }
    }

    /// `number | 'indeterminate'`
    public enum Bytes: Sendable, Equatable {
        case indeterminate
        case count(Double)
    }

    /// `<AxoMediaButton.Root>`
    public struct Root: View {
        let status: Status
        let downloadedBytes: Bytes
        let totalBytes: Bytes
        let label: String?
        let disabled: Bool
        let onClick: () -> Void

        public init(status: Status, downloadedBytes: Bytes, totalBytes: Bytes, label: String? = nil, disabled: Bool = false,
                    onClick: @escaping () -> Void = {}) {
            self.status = status
            self.downloadedBytes = downloadedBytes
            self.totalBytes = totalBytes
            self.label = label
            self.disabled = disabled
            self.onClick = onClick
        }

        public var body: some View {
            Button {
                if !disabled { onClick() }
            } label: {
                // p-3 around a 24px icon; text-primary / aria-disabled:text-placeholder
                AxoSymbol.Icon(status.symbol, size: 24, label: nil)
                    .padding(12)
                    .cssTextColor(disabled ? .labelPlaceholder : .labelPrimary)
                    .overlay {
                        if status == .downloading {
                            Spinner(size: 42, downloadedBytes: downloadedBytes, totalBytes: totalBytes)
                        }
                    }
            }
            .buttonStyle(AxoMediaButtonStyle())
            .accessibilityLabel(label ?? status.defaultLabel)
        }
    }

    /// `AxoMediaButton.Spinner` (internal): centred `AxoBaseSpinner`, determinate when both byte counts are known.
    struct Spinner: View {
        let size: CGFloat
        let downloadedBytes: Bytes
        let totalBytes: Bytes

        var value: AxoBaseSpinner.Value {
            precondition(totalBytes != .count(0), "totalBytes should not be 0, use \"indeterminate\"")
            if case .count(let done) = downloadedBytes, case .count(let total) = totalBytes {
                return .progress(completed: done, total: total)
            }
            return .indeterminate
        }

        var body: some View {
            AxoBaseSpinner.Root(size: size, weight: .regular, variant: .default, value: value, track: false)
        }
    }
}

/// `rounded-full bg-material-quaternary backdrop-blur-thin` (the blur shows only the page behind).
struct AxoMediaButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Circle().fill(AxoColor.materialQuaternary))
            .contentShape(Circle())
    }
}
