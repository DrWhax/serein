// Server alerts in the left pane (ts/components/ServerAlerts.dom.tsx): the critical (account at
// risk) and warning idle-primary-device banners.

import SignalI18n
import SwiftUI

/// `ServerAlert`
public enum ServerAlert: Sendable { case criticalIdlePrimaryDevice, idlePrimaryDevice }

/// CriticalIdlePrimaryDeviceDialog: a warning banner with a "Learn more" link in the body.
public struct CriticalIdlePrimaryDeviceDialog: View {
    static let supportPage = "https://support.signal.org/hc/articles/8997185514138-Re-connect-your-primary-device-to-continue-using-Signal-Desktop"
    let containerWidthBreakpoint: WidthBreakpoint
    @Environment(\.i18n) var i18n
    @Environment(\.openURL) var openURL

    public init(containerWidthBreakpoint: WidthBreakpoint) { self.containerWidthBreakpoint = containerWidthBreakpoint }

    public var body: some View {
        let runs = CSSTextRun.runs(i18n.richText("icu:CriticalIdlePrimaryDevice__body"),
                                   tags: ["learnMoreLink": I18nTagStyle(fontName: AxoFonts.interName(weight: 700), action: "learnMore")])
        LeftPaneDialog(type: .warning, title: i18n("icu:CriticalIdlePrimaryDevice__title"), containerWidthBreakpoint: containerWidthBreakpoint) {
            CSSText(runs: runs, style: LeftPaneDialog<EmptyView>.textStyle, onTap: { _ in
                if let url = URL(string: Self.supportPage) { openURL(url) }
            })
        }
    }
}

/// WarningIdlePrimaryDeviceDialog: an info banner with a yellow-disc icon, the body and a bold
/// "Learn more" link (the whole banner is the link when narrow); dismissable once.
public struct WarningIdlePrimaryDeviceDialog: View {
    let containerWidthBreakpoint: WidthBreakpoint
    let handleClose: (() -> Void)?
    @Environment(\.i18n) var i18n
    @Environment(\.openURL) var openURL

    public init(containerWidthBreakpoint: WidthBreakpoint, handleClose: (() -> Void)? = nil) {
        self.containerWidthBreakpoint = containerWidthBreakpoint
        self.handleClose = handleClose
    }

    static let supportPage = "https://support.signal.org/hc/articles/9021007554074-Open-Signal-on-your-phone-to-keep-your-account-active"

    func learnMore() {
        if let url = URL(string: Self.supportPage) { openURL(url) }
    }

    public var body: some View {
        let narrow = containerWidthBreakpoint == .narrow
        let icon = AnyView(LeftPaneDialogIconBackground { SignalIcon("v3/error/error-circle", size: 20, color: AxoColor(LegacyColor.black)) })
        let onClick: (() -> Void)? = narrow ? { learnMore() } : nil
        let clickLabel: String? = narrow ? i18n("icu:IdlePrimaryDevice__learnMore") : nil
        let closeLabel: String? = handleClose == nil ? nil : i18n("icu:close")
        return LeftPaneDialog(type: .info, icon: .custom(icon), containerWidthBreakpoint: containerWidthBreakpoint, onClick: onClick,
                              clickLabel: clickLabel, onClose: handleClose, closeLabel: closeLabel) { message(narrow: narrow) }
    }

    @ViewBuilder func message(narrow: Bool) -> some View {
        CSSText(i18n("icu:IdlePrimaryDevice__body"), style: LeftPaneDialog<EmptyView>.textStyle)
        if !narrow {
            CSSText(runs: [CSSTextRun(i18n("icu:IdlePrimaryDevice__learnMore"), fontName: AxoFonts.interName(weight: 700), action: "learnMore")],
                    style: LeftPaneDialog<EmptyView>.textStyle, onTap: { _ in learnMore() })
        }
    }
}
