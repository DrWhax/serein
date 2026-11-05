// CallingNotification (ts/components/conversation/CallingNotification.dom.tsx +
// ts/util/callingNotification.std.ts): a call in the timeline: its description and time,
// the phone / video icon (danger when missed or declined), and Call back / Call again /
// Join call / Return to call / Call is full (with its tooltip), unless the next item is
// another call. In another call the button is discouraged with the in-another-call tooltip.
// Right-click: the message context menu with Delete only.

import SignalI18n
import SwiftUI

/// ts/types/CallDisposition.std.ts
public enum CallMode: String, Sendable { case direct = "Direct", group = "Group", adhoc = "Adhoc" }
public enum CallType: String, Sendable { case audio = "Audio", video = "Video", group = "Group", adhoc = "Adhoc", unknown = "Unknown" }
public enum CallDirection: String, Sendable { case incoming = "Incoming", outgoing = "Outgoing", unknown = "Unknown" }
/// The `CallStatusValue` strings shared by DirectCallStatus / GroupCallStatus.
public enum CallStatus: String, Sendable {
    case pending = "Pending", accepted = "Accepted", missed = "Missed", missedNotificationProfile = "MissedNotificationProfile"
    case declined = "Declined", deleted = "Deleted", unknown = "Unknown"
    case genericGroupCall = "GenericGroupCall", outgoingRing = "OutgoingRing", ringing = "Ringing", joined = "Joined"
    case genericAdhocCall = "GenericAdhocCall"
}

public struct CallHistoryDetails: Sendable, Hashable {
    public var mode: CallMode
    public var type: CallType
    public var direction: CallDirection
    public var status: CallStatus
    public var timestamp: Date
    public init(mode: CallMode, type: CallType, direction: CallDirection, status: CallStatus, timestamp: Date) {
        self.mode = mode
        self.type = type
        self.direction = direction
        self.status = status
        self.timestamp = timestamp
    }
}

public struct CallingNotification: View {
    public struct Creator: Sendable, Hashable {
        public var title: String
        public var systemGivenName: String?
        public var isMe: Bool
        public init(title: String, systemGivenName: String? = nil, isMe: Bool) {
            self.title = title
            self.systemGivenName = systemGivenName
            self.isMe = isMe
        }
    }

    let callHistory: CallHistoryDetails?
    let callCreator: Creator?
    let conversationId: String
    let activeConversationId: String?
    let groupCallEnded: Bool?
    let deviceCount: Int
    let maxDevices: Int
    let isNextItemCallingNotification: Bool
    let isSelectMode: Bool
    let expireTimer: (length: TimeInterval, expiration: Date)?
    let onOutgoingAudioCall: () -> Void
    let onOutgoingVideoCall: () -> Void
    let returnToActiveCall: () -> Void
    let onDelete: () -> Void
    @Environment(\.i18n) var i18n
    @Environment(\.conversationListNow) var fixedNow
    @Environment(\.timeZone) var timeZone

    public init(callHistory: CallHistoryDetails?, callCreator: Creator?, conversationId: String, activeConversationId: String? = nil,
                groupCallEnded: Bool?, deviceCount: Int, maxDevices: Int, isNextItemCallingNotification: Bool = false, isSelectMode: Bool = false,
                expireTimer: (length: TimeInterval, expiration: Date)? = nil, onOutgoingAudioCall: @escaping () -> Void = {},
                onOutgoingVideoCall: @escaping () -> Void = {}, returnToActiveCall: @escaping () -> Void = {}, onDelete: @escaping () -> Void = {}) {
        self.callHistory = callHistory
        self.callCreator = callCreator
        self.conversationId = conversationId
        self.activeConversationId = activeConversationId
        self.groupCallEnded = groupCallEnded
        self.deviceCount = deviceCount
        self.maxDevices = maxDevices
        self.isNextItemCallingNotification = isNextItemCallingNotification
        self.isSelectMode = isSelectMode
        self.expireTimer = expireTimer
        self.onOutgoingAudioCall = onOutgoingAudioCall
        self.onOutgoingVideoCall = onOutgoingVideoCall
        self.returnToActiveCall = returnToActiveCall
        self.onDelete = onDelete
    }

    var now: Date { fixedNow ?? .now }

    /// `isMoreRecentThan(timestamp, 5 * MINUTE)`
    func isRecent(_ d: Date) -> Bool { now.timeIntervalSince(d) < 5 * 60 }

    /// `getDirectCallNotificationText`
    static func directText(_ direction: CallDirection, _ type: CallType, _ status: CallStatus, _ i18n: Localizer) -> String {
        let video = type == .video, incoming = direction == .incoming
        switch status {
        case .accepted:
            return i18n(incoming ? (video ? "icu:acceptedIncomingVideoCall" : "icu:acceptedIncomingAudioCall")
                        : (video ? "icu:acceptedOutgoingVideoCall" : "icu:acceptedOutgoingAudioCall"))
        case .declined:
            return i18n(incoming ? (video ? "icu:declinedIncomingVideoCall" : "icu:declinedIncomingAudioCall")
                        : (video ? "icu:missedOrDeclinedOutgoingVideoCall" : "icu:missedOrDeclinedOutgoingAudioCall"))
        case .missed, .missedNotificationProfile:
            return i18n(incoming ? (video ? "icu:missedIncomingVideoCall" : "icu:missedIncomingAudioCall")
                        : (video ? "icu:missedOrDeclinedOutgoingVideoCall" : "icu:missedOrDeclinedOutgoingAudioCall"))
        default:     // Pending, Unknown (Deleted is never rendered)
            return i18n(incoming ? (video ? "icu:incomingVideoCall" : "icu:incomingAudioCall")
                        : (video ? "icu:outgoingVideoCall" : "icu:outgoingAudioCall"))
        }
    }

