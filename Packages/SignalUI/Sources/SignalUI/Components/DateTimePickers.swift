// Ports of ts/components/DatePicker.dom.tsx and TimePicker.dom.tsx (react-aria fields): a date
// field (MM/DD/YYYY segments, a calendar button opening a month grid) and a time field
// (h:mm AM segments, a chevron opening hour / minute / period columns).
//
// Fields: rounded-lg, a 2.5px transparent border (Blink draws 2px), fill-primary, px-2 py-0.5;
// segments are body-medium with 1px side padding.

import SwiftUI

/// A calendar day (`CalendarDate`).
public struct CalendarDay: Sendable, Hashable, Comparable {
    public var year: Int, month: Int, day: Int
    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }
    public init(_ date: Date, in zone: TimeZone) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }
    func date(in zone: TimeZone, hour: Int = 0, minute: Int = 0) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))
    }
    func adding(days: Int) -> CalendarDay {
        let zone = TimeZone(identifier: "UTC") ?? .current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return date(in: zone).flatMap { cal.date(byAdding: .day, value: days, to: $0) }.map { CalendarDay($0, in: zone) } ?? self
    }
    public static func < (a: CalendarDay, b: CalendarDay) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }
}

/// The field chrome shared by both pickers.
struct DateTimeFieldChrome<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        HStack(spacing: 0) { content }
            .padding(.horizontal, 8)
            .padding(.horizontal, 2)                  // border-[2.5px] (drawn 2px)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(AxoColor.fillPrimary))
    }
}

/// `DateSegment`: inline-block px-px type-body-medium.
struct DateTimeSegment: View {
    let text: String
    var disabled = false
    var leading: CGFloat = 1
    var body: some View {
        CSSText(text, type: .bodyMedium, wrap: .nowrap, color: disabled ? .labelPlaceholder : .labelPrimary)
            .padding(.leading, leading).padding(.trailing, 1)
    }
}

public struct DatePicker: View {
    @Binding var value: CalendarDay?
    let minValue: CalendarDay?
    let disabled: Bool
    let label: String
    @State private var open = false
    @State private var shownMonth: CalendarDay?
    @Environment(\.i18n) var i18n

    public init(value: Binding<CalendarDay?>, minValue: CalendarDay? = nil, disabled: Bool = false, label: String) {
        _value = value
        self.minValue = minValue
        self.disabled = disabled
        self.label = label
    }

    func two(_ n: Int) -> String { n < 10 ? "0\(n)" : String(n) }

