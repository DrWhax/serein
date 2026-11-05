// swift-tools-version:6.2
//
// SignalI18n: Signal Desktop's localized strings and their ICU MessageFormat formatting,
// behaving like upstream's `i18n` (ts/util/setupI18nMain.std.ts → @formatjs/intl →
// intl-messageformat 11.2 / @formatjs/icu-messageformat-parser 3.5.3).
//
//   * Resources/Locales: compact per-locale string tables generated from
//     Signal-Desktop/_locales by Tools/gen-locales.mjs, loaded lazily.
//   * Generated/: CLDR plural rules and number symbols, also from Tools/gen-locales.mjs.
//   * The ICU grammar is recognised by a LangSec-style parser into a typed AST before
//     anything is formatted; malformed messages are typed errors.
//
// Tests compare every en message and every message of de/ar/ja/ru/pl/he (plus a sample
// of all other locales) against formatjs output (Tools/gen-i18n-fixtures.mjs).

import PackageDescription

let memorySafety: [SwiftSetting] = [
    .strictMemorySafety(),
    .treatWarning("StrictMemorySafety", as: .error),
]
let strict: [SwiftSetting] = memorySafety + [.treatAllWarnings(as: .error)]

let package = Package(
    name: "SignalI18n",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "SignalI18n", targets: ["SignalI18n"]),
    ],
    targets: [
        .target(
            name: "SignalI18n",
            resources: [.copy("Resources/Locales")],
            swiftSettings: strict
        ),
        .testTarget(
            name: "SignalI18nTests",
            dependencies: ["SignalI18n"],
            resources: [.copy("Fixtures")],
            swiftSettings: memorySafety
        ),
    ]
)
