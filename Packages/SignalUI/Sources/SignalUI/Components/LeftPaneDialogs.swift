// The banners LeftPane shows above the chat list, each a LeftPaneDialog:
// DialogNetworkStatus, DialogRelink, DialogClockSkew, DialogExpiredBuild
// (ts/components/Dialog*.dom.tsx).

import SignalI18n
import SwiftUI

/// `SocketStatus` (ts/types/SocketStatus.std.ts)
public enum SocketStatus: Sendable { case connecting, open, closing, closed }

/// DialogNetworkStatus: outage, connecting (for up to 5 s after a (re)connect), or
/// disconnected/offline with "Click to reconnect."
public struct DialogNetworkStatus: View {
    let containerWidthBreakpoint: WidthBreakpoint
    let isOnline: Bool
    let isOutage: Bool
    let socketStatus: SocketStatus
    let manualReconnect: () -> Void
    @Environment(\.i18n) var i18n
    @State private var isConnecting: Bool
    @State private var timeout: Task<Void, Never>?

    public init(containerWidthBreakpoint: WidthBreakpoint, isOnline: Bool, isOutage: Bool, socketStatus: SocketStatus,
                manualReconnect: @escaping () -> Void = {}) {
        self.containerWidthBreakpoint = containerWidthBreakpoint
        self.isOnline = isOnline
        self.isOutage = isOutage
        self.socketStatus = socketStatus
        self.manualReconnect = manualReconnect
        _isConnecting = State(initialValue: socketStatus == .connecting)
    }

    public var body: some View {
        Group {
            if isOutage {
                LeftPaneDialog(type: .warning, icon: .error, subtitle: i18n("icu:DialogNetworkStatus__outage"),
                               containerWidthBreakpoint: containerWidthBreakpoint)
            } else if isConnecting {
                // `.LeftPaneDialog__spinner-container` (margin-end 18 inside the 24px icon box,
                // so the 22px spinner sits at its start) with a black arc on accent yellow.
                let spinner = Spinner(svgSize: .small, direction: .onAvatar, size: 22, circleColor: AxoColor(LegacyColor.accentYellow),
                                      arcColor: AxoColor(LegacyColor.black))
                    .frame(width: 22, height: 22)
                    .frame(width: 24, height: 24, alignment: .topLeading)
                LeftPaneDialog(type: .warning, icon: .custom(AnyView(spinner)), title: i18n("icu:connecting"),
                               subtitle: i18n("icu:connectingHangOn"), containerWidthBreakpoint: containerWidthBreakpoint)
            } else {
                LeftPaneDialog(type: .warning, icon: .network, title: i18n(isOnline ? "icu:disconnected" : "icu:offline"),
                               subtitle: i18n("icu:checkNetworkConnection"), containerWidthBreakpoint: containerWidthBreakpoint,
                               onClick: reconnect, clickLabel: i18n("icu:connect"), hasAction: true)
            }
        }
        .task(id: isConnecting) {
            guard isConnecting else { return }
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { isConnecting = false }
        }
    }

    func reconnect() {
        isConnecting = true
        manualReconnect()
    }
}

/// DialogRelink: "Unlinked" (linked device) or "No longer registered" (primary).
/// Clicking it on a linked device opens MaybeTransferModal → DeleteDataAndRelinkConfirmationDialog
/// (presented by the caller through `onRelinkClick`).
public struct DialogRelink: View {
    let containerWidthBreakpoint: WidthBreakpoint
    let weArePrimaryDevice: Bool
    let onRelinkClick: () -> Void
    let reregister: () -> Void
    @Environment(\.i18n) var i18n

    public init(containerWidthBreakpoint: WidthBreakpoint, weArePrimaryDevice: Bool = false, onRelinkClick: @escaping () -> Void = {},
                reregister: @escaping () -> Void = {}) {
        self.containerWidthBreakpoint = containerWidthBreakpoint
        self.weArePrimaryDevice = weArePrimaryDevice
        self.onRelinkClick = onRelinkClick
        self.reregister = reregister
    }

    public var body: some View {
        if weArePrimaryDevice {
            LeftPaneDialog(type: .warning, icon: .relink, title: i18n("icu:unregistered"), containerWidthBreakpoint: containerWidthBreakpoint,
                           onClick: reregister, clickLabel: i18n("icu:unregisteredWarning"), hasAction: true)
        } else {
            LeftPaneDialog(type: .warning, icon: .relink, title: i18n("icu:unlinked"), containerWidthBreakpoint: containerWidthBreakpoint,
                           onClick: onRelinkClick, clickLabel: i18n("icu:unlinkedWarning"), hasAction: true)
        }
    }
}

/// DialogClockSkew: the device's date and time (refreshed every 30 s) in an error banner.
public struct DialogClockSkew: View {
    let containerWidthBreakpoint: WidthBreakpoint
    let fixedNow: Date?
    @Environment(\.i18n) var i18n
    @Environment(\.timeZone) var timeZone

    /// - Parameter now: a fixed time (stories/tests); nil follows the clock.
    public init(containerWidthBreakpoint: WidthBreakpoint, now: Date? = nil) {
        self.containerWidthBreakpoint = containerWidthBreakpoint
        self.fixedNow = now
    }

    public var body: some View {
        if let fixedNow {
            dialog(fixedNow)
        } else {
            TimelineView(.periodic(from: .now, by: 30)) { context in dialog(context.date) }
        }
    }

