// Call history (ts/util/callDisposition.preload.ts, ts/types/CallDisposition.std.ts): calls are
// events (local: started, ringing, accepted, declined, hangups, missed, delete; remote: the
// CallEvent sync's accepted / not accepted / delete / observed) applied to a per-call status
// machine — direct, group or ad hoc (call link) — saved in `callsHistory`, shown as a
// `call-history` timeline message, and synced to our other devices when the status is one
// that syncs. CallLogEvent syncs clear history or mark it read.

import Foundation
import GRDB
import SignalProtos

public enum CallMode: String, Sendable, Codable { case direct = "Direct", group = "Group", adhoc = "Adhoc" }
public enum CallType: String, Sendable, Codable { case audio = "Audio", video = "Video", group = "Group", adhoc = "Adhoc", unknown = "Unknown" }
public enum CallDirection: String, Sendable, Codable { case incoming = "Incoming", outgoing = "Outgoing", unknown = "Unknown" }

public enum LocalCallEvent: String, Sendable {
    case started = "LocalStarted", ringing = "LocalRinging", accepted = "LocalAccepted", declined = "LocalDeclined"
    /// Incoming: declined; outgoing: missed.
    case hangup = "LocalHangup"
    /// Incoming: missed; outgoing: declined.
    case remoteHangup = "LocalRemoteHangup"
    case missed = "LocalMissed", delete = "LocalDelete"
}

public enum RemoteCallEvent: String, Sendable { case accepted = "Accepted", notAccepted = "NotAccepted", delete = "Delete", observed = "Observed" }

public enum CallEvent: Sendable, Equatable {
    case local(LocalCallEvent)
    case remote(RemoteCallEvent)
}

/// `CallStatusValue` (direct, group and ad hoc statuses share the stored names).
public enum CallStatus: String, Sendable, Codable {
    case pending = "Pending", accepted = "Accepted", missed = "Missed", missedNotificationProfile = "MissedNotificationProfile", declined = "Declined"
    case deleted = "Deleted", genericGroupCall = "GenericGroupCall", genericAdhocCall = "GenericAdhocCall", outgoingRing = "OutgoingRing"
    case ringing = "Ringing", joined = "Joined", joinedAdhoc = "JoinedAdhoc", unknown = "Unknown"
}

public struct CallDetails: Sendable, Equatable {
    public var callId: String
    /// ACI (direct), base64 group id (group) or hex room id (ad hoc).
    public var peerId: String
    public var ringerId: String?
    public var startedById: String?
    public var mode: CallMode
    public var type: CallType
    public var direction: CallDirection
    public var timestamp: Int64
    public var endedTimestamp: Int64?
    public init(callId: String, peerId: String, ringerId: String?, startedById: String?, mode: CallMode, type: CallType, direction: CallDirection,
                timestamp: Int64, endedTimestamp: Int64? = nil) {
        self.callId = callId
        self.peerId = peerId
        self.ringerId = ringerId
        self.startedById = startedById
        self.mode = mode
        self.type = type
        self.direction = direction
        self.timestamp = timestamp
        self.endedTimestamp = endedTimestamp
    }
}

public struct CallEventDetails: Sendable, Equatable {
    public var details: CallDetails
    public var event: CallEvent
    public var eventSource: String
    public var eventTimestamp: Int64
}

public struct CallHistoryDetails: Sendable, Equatable {
    public var details: CallDetails
    public var status: CallStatus
    public var callId: String { details.callId }
    public var peerId: String { details.peerId }
}

public enum CallHistoryError: Error, Equatable { case invalidTransition(String), mismatch(String) }

/// The status machines (`transitionCallHistory` and friends).
public enum CallHistoryTransitions {
    public static func transition(_ prev: CallHistoryDetails?, _ e: CallEventDetails) throws -> CallHistoryDetails {
        let d = e.details
        if let prev {
            let p = prev.details
            guard p.callId == d.callId else { throw CallHistoryError.mismatch("callId must be same") }
            guard p.peerId == d.peerId else { throw CallHistoryError.mismatch("peerId must be same") }
            guard d.ringerId == nil || p.ringerId == nil || p.ringerId == d.ringerId else { throw CallHistoryError.mismatch("ringerId must be same if it exists") }
            guard d.startedById == nil || p.startedById == nil || p.startedById == d.startedById else {
                throw CallHistoryError.mismatch("startedById must be same if it exists")
            }
            guard p.direction == d.direction else { throw CallHistoryError.mismatch("direction must be same") }
            guard p.type == d.type else { throw CallHistoryError.mismatch("type must be same") }
            guard p.mode == d.mode else { throw CallHistoryError.mismatch("mode must be same") }
        }
        let status: CallStatus = switch d.mode {
        case .direct: try direct(prev?.status, e.event, d.direction)
        case .group: try group(prev?.status, e.event, d.direction)
        case .adhoc: adhoc(prev?.status, e.event)
        }
        var out = d
        out.timestamp = timestamp(prev, e)
        out.endedTimestamp = nil
        return CallHistoryDetails(details: out, status: status)
    }

