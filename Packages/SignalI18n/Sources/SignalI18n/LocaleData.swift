// Per-locale formatting data; the table itself is Generated/LocaleData.generated.swift.

/// Writing direction of a locale (upstream: `Intl.Locale#getTextInfo().direction`).
public enum LayoutDirection: Sendable, Hashable {
    case leftToRight, rightToLeft
}

struct LocaleData: Sendable {
    /// Signal's locale id (`_locales/<id>`), e.g. `pt-BR`, `zh-Hant`.
    let identifier: String
    /// What Intl resolves the id to (`fil-PH` for `tl-PH`).
    let intlIdentifier: String
    let direction: LayoutDirection
    /// ICU plural rule set numbers (`setN`).
    let cardinalRules: Int
    let ordinalRules: Int
    let numbers: NumberSymbols

    static let english: LocaleData = named("en") ?? all[0]

    static func named(_ identifier: String) -> LocaleData? {
        all.first { $0.identifier == identifier }
    }
}