    public var body: some View {
        // shouldForceLeadingZeros, en-US order.
        DateTimeFieldChrome {
            if let v = value {
                DateTimeSegment(text: two(v.month), disabled: disabled)
                DateTimeSegment(text: "/", disabled: disabled)
                DateTimeSegment(text: two(v.day), disabled: disabled)
                DateTimeSegment(text: "/", disabled: disabled)
                DateTimeSegment(text: String(v.year), disabled: disabled)
            } else {
                DateTimeSegment(text: "mm/dd/yyyy", disabled: true)
            }
            Spacer(minLength: 0)
            SwiftUI.Button { if !disabled { open.toggle() } } label: {
                AxoSymbol.Icon("calendar", size: 14, label: nil).cssTextColor(disabled ? .labelPlaceholder : .labelPrimary)
                    .padding(2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(i18n("icu:DatePicker__popupTitle"))
            .popover(isPresented: $open, arrowEdge: .bottom) { calendar }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    /// The popover's Calendar: a header (previous, month heading, next) and a short-weekday grid.
    var calendar: some View {
        let month = shownMonth ?? value ?? minValue ?? CalendarDay(Date(), in: .current)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let first = CalendarDay(year: month.year, month: month.month, day: 1)
        let firstDate = first.date(in: cal.timeZone) ?? Date()
        let weekday = cal.component(.weekday, from: firstDate) - 1
        let days = cal.range(of: .day, in: .month, for: firstDate)?.count ?? 30
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = cal.timeZone
        f.dateFormat = "MMMM yyyy"
        let heading = f.string(from: firstDate)
        let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        func shift(_ months: Int) {
            let d = cal.date(byAdding: .month, value: months, to: firstDate) ?? firstDate
            shownMonth = CalendarDay(d, in: cal.timeZone)
        }
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                SwiftUI.Button { shift(-1) } label: { AxoSymbol.Icon("chevron-[start]", size: 14, label: nil).padding(4) }.buttonStyle(.plain)
                Spacer()
                CSSText(heading, type: AxoType.bodyMedium.weight(500), color: .labelPrimary)
                Spacer()
                SwiftUI.Button { shift(1) } label: { AxoSymbol.Icon("chevron-[end]", size: 14, label: nil).padding(4) }.buttonStyle(.plain)
            }
            .padding(8)
            .overlay(alignment: .bottom) { Rectangle().fill(AxoColor.borderPrimary).frame(height: 1) }
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow { ForEach(weekdays, id: \.self) { CSSText($0, type: AxoType.bodySmall.weight(500), color: .labelSecondary).frame(width: 36) } }
                ForEach(0..<((weekday + days + 6) / 7), id: \.self) { row in
                    GridRow {
                        ForEach(0..<7, id: \.self) { col in
                            let n = row * 7 + col - weekday + 1
                            if n >= 1 && n <= days {
                                let d = CalendarDay(year: month.year, month: month.month, day: n)
                                let off = minValue.map { d < $0 } ?? false
                                SwiftUI.Button {
                                    value = d
                                    open = false
                                } label: {
                                    CSSText(String(n), type: .bodyMedium, color: off ? .labelDisabled : .labelPrimary)
                                        .frame(width: 36, height: 32)
                                        .background { if d == value { RoundedRectangle(cornerRadius: 8).fill(AxoColor.fillSecondaryPressed) } }
                                }
                                .buttonStyle(.plain)
                                .disabled(off)
                            } else {
                                Color.clear.frame(width: 36, height: 32)
                            }
                        }
                    }
                }
            }
            .padding(6)
        }
        .background(AxoColor.surfaceSecondary)
    }
}

public struct TimePicker: View {
    /// HHMM (e.g. 800 for 8:00, 1730 for 17:30).
    @Binding var time: Int
    let disabled: Bool
    let label: String
    let use24HourTime: Bool
    @State private var open = false
    @Environment(\.i18n) var i18n

    public init(time: Binding<Int>, disabled: Bool = false, label: String, use24HourTime: Bool = false) {
        _time = time
        self.disabled = disabled
        self.label = label
        self.use24HourTime = use24HourTime
    }

    /// `getTimeDetails`
    static func details(_ time: Int, use24: Bool) -> (hours: Int, minutes: Int, pm: Bool?) {
        let h = time / 100, m = time % 100
        if use24 { return (h, m, nil) }
        if h == 0 { return (12, m, false) }
        if h == 12 { return (12, m, true) }
        return h > 12 ? (h - 12, m, true) : (h, m, false)
    }

    /// `makeTime`
    static func make(_ hours: Int, _ minutes: Int, pm: Bool?) -> Int {
        guard let pm else { return hours * 100 + minutes }
        let h = !pm && hours == 12 ? 0 : pm && hours < 12 ? hours + 12 : hours
        return h * 100 + minutes
    }

    func two(_ n: Int) -> String { n < 10 ? "0\(n)" : String(n) }

