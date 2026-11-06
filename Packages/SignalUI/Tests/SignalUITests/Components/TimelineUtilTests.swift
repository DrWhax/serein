import Foundation
import Testing
@testable import SignalUI

@Suite struct TimelineUtilTests {
    var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)    // 2023-11-14 22:13 UTC

    @Test func groupsSameAuthorWithinThreeMinutesSameDay() {
        let a = TimelineGroupingInfo(authorId: "a", timestamp: t0)
        #expect(TimelineUtil.areMessagesInSameGroup(a, unreadIndicator: false, .init(authorId: "a", timestamp: t0 + 179), calendar: utc))
        #expect(!TimelineUtil.areMessagesInSameGroup(a, unreadIndicator: false, .init(authorId: "a", timestamp: t0 + 180), calendar: utc))
        #expect(!TimelineUtil.areMessagesInSameGroup(a, unreadIndicator: false, .init(authorId: "b", timestamp: t0 + 1), calendar: utc))
        #expect(!TimelineUtil.areMessagesInSameGroup(a, unreadIndicator: true, .init(authorId: "a", timestamp: t0 + 1), calendar: utc))
        #expect(!TimelineUtil.areMessagesInSameGroup(a, unreadIndicator: false, .init(authorId: "a", timestamp: t0 - 1), calendar: utc))
        var reacted = a
        reacted.hasReactions = true
        #expect(!TimelineUtil.areMessagesInSameGroup(reacted, unreadIndicator: false, .init(authorId: "a", timestamp: t0 + 1), calendar: utc))
        // 23:59 → 00:00 is a new day.
        let late = Date(timeIntervalSince1970: 1_700_006_340)
        let acrossMidnight = TimelineUtil.areMessagesInSameGroup(.init(authorId: "a", timestamp: late), unreadIndicator: false,
                                                                 .init(authorId: "a", timestamp: late + 120), calendar: utc)
        #expect(!acrossMidnight)
    }

    @Test func hidesMetadataOnlyForSettledGroupedMessages() {
        let next = TimelineGroupingInfo(authorId: "a", timestamp: t0 + 1)
        #expect(TimelineUtil.shouldHideMetadata(grouped: true, .init(authorId: "a", timestamp: t0, status: .delivered), next))
        #expect(TimelineUtil.shouldHideMetadata(grouped: true, .init(authorId: "a", timestamp: t0), next))
        #expect(!TimelineUtil.shouldHideMetadata(grouped: true, .init(authorId: "a", timestamp: t0, status: .sending), next))
        #expect(!TimelineUtil.shouldHideMetadata(grouped: false, .init(authorId: "a", timestamp: t0), next))
        var deleted = next
        deleted.deletedForEveryone = true
        #expect(!TimelineUtil.shouldHideMetadata(grouped: true, .init(authorId: "a", timestamp: t0), deleted))
    }

    @Test func dateHeaderOnOldestAndNewDay() {
        let a = TimelineGroupingInfo(authorId: "a", timestamp: t0)
        #expect(TimelineUtil.shouldRenderDateHeader(isOldest: true, a, previous: nil, calendar: utc))
        #expect(!TimelineUtil.shouldRenderDateHeader(isOldest: false, .init(authorId: "a", timestamp: t0 + 60), previous: a, calendar: utc))
        #expect(TimelineUtil.shouldRenderDateHeader(isOldest: false, .init(authorId: "a", timestamp: t0 + 86_400), previous: a, calendar: utc))
        #expect(!TimelineUtil.shouldRenderDateHeader(isOldest: false, .init(authorId: "a", timestamp: t0 - 86_400), previous: a, calendar: utc))
    }
}