    /// `transitionTimestamp`
    static func timestamp(_ prev: CallHistoryDetails?, _ e: CallEventDetails) -> Int64 {
        guard let prev else { return e.details.timestamp }
        let latest = max(e.details.timestamp, prev.details.timestamp)
        switch prev.status {
        case .deleted:
            return prev.details.timestamp
        case .accepted, .joined, .joinedAdhoc:
            return e.event == .remote(.accepted) ? latest : prev.details.timestamp
        case .genericAdhocCall:
            return e.event == .remote(.observed) ? latest : prev.details.timestamp
        case .declined:
            return e.event == .remote(.notAccepted) ? latest : prev.details.timestamp
        case .pending, .unknown, .genericGroupCall, .outgoingRing, .ringing, .missed, .missedNotificationProfile:
            return latest
        }
    }

    static func direct(_ status: CallStatus?, _ event: CallEvent, _ direction: CallDirection) throws -> CallStatus {
        if event == .remote(.delete) || event == .local(.delete) || status == .deleted { return .deleted }
        if event == .remote(.accepted) || event == .local(.accepted) { return .accepted }
        if status == .accepted { return .accepted }
        switch event {
        case .remote(.notAccepted): return status == .declined ? .declined : .missed
        case .remote(.observed): throw CallHistoryError.invalidTransition("Direct calls shouldn't send Observed")
        case .local(.missed): return .missed
        case .local(.declined): return .declined
        case .local(.hangup): return direction == .incoming ? .declined : .missed
        case .local(.remoteHangup): return direction == .incoming ? .missed : .declined
        case .local(.started), .local(.ringing): return .pending
        default: throw CallHistoryError.invalidTransition("\(event)")
        }
    }

    static func group(_ status: CallStatus?, _ event: CallEvent, _ direction: CallDirection) throws -> CallStatus {
        if event == .remote(.delete) || event == .local(.delete) || status == .deleted { return .deleted }
        if status == .accepted { return .accepted }
        if event == .remote(.notAccepted) || event == .remote(.observed) { throw CallHistoryError.invalidTransition("Group calls shouldn't send \(event)") }
        if event == .remote(.accepted) || event == .local(.accepted) {
            switch status {
            case nil, .genericGroupCall: return .joined
            case .ringing, .missed, .missedNotificationProfile, .declined: return .accepted
            case .joined, .outgoingRing: return status!
            default: throw CallHistoryError.invalidTransition("group status \(String(describing: status))")
            }
        }
        switch event {
        case .local(.started): return .genericGroupCall
        case .local(.ringing): return .ringing
        case .local(.missed): return .missed
        case .local(.declined): return .declined
        case .local(.hangup): return direction == .incoming ? .declined : .missed
        case .local(.remoteHangup): return direction == .incoming ? .missed : .declined
        default: throw CallHistoryError.invalidTransition("\(event)")
        }
    }

    static func adhoc(_ status: CallStatus?, _ event: CallEvent) -> CallStatus {
        if event == .remote(.delete) || event == .local(.delete) || status == .deleted { return .deleted }
        if event == .remote(.accepted) || event == .local(.accepted) { return .joinedAdhoc }
        if status == .joinedAdhoc { return .joinedAdhoc }
        if event == .remote(.observed) || event == .local(.started) { return .genericAdhocCall }
        return .pending
    }

    // MARK: events from ringrtc state

    /// `endedReasonToEvent` (Desktop's CallEndedReason names).
    public static func eventForEndedReason(_ reason: String) -> LocalCallEvent {
        switch reason {
        case "AcceptedOnAnotherDevice": .accepted
        case "RemoteHangup": .remoteHangup
        case "LocalHangup": .hangup
        default: .missed
        }
    }

    /// `ringUpdateToEvent`
    public static func eventForRingUpdate(_ update: Int) -> LocalCallEvent {
        switch update {
        case 0: .ringing          // Requested
        case 2: .accepted         // AcceptedOnAnotherDevice
        default: .missed          // expired, declined elsewhere, busy, cancelled
        }
    }

