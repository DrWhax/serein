// Port of ts/components/preferences/PreferencesLanguageDialog.dom.tsx: choose the app
// language (the override first, then the system language, then every available locale by
// code) with a search, then confirm the restart. Display names come from upstream's
// build/locale-display-names.json (getLocaleDisplayName).

import Foundation
import SignalI18n
import SwiftUI

public enum LocaleDisplayNames {
    static let table: [String: [String: String]] = {
        guard let url = Bundle.module.url(forResource: "locale-display-names", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: [String: String]].self, from: data)) ?? [:]
    }()
    /// build/available-locales.json
    public static let availableLocales: [String] = {
        guard let url = Bundle.module.url(forResource: "available-locales", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return ["en"] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? ["en"]
    }()

    /// `getLocaleDisplayName(inLocale, ofLocale)`
    public static func name(in inLocale: String, of locale: String) -> String {
        table[inLocale]?[locale] ?? Locale(identifier: inLocale).localizedString(forIdentifier: locale) ?? locale
    }

    /// `LocaleMatcher.match(preferred, AVAILABLE_LOCALES, 'en')`: an exact match, then one on
    /// the language subtag.
    public static func match(_ preferred: [String]) -> String {
        for p in preferred {
            if let exact = availableLocales.first(where: { $0.caseInsensitiveCompare(p) == .orderedSame }) { return exact }
            let language = p.split(separator: "-").first.map(String.init) ?? p
            if let byLanguage = availableLocales.first(where: { $0 == language || $0.hasPrefix(language + "-") }) { return byLanguage }
        }
        return "en"
    }
}

public struct PreferencesLanguageDialog: View {
    struct Option: Identifiable {
        var locale: String?
        var currentLocaleLabel: String
        var matchingLocaleLabel: String
        var id: String { locale ?? "system" }
    }

    let resolvedLocale: String
    let preferredSystemLocales: [String]
    let localeOverride: String?
    let onLocaleChange: (String?) -> Void
    let onClose: () -> Void
    @State private var confirming = false
    @State private var selected: String?
    @State private var search = ""
    @Environment(\.i18n) var i18n

    public init(resolvedLocale: String, preferredSystemLocales: [String], localeOverride: String?, onLocaleChange: @escaping (String?) -> Void = { _ in },
                onClose: @escaping () -> Void = {}) {
        self.resolvedLocale = resolvedLocale
        self.preferredSystemLocales = preferredSystemLocales
        self.localeOverride = localeOverride
        self.onLocaleChange = onLocaleChange
        self.onClose = onClose
        _selected = State(initialValue: localeOverride)
    }

    var options: [Option] {
        let system = LocaleDisplayNames.match(preferredSystemLocales)
        let all = LocaleDisplayNames.availableLocales.sorted { $0.compare($1, locale: Locale(identifier: "en")) == .orderedAscending }.map {
            Option(locale: $0, currentLocaleLabel: LocaleDisplayNames.name(in: resolvedLocale, of: $0), matchingLocaleLabel: LocaleDisplayNames.name(in: $0, of: $0))
        }
        let systemOption = Option(locale: nil, currentLocaleLabel: i18n("icu:Preferences__Language__SystemLanguage"),
                                  matchingLocaleLabel: LocaleDisplayNames.name(in: system, of: system))
        return all.filter { $0.locale == localeOverride } + [systemOption] + all.filter { $0.locale != localeOverride }
    }

    var results: [Option] {
        let input = ConversationSearch.removeDiacritics(search.trimmingCharacters(in: .whitespaces).lowercased())
        guard !input.isEmpty else { return options }
        func matches(_ s: String) -> Bool { ConversationSearch.removeDiacritics(s.lowercased()).contains(input) }
        return options.filter { matches($0.currentLocaleLabel) || matches($0.matchingLocaleLabel) }
    }

    public var body: some View {
        if confirming {
            AxoConfirmDialog.Root(title: i18n("icu:Preferences__LanguageModal__Restart__Title"),
                                  description: i18n("icu:Preferences__LanguageModal__Restart__Description")) {
                AxoConfirmDialog.Cancel(i18n("icu:cancel")) { confirming = false }
                AxoConfirmDialog.Action(i18n("icu:Preferences__LanguageModal__Restart__Button"), variant: .strongPrimary) {
                    onLocaleChange(selected)
                    onClose()
                }
            }
        } else {
            let results = results
            let selectionVisible = results.contains { $0.locale == selected }
            AxoDialog.Content(size: .sm) {
                AxoDialog.Header {
                    AxoDialog.Title(i18n("icu:Preferences__Language__ModalTitle"))
                    AxoDialog.Close(action: onClose)
                }
                AxoDialog.Search {
                    AxoSearchField.Root(value: $search) {
                        AxoSearchField.Icon()
                        AxoSearchField.Input(placeholder: i18n("icu:Preferences__Language__SearchLanguages"), autoFocus: true)
                        AxoSearchField.Clear()
                    }
                }
                AxoDialog.Body(padding: .md, forceMaxHeight: true) {
                    if results.isEmpty {
                        CSSText(i18n("icu:Preferences__Language__NoResults", ["searchTerm": .string(search.trimmingCharacters(in: .whitespaces))]),
                                type: .bodyLarge, alignment: .center, color: .labelPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(16)
                    } else {
                        AxoList.Group {
                            AxoRadioGroupList.Root(value: Binding { selected ?? "system" } set: { selected = $0 == "system" ? nil : $0 }) {
                                ForEach(results) { option in
                                    AxoRadioGroupList.Item(value: option.id) {
                                        AxoRadioGroupList.Label(option.currentLocaleLabel)
                                        AxoRadioGroupList.Description(option.matchingLocaleLabel)
                                    }
                                }
                            }
                        }
                    }
                }
                AxoDialog.Footer {
                    AxoDialog.Actions {
                        AxoDialog.Action(i18n("icu:cancel"), variant: .subtleSecondary, action: onClose)
                        AxoDialog.Action(i18n("icu:Preferences__LanguageModal__Set"), variant: .strongPrimary,
                                         disabled: selected == localeOverride || !selectionVisible) { confirming = true }
                    }
                }
            }
        }
    }
}
