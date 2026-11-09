import SignalI18n
import Testing

@Suite struct RebrandTests {
    let i18n = Localizer(locale: "en", rebrand: Rebrand(name: "Serein", messages: ["icu:signalNonProfit": "{appName} is independent."]))

    @Test func appNameStringsAreRebranded() {
        #expect(i18n("icu:signalDesktop") == "Serein")
        #expect(i18n("icu:aboutSignalDesktop") == "About Serein")
        #expect(i18n("icu:appMenuQuit") == "Quit Serein")
        #expect(i18n("icu:welcomeToSignal") == "Welcome to Serein")
        #expect(i18n("icu:signalNonProfit") == "Serein is independent.")
    }

    @Test func signalNetworkStringsAreKept() {
        // "Signal Desktop" is the app; "non-Signal contacts" is the network.
        #expect(i18n("icu:CompositionArea--sms-only__body").hasPrefix("Serein does not support messaging non-Signal contacts"))
        #expect(i18n("icu:Install__instructions__1") == "Open Signal on your phone")
        #expect(i18n("icu:PinReminderModal__title") == "Enter your Signal PIN")
    }

    @Test func upstreamTextWithoutRebrand() {
        #expect(Localizer(locale: "en")("icu:signalDesktop") == "Signal Desktop")
    }
}