    /// `getLocalCallEventFromJoinState` (joinState: 0 not joined, 1 joining, 2 pending, 3 joined).
    public static func eventForJoinState(_ joinState: Int?, outgoing: Bool) -> LocalCallEvent {
        if outgoing { return joinState == nil || joinState == 0 ? .started : .ringing }
        switch joinState {
        case nil, 0: return .started
        default: return .accepted
        }
    }
}

/// CallEvent / CallLogEvent protos (`getCallEventForProto`, `getProtoForCallHistory`).
public enum CallHistoryProto {
    /// Statuses that sync, and the event they sync as.
    static func event(for status: CallStatus) -> Signalservice_SyncMessage.CallEvent.Event? {
        switch status {
        case .accepted, .joinedAdhoc: .accepted
        case .declined: .notAccepted
        case .deleted: .delete
        case .genericAdhocCall: .observed
        case .unknown: .unknownEvent
        default: nil
        }
    }

    public static func shouldSync(_ status: CallStatus) -> Bool { event(for: status) != nil }

    /// `getBytesForPeerId`
    public static func peerBytes(_ d: CallDetails) -> Data? {
        switch d.mode {
        case .adhoc: Data(hex: d.peerId)
        case .group: Data(base64Encoded: d.peerId)
        case .direct: UUID(uuidString: d.peerId.hasPrefix("ACI:") ? String(d.peerId.dropFirst(4)) : d.peerId)?.data
        }
    }

    public static func proto(_ h: CallHistoryDetails) -> Signalservice_SyncMessage.CallEvent? {
        guard let event = event(for: h.status), let peer = peerBytes(h.details) else { return nil }
        var p = Signalservice_SyncMessage.CallEvent()
        p.conversationID = peer
        if let id = UInt64(h.callId) { p.callID = id }
        p.type = switch h.details.type {
        case .audio: .audioCall
        case .video: .videoCall
        case .group: .groupCall
        case .adhoc: .adHocCall
        case .unknown: .unknownType
        }
        p.direction = switch h.details.direction {
        case .incoming: .incoming
        case .outgoing: .outgoing
        case .unknown: .unknownDirection
        }
        p.event = event
        p.timestamp = UInt64(max(0, h.details.timestamp))
        return p
    }

    /// The details of a received CallEvent (`peerId` decoded per type: ACI, base64 group id,
    /// hex room id).
    public static func details(_ p: Signalservice_SyncMessage.CallEvent, eventSource: String, eventTimestamp: Int64) throws -> CallEventDetails {
        let type: CallType
        switch p.type {
        case .groupCall: type = .group
        case .audioCall: type = .audio
        case .videoCall: type = .video
        case .adHocCall: type = .adhoc
        default: throw CallHistoryError.invalidTransition("Unknown call type \(p.type)")
        }
        let mode: CallMode = type == .group ? .group : type == .adhoc ? .adhoc : .direct
        let direction: CallDirection
        switch p.direction {
        case .incoming: direction = .incoming
        case .outgoing: direction = .outgoing
        default: throw CallHistoryError.invalidTransition("Unknown call direction")
        }
        let event: RemoteCallEvent
        switch p.event {
        case .accepted: event = .accepted
        case .notAccepted: event = .notAccepted
        case .delete: event = .delete
        case .observed: event = .observed
        default: throw CallHistoryError.invalidTransition("Unknown call event")
        }
        let peerId: String
        switch mode {
        case .group: peerId = p.conversationID.base64EncodedString()
        case .adhoc: peerId = p.conversationID.hexString
        case .direct:
            guard p.conversationID.count == 16 else { throw CallHistoryError.invalidTransition("bad peer id") }
            peerId = UUID(uuid: p.conversationID.uuidTuple).uuidString.lowercased()
        }
        return CallEventDetails(details: CallDetails(callId: String(p.callID), peerId: peerId, ringerId: nil, startedById: nil, mode: mode, type: type,
                                                     direction: direction, timestamp: Int64(p.timestamp)),
                                event: .remote(event), eventSource: eventSource, eventTimestamp: eventTimestamp)
    }

    public static func logEvent(type: Signalservice_SyncMessage.CallLogEvent.TypeEnum, latest: CallHistoryDetails) -> Signalservice_SyncMessage.CallLogEvent {
        var e = Signalservice_SyncMessage.CallLogEvent()
        e.type = type
        e.timestamp = UInt64(max(0, latest.details.timestamp))
        if let peer = peerBytes(latest.details) { e.conversationID = peer }
        if let id = UInt64(latest.callId) { e.callID = id }
        return e
    }
}

