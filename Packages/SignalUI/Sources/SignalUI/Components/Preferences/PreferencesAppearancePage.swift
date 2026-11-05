// The Appearance page of ts/components/Preferences.dom.tsx: language, theme, chat colour and
// zoom, in an AxoPanel.

import SignalI18n
import SwiftUI

public struct PreferencesAppearancePage: View {
    /// `localeOverride`: nil follows the system; `.some(nil)` is not loaded yet.
    let localeText: String?
    @Binding var themeSetting: String?
    @Binding var zoomFactor: String?
    let defaultBubbleColor: BubbleColor
    let onOpenChatColor: () -> Void
    /// For PreferencesLanguageDialog: nil until the setting has loaded.
    let languageSetting: (resolvedLocale: String, preferredSystemLocales: [String], localeOverride: String?)?
    let onLocaleChange: (String?) -> Void
    @State private var languageDialogOpen = false
    @Environment(\.i18n) var i18n

    /// `DEFAULT_ZOOM_FACTORS`
    static let zoomFactors: [(text: String, value: Double)] = [("75%", 0.75), ("100%", 1), ("125%", 1.25), ("150%", 1.5), ("200%", 2)]

    public init(localeText: String?, themeSetting: Binding<String?>, zoomFactor: Binding<String?>, defaultBubbleColor: BubbleColor = .default,
                languageSetting: (resolvedLocale: String, preferredSystemLocales: [String], localeOverride: String?)? = nil,
                onLocaleChange: @escaping (String?) -> Void = { _ in }, onOpenChatColor: @escaping () -> Void = {}) {
        self.localeText = localeText
        _themeSetting = themeSetting
        _zoomFactor = zoomFactor
        self.defaultBubbleColor = defaultBubbleColor
        self.languageSetting = languageSetting
        self.onLocaleChange = onLocaleChange
        self.onOpenChatColor = onOpenChatColor
    }

    var zoomOptions: [AxoSelectItem.Option] {
        var factors = Self.zoomFactors
        if let z = zoomFactor.flatMap(Double.init), !factors.contains(where: { $0.value == z }) {
            factors.append(("\(Int((z * 100).rounded()))%", z))
            factors.sort { $0.value < $1.value }
        }
        return factors.map { AxoSelectItem.Option(value: Self.zoomValue($0.value), label: $0.text) }
    }

    /// `String(value)` as JS prints a number.
    static func zoomValue(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }

    public var body: some View {
        AxoPanel.Root {
            AxoPanel.Header { AxoPanel.Label(i18n("icu:Preferences__button--appearance")) }
            AxoPanel.Content {
                AxoList.Group {
                    PreferencesList {
                        AxoClickableItem.Root(symbol: "globe", label: i18n("icu:Preferences__Language__Label"), value: localeText ?? "", arrow: .next) {
                            // We haven't loaded the user's setting yet.
                            if languageSetting != nil { languageDialogOpen = true }
                        }
                        AxoSelectItem.Root(symbol: "contrast", label: i18n("icu:Preferences--theme"), disabled: themeSetting == nil, placeholder: "",
                                           value: Binding { themeSetting ?? "system" } set: { themeSetting = $0 },
                                           options: [.init(value: "system", label: i18n("icu:themeSystem")), .init(value: "light", label: i18n("icu:themeLight")),
                                                     .init(value: "dark", label: i18n("icu:themeDark"))])
                        AxoClickableItem.Root(symbol: "palette", label: i18n("icu:showChatColorEditor"), arrow: .next, onClick: onOpenChatColor) {
                            // .ConversationDetails__chat-color
                            BubbleFill(color: defaultBubbleColor, shape: UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(topLeading: 10, bottomLeading: 10, bottomTrailing: 10, topTrailing: 10))).frame(width: 20, height: 20).padding(6)
                        }
                        AxoSelectItem.Root(symbol: "zoom-in", label: i18n("icu:Preferences--zoom"), disabled: zoomFactor == nil, placeholder: "",
                                           value: Binding { zoomFactor ?? "1" } set: { zoomFactor = $0 }, options: zoomOptions)
                    }
                }
            }
        }
        .viewportPortal {
            if languageDialogOpen, let l = languageSetting {
                AxoBaseDialog.Host {
                    PreferencesLanguageDialog(resolvedLocale: l.resolvedLocale, preferredSystemLocales: l.preferredSystemLocales, localeOverride: l.localeOverride,
                                              onLocaleChange: onLocaleChange, onClose: { languageDialogOpen = false })
                }
            }
        }
    }
}
