// mapItemsIntoCollapseSets (ts/util/CollapseSet.std.ts): the timeline's items folded into
// collapse sets. Consecutive group updates (with the other chat-update notices: safety number
// and verification changes, profile and number changes, pins, ended polls), consecutive timer
// changes, or consecutive call events become one set, at most 50 and never across a day or the
// oldest unseen item; everything else is a set of its own (`none`). A group change carrying
// several changes is a set by itself.
//
// Subset: upstream's multiday sets (`allowMultidaySets`, and `maybeSplitLastCollapseSet` for
// them) are off in its timeline and are left out here.

import Foundation

/// The kind of a collapse set that folds (`CollapseSet['type']` other than `none`).
public enum CollapseSetKind: Sendable, Hashable {
    case groupUpdates
    /// `endingState`: the last timer set, in seconds (nil / 0: disabled).
    case timerChanges(endingState: Int?)
    case callEvents
}

/// `CollapseSet`: one timeline row. `kind` nil is upstream's `none` (one item, no messages).
public struct CollapseSet: Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: CollapseSetKind?
    public var messages: [CollapsedMessage]
    public init(id: String, kind: CollapseSetKind?, messages: [CollapsedMessage] = []) {
        self.id = id
        self.kind = kind
        self.messages = messages
    }
}

/// What the grouping needs to know of one timeline item.
public struct CollapseSetItem: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// A message, or a notice that never folds.
        case other
        /// `canCollapseForGroupSet`; `changes`: a group change's number of changes (1 otherwise).
        /// A group change that terminated the group is `other`.
        case groupUpdate(changes: Int)
        /// `canCollapseForTimerSet`: the timer set, in seconds (nil / 0: disabled).
        case timerChange(Int?)
        /// `canCollapseForCallSet`: a call event (one for the call in progress is `other`).
        case callEvent
    }
    public var id: String
    public var kind: Kind
    public var isUnseen: Bool
    /// The item's day (any instant in it: days are compared by the calendar).
    public var date: Date
    public init(id: String, kind: Kind, isUnseen: Bool = false, date: Date) {
        self.id = id
        self.kind = kind
        self.isUnseen = isUnseen
        self.date = date
    }

    var changes: Int { if case .groupUpdate(let n) = kind { n } else { 1 } }
    var extraItems: Int { max(0, changes - 1) }
}

public enum CollapseSets {
    /// `MAX_COLLAPSE_SET_SIZE`
    public static let maxSize = 50

    /// `mapItemsIntoCollapseSets`: the sets, and the oldest unseen and scroll-to item indices as
    /// set indices.
    public static func map(_ items: [CollapseSetItem], oldestUnseenIndex: Int? = nil, scrollToIndex: Int? = nil,
                           calendar: Calendar = .current) -> (sets: [CollapseSet], unseenIndex: Int?, scrollToIndex: Int?) {
        var sets: [CollapseSet] = []
        var unseenIndex = oldestUnseenIndex, scrollIndex = scrollToIndex
        for (i, item) in items.enumerated() {
            // A group change with more than one change is a set all by itself.
            let single = item.extraItems > 0
                ? CollapseSet(id: item.id, kind: .groupUpdates,
                              messages: [CollapsedMessage(id: item.id, isUnseen: item.isUnseen, extraItems: item.extraItems)])
                : CollapseSet(id: item.id, kind: nil)
            if i == scrollToIndex { scrollIndex = sets.count }
            if i == oldestUnseenIndex { unseenIndex = sets.count }
            // The first item, and the oldest unseen one, start a new set.
            guard i > 0, i != oldestUnseenIndex, let last = sets.last else {
                sets.append(single)
                continue
            }
            let previous = items[i - 1]
            let atDateBoundary = !calendar.isDate(item.date, inSameDayAs: previous.date)
            let canContinue = (last.kind == nil || last.messages.count < maxSize) && !atDateBoundary
            let kind: CollapseSetKind? = switch (previous.kind, item.kind) {
            case (.groupUpdate, .groupUpdate): .groupUpdates
            case (.timerChange, .timerChange(let seconds)): .timerChanges(endingState: seconds)
            case (.callEvent, .callEvent): .callEvents
            default: nil
            }
            guard canContinue, let kind else {
                sets.append(single)
                continue
            }
            let message = CollapsedMessage(id: item.id, isUnseen: item.isUnseen, extraItems: item.extraItems, atDateBoundary: atDateBoundary)
            if last.kind == nil {
                // The previous item's own set becomes this kind of set.
                sets[sets.count - 1] = CollapseSet(id: previous.id, kind: kind,
                                                   messages: [CollapsedMessage(id: previous.id, isUnseen: previous.isUnseen), message])
            } else {
                sets[sets.count - 1].messages.append(message)
                sets[sets.count - 1].kind = kind     // a timer set ends in the latest timer
            }
            if i == scrollToIndex { scrollIndex = sets.count - 1 }
            if i == oldestUnseenIndex { unseenIndex = sets.count - 1 }
        }
        return (sets, unseenIndex, scrollIndex)
    }
}