extension Data {
    var uuidTuple: uuid_t {
        let b = Array(self.prefix(16)) + Array(repeating: 0, count: Swift.max(0, 16 - count))
        return (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
    }
}

/// `callsHistory` and the `call-history` timeline messages.
public enum CallHistoryStore {
    public static func get(_ db: Database, callId: String, peerId: String) throws -> CallHistoryDetails? {
        try Row.fetchOne(db, sql: "SELECT * FROM callsHistory WHERE callId = ? AND peerId = ?", arguments: [callId, peerId]).map(decode)
    }

    static func decode(_ r: Row) -> CallHistoryDetails {
        CallHistoryDetails(details: CallDetails(callId: r["callId"], peerId: r["peerId"], ringerId: r["ringerId"], startedById: r["startedById"],
                                                mode: CallMode(rawValue: r["mode"]) ?? .direct, type: CallType(rawValue: r["type"]) ?? .unknown,
                                                direction: CallDirection(rawValue: r["direction"]) ?? .unknown, timestamp: r["timestamp"],
                                                endedTimestamp: r["endedTimestamp"]),
                           status: CallStatus(rawValue: r["status"]) ?? .unknown)
    }

    /// `saveCallHistory` (the row).
    public static func save(_ db: Database, _ h: CallHistoryDetails) throws {
        let d = h.details
        try db.execute(sql: """
            INSERT INTO callsHistory (callId, peerId, ringerId, startedById, mode, type, direction, status, timestamp, endedTimestamp)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (callId) DO UPDATE SET peerId = excluded.peerId, ringerId = excluded.ringerId, startedById = excluded.startedById,
                mode = excluded.mode, type = excluded.type, direction = excluded.direction, status = excluded.status,
                timestamp = excluded.timestamp, endedTimestamp = excluded.endedTimestamp
            """, arguments: [d.callId, d.peerId, d.ringerId, d.startedById, d.mode.rawValue, d.type.rawValue, d.direction.rawValue, h.status.rawValue,
                             d.timestamp, d.endedTimestamp])
    }

    /// The conversation a direct or group call belongs to.
    static func conversation(_ db: Database, for d: CallDetails) throws -> String? {
        switch d.mode {
        case .direct:
            let aci = d.peerId.hasPrefix("ACI:") ? String(d.peerId.dropFirst(4)) : d.peerId
            // A call from a contact we have no conversation with yet (a sync) creates it.
            guard UUID(uuidString: aci) != nil else { return nil }
            return try MessageStore.privateConversation(db, serviceId: aci.lowercased())
        case .group:
            return try String.fetchOne(db, sql: "SELECT id FROM conversations WHERE groupId = ?", arguments: [d.peerId])
        case .adhoc:
            return nil
        }
    }

    /// `updateLocalCallHistory` + `saveCallHistory`: applies `event`, saves the row and the
    /// timeline message; returns the new history (nil when the transition is invalid).
    @discardableResult
    public static func apply(_ db: Database, _ event: CallEventDetails, activeCallConversationIds: Set<String> = []) throws -> CallHistoryDetails? {
        let prev = try get(db, callId: event.details.callId, peerId: event.details.peerId)
        guard let next = try? CallHistoryTransitions.transition(prev, event) else { return nil }
        if event.details.mode == .adhoc {
            if prev != next { try save(db, next) }
            return next
        }
        try save(db, next)
        guard let conversationId = try conversation(db, for: next.details) else { return next }
        try saveMessage(db, next, conversationId: conversationId, activeCall: activeCallConversationIds.contains(conversationId))
        return next
    }

    /// The `call-history` message for a call: created, updated or (when deleted) removed.
    static func saveMessage(_ db: Database, _ h: CallHistoryDetails, conversationId: String, activeCall: Bool) throws {
        let prev = try Row.fetchOne(db, sql: "SELECT id, json, seenStatus FROM messages WHERE conversationId = ? AND type = 'call-history' AND callId = ?",
                                    arguments: [conversationId, h.callId])
        if h.status == .deleted {
            if let prev { try db.execute(sql: "DELETE FROM messages WHERE id = ?", arguments: [prev["id"] as String]) }
            return
        }
        let d = h.details
        let unseen = d.direction == .incoming && (
            (d.mode == .direct && (h.status == .missed || h.status == .pending)) ||
            (d.mode == .group && (h.status == .ringing || h.status == .genericGroupCall || h.status == .missed)))
        var seen = unseen ? SeenStatus.unseen.rawValue : SeenStatus.seen.rawValue
        if let p: Int = prev?["seenStatus"] { seen = max(seen, p) }
        if let prev {
            var json = try MessageStore.jsonObject(prev["json"])
            json["seenStatus"] = seen
            try db.execute(sql: "UPDATE messages SET json = ?, seenStatus = ? WHERE id = ?", arguments: [try MessageStore.jsonString(json), seen, prev["id"] as String])
        } else {
            let id = try MessageStore.insert(db, .init(conversationId: conversationId, type: "call-history", body: "", sentAt: UInt64(max(0, d.timestamp)), source: nil,
                                                       sourceDevice: nil, serverGuid: nil, serverTimestamp: nil, unidentified: false,
                                                       extra: ["callId": d.callId, "readStatus": ReadStatus.read.rawValue, "seenStatus": seen]))
            try db.execute(sql: "UPDATE messages SET readStatus = ?, seenStatus = ? WHERE id = ?", arguments: [ReadStatus.read.rawValue, seen, id])
        }
        try db.execute(sql: "UPDATE conversations SET active_at = max(ifnull(active_at, 0), ?) WHERE id = ?", arguments: [d.timestamp, conversationId])
        _ = activeCall
    }

