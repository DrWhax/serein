import Foundation

package struct GroupSFUVideoRequest: Sendable {
    package let demuxID: UInt32
    package let height: UInt32
    package init(demuxID: UInt32, height: UInt32) { self.demuxID = demuxID; self.height = height }
}

package enum GroupSFUCommand: Sendable {
    case videoRequest([GroupSFUVideoRequest], maxKbps: UInt32?, activeSpeakerHeight: UInt32?)
    case approve(UInt32), deny(UInt32), remove(UInt32), block(UInt32)
    case raiseHand(Bool), leave
}

/// Reliable control messages have a per-client MRP sequence in addition to each
/// transmission's independent RTP sequence. Sequence one starts a new SFU connection.
package struct GroupSFUControl: Sendable {
    private static let window = 64
    private static let fragmentSize = 1140
    static let maxContent = window * 1200
    private struct Pending: Sendable {
        let seq: UInt64
        let data: Data
        var retryAt: ContinuousClock.Instant
    }
    private struct Incoming: Sendable {
        let timestamp: UInt32
        let data: Data
        var seq: UInt64?
        var ack: UInt64?
        var count: UInt32?
        var content: Data?

        init(_ bytes: Data, timestamp: UInt32) throws {
            self.data = bytes
            self.timestamp = timestamp
            var r = try CallingProtoReader(bytes, limit: 1200)
            while let f = try r.next() {
                switch f.number {
                case 11:
                    try r.message(f) { field, value in
                        switch field.number {
                        case 1: seq = try value.integer(field)
                        case 2: ack = try value.integer(field)
                        case 3: count = try value.uint32(field)
                        default: try value.skip(field)
                        }
                    }
                case 12: content = Data(try r.bytes(f))
                default: try r.skip(f)
                }
            }
        }
    }
    private struct Merge: Sendable {
        let end: UInt64
        let timestamp: UInt32
        var content: Data
    }
    private var nextSend: UInt64 = 1
    private var nextReceive: UInt64 = 1
    private var sent: [Pending] = []
    private var received: [UInt64: Incoming] = [:]
    private var merge: Merge?
    private var discardThrough: UInt64 = 0
    private var ackNeeded = false
    private var handSequence: UInt32 = 0
    private var raised: (data: Data, retryAt: ContinuousClock.Instant)?

    private var videoSubscription: (data: Data, retryAt: ContinuousClock.Instant, lastFragment: UInt64?)?

    package init() {}

    package mutating func send(_ command: GroupSFUCommand, now: ContinuousClock.Instant = .now) throws -> [Data] {
        var fields = CallingProtoWriter()
        var message = CallingProtoWriter()
        switch command {
        case .videoRequest(let requests, let maxKbps, let speaker):
            guard requests.count <= 4096 else { throw CallingWireError.tooLarge }
            for request in requests {
                var one = CallingProtoWriter()
                one.integer(2, UInt64(request.height))
                one.fixed32(3, request.demuxID)
                fields.bytes(1, one.data)
            }
            if let maxKbps { fields.integer(3, UInt64(maxKbps)) }
            if let speaker { fields.integer(4, UInt64(speaker)) }
            message.bytes(1, fields.data)
            return try subscribe(message.data, now: now)
        case .approve(let target), .deny(let target), .remove(let target), .block(let target):
            let tag: UInt32
            switch command {
            case .approve: tag = 3
            case .deny: tag = 4
            case .remove: tag = 5
            default: tag = 6
            }
            fields.fixed32(1, target)
            message.bytes(tag, fields.data)
            return try reliable(message.data, fragmented: false, now: now)
        case .raiseHand(let value):
            guard handSequence < UInt32.max else { throw CallingWireError.tooLarge }
            handSequence += 1
            fields.integer(1, value ? 1 : 0)
            fields.integer(2, UInt64(handSequence))
            message.bytes(7, fields.data)
            raised = (message.data, now + .milliseconds(500))
            return [message.data]
        case .leave:
            videoSubscription = nil
            message.bytes(2, Data())
            return [message.data, message.data]
        }
    }

    private mutating func subscribe(_ data: Data, now: ContinuousClock.Instant) throws -> [Data] {
        if data.count <= Self.fragmentSize {
            videoSubscription = (data, now + .seconds(1), nil)
            return [data]
        }
        let frames = try reliable(data, fragmented: true, now: now)
        videoSubscription = (data, now + .seconds(1), nextSend - 1)
        return frames
    }

    /// A logical message either fits the send window in its entirety or leaves it untouched.
    private mutating func reliable(_ data: Data, fragmented: Bool, now: ContinuousClock.Instant) throws -> [Data] {
        let count = fragmented ? (data.count + Self.fragmentSize - 1) / Self.fragmentSize : 1
        guard count > 0, sent.count + count <= Self.window, nextSend <= UInt64.max - UInt64(count)
        else { throw CallingWireError.tooLarge }
        var frames: [Data] = []
        for index in 0..<count {
            var header = CallingProtoWriter()
            header.integer(1, nextSend)
            if fragmented && index == 0 { header.integer(3, UInt64(count)) }
            var frame = CallingProtoWriter()
            frame.bytes(8, header.data)
            let wire: Data
            if fragmented {
                let start = index * Self.fragmentSize
                frame.bytes(9, data[start..<min(data.count, start + Self.fragmentSize)])
                wire = frame.data
            } else { wire = data + frame.data }
            frames.append(wire)
            sent.append(Pending(seq: nextSend, data: wire, retryAt: now + .seconds(1)))
            nextSend += 1
        }
        return frames
    }

    package mutating func receive(_ payload: Data, timestamp: UInt32) throws -> [GroupSFUUpdate] {
        let packet = try Incoming(payload, timestamp: timestamp)
        if let ack = packet.ack {
            if ack <= nextSend { sent.removeAll { $0.seq < ack } }
            return []
        }
        guard let seq = packet.seq else { return [try process(packet.data, timestamp: timestamp)] }
        guard seq >= nextReceive else { ackNeeded = true; return [] }
        guard seq != UInt64.max, seq - nextReceive < UInt64(Self.window) else { throw CallingWireError.tooLarge }
        received[seq] = packet
        var updates: [GroupSFUUpdate] = []
        while let ready = received.removeValue(forKey: nextReceive) {
            let sequence = nextReceive
            nextReceive += 1
            ackNeeded = true
            if sequence <= discardThrough { continue }
            if let active = merge {
                guard ready.count == nil else {
                    merge = nil
                    discardThrough = active.end
                    continue
                }
                if let content = ready.content { merge?.content.append(content) }
                if sequence == active.end, let complete = merge {
                    merge = nil
                    updates.append(try process(complete.content, timestamp: complete.timestamp))
                }
            } else if let count = ready.count, count > 1 {
                guard count <= UInt32(Self.window), sequence <= UInt64.max - UInt64(count) else { throw CallingWireError.tooLarge }
                merge = Merge(end: sequence + UInt64(count) - 1, timestamp: ready.timestamp, content: ready.content ?? Data())
            } else { updates.append(try process(ready.content ?? ready.data, timestamp: ready.timestamp)) }
        }
        return updates
    }

    private mutating func process(_ bytes: Data, timestamp: UInt32) throws -> GroupSFUUpdate {
        var update = try GroupSFUUpdate(bytes, timestamp: timestamp)
        if let hands = update.raisedHands {
            if let ack = hands.targetSequence, ack >= handSequence {
                handSequence = ack
                raised = nil
            } else { update.raisedHands = nil }
        }
        return update
    }

    /// Call on the group's regular 200 ms tick. These plaintext control payloads must
    /// be sealed as new SRTP packets, including when retransmitting identical MRP content.
    package mutating func tick(now: ContinuousClock.Instant = .now) -> [Data] {
        var output: [Data] = []
        if ackNeeded {
            var header = CallingProtoWriter()
            header.integer(2, nextReceive)
            var frame = CallingProtoWriter()
            frame.bytes(8, header.data)
            output.append(frame.data)
            ackNeeded = false
        }
        for i in sent.indices where sent[i].retryAt <= now {
            output.append(sent[i].data)
            sent[i].retryAt = now + .seconds(1)
        }
        // Preserve the current subscription across packet loss. Outstanding MRP
        // fragments already retransmit above until the server acknowledges them.
        if let video = videoSubscription, video.retryAt <= now,
           !sent.contains(where: { $0.seq == video.lastFragment }),
           let packets = try? subscribe(video.data, now: now) { output += packets }
        if let hand = raised, hand.retryAt <= now {
            output.append(hand.data)
            raised = (hand.data, now + .milliseconds(500))
        }
        return output
    }
}
