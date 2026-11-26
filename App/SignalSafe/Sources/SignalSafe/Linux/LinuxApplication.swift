#if os(Linux)
import Foundation
import SignalI18n
import SignalSafeSystem
import SignalUI
import SwiftUI

@main
@MainActor
struct LinuxApplication: App {
    let model: AppModel
    let session: SignalSession
    let i18n: Localizer

    init() {
        AppSandbox.requireConfinement()
        AxoFonts.register()
        model = AppModel()
        session = SignalSession()
        i18n = Localizer(locale: AppLanguage.resolvedLocale, rebrand: Rebrand(name: "Serein", messages: [
            "icu:signalNonProfit": "{appName} is not affiliated with or endorsed by Signal Messenger LLC.",
            "icu:EntryPoint--nonprofit": "{appName} is not affiliated with or endorsed by Signal Messenger LLC.",
        ]))
        session.start()
    }

    var body: some Scene {
        WindowGroup(i18n("icu:signalDesktop")) {
            RootView(model: model, session: session, i18n: i18n)
                .environment(\.spellCheckEnabled, model.spellCheckAtLaunch)
                .environment(\.brandLogo, BundledImage.named("serein-logo"))
        }
        .defaultSize(width: 800, height: 610)
    }
}
#endif
