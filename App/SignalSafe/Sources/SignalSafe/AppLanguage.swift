// The app language (upstream's `localeOverride` in its ephemeral config, read by app/locale at
// startup): nil follows the system's preferred languages. Changing it relaunches the app, as
// upstream's language dialog says ("Restart Signal to apply").

import Foundation
import SignalI18n

enum AppLanguage {
    private static let key = "localeOverride"

    /// The chosen locale, if it is one Serein has.
    static var override: String? {
        UserDefaults.standard.string(forKey: key).flatMap { Localizer.availableLocales.contains($0) ? $0 : nil }
    }

    /// The locale in use: the override, else the best match for the system's languages.
    static var resolvedLocale: String { override ?? Localizer.match(Locale.preferredLanguages) }

    /// Saves the choice (nil: the system language) and relaunches.
    @MainActor static func change(to locale: String?, session: SignalSession) {
        guard locale != override else { return }
        if let locale { UserDefaults.standard.set(locale, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        DesktopActions.relaunch(session)
    }
}
