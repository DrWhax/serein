// CountryCodeSelect (ts/components/CountryCodeSelect.dom.tsx) and its country data
// (ts/util/getCountryData.dom.ts): localised region names (build/country-display-names.json)
// with libphonenumber calling codes (Tools/gen-country-codes.mjs), sorted by name.

import Foundation
import SignalI18n
import SwiftUI
import Synchronization

public struct CountryData: Sendable, Hashable, Identifiable {
    public var region: String
    public var displayName: String
    public var code: String
    public var id: String { region }
}

public enum CountryDataSource {
    private static let cache = Mutex<[String: [CountryData]]>([:])
    private static let names: [String: [String: String]] = {
        guard let url = Bundle.module.url(forResource: "country-display-names", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data) else { return [:] }
        return decoded
    }()

    /// `getCountryDataForLocale` (English names for locales the file lacks).
    public static func countries(locale: String) -> [CountryData] {
        if let hit = cache.withLock({ $0[locale] }) { return hit }
        let map = names[locale] ?? names["en"] ?? [:]
        let list = map.compactMap { region, name -> CountryData? in
            guard let code = CountryCodesTable.codes[region] else { return nil }
            return CountryData(region: region, displayName: name, code: "+\(code)")
        }
        .sorted { $0.displayName < $1.displayName }
        cache.withLock { $0[locale] = list }
        return list
    }
}

/// The 28px country button ("Country", the code, a chevron); opens ChooseCountryCodeModal.
public struct CountryCodeSelect: View {
    let countries: [CountryData]
    let defaultRegion: String
    let value: String?
    let onShowModal: () -> Void
    @Environment(\.i18n) var i18n

    public init(countries: [CountryData], defaultRegion: String, value: String?, onShowModal: @escaping () -> Void = {}) {
        self.countries = countries
        self.defaultRegion = defaultRegion
        self.value = value
        self.onShowModal = onShowModal
    }

    public var body: some View {
        let selected = countries.first { $0.region == value }
        let defaultCode = countries.first { $0.region == defaultRegion }?.code ?? ""
        let color = AxoColor(light: LegacyColor.gray90, dark: LegacyColor.gray05)
        SwiftUI.Button(action: onShowModal) {
            HStack(spacing: 12) {
                CSSText(selected?.displayName ?? i18n("icu:CountryCodeSelect__placeholder"), style: LegacyType.body2(), wrap: .nowrap, color: color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                CSSText(selected?.code ?? defaultCode, style: LegacyType.body2(), wrap: .nowrap, color: color)
                SignalIcon("v3/dropdown/dropdown-compact", size: 16, color: AxoColor(light: LegacyColor.black, dark: LegacyColor.gray05))
                    .frame(width: 16, height: 16)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(AxoColor(light: LegacyColor.blackAlpha06, dark: LegacyColor.whiteAlpha12)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
