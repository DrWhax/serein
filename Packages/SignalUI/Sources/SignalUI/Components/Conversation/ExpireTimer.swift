// ExpireTimer (ts/components/conversation/ExpireTimer.dom.tsx + `.module-expire-timer`): the
// 12px disappearing-message timer glyph for the remaining time in twelfths
// (messagetimer-60 … -00), in the inherited colour; redrawn every length / 12 (≥ 0.5s).

import SwiftUI

public struct ExpireTimer: View {
    let expirationLength: TimeInterval
    let expirationTimestamp: Date?
    let color: AxoColor?
    @Environment(\.conversationListNow) var fixedNow

    /// - Parameter expirationLength: seconds.
    public init(expirationLength: TimeInterval, expirationTimestamp: Date?, color: AxoColor? = nil) {
        self.expirationLength = expirationLength
        self.expirationTimestamp = expirationTimestamp
        self.color = color
    }

    /// `getTimerBucket`: "60", "55" … "05", "00".
    public static func bucket(expiration: Date?, length: TimeInterval, now: Date) -> String {
        guard let expiration else { return "60" }
        let delta = expiration.timeIntervalSince(now)
        if delta < 0 { return "00" }
        if delta > length { return "60" }
        let b = Int((delta / length * 12).rounded(.toNearestOrAwayFromZero))
        return b * 5 < 10 ? "0\(b * 5)" : "\(b * 5)"
    }

    /// `getIncrement`, at least 0.5s.
    var updateInterval: TimeInterval { max(expirationLength < 0 ? 1 : (expirationLength / 12), 0.5) }

    public var body: some View {
        if let fixedNow {
            glyph(fixedNow)
        } else {
            TimelineView(.periodic(from: .now, by: updateInterval)) { glyph($0.date) }
        }
    }

    func glyph(_ now: Date) -> some View {
        SignalIcon("v3/message_timer/messagetimer-" + Self.bucket(expiration: expirationTimestamp, length: expirationLength, now: now),
                   size: 12, color: color)
    }
}
