import Foundation
import Testing
@testable import SignalUI

/// `mapItemsIntoCollapseSets`, after upstream's ts/test-node/util/CollapseSet_test.std.ts (its
/// `allowMultidaySets: false` behaviour, the one its timeline uses).
@Suite struct CollapseSetMappingTests {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    /// Noon, `daysAgo` days before a fixed day.
    static func day(_ daysAgo: Int) -> Date { Date(timeIntervalSince1970: 1_790_000_000 - Double(daysAgo) * 86_400) }

    static func message(_ id: String, _ daysAgo: Int = 1) -> CollapseSetItem { .init(id: id, kind: .other, date: day(daysAgo)) }
    static func group(_ id: String, changes: Int = 1, _ daysAgo: Int = 1, unseen: Bool = false) -> CollapseSetItem {
        .init(id: id, kind: .groupUpdate(changes: changes), isUnseen: unseen, date: day(daysAgo))
    }
    static func timer(_ id: String, _ seconds: Int?, _ daysAgo: Int = 1) -> CollapseSetItem { .init(id: id, kind: .timerChange(seconds), date: day(daysAgo)) }
    static func call(_ id: String, _ daysAgo: Int = 1) -> CollapseSetItem { .init(id: id, kind: .callEvent, date: day(daysAgo)) }

    static func map(_ items: [CollapseSetItem], unseen: Int? = nil, scroll: Int? = nil) -> (sets: [CollapseSet], unseenIndex: Int?, scrollToIndex: Int?) {
        CollapseSets.map(items, oldestUnseenIndex: unseen, scrollToIndex: scroll, calendar: calendar)
    }
    static func none(_ id: String) -> CollapseSet { CollapseSet(id: id, kind: nil) }
    static func m(_ id: String, extra: Int = 0) -> CollapsedMessage { CollapsedMessage(id: id, extraItems: extra) }

    @Test func messagesAreSetsOfTheirOwn() {
        let r = Self.map([Self.message("id0"), Self.message("id1"), Self.message("id2")])
        #expect(r.sets == [Self.none("id0"), Self.none("id1"), Self.none("id2")])
        #expect(r.unseenIndex == nil && r.scrollToIndex == nil)
    }

    /// 'returns single set for all group update items': a change with several changes counts
    /// them as extra items.
    @Test func groupUpdatesFoldIntoOneSet() {
        let r = Self.map([Self.group("id0"), Self.group("id1", changes: 2), Self.group("id2")])
        #expect(r.sets == [CollapseSet(id: "id0", kind: .groupUpdates, messages: [Self.m("id0"), Self.m("id1", extra: 1), Self.m("id2")])])
    }