    /// `getCallingNotificationText`
    var text: String? {
        guard let h = callHistory else { return nil }
        switch h.mode {
        case .direct: return Self.directText(h.direction, h.type, h.status, i18n)
        case .adhoc: return nil
        case .group:
            if groupCallEnded == true {
                if h.direction == .incoming {
                    if h.status == .declined { return i18n("icu:CallHistory__DescriptionVideoCall--Declined") }
                    if h.status == .missed { return i18n("icu:CallHistory__DescriptionVideoCall--Missed") }
                    return isRecent(h.timestamp) ? i18n("icu:calling__call-notification__ended") : i18n("icu:acceptedIncomingVideoCall")
                }
                return isRecent(h.timestamp) ? i18n("icu:calling__call-notification__ended") : i18n("icu:acceptedOutgoingVideoCall")
            }
            guard let creator = callCreator else { return i18n("icu:calling__call-notification__started-by-someone") }
            if creator.isMe { return i18n("icu:calling__call-notification__started-by-you") }
            return i18n("icu:calling__call-notification__started", ["name": .string(creator.systemGivenName ?? creator.title)])
        }
    }

    /// `getCallingIcon`: every audio variant is the phone, every video / group one the video icon.
    var icon: String {
        callHistory?.type == .audio ? "v3/phone/phone-compact" : "v3/video/video-compact"
    }

    var kind: SystemMessage<EmptyView>.Kind {
        switch callHistory?.status {
        case .missed, .declined: .danger
        default: .normal
        }
    }

    struct ButtonSpec {
        var label: String
        var disabledTooltip: String?
        var action: () -> Void
    }

    /// `renderCallingNotificationButton`
    var button: ButtonSpec? {
        guard !isNextItemCallingNotification, let h = callHistory else { return nil }
        let inThisCall = activeConversationId != nil && activeConversationId == conversationId
        switch h.mode {
        case .direct:
            if h.status == .pending || inThisCall { return nil }
            return ButtonSpec(label: i18n(h.direction == .incoming ? "icu:calling__call-back" : "icu:calling__call-again"),
                              action: h.type == .video ? onOutgoingVideoCall : onOutgoingAudioCall)
        case .group:
            if groupCallEnded == true {
                if (h.direction == .incoming && (h.status == .declined || h.status == .missed)) || isRecent(h.timestamp) {
                    return ButtonSpec(label: i18n("icu:calling__call-back"), action: onOutgoingVideoCall)
                }
                return nil
            }
            if activeConversationId != nil {
                return inThisCall ? ButtonSpec(label: i18n("icu:calling__return"), action: returnToActiveCall)
                    : ButtonSpec(label: i18n("icu:calling__join"), action: onOutgoingVideoCall)
            }
            if deviceCount >= maxDevices {
                return ButtonSpec(label: i18n("icu:calling__call-is-full"),
                                  disabledTooltip: i18n("icu:calling__call-notification__button__call-full-tooltip", ["max": .number(Double(maxDevices))]),
                                  action: {})
            }
            return ButtonSpec(label: i18n("icu:calling__join"), action: onOutgoingVideoCall)
        case .adhoc:
            return nil
        }
    }

    public var body: some View {
        if let h = callHistory, let text {
            let contents = [CSSTextRun(text + " \u{00B7} "),
                            CSSTextRun(FormatTimestamp.time(h.timestamp, now: now, i18n: i18n, timeZone: timeZone))]
            SystemMessage(.icon(icon), contents: contents, kind: kind == .danger ? .danger : .normal, expireTimer: expireTimer) {
                if let spec = button { buttonView(spec) }
            }
            .allowsHitTesting(!isSelectMode)
            .contextMenu {
                if !isSelectMode {
                    SwiftUI.Button(i18n("icu:MessageContextMenu__deleteMessage"), action: onDelete)
                }
            }
        }
    }

    @ViewBuilder func buttonView(_ spec: ButtonSpec) -> some View {
        let disabled = spec.disabledTooltip != nil
        let inAnotherCall = !disabled && activeConversationId != nil && activeConversationId != conversationId
        let button = AxoButton.Root(spec.label, variant: .subtleSecondary, size: .md, disabled: disabled, discouraged: inAnotherCall, action: spec.action)
        if let tip = spec.disabledTooltip {
            Tooltip(tip, direction: .top) { button }
        } else if inAnotherCall {
            AxoTooltip.Root(label: i18n("icu:calling__in-another-call-tooltip")) { button }
        } else {
            button
        }
    }
}
