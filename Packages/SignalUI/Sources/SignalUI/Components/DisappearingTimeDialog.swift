// Port of ts/components/DisappearingTimeDialog.dom.tsx: a custom disappearing-messages time as
// a value and a unit (two legacy Selects, 9px apart, sharing the width).

import SignalI18n
import SwiftUI

public struct DisappearingTimeDialog: View {
    public enum Unit: String, CaseIterable, Sendable {
        case seconds, minutes, hours, days, weeks
        var seconds: Int {
            switch self {
            case .seconds: 1
            case .minutes: 60
            case .hours: 60 * 60
            case .days: 24 * 60 * 60
            case .weeks: 7 * 24 * 60 * 60
            }
        }
        /// `RANGES`: values offered are `lower..<upper`.
        var range: Range<Int> {
            switch self {
            case .seconds, .minutes: 1..<60
            case .hours: 1..<24
            case .days: 1..<7
            case .weeks: 1..<5
            }
        }
        var key: String {
            switch self {
            case .seconds: "icu:DisappearingTimeDialog__seconds"
            case .minutes: "icu:DisappearingTimeDialog__minutes"
            case .hours: "icu:DisappearingTimeDialog__hours"
            case .days: "icu:DisappearingTimeDialog__days"
            case .weeks: "icu:DisappearingTimeDialog__weeks"
            }
        }
    }

    let onSubmit: (Int) -> Void
    let onClose: () -> Void
    @State private var unitValue: Int
    @State private var unit: Unit
    @Environment(\.i18n) var i18n

    /// The largest unit that fits `initialValue` (seconds; default 60), and its whole count.
    public init(initialValue: Int = 60, onSubmit: @escaping (Int) -> Void = { _ in }, onClose: @escaping () -> Void = {}) {
        var initialUnit = Unit.seconds
        var initialUnitValue = 1
        for u in Unit.allCases {
            if initialValue < u.seconds { break }
            initialUnit = u
            initialUnitValue = initialValue / u.seconds
        }
        _unit = State(initialValue: initialUnit)
        _unitValue = State(initialValue: initialUnitValue)
        self.onSubmit = onSubmit
        self.onClose = onClose
    }

    public var body: some View {
        AxoDialog.Content(size: .sm) {
            AxoDialog.Header {
                AxoDialog.Title(i18n("icu:DisappearingTimeDialog__title"))
                AxoDialog.Close(action: onClose)
            }
            AxoDialog.Body {
                VStack(alignment: .leading, spacing: 0) {
                    AxoDialog.Description(i18n("icu:DisappearingTimeDialog__body"))
                    HStack(spacing: 9) {
                        Select(options: unit.range.map { Select.Option(text: String($0), value: String($0)) }, value: String(unitValue),
                               ariaLabel: i18n("icu:DisappearingTimeDialog__label--value")) { unitValue = Int($0) ?? unitValue }
                            .frame(maxWidth: .infinity)
                        Select(options: Unit.allCases.map { Select.Option(text: i18n($0.key), value: $0.rawValue) }, value: unit.rawValue,
                               ariaLabel: i18n("icu:DisappearingTimeDialog__label--units")) { raw in
                            guard let newUnit = Unit(rawValue: raw) else { return }
                            unit = newUnit
                            unitValue = max(newUnit.range.lowerBound, min(newUnit.range.upperBound - 1, unitValue))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.top, 12)
                }
            }
            AxoDialog.Footer {
                AxoDialog.Actions(width: .fill) {
                    AxoDialog.Action(i18n("icu:cancel"), variant: .subtleSecondary, action: onClose)
                    AxoDialog.Action(i18n("icu:DisappearingTimeDialog__set"), variant: .strongPrimary) {
                        onSubmit(unitValue * unit.seconds)
                        onClose()
                    }
                }
            }
        }
    }
}
