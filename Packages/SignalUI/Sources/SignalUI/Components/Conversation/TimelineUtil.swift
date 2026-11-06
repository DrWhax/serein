// Port of ts/util/timelineUtil.std.ts (areMessagesInSameGroup, shouldCurrentMessageHideMetadata)
// and the date-header rule of ts/state/smart/TimelineItem.preload.tsx.

import Foundation

/// What the grouping rules read from a message timeline item.
public struct TimelineGroupingInfo: Sendable, Hashable {
    public var authorId: String
    public var timestamp: Date
    public var status: MessageStatus?
    public var isEditedMessage = false
    public var deletedForEveryone = false
    public var hasReactions = false
    public init(authorId: String, timestamp: Date, status: MessageStatus? = nil) {
        self.authorId = authorId
        self.timestamp = timestamp
        self.status = status
    }
}

public enum TimelineUtil {
    /// `COLLAPSE_WITHIN`: 3 minutes.
    public static let collapseWithin: TimeInterval = 3 * 60

    public static func areMessagesInSameGroup(_ older: TimelineGroupingInfo?, unreadIndicator: Bool, _ newer: TimelineGroupingInfo?,
                                              calendar: Calendar = .current) -> Bool {
        guard !unreadIndicator, let older, let newer else { return false }
        return !older.hasReactions && older.authorId == newer.authorId
            && (older.isEditedMessage || newer.timestamp >= older.timestamp)
            && newer.timestamp.timeIntervalSince(older.timestamp) < collapseWithin
            && calendar.isDate(older.timestamp, inSameDayAs: newer.timestamp)
    }

    public static func shouldHideMetadata(grouped: Bool, _ item: TimelineGroupingInfo?, _ newer: TimelineGroupingInfo?) -> Bool {
        guard grouped, let item, !item.isEditedMessage, let newer else { return false }
        if newer.deletedForEveryone && !item.deletedForEveryone { return false }
        switch item.status {
        case nil, .sent, .delivered, .read, .viewed: return true
        case .paused, .error, .partialSent, .sending: return false
        }
    }

    public static func shouldRenderDateHeader(isOldest: Bool, _ item: TimelineGroupingInfo?, previous: TimelineGroupingInfo?,
                                              calendar: Calendar = .current) -> Bool {
        if isOldest { return true }
        guard let item, let previous else { return false }
        return item.timestamp > previous.timestamp && !calendar.isDate(previous.timestamp, inSameDayAs: item.timestamp)
    }
}
