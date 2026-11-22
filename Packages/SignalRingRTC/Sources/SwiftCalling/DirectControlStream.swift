import Foundation

/// One device leg of a direct call. The local state is cumulative, so loss of a control
/// packet is repaired by a later heartbeat. Each send receives a fresh SRTP packet index.
struct DirectControlStream: ~Copyable, Sendable {
    enum Failure: Error { case wrongRole, wrongCall, outOfOrder }
    let callID: UInt64
    let role: DirectCallRole
    private let sender: SRTPSender
    private let receiver: SRTPReceiver
    private var local = DirectCallControl()
    private var timestamp: UInt32 = 0
    private var lastTimestamp: UInt32?
    private var lastSenderState: UInt64?
    private var lastReceiverState: UInt64?

    init(callID: UInt64, role: DirectCallRole, outgoing: SRTPKeys, incoming: SRTPKeys) {
        self.callID = callID
        self.role = role
        sender = SRTPSender(keys: outgoing, ssrc: DirectCallControl.ssrc, startingAt: 1)
        receiver = SRTPReceiver(keys: incoming, ssrc: DirectCallControl.ssrc)
    }

    mutating func accept() throws {
        guard role == .callee else { throw Failure.wrongRole }
        if local.acceptedID == nil {
            try advance()
            local.acceptedID = callID
        }
    }

    mutating func setAudio(enabled: Bool) throws {
        if local.sender?.audio != enabled {
            try advance()
            if local.sender == nil { local.sender = .init(id: callID) }
            local.sender?.audio = enabled
        }
    }

    mutating func setReceiveBitrate(_ bitrate: UInt64) throws {
        if local.receiver?.bitrate != bitrate {
            try advance()
            local.receiver = .init(id: callID, bitrate: bitrate)
        }
    }

    mutating func setVideo(enabled: Bool, screen: Bool) throws {
        if local.sender?.video != enabled || local.sender?.screen != screen {
            try advance()
            if local.sender == nil { local.sender = .init(id: callID) }
            local.sender?.video = enabled
            local.sender?.screen = screen
        }
    }

    mutating func hangup(reason: UInt32 = 0, deviceID: UInt32? = nil) throws {
        if local.hangup == nil {
            try advance()
            local.hangup = .init(id: callID, reason: reason, deviceID: deviceID)
        }
    }

    private mutating func advance() throws {
        let previous = local.sequence ?? 0
        guard previous < .max else { throw SRTPError.exhausted }
        local.sequence = previous + 1
    }

    mutating func packet() throws -> Data? {
        guard local.sequence != nil else { return nil }
        guard timestamp < .max else { throw SRTPError.exhausted }
        timestamp += 1
        return try sender.seal(local.payload(), type: DirectCallControl.payloadType, timestamp: timestamp)
    }

    /// Retransmitted accept and hangup are idempotent. Sender and receiver status each
    /// carry their own last-applied sequence, as in RingRTC's connection FSM.
    mutating func receive(_ packet: Data) throws -> DirectCallControl {
        let media = try receiver.open(packet)
        guard media.type == DirectCallControl.payloadType, (1...1024).contains(media.bytes.count) else { throw SRTPError.invalidPacket }
        if let lastTimestamp, media.timestamp < lastTimestamp { throw Failure.outOfOrder }
        var message = try DirectCallControl(payload: media.bytes)
        let ids = [message.acceptedID, message.hangup?.id, message.sender?.id, message.receiver?.id]
        guard ids.compactMap({ $0 }).allSatisfy({ $0 == callID }) else { throw Failure.wrongCall }
        if message.acceptedID != nil, role != .caller { throw Failure.wrongRole }
        if let seq = message.sequence, message.sender?.id != nil, lastSenderState.map({ seq > $0 }) ?? true {
            lastSenderState = seq
        } else { message.sender = nil }
        if let seq = message.sequence, message.receiver?.id != nil, lastReceiverState.map({ seq > $0 }) ?? true {
            lastReceiverState = seq
        } else { message.receiver = nil }
        if message.hangup?.id == nil { message.hangup = nil }
        lastTimestamp = media.timestamp
        return message
    }
}
