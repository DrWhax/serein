// The app's Localizer (SignalI18n) in the SwiftUI environment: upstream components take
// an `i18n` prop; SwiftUI components read `@Environment(\.i18n)`.

import SignalI18n
import SwiftUI

enum DefaultLocalizer { static let english = Localizer(locale: "en") }

extension EnvironmentValues {
    @Entry public var i18n: Localizer = DefaultLocalizer.english
}
