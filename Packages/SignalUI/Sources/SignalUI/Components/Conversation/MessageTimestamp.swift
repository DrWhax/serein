// MessageTimestamp (ts/components/conversation/MessageTimestamp.dom.tsx): `formatTime` of the
// timestamp ("Now", "5m", then the time, or "1h"… when relative), refreshed every minute, in
// the inherited text style.

import SignalI18n
import SwiftUI

public struct MessageTimestamp: View {
    let timestamp: Date
    let isRelativeTime: Bool
    let style: CSSTextStyle
    let color: AxoColor?
    @Environment(\.i18n) var i18n
    @Environment(\.timeZone) var timeZone
    @Environment(\.conversationListNow) var fixedNow

    public init(timestamp: Date, isRelativeTime: Bool = false, style: CSSTextStyle = CSSTextStyle(AxoType.bodyLarge), color: AxoColor? = nil) {
        self.timestamp = timestamp
        self.isRelativeTime = isRelativeTime
        self.style = style
        self.color = color
    }

    public var body: some View {
        if let fixedNow {
            label(fixedNow)
        } else {
            TimelineView(.periodic(from: .now, by: 60)) { context in label(context.date) }
        }
    }

    func label(_ now: Date) -> some View {
        CSSText(FormatTimestamp.time(timestamp, now: now, i18n: i18n, timeZone: timeZone, relative: isRelativeTime), style: style,
                wrap: .nowrap, color: color)
            .accessibilityLabel(FormatTimestamp.mediumDateLongTime(timestamp, locale: i18n.locale, timeZone: timeZone))
    }
}
