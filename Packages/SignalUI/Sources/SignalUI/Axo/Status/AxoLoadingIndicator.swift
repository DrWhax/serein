// Port of ts/axo/status/AxoLoadingIndicator.dom.tsx: a standalone indeterminate spinner
// (AxoBaseSpinner, default variant, no track), labelled "Loading" by default.

import SwiftUI

public enum AxoLoadingIndicator {
    /// Preset sizes for standalone loading indicators.
    public enum Size: String, CaseIterable, Sendable {
        case sm, md, lg
        var base: AxoBaseSpinner.Size {
            switch self {
            case .sm: .sm
            case .md: .md
            case .lg: .lg
            }
        }
    }

    public typealias Weight = AxoBaseSpinner.Weight

    /// `<AxoLoadingIndicator.Root>`
    public struct Root: View {
        let size: Size
        let weight: Weight
        let label: String?

        public init(size: Size, weight: Weight = .regular, label: String? = nil) {
            self.size = size
            self.weight = weight
            self.label = label
        }

        public var body: some View {
            AxoBaseSpinner.Root(size: size.base, weight: weight, variant: .default, value: .indeterminate, track: false)
                .accessibilityLabel(label ?? "Loading")
        }
    }
}
