// DisappearingTimerSelect (ts/components/DisappearingTimerSelect.dom.tsx) and the duration text
// of ts/util/expirationTimer.std.ts `format`.

import SignalI18n
import SwiftUI

public enum ExpirationTimer {
    /// `DEFAULT_DURATIONS_IN_SECONDS`
    public static let defaultDurations: [Int] = [0, 4 * 604_800, 604_800, 86_400, 8 * 3600, 3600, 5 * 60, 30]

    /// `format`: "Off", whole weeks as weeks, else days / hours / minutes / seconds joined
    /// with ", " (humanize-duration). Unit names are English: the other languages'
    /// humanize-duration tables are not ported yet.
    ///
    /// With `largest`, the first `largest` non-zero units of years, months, weeks, days,
    /// hours, minutes and seconds (humanize-duration's year 365.25 days, month 30.4375).
    /// The last unit is truncated where humanize-duration would show a decimal.
    public static func format(_ i18n: Localizer, _ seconds: Int?, capitalizeOff: Bool = false, largest: Int? = nil) -> String {
        var s = abs(seconds ?? 0)
        guard s > 0 else { return i18n(capitalizeOff ? "icu:off" : "icu:disappearingMessages__off") }
        s = max(s, 1)
        func unit(_ n: Int, _ singular: String) -> String { "\(n) \(singular)\(n == 1 ? "" : "s")" }
        if let largest {
            let units: [(Int, String)] = [(31_557_600, "year"), (2_629_800, "month"), (604_800, "week"), (86_400, "day"), (3600, "hour"),
                                          (60, "minute"), (1, "second")]
            var rest = s, parts: [String] = []
            for (size, name) in units where parts.count < largest {
                let n = rest / size
                rest -= n * size
                if n > 0 { parts.append(unit(n, name)) }
            }
            return parts.joined(separator: ", ")
        }
        if s % 604_800 == 0 { return unit(s / 604_800, "week") }
        var parts: [String] = []
        let d = s / 86_400, h = s % 86_400 / 3600, m = s % 3600 / 60, sec = s % 60
        if d > 0 { parts.append(unit(d, "day")) }
        if h > 0 { parts.append(unit(h, "hour")) }
        if m > 0 { parts.append(unit(m, "minute")) }
        if sec > 0 { parts.append(unit(sec, "second")) }
        return parts.joined(separator: ", ")
    }
}

public struct DisappearingTimerSelect: View {
    let value: Int
    let disabled: Bool
    let onChange: (Int) -> Void
    let onCustom: () -> Void
    @Environment(\.i18n) var i18n

    /// - Parameter onCustom: "Custom time…" (opens DisappearingTimeDialog).
    public init(value: Int = 0, disabled: Bool = false, onChange: @escaping (Int) -> Void = { _ in }, onCustom: @escaping () -> Void = {}) {
        self.value = value
        self.disabled = disabled
        self.onChange = onChange
        self.onCustom = onCustom
    }

    var isCustom: Bool { !ExpirationTimer.defaultDurations.contains(value) }

    public var body: some View {
        let selection = Binding<String?>(get: { String(isCustom ? -1 : value) }, set: { new in
            guard let new, let v = Int(new) else { return }
            if v == -1 { onCustom() } else { onChange(v) }
        })
        VStack(alignment: .leading, spacing: 0) {
            AxoSelect.Root(label: nil, value: selection, disabled: disabled) {
                AxoSelect.Trigger(width: .full, placeholder: "")
                AxoSelect.Content {
                    ForEach(ExpirationTimer.defaultDurations, id: \.self) { seconds in
                        AxoSelect.Item(value: String(seconds)) { AxoSelect.ItemText(ExpirationTimer.format(i18n, seconds, capitalizeOff: true)) }
                    }
                    AxoSelect.Item(value: "-1") {
                        AxoSelect.ItemText(i18n(isCustom ? "icu:selectedCustomDisappearingTimeOption" : "icu:customDisappearingTimeOption"))
                    }
                }
            }
            if isCustom {
                CSSText(ExpirationTimer.format(i18n, value), type: .bodySmall, color: .labelSecondary)
                    .padding(.top, 4).padding(.leading, 14)
            }
        }
        .fixedSize()
    }
}