    /// A group change with several changes is a set by itself, and a terminating change (here
    /// `other`) never folds.
    @Test func severalChangesAreASetAndOthersStayApart() {
        let r = Self.map([Self.message("id0"), Self.group("id1", changes: 3), Self.message("id2"), Self.group("id3"), Self.message("id4")])
        #expect(r.sets == [Self.none("id0"), CollapseSet(id: "id1", kind: .groupUpdates, messages: [Self.m("id1", extra: 2)]),
                           Self.none("id2"), Self.none("id3"), Self.none("id4")])
    }

    /// 'returns single set for all timer change items': the set ends in the last timer.
    @Test func timerChangesEndInTheLastTimer() {
        let r = Self.map([Self.timer("id0", 3600), Self.timer("id1", nil), Self.timer("id2", 300)])
        #expect(r.sets == [CollapseSet(id: "id0", kind: .timerChanges(endingState: 300), messages: [Self.m("id0"), Self.m("id1"), Self.m("id2")])])
    }

    @Test func callEventsFold() {
        let r = Self.map([Self.call("id0"), Self.call("id1"), Self.call("id2")])
        #expect(r.sets == [CollapseSet(id: "id0", kind: .callEvents, messages: [Self.m("id0"), Self.m("id1"), Self.m("id2")])])
    }

    /// 'returns a combination of sets for combination of items': each kind folds only with its own.
    @Test func eachKindFoldsWithItsOwn() {
        let r = Self.map([Self.message("id0"), Self.group("id1"), Self.group("id2"), Self.timer("id3", 60), Self.timer("id4", 120),
                          Self.call("id5"), Self.call("id6"), Self.group("id7"), Self.call("id8"), Self.message("id9")])
        #expect(r.sets == [Self.none("id0"),
                           CollapseSet(id: "id1", kind: .groupUpdates, messages: [Self.m("id1"), Self.m("id2")]),
                           CollapseSet(id: "id3", kind: .timerChanges(endingState: 120), messages: [Self.m("id3"), Self.m("id4")]),
                           CollapseSet(id: "id5", kind: .callEvents, messages: [Self.m("id5"), Self.m("id6")]),
                           Self.none("id7"), Self.none("id8"), Self.none("id9")])
    }

    /// 'splits sets across the lastSeenIndex'
    @Test func theOldestUnseenItemStartsASet() {
        let items = [Self.group("id0"), Self.group("id1", changes: 2), Self.group("id2"), Self.group("id3")]
        let r = Self.map(items, unseen: 2)
        #expect(r.sets == [CollapseSet(id: "id0", kind: .groupUpdates, messages: [Self.m("id0"), Self.m("id1", extra: 1)]),
                           CollapseSet(id: "id2", kind: .groupUpdates, messages: [Self.m("id2"), Self.m("id3")])])
        #expect(r.unseenIndex == 1)
    }

    /// 'splits timer events and updates endingState properly': a new day starts a new set.
    @Test func aNewDayStartsASet() {
        let r = Self.map([Self.timer("id0", 3600, 2), Self.timer("id1", 7200, 2), Self.timer("id2", 10800), Self.timer("id3", 14400), Self.message("id4")])
        #expect(r.sets == [CollapseSet(id: "id0", kind: .timerChanges(endingState: 7200), messages: [Self.m("id0"), Self.m("id1")]),
                           CollapseSet(id: "id2", kind: .timerChanges(endingState: 14400), messages: [Self.m("id2"), Self.m("id3")]),
                           Self.none("id4")])
    }

    /// 'if allowMultidaySets=false, generates a set for each day'
    @Test func aSetForEachDay() {
        let items = [Self.message("id0", 4), Self.group("id1", changes: 2, 4), Self.group("id2", 4),
                     Self.group("id3", 3), Self.group("id4", 3), Self.group("id5", 3),
                     Self.group("id6", 2), Self.group("id7", 2),
                     Self.group("id8"), Self.group("id9"), Self.message("id10")]
        #expect(Self.map(items).sets == [
            Self.none("id0"),
            CollapseSet(id: "id1", kind: .groupUpdates, messages: [Self.m("id1", extra: 1), Self.m("id2")]),
            CollapseSet(id: "id3", kind: .groupUpdates, messages: [Self.m("id3"), Self.m("id4"), Self.m("id5")]),
            CollapseSet(id: "id6", kind: .groupUpdates, messages: [Self.m("id6"), Self.m("id7")]),
            CollapseSet(id: "id8", kind: .groupUpdates, messages: [Self.m("id8"), Self.m("id9")]),
            Self.none("id10"),
        ])
    }

    /// 'limits collapse set size based on MAX_COLLAPSE_SET_SIZE'
    @Test func setsHoldAtMostFifty() {
        let items = (0...(CollapseSets.maxSize * 3)).map { Self.group("id\($0)") }
        let sets = Self.map(items).sets
        #expect(sets.map(\.messages.count) == [50, 50, 50, 0])
        #expect(sets.last?.kind == nil)
    }

    /// Unseen flags are kept, and the scroll target and divider move to their sets.
    @Test func indicesFollowTheirSets() {
        let items = [Self.message("id0"), Self.call("id1"), Self.call("id2"), .init(id: "id3", kind: .callEvent, isUnseen: true, date: Self.day(1)),
                     Self.message("id4")]
        let r = Self.map(items, unseen: 3, scroll: 2)
        #expect(r.sets == [Self.none("id0"), CollapseSet(id: "id1", kind: .callEvents, messages: [Self.m("id1"), Self.m("id2")]),
                           Self.none("id3"), Self.none("id4")])
        #expect(r.scrollToIndex == 1 && r.unseenIndex == 2)
        let unseenLater = Self.map([Self.call("id0"), .init(id: "id1", kind: .callEvent, isUnseen: true, date: Self.day(1))])
        #expect(unseenLater.sets == [CollapseSet(id: "id0", kind: .callEvents, messages: [Self.m("id0"), CollapsedMessage(id: "id1", isUnseen: true)])])
    }
}
