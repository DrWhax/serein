// Port of ts/components/conversation/TimelineDateHeader.dom.tsx (TimelineDateHeader,
// TimelineDate) and TimelineFloatingHeader.dom.tsx + stylesheets/components/
// TimelineFloatingHeader.scss.

import SignalI18n
import SwiftUI

extension FormatTimestamp {
    /// `formatDate`: "Today", "Yesterday", "Wed, Nov 4" within six months, else "Nov 4, 2025".
    public static func date(_ date: Date, now: Date, i18n: Localizer, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        if cal.isDate(date, inSameDayAs: now) { return i18n("icu:today") }
        if let yesterday = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: yesterday) { return i18n("icu:yesterday") }
        if abs(now.timeIntervalSince(date)) < 6 * 30 * 86_400 {
            return format(date, template: "EEEMMMd", locale: i18n.locale, timeZone: timeZone)
        }
        return format(date, template: "yMMMd", locale: i18n.locale, timeZone: timeZone)
    }
}

extension FormatTimestamp {
    /// `formatDateTimeLong`: "Today 12:00 PM", "Yesterday 9:41 AM", else "Nov 2, 2026, 9:41 AM".
    public static func dateTimeLong(_ date: Date, now: Date, i18n: Localizer, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let time = format(date, template: "jmm", locale: i18n.locale, timeZone: timeZone)
        if cal.isDate(date, inSameDayAs: now) { return i18n("icu:timestampFormat__long--today", ["time": .string(time)]) }
        if let yesterday = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: yesterday) {
            return i18n("icu:timestampFormat__long--yesterday", ["time": .string(time)])
        }
        return format(date, template: "yMMMdjmm", locale: i18n.locale, timeZone: timeZone)
    }
}

/// `TimelineDate`: the formatted day, refreshed every minute.
public struct TimelineDate: View {
    let timestamp: Date
    let style: CSSTextStyle
    let color: AxoColor
    @Environment(\.i18n) var i18n
    @Environment(\.conversationListNow) var fixedNow
    @Environment(\.timeZone) var timeZone

    public init(timestamp: Date, style: CSSTextStyle = CSSTextStyle(AxoType.bodyMedium), color: AxoColor = .labelSecondary) {
        self.timestamp = timestamp
        self.style = style
        self.color = color
    }

    public var body: some View {
        if let fixedNow {
            text(now: fixedNow)
        } else {
            TimelineView(.everyMinute) { context in text(now: context.date) }
        }
    }

    func text(now: Date) -> some View {
        CSSText(FormatTimestamp.date(timestamp, now: now, i18n: i18n, timeZone: timeZone), style: style, wrap: .nowrap, color: color)
            .accessibilityAddTraits(.isHeader)
    }
}

/// `TimelineDateHeader`: the day centred with 20px padding (no top padding when asked); in
/// the Signal chat a bordered pill, type-body-small medium.
public struct TimelineDateHeader: View {
    let timestamp: Date
    let isSignalConversation: Bool
    let noPaddingTop: Bool

    public init(timestamp: Date, isSignalConversation: Bool = false, noPaddingTop: Bool = false) {
        self.timestamp = timestamp
        self.isSignalConversation = isSignalConversation
        self.noPaddingTop = noPaddingTop
    }

    public var body: some View {
        Group {
            if isSignalConversation {
                TimelineDate(timestamp: timestamp, style: CSSTextStyle(AxoType.bodySmall.weight(500)),
                             color: AxoColor(light: AxoColor.labelSecondary.light, dark: AxoColor.labelSecondaryOncolor.dark))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(AxoColor.legacySignalConversationBg))
                    .overlay(Capsule().strokeBorder(AxoColor.borderSecondary, lineWidth: 1))
            } else {
                TimelineDate(timestamp: timestamp)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, noPaddingTop ? 0 : 20)
        .padding(.bottom, 20)
    }
}

/// `TimelineFloatingHeader`: the oldest visible message's day, pinned 10px below the top of
/// the timeline (centred, 14px kept clear for the scrollbar), fading in while scrolling; a
/// spinner in a white (gray-80) shadowed circle 12px below while older messages load.
public struct TimelineFloatingHeader: View {
    let timestamp: Date
    let visible: Bool
    let isLoading: Bool
    @State private var showSpinner: Bool
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    public init(timestamp: Date, visible: Bool, isLoading: Bool = false) {
        self.timestamp = timestamp
        self.visible = visible
        self.isLoading = isLoading
        _showSpinner = State(initialValue: isLoading)
    }

    static let nodeShadow = AxoShadow(light: [AxoShadowLayer(inset: false, x: 0, y: 1, blur: 4, spread: 0, color: LegacyColor.blackAlpha20)],
                                      dark: [AxoShadowLayer(inset: false, x: 0, y: 1, blur: 4, spread: 0, color: LegacyColor.blackAlpha20)])

    public var body: some View {
        VStack(spacing: 0) {
            // rounded-full bg-material-tertiary px-2.5 py-1.5 type-body-medium text-secondary
            // shadow-elevation-1 backdrop-blur-thin
            TimelineDate(timestamp: timestamp)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(AxoColor.materialTertiary))
                .axoShadow(.shadowElevation1, in: Capsule())
            if showSpinner {
                Spinner(svgSize: .small, direction: .onBackground, size: 20)
                    .padding(6)
                    .background(Circle().fill(AxoColor(light: LegacyColor.white, dark: LegacyColor.gray80)))
                    .axoShadow(Self.nodeShadow, in: Circle())
                    .padding(.top, 12)
                    .opacity(isLoading ? 1 : 0)
                    .animation(reduceMotion ? nil : .linear(duration: 0.25).delay(0.3), value: isLoading)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.trailing, 14)
        .padding(.top, 10)
        .opacity(visible ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: visible)
        .allowsHitTesting(false)
        .accessibilityHidden(!visible)
        .task(id: isLoading) {
            if isLoading { showSpinner = true; return }
            guard showSpinner else { return }
            try? await Task.sleep(for: .milliseconds(550))
            if !Task.isCancelled { showSpinner = false }
        }
    }
}
