// Ports of the two upstream components named `About` (one Swift type, two initialisers):
// - ts/components/About.dom.tsx (stylesheets/components/About.scss): the About window — the
//   splash logo, version, environment, links and the nonprofit line, centred.
// - ts/components/conversation/About.dom.tsx (`.module-about__text`): a contact's about text,
//   body-1 in gray-60 (gray-25), at most 400px wide and two lines.

import AppKit
import SignalI18n
import SwiftUI

public struct About: View {
    let appEnv: String
    let arch: String
    let platform: String
    let version: String
    let closeAbout: () -> Void
    /// A rebranded build's logo in place of signal-logo.svg; Signal's links are dropped too.
    @Environment(\.brandLogo) var productLogo
    /// The conversation About: a contact's about text.
    let contactAbout: String?
    @Environment(\.i18n) var i18n

    /// The About window.
    public init(appEnv: String, arch: String = "arm64", platform: String = "darwin", version: String,
                closeAbout: @escaping () -> Void = {}) {
        self.appEnv = appEnv
        self.arch = arch
        self.platform = platform
        self.version = version
        self.closeAbout = closeAbout
        contactAbout = nil
    }

    /// ts/components/conversation/About: a contact's about text.
    public init(text: String) {
        appEnv = ""
        arch = ""
        platform = ""
        version = ""
        closeAbout = {}
        contactAbout = text
    }

    var env: String {
        if platform == "darwin" {
            return i18n(arch == "arm64" ? "icu:About__AppEnvironment--AppleSilicon" : "icu:About__AppEnvironment--AppleIntel", ["appEnv": .string(appEnv)])
        }
        return i18n("icu:About__AppEnvironment", ["appEnv": .string(appEnv)])
    }

    static let text = AxoColor(light: LegacyColor.black, dark: LegacyColor.whiteAlpha80)
    static let link = AxoColor(light: LegacyColor.ultramarine, dark: LegacyColor.ultramarinePastel)
    static let style = LegacyType.body1()

    func line(_ s: String, color: AxoColor = text) -> some View {
        CSSText(s, style: Self.style, alignment: .center, color: color)
    }

    func link(_ label: String, _ url: String) -> some View {
        Button { if let u = URL(string: url) { NSWorkspace.shared.open(u) } } label: { line(label, color: Self.link) }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isLink)
    }

    public var body: some View {
        if let contactAbout {
            if !contactAbout.isEmpty {
                CSSText(runs: [Emojify.run(contactAbout)], style: LegacyType.body1(), wrap: .clamp(2),
                        color: AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25))
                    .frame(maxWidth: 400, alignment: .leading)
            }
        } else {
            window
        }
    }

    var window: some View {
        VStack(spacing: 0) {
            // module-splash-screen__logo--128: signal-logo.svg in the logo colour, 24px above and below.
            Group {
                if let productLogo {
                    PixelImage(productLogo, fit: .contain).frame(width: 128, height: 128)
                } else {
                    SignalIcon("signal-logo", size: 128, color: AxoColor(light: LegacyColor.ultramarineLogo, dark: LegacyColor.white), mask: true)
                }
            }
            .padding(.vertical, 24)
            CSSText(i18n("icu:signalDesktop"), style: LegacyType.body1(weight: 600), alignment: .center, color: Self.text)
                .accessibilityAddTraits(.isHeader)
            line(version).textSelection(.enabled)
            line(env).textSelection(.enabled)
            Color.clear.frame(height: 20)    // <br />
            if productLogo == nil {
                link("signal.org", "https://signal.org")
                Color.clear.frame(height: 20)
                link(i18n("icu:softwareAcknowledgments"), "https://github.com/signalapp/Signal-Desktop/blob/main/ACKNOWLEDGMENTS.md")
                link(i18n("icu:privacyPolicy"), "https://signal.org/legal")
            }
            line(i18n("icu:signalNonProfit"), color: .labelSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AxoColor(light: LegacyColor.white, dark: LegacyColor.gray95))
        .onExitCommand(perform: closeAbout)
    }
}
