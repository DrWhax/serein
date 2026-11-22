import Foundation
import SignalRingRTC
import SwiftCalling

/// The most recent ring for each group belongs to a specific sender. Each request also
/// generates an expiry notification, even if another device handles it in the meantime.
struct CallGroupRings: Sendable {
    struct Pending: Sendable {
        let group: Data
        let id: Int64
        let sender: Data
        let deadline: ContinuousClock.Instant

        func update(_ kind: RingUpdate) -> JSONValue {
            .object(["type": .string("groupCallRingUpdate"), "groupId": .bytes(group), "ringId": .string(String(id)),
                     "sender": .bytes(sender), "update": .int(Int64(kind.rawValue))])
        }
    }

    private(set) var selfUUID: Data?
    private var outstanding: [Data: Pending] = [:]
    private var deadlines: [Pending] = []

    func waitDeadline(timeoutMs: UInt32, now: ContinuousClock.Instant = .now) -> DispatchTime {
        let timeout = DispatchTime.now() + .milliseconds(Int(timeoutMs))
        guard let first = deadlines.first else { return timeout }
        let remaining = max(.zero, now.duration(to: first.deadline)).components
        let nanos = remaining.seconds * 1_000_000_000 + remaining.attoseconds / 1_000_000_000
        return min(timeout, .now() + .nanoseconds(Int(nanos)))
    }

    mutating func expire(now: ContinuousClock.Instant = .now) -> [JSONValue] {
        let due = deadlines.prefix { $0.deadline <= now }
        var events: [JSONValue] = []
        for ring in due {
            remove(group: ring.group, id: ring.id, sender: ring.sender)
            events.append(ring.update(.expiredRequest))
        }
        deadlines.removeFirst(due.count)
        return events
    }

    func outstandingID(for group: Data, now: ContinuousClock.Instant = .now) -> Int64? {
        guard let ring = outstanding[group], ring.deadline > now else { return nil }
        return ring.id
    }

    private mutating func remove(group: Data, id: Int64, sender: Data? = nil) {
        guard let ring = outstanding[group], ring.id == id, sender == nil || sender == ring.sender else { return }
        outstanding.removeValue(forKey: group)
    }

    /// Sent only to the authenticated account's own linked devices.
    func response(_ kind: GroupRingMessage.Response, group: Data, id: Int64) -> JSONValue? {
        guard let selfUUID else { return nil }
        return .object(["type": .string("sendCallMessage"), "recipientUuid": .bytes(selfUUID),
                        "message": .bytes(GroupRingMessage(group: group, id: id, kind: .response(kind)).encode()),
                        "urgency": .int(Int64(CallMessageUrgency.handleImmediately.rawValue))])
    }

    mutating func command(_ name: String, _ fields: [String: JSONValue], busy: Bool,
                          now: ContinuousClock.Instant = .now) throws -> [JSONValue] {
        switch name {
        case "setSelfUuid":
            guard let uuid = fields["uuid"]?.data, uuid.count == 16 else { throw RingRTCError.invalidResponse }
            if let previous = selfUUID, previous != uuid { self = CallGroupRings() }
            selfUUID = uuid
            return []
        case "cancelGroupRing":
            guard let group = fields["groupId"]?.data, let id = fields["ringId"]?.int64 else { throw RingRTCError.invalidResponse }
            let reason: RingCancelReason?
            if let field = fields["reason"], !field.isNull {
                guard let value = field.int, let valid = RingCancelReason(rawValue: value) else { throw RingRTCError.invalidResponse }
                reason = valid
            } else { reason = nil }
            remove(group: group, id: id)
            guard let reason, let send = response(reason == .busy ? .busy : .declined, group: group, id: id) else { return [] }
            return [send]
        case "receivedCallMessage":
            guard let sender = fields["remoteUserId"]?.data, sender.count == 16,
                  let data = fields["data"]?.data, let age = fields["messageAgeSec"]?.uint64 else { throw RingRTCError.invalidResponse }
            guard case .ring(let message) = try? GroupSignalingMessage(data) else { return [] }
            var events = expire(now: now)
            let pending = Pending(group: message.group, id: message.id, sender: sender, deadline: now + .seconds(60))
            switch message.kind {
            case .intention(.ring):
                if age > 60 { events.append(pending.update(.expiredRequest)) }
                else if busy {
                    remove(group: message.group, id: message.id)
                    if let send = response(.busy, group: message.group, id: message.id) { events.append(send) }
                    events.append(pending.update(.busyLocally))
                } else {
                    // Bound timer storage independently of the event queue when signalling is flooded.
                    guard deadlines.count < 256 else { return events }
                    outstanding[message.group] = pending
                    deadlines.append(pending)
                    events.append(pending.update(.requested))
                }
            case .intention(.cancelled):
                remove(group: message.group, id: message.id, sender: sender)
                events.append(pending.update(.cancelledByRinger))
            case .response(let kind):
                guard sender == selfUUID, kind != .ringing else { return events }
                remove(group: message.group, id: message.id)
                let update: RingUpdate
                switch kind {
                case .accepted: update = .acceptedOnAnotherDevice
                case .declined: update = .declinedOnAnotherDevice
                case .busy: update = .busyOnAnotherDevice
                case .ringing: return events
                }
                events.append(pending.update(update))
            }
            return events
        default: throw RingRTCError.invalidResponse
        }
    }
}