    func dialog(_ now: Date) -> some View {
        LeftPaneDialog(type: .error, containerWidthBreakpoint: containerWidthBreakpoint) {
            CSSText(i18n("icu:clockSkewDetected"), style: LeftPaneDialog<EmptyView>.textStyle)
            CSSText(FormatTimestamp.mediumDateLongTime(now, locale: i18n.locale, timeZone: timeZone), style: LeftPaneDialog<EmptyView>.textStyle)
        }
    }
}

/// DialogExpiredBuild: "This version … has expired." with the download link inline after it.
public struct DialogExpiredBuild: View {
    static let websiteURL = "https://signal.org/download/"
    static let appStoreURL = "https://apps.apple.com/app/signal-private-messenger/id1230208093"
    let containerWidthBreakpoint: WidthBreakpoint
    let isMAS: Bool
    @Environment(\.i18n) var i18n
    @Environment(\.openURL) var openURL

    public init(containerWidthBreakpoint: WidthBreakpoint, isMAS: Bool = false) {
        self.containerWidthBreakpoint = containerWidthBreakpoint
        self.isMAS = isMAS
    }

    public var body: some View {
        LeftPaneDialog(type: .error, containerWidthBreakpoint: containerWidthBreakpoint, onClick: {
            if let url = URL(string: isMAS ? Self.appStoreURL : Self.websiteURL) { openURL(url) }
        }, clickLabel: i18n(isMAS ? "icu:DialogExpiredBuild__upgrade-mas" : "icu:upgrade"), hasAction: true,
           text: i18n("icu:expiredWarning") + " ")
    }
}

/// `formatTimestamp` (ts/util/formatTimestamp.dom.ts) for the Intl styles upstream uses.
public enum FormatTimestamp {
    /// `Intl.DateTimeFormat` for a skeleton (e.g. "jmm" for `{hour: 'numeric', minute: '2-digit'}`).
    public static func format(_ date: Date, template: String, locale: String, timeZone: TimeZone) -> String {
        let loc = Locale(identifier: locale)
        let f = DateFormatter()
        f.locale = loc
        f.timeZone = timeZone
        var pattern = DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: loc) ?? template
        // A date + time skeleton: Apple's ICU joins the two with CLDR's "atTime" glue
        // ("Jan 12, 1970 'at' 1:27 AM"); Chromium's Intl.DateTimeFormat uses the standard
        // medium glue "{1}, {0}" ("Jan 12, 1970, 1:27 AM").
        if template.contains(where: { "jhHk".contains($0) }) && template.contains(where: { "dMy".contains($0) }) {
            pattern = pattern.replacing(#/ '[^']+' /#, with: ", ")
        }
        f.dateFormat = pattern
        return f.string(from: date).replacingOccurrences(of: "\u{202F}", with: " ")
    }

    /// `formatTime`: "Now", "5m", else the clock time.
    public static func time(_ date: Date, now: Date, i18n: Localizer, timeZone: TimeZone, relative: Bool = false) -> String {
        let diff = now.timeIntervalSince(date) * 1000
        if diff < 60_000 { return i18n("icu:justNow") }
        if diff < 3_600_000 { return i18n("icu:minutesAgo", ["minutes": .number(Double(Int(diff / 60_000)))]) }
        if relative { return i18n("icu:hoursAgo", ["hours": .number(Double(Int(diff / 3_600_000)))]) }
        return format(date, template: "jmm", locale: i18n.locale, timeZone: timeZone)
    }

    /// `formatDateTimeShort`: time today (or within the hour), weekday this week and month,
    /// "Nov 4" within 6 months, else "Nov 4, 2025".
    public static func dateTimeShort(_ date: Date, now: Date, i18n: Localizer, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let diff = now.timeIntervalSince(date)
        if diff < 3600 || cal.isDate(date, inSameDayAs: now) { return time(date, now: now, i18n: i18n, timeZone: timeZone) }
        if diff < 7 * 86_400 && cal.isDate(date, equalTo: now, toGranularity: .month) {
            return format(date, template: "EEE", locale: i18n.locale, timeZone: timeZone)
        }
        if abs(diff) < 6 * 30 * 86_400 { return format(date, template: "MMMd", locale: i18n.locale, timeZone: timeZone) }
        return format(date, template: "yMMMd", locale: i18n.locale, timeZone: timeZone)
    }

    /// `{ dateStyle: 'medium', timeStyle: 'long' }`, e.g. "Nov 4, 2026, 2:34:14 PM GMT+1".
    public static func mediumDateLongTime(_ date: Date, locale: String, timeZone: TimeZone) -> String {
        let loc = Locale(identifier: locale)
        let d = DateFormatter(), t = DateFormatter()
        for f in [d, t] {
            f.locale = loc
            f.timeZone = timeZone
        }
        d.dateStyle = .medium
        t.dateFormat = DateFormatter.dateFormat(fromTemplate: "jmmssz", options: 0, locale: loc)
        // ICU's localized GMT format: Intl writes a zero offset as "GMT+0".
        // Chromium's Intl keeps a plain space before the day period where newer ICU data
        // (Foundation) uses U+202F NARROW NO-BREAK SPACE.
        var time = t.string(from: date).replacingOccurrences(of: "\u{202F}", with: " ")
        if timeZone.secondsFromGMT(for: date) == 0, time.hasSuffix("GMT") { time += "+0" }
        return d.string(from: date) + ", " + time
    }
}