    public var body: some View {
        let d = Self.details(time, use24: use24HourTime)
        DateTimeFieldChrome {
            // DateInput: inline-flex, min-w 5em (at 13px); the hour grows, end-aligned.
            HStack(spacing: 0) {
                DateTimeSegment(text: use24HourTime ? two(d.hours) : String(d.hours), disabled: disabled)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                DateTimeSegment(text: i18n("icu:NotificationProfile--time-separator"), disabled: disabled)
                DateTimeSegment(text: two(d.minutes), disabled: disabled)
                if let pm = d.pm {
                    DateTimeSegment(text: i18n(pm ? "icu:NotificationProfile--pm" : "icu:NotificationProfile--am"), disabled: disabled, leading: 2)
                }
            }
            .frame(minWidth: 65)
            .fixedSize()
            SwiftUI.Button { if !disabled { open.toggle() } } label: {
                AxoSymbol.Icon("chevron-down", size: 14, label: i18n("icu:NotificationProfiles--open-time-picker"))
                    .cssTextColor(disabled ? .labelPlaceholder : .labelPrimary)
                    .padding(2)
            }
            .buttonStyle(.plain)
            .padding(.leading, 12)
            .popover(isPresented: $open, arrowEdge: .bottom) { popup(d) }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    /// The popup: 244px of scrolling hour / minute (/ AM-PM) columns, 46px wide.
    func popup(_ d: (hours: Int, minutes: Int, pm: Bool?)) -> some View {
        func column<T: Hashable>(_ items: [T], selected: T, text: @escaping (T) -> String, pick: @escaping (T) -> Void) -> some View {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(items, id: \.self) { item in
                            SwiftUI.Button { pick(item) } label: {
                                CSSText(text(item), type: .bodyMedium, color: .labelPrimary)
                                    .frame(width: 46).padding(.vertical, 9.5)
                                    .background { if item == selected { RoundedRectangle(cornerRadius: 4).fill(AxoColor.fillPrimary) } }
                            }
                            .buttonStyle(.plain)
                            .id(item)
                        }
                    }
                }
                .frame(width: 46)
                .onAppear { proxy.scrollTo(selected, anchor: .top) }
            }
        }
        let hours = use24HourTime ? Array(0..<24) : Array(1..<13)
        return HStack(spacing: 2) {
            column(hours, selected: d.hours, text: { String($0) }) { time = Self.make($0, d.minutes, pm: d.pm) }
            column(Array(0..<60), selected: d.minutes, text: { two($0) }) { time = Self.make(d.hours, $0, pm: d.pm) }
            if let pm = d.pm {
                column([false, true], selected: pm, text: { i18n($0 ? "icu:NotificationProfile--pm" : "icu:NotificationProfile--am") }) {
                    time = Self.make(d.hours, d.minutes, pm: $0)
                }
            }
        }
        .padding(4)
        .frame(height: 244)
        .background(AxoColor.surfaceSecondary)
    }
}

/// `MuteUntilDialog`: mute until a chosen date and time (default: tomorrow 8:00).
public struct MuteUntilDialog: View {
    let now: Date
    let onSubmit: (Date) -> Void
    let onClose: () -> Void
    @State private var date: CalendarDay?
    @State private var time = 800
    @Environment(\.i18n) var i18n
    @Environment(\.timeZone) var zone

    public init(now: Date = Date(), onSubmit: @escaping (Date) -> Void = { _ in }, onClose: @escaping () -> Void = {}) {
        self.now = now
        self.onSubmit = onSubmit
        self.onClose = onClose
    }

    var muteExpiresAt: Date? {
        let d = date ?? CalendarDay(now, in: zone).adding(days: 1)
        let (h, m, _) = TimePicker.details(time, use24: true)
        return d.date(in: zone, hour: h, minute: m)
    }

    /// `getTimeZoneDisplayName`: the zone's long generic name ("Western European Time").
    var timeZoneName: String {
        zone.localizedName(for: .generic, locale: Locale(identifier: "en_US")) ?? zone.identifier
    }

    public var body: some View {
        let today = CalendarDay(now, in: zone)
        let dateBinding = Binding<CalendarDay?>(get: { date ?? today.adding(days: 1) }, set: { date = $0 })
        let valid = muteExpiresAt.map { $0 > now } ?? false
        AxoDialog.Content(size: .sm) {
            AxoDialog.Header {
                AxoDialog.Title(i18n("icu:MuteUntilDialog__title"))
                AxoDialog.Close(action: onClose)
            }
            AxoDialog.Body {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        DatePicker(value: dateBinding, minValue: today, label: i18n("icu:MuteUntilDialog__dateLabel"))
                        TimePicker(time: $time, label: i18n("icu:MuteUntilDialog__timeLabel"))
                    }
                    .padding(.bottom, 10)
                    CSSText(i18n("icu:MuteUntilDialog__timeZoneNote", ["timeZone": .string(timeZoneName)]), type: .bodyMedium, color: .labelSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            AxoDialog.Footer {
                AxoDialog.Actions {
                    AxoDialog.Action(i18n("icu:cancel"), variant: .subtleSecondary, action: onClose)
                    AxoDialog.Action(i18n("icu:mute"), variant: .strongPrimary, disabled: !valid) {
                        if let at = muteExpiresAt { onSubmit(at) }
                    }
                }
            }
        }
    }
}
