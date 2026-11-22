import Foundation

/// Signal's group_call.DeviceToDevice. Media keys are accepted only inside a
/// Signal signaling envelope. Heartbeats and reactions travel inside encrypted RTP.
package struct GroupDeviceMessage: Sendable {
    package struct Key: Sendable {
        package let demux: UInt32
        package let ratchet: UInt8
        package let secret: Data
        package init(demux: UInt32, ratchet: UInt8, secret: Data) { self.demux = demux; self.ratchet = ratchet; self.secret = secret }
    }
    package var group: Data?
    package var key: Key?
    package var audioMuted: Bool?
    package var videoMuted: Bool?
    package var presenting: Bool?
    package var sharingScreen: Bool?
    package var mutedBy: UInt32?
    package var leaving = false
    package var leavingDemux: UInt32?
    package var reaction: String?
    package var muteTarget: UInt32?

    package init() {}

    package init(_ bytes: Data) throws {
        guard bytes.count <= 8192 else { throw CallingWireError.tooLarge }
        var p = try CallingProtoReader(bytes)
        while let tag = try p.next() {
            switch tag.number {
            case 1: group = Data(try p.bytes(tag))
            case 2:
                var sub = CallingProtoReader(try p.bytes(tag))
                var demux: UInt32?, secret: Data?, ratchet: UInt8?
                while let t = try sub.next() {
                    switch t.number {
                    case 1: ratchet = UInt8(exactly: try sub.integer(t))
                    case 2: secret = Data(try sub.bytes(t))
                    case 3: demux = UInt32(exactly: try sub.integer(t))
                    default: try sub.skip(t)
                    }
                }
                guard let demux, let secret, secret.count == 32, let ratchet else { throw CallingWireError.malformed }
                key = Key(demux: demux, ratchet: ratchet, secret: secret)
            case 3:
                var sub = CallingProtoReader(try p.bytes(tag))
                while let t = try sub.next() {
                    switch t.number {
                    case 1: audioMuted = try sub.integer(t) != 0
                    case 2: videoMuted = try sub.integer(t) != 0
                    case 3: presenting = try sub.integer(t) != 0
                    case 4: sharingScreen = try sub.integer(t) != 0
                    case 5: mutedBy = UInt32(exactly: try sub.integer(t))
                    default: try sub.skip(t)
                    }
                }
            case 4, 5, 6:
                var sub = CallingProtoReader(try p.bytes(tag))
                if tag.number == 4 { leaving = true }
                while let t = try sub.next() {
                    guard t.number == 1 else { try sub.skip(t); continue }
                    switch tag.number {
                    case 4: leavingDemux = UInt32(exactly: try sub.integer(t))
                    case 5:
                        let value = try sub.string(t)
                        if value.utf8.count <= 256 { reaction = value }
                    default: muteTarget = UInt32(exactly: try sub.integer(t))
                    }
                }
            default: try p.skip(tag)
            }
        }
    }

    package static func fromSignaling(_ bytes: Data) throws -> Self? {
        var envelope = try CallingProtoReader(bytes)
        while let t = try envelope.next() {
            if t.number == 1 { return try Self(Data(envelope.bytes(t))) }
            try envelope.skip(t)
        }
        return nil
    }

    package func encode(signaling: Bool = false) -> Data {
        var message = CallingProtoWriter()
        if let group { message.bytes(1, group) }
        if let key {
            var sub = CallingProtoWriter()
            sub.integer(1, UInt64(key.ratchet))
            sub.bytes(2, key.secret)
            sub.integer(3, UInt64(key.demux))
            message.bytes(2, sub.data)
        }
        var heartbeat = CallingProtoWriter()
        for (index, flag) in [audioMuted, videoMuted, presenting, sharingScreen].enumerated() {
            if let flag { heartbeat.integer(UInt32(index + 1), flag ? 1 : 0) }
        }
        if let mutedBy { heartbeat.integer(5, UInt64(mutedBy)) }
        if !heartbeat.data.isEmpty { message.bytes(3, heartbeat.data) }
        if leaving {
            var sub = CallingProtoWriter()
            if let leavingDemux { sub.integer(1, UInt64(leavingDemux)) }
            message.bytes(4, sub.data)
        }
        if let reaction {
            var sub = CallingProtoWriter()
            sub.bytes(1, reaction.utf8)
            message.bytes(5, sub.data)
        }
        if let muteTarget {
            var sub = CallingProtoWriter()
            sub.integer(1, UInt64(muteTarget))
            message.bytes(6, sub.data)
        }
        guard signaling else { return message.data }
        var envelope = CallingProtoWriter()
        envelope.bytes(1, message.data)
        return envelope.data
    }
}
