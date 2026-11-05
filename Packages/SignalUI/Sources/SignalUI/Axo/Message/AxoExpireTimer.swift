// Port of ts/axo/message/AxoExpireTimer.dom.tsx: the disappearing-message countdown, a
// clock glyph that empties in 12 steps over the timer's duration (updating itself at
// each step), labelled with the expiry date.

import Foundation
import SwiftUI

public enum AxoExpireTimer {
    public struct ExpireTimer: Sendable, Hashable {
        /// Duration in seconds.
        public var duration: Double
        /// When the countdown started; nil = not started yet (full clock).
        public var startedAt: Date?

        public init(duration: Double, startedAt: Date?) {
            self.duration = duration
            self.startedAt = startedAt
        }

        var expiresAt: Date? { startedAt.map { $0.addingTimeInterval(duration) } }
    }

    struct State: Equatable {
        var symbol: AxoSymbol.Name
        var updateAt: Date?
    }

    static func intervalSymbol(_ index: Int) -> AxoSymbol.Name {
        "timer-countdown-\(max(0, 12 - max(0, index)))"
    }

    /// `_getExpireTimerState`: the glyph for `now`, and when it next changes.
    static func state(_ timer: ExpireTimer, now: Date) -> State {
        guard let startedAt = timer.startedAt else { return State(symbol: "timer-countdown-12", updateAt: nil) }
        let durationMs = timer.duration * 1000
        let elapsed = max(0, now.timeIntervalSince(startedAt) * 1000)
        if elapsed >= durationMs { return State(symbol: "timer-countdown-0", updateAt: nil) }
        let interval = (durationMs / 12).rounded(.up)
        let current = Int((elapsed / interval).rounded(.down))
        let next = current + 1
        let symbol = intervalSymbol(current)
        if next > 12 { return State(symbol: symbol, updateAt: nil) }
        return State(symbol: symbol, updateAt: startedAt.addingTimeInterval(interval * Double(next) / 1000))
    }

    /// `_getExpireTimerLabel`: the expiry date, in the user's locale.
    static func label(_ timer: ExpireTimer) -> String {
        (timer.expiresAt ?? Date()).formatted(date: .numeric, time: .omitted)
    }

    /// `<AxoExpireTimer.Root>`
    public struct Root: View {
        let expireTimer: ExpireTimer
        let type: AxoType
        let fixedNow: Date?
        @Environment(\.layoutDirection) var direction

        /// - Parameters:
        ///   - type: the surrounding text the glyph flows with (inherited font).
        ///   - now: a fixed "now" (previews and tests); nil follows the clock.
        public init(expireTimer: ExpireTimer, type: AxoType = .bodyLarge, now: Date? = nil) {
            self.expireTimer = expireTimer
            self.type = type
            self.fixedNow = now
        }

        func glyph(_ now: Date) -> some View {
            let s = AxoExpireTimer.state(expireTimer, now: now)
            return AxoInlineGlyphLine(glyph: AxoSymbol.inlineGlyph(s.symbol, rtl: direction == .rightToLeft), type: type)
        }

        public var body: some View {
            Group {
                if let fixedNow {
                    glyph(fixedNow)
                } else {
                    TimelineView(.periodic(from: expireTimer.startedAt ?? Date(), by: max(0.001, (expireTimer.duration * 1000 / 12).rounded(.up) / 1000))) { context in
                        glyph(context.date)
                    }
                }
            }
            .accessibilityElement()
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityLabel(AxoExpireTimer.label(expireTimer))
        }
    }
}
