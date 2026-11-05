// Port of ts/components/conversation/conversation-details/CallHistoryGroupPanelSection.dom.tsx:
// the call history group's day as the list header, then one text item per call (the call's
// kind, and its time: "Now", "30m", else the clock time).

import SignalI18n
import SwiftUI

/// `CallHistoryGroup` (the parts the panel shows).
public struct CallHistoryGroup: Sendable, Hashable {
    public struct Child: Sendable, Hashable {
        public var callId: String
        public var timestamp: Date
        public init(callId: String, timestamp: Date) {
            self.callId = callId
            self.timestamp = timestamp
        }
    }
    public var type: CallType
    public var direction: CallDirection
    public var status: CallStatus
    public var timestamp: Date
    public var children: [Child]
    public init(type: CallType, direction: CallDirection, status: CallStatus, timestamp: Date, children: [Child]) {
        self.type = type
        self.direction = direction
        self.status = status
        self.timestamp = timestamp
        self.children = children
    }
}

public struct CallHistoryGroupPanelSection: View {
    let callHistoryGroup: CallHistoryGroup
    @Environment(\.i18n) var i18n
    @Environment(\.conversationListNow) var fixedNow
    @Environment(\.timeZone) var timeZone

    public init(callHistoryGroup: CallHistoryGroup) { self.callHistoryGroup = callHistoryGroup }

    /// `describeCallHistory`
    static func describe(_ type: CallType, _ direction: CallDirection, _ status: CallStatus, _ i18n: Localizer) -> String {
        if type == .adhoc { return i18n("icu:CallHistory__Description--Adhoc") }
        if type == .audio || type == .video, [.accepted, .declined, .deleted, .missed, .pending].contains(status) {
            return CallingNotification.directText(direction, type, status, i18n)
        }
        if status == .missed {
            return i18n(direction == .incoming ? "icu:CallHistory__DescriptionVideoCall--Missed" : "icu:CallHistory__DescriptionVideoCall--Unanswered")
        }
        if status == .declined { return i18n("icu:CallHistory__DescriptionVideoCall--Declined") }
        return i18n("icu:CallHistory__DescriptionVideoCall--Default", ["direction": .string(direction.rawValue)])
    }

    var symbol: AxoSymbol.Name? {
        switch callHistoryGroup.type {
        case .audio: "phone"
        case .video, .group: "videocamera"
        case .adhoc: "link"
        case .unknown: nil
        }
    }

    public var body: some View {
        let g = callHistoryGroup
        let now = fixedNow ?? .now
        AxoList.Root {
            AxoList.Header { AxoList.Label(FormatTimestamp.date(g.timestamp, now: now, i18n: i18n, timeZone: timeZone)) }
            AxoList.Body {
                AxoItem.Group {
                    ForEach(g.children.indices, id: \.self) { i in
                        AxoTextItem.Root(symbol: symbol, label: Self.describe(g.type, g.direction, g.status, i18n),
                                         value: FormatTimestamp.time(g.children[i].timestamp, now: now, i18n: i18n, timeZone: timeZone))
                    }
                }
            }
        }
    }
}
