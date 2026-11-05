// Port of ts/axo/status/AxoProgressIndicator.dom.tsx: a standalone progress ring
// (AxoBaseSpinner, default variant, with a track unless `noTrack`). An unknown completed
// or total amount makes it indeterminate.

import SwiftUI

public enum AxoProgressIndicator {
    public typealias Size = AxoLoadingIndicator.Size
    public typealias Weight = AxoBaseSpinner.Weight

    /// `number | 'indeterminate'`
    public enum Amount: Sendable, Equatable {
        case indeterminate
        case value(Double)
    }

    /// `<AxoProgressIndicator.Root>`
    public struct Root: View {
        let size: Size
        let weight: Weight
        let completed: Amount
        let total: Amount
        let noTrack: Bool
        let label: String?

        public init(size: Size, weight: Weight = .regular, completed: Amount, total: Amount, noTrack: Bool = false, label: String? = nil) {
            self.size = size
            self.weight = weight
            self.completed = completed
            self.total = total
            self.noTrack = noTrack
            self.label = label
        }

        public init(size: Size, weight: Weight = .regular, completed: Double, total: Double, noTrack: Bool = false, label: String? = nil) {
            self.init(size: size, weight: weight, completed: .value(completed), total: .value(total), noTrack: noTrack, label: label)
        }

        var value: AxoBaseSpinner.Value {
            guard case .value(let c) = completed, case .value(let t) = total else { return .indeterminate }
            return .progress(completed: c, total: t)
        }

        public var body: some View {
            AxoBaseSpinner.Root(size: size.base, weight: weight, variant: .default, value: value, track: !noTrack)
                .accessibilityLabel(label ?? "Loading")
        }
    }
}