    /// `clearCallHistory`: everything up to the latest call, and its messages.
    public static func clear(_ db: Database, before latest: CallHistoryDetails) throws {
        try db.execute(sql: """
            DELETE FROM messages WHERE type = 'call-history' AND callId IN (SELECT callId FROM callsHistory WHERE timestamp <= ?)
            """, arguments: [latest.details.timestamp])
        try db.execute(sql: "UPDATE callsHistory SET status = 'Deleted' WHERE timestamp <= ?", arguments: [latest.details.timestamp])
    }

    /// `getUnreadCallMessagesAndMarkRead`: unseen call messages up to the latest call (in one
    /// conversation or all) become seen; returns how many.
    @discardableResult
    public static func markRead(_ db: Database, before latest: CallHistoryDetails, conversationId: String?) throws -> Int {
        var sql = """
            UPDATE messages SET seenStatus = ?, json = json_set(json, '$.seenStatus', ?)
            WHERE type = 'call-history' AND seenStatus = ? AND sent_at <= ?
            """
        var args: [any DatabaseValueConvertible] = [SeenStatus.seen.rawValue, SeenStatus.seen.rawValue, SeenStatus.unseen.rawValue, latest.details.timestamp]
        if let conversationId {
            sql += " AND conversationId = ?"
            args.append(conversationId)
        }
        try db.execute(sql: sql, arguments: StatementArguments(args))
        return db.changesCount
    }

    /// `onCallLogEventSync`: Clear / MarkedAsRead / MarkedAsReadInConversation up to the target
    /// call (found by call id, else by the event's timestamp).
    public static func applyLogEvent(_ db: Database, _ e: Signalservice_SyncMessage.CallLogEvent, now: Int64) throws {
        var timestamp = Int64(clamping: e.timestamp)
        var target: CallHistoryDetails? = nil
        if e.hasCallID, let row = try Row.fetchOne(db, sql: "SELECT * FROM callsHistory WHERE callId = ?", arguments: [String(e.callID)]) {
            target = decode(row)
            timestamp = target!.details.timestamp
        }
        let latest = target ?? CallHistoryDetails(details: CallDetails(callId: e.hasCallID ? String(e.callID) : "", peerId: "", ringerId: nil, startedById: nil,
                                                                       mode: .direct, type: .unknown, direction: .unknown, timestamp: timestamp),
                                                  status: .unknown)
        switch e.type {
        case .clear:
            try clear(db, before: latest)
            try CallLinkStore.markAllDeleted(db, at: now)
        case .markedAsRead:
            try markRead(db, before: latest, conversationId: nil)
        case .markedAsReadInConversation:
            var conversationId: String? = nil
            if let target { conversationId = try conversation(db, for: target.details) }
            if conversationId == nil {
                conversationId = e.conversationID.count == 16
                    ? try MessageStore.privateConversation(db, serviceId: UUID(uuid: e.conversationID.uuidTuple).uuidString.lowercased())
                    : try String.fetchOne(db, sql: "SELECT id FROM conversations WHERE groupId = ?", arguments: [e.conversationID.base64EncodedString()])
            }
            if let conversationId { try markRead(db, before: latest, conversationId: conversationId) }
        default:
            break
        }
    }

    public static func all(_ db: Database, limit: Int = 500) throws -> [CallHistoryDetails] {
        try Row.fetchAll(db, sql: "SELECT * FROM callsHistory WHERE status != 'Deleted' ORDER BY timestamp DESC LIMIT ?", arguments: [limit]).map(decode)
    }
}
