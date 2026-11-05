// UnsupportedOSDialog (ts/components/UnsupportedOSDialog.dom.tsx) and LeftPaneBanner
// (ts/components/LeftPaneBanner.dom.tsx, stylesheets/components/LeftPaneBanner.scss).

import SignalI18n
import SwiftUI

/// The warning (support ends on a date) or error (no longer supported) for an old OS.
public struct UnsupportedOSDialog: View {
    static let unsupportedOSURL = "https://support.signal.org/hc/articles/5109141421850"
    let containerWidthBreakpoint: WidthBreakpoint
    let expirationTimestamp: Date
    let type: LeftPaneDialogType
    let os: String
    @Environment(\.i18n) var i18n
    @Environment(\.openURL) var openURL
    @Environment(\.timeZone) var timeZone

    public init(containerWidthBreakpoint: WidthBreakpoint, expirationTimestamp: Date, type: LeftPaneDialogType, os: String) {
        self.containerWidthBreakpoint = containerWidthBreakpoint
        self.expirationTimestamp = expirationTimestamp
        self.type = type
        self.os = os
    }

    /// moment's `ll` format ("Nov 9, 2026").
    var expirationDate: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: i18n.locale)
        f.timeZone = timeZone
        f.dateStyle = .medium
        return f.string(from: expirationTimestamp)
    }

    func openLearnMore() {
        if let url = URL(string: Self.unsupportedOSURL) { openURL(url) }
    }

    public var body: some View {
        let key = type == .error ? "icu:UnsupportedOSErrorDialog__body" : "icu:UnsupportedOSWarningDialog__body"
        var args: [String: I18nArgument] = ["OS": .string(os)]
        if type != .error { args["expirationDate"] = .string(expirationDate) }
        let runs = CSSTextRun.runs(i18n.richText(key, args), tags: ["learnMoreLink": I18nTagStyle(fontName: AxoFonts.interName(weight: 700), action: "learnMore")])
        return LeftPaneDialog(type: type, containerWidthBreakpoint: containerWidthBreakpoint) {
            CSSText(runs: runs, style: LegacyType.body1(), onTap: { _ in openLearnMore() })
        }
    }
}

/// A rounded grey banner with content and a bold action button at its end.
public struct LeftPaneBanner<Content: View>: View {
    let actionText: String
    let onClick: () -> Void
    let content: Content

    public init(actionText: String, onClick: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.actionText = actionText
        self.onClick = onClick
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                SwiftUI.Button(action: onClick) {
                    CSSText(actionText, style: LegacyType.body1(weight: 600), wrap: .nowrap,
                            color: AxoColor(light: LegacyColor.gray90, dark: LegacyColor.gray05))
                }
                .buttonStyle(.plain)
                .help(actionText)
                .accessibilityLabel(actionText)
            }
            .padding(.trailing, 9)
        }
        .padding(.top, 12)
        .padding(.bottom, 16)
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(AxoColor(light: LegacyColor.gray15, dark: LegacyColor.gray75)))
        .cssTextColor(AxoColor(light: LegacyColor.gray75, dark: LegacyColor.gray15))
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }
}

extension LeftPaneBanner where Content == CSSText {
    public init(actionText: String, onClick: @escaping () -> Void, text: String) {
        self.init(actionText: actionText, onClick: onClick) { CSSText(text, style: LegacyType.body2()) }
    }
}
