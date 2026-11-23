import Foundation

/// SFU control fields after SRTP authentication and, when present, MRP reassembly.
package struct GroupSFUUpdate: Sendable, Equatable {
    package struct Device: Sendable, Equatable {
        package var demuxID: UInt32?
        package var opaqueUserID: String?
        package var requiresSVC: Bool?
    }
    package struct LinkState: Sendable, Equatable {
        package var encryptedName: String?
        package var restrictions: UInt32?
        package var revoked: Bool?
        package var expiration: UInt64?
    }
    package struct Peek: Sendable, Equatable {
        package var eraID: String?
        package var maxDevices: UInt32?
        package var creator: String?
        package var devices: [Device] = []
        package var pendingDevices: [Device] = []
        package var linkState: LinkState?
    }
    package struct CurrentDevices: Sendable, Equatable {
        package var withVideo: [UInt32] = []
        package var allDemuxIDs: [UInt32] = []
        package var allocatedHeights: [UInt32] = []
    }
    package struct Stats: Sendable, Equatable {
        package var targetKbps: UInt32?
        package var idealKbps: UInt32?
        package var allocatedKbps: UInt32?
    }
    package struct RaisedHands: Sendable, Equatable {
        package var demuxIDs: [UInt32] = []
        package var sequenceNumbers: [UInt32] = []
        package var targetSequence: UInt32?
    }
    package struct Endorsements: Sendable, Equatable {
        package var serialized: Data?
        package var memberCiphertexts: [Data] = []
    }
    package struct ServerAddress: Sendable, Equatable {
        package var udp: [String] = []
        package var tcp: [String] = []
        package var tls: [String] = []
        package var tlsHostname: String?

        package init(udp: [String] = [], tcp: [String] = [], tls: [String] = [], tlsHostname: String? = nil) {
            self.udp = udp
            self.tcp = tcp
            self.tls = tls
            self.tlsHostname = tlsHostname
        }
    }

    package let timestamp: UInt32
    package var speaker: UInt32?
    package var videoHeight: UInt32?
    package var rosterChanged = false
    package var removed = false
    package var peek: Peek?
    package var currentDevices: CurrentDevices?
    package var stats: Stats?
    package var raisedHands: RaisedHands?
    package var endorsements: Endorsements?
    package var serverAddress: ServerAddress?

    init(_ data: Data, timestamp: UInt32) throws {
        self.timestamp = timestamp
        var reader = try CallingProtoReader(data, limit: GroupSFUControl.maxContent)
        while let tag = try reader.next() {
            switch tag.number {
            case 2:
                try reader.message(tag) { f, r in
                    if f.number == 1 { videoHeight = try r.uint32(f) } else { try r.skip(f) }
                }
            case 4:
                try reader.message(tag) { f, r in
                    if f.number == 2 { speaker = try r.fixed32(f) } else { try r.skip(f) }
                }
            case 6:
                rosterChanged = true
                try reader.message(tag) { f, r in
                    if f.number == 1 { peek = try Peek.decode(r.bytes(f)) } else { try r.skip(f) }
                }
            case 7:
                var current = currentDevices ?? CurrentDevices()
                try reader.message(tag) { f, r in
                    switch f.number {
                    case 1: try r.repeatedUInt32(f, fixed: false, into: &current.withVideo)
                    case 2: try r.repeatedUInt32(f, fixed: true, into: &current.allDemuxIDs)
                    case 3: try r.repeatedUInt32(f, fixed: false, into: &current.allocatedHeights)
                    default: try r.skip(f)
                    }
                }
                currentDevices = current
            case 8:
                var rates = stats ?? Stats()
                try reader.message(tag) { f, r in
                    switch f.number {
                    case 1: rates.targetKbps = try r.uint32(f)
                    case 2: rates.idealKbps = try r.uint32(f)
                    case 3: rates.allocatedKbps = try r.uint32(f)
                    default: try r.skip(f)
                    }
                }
                stats = rates
            case 9: try reader.message(tag) { f, r in try r.skip(f) }; removed = true
            case 10:
                var hands = raisedHands ?? RaisedHands()
                try reader.message(tag) { f, r in
                    switch f.number {
                    case 1: try r.repeatedUInt32(f, fixed: true, into: &hands.demuxIDs)
                    case 2: try r.repeatedUInt32(f, fixed: false, into: &hands.sequenceNumbers)
                    case 3: hands.targetSequence = try r.uint32(f)
                    default: try r.skip(f)
                    }
                }
                raisedHands = hands
            case 13:
                var value = endorsements ?? Endorsements()
                try reader.message(tag) { f, r in
                    switch f.number {
                    case 1: value.serialized = Data(try r.bytes(f))
                    case 2:
                        guard value.memberCiphertexts.count < 4096 else { throw CallingWireError.tooLarge }
                        value.memberCiphertexts.append(Data(try r.bytes(f)))
                    default: try r.skip(f)
                    }
                }
                endorsements = value
            case 15:
                var address = serverAddress ?? ServerAddress()
                try reader.message(tag) { f, r in
                    guard address.udp.count + address.tcp.count + address.tls.count < 256 else { throw CallingWireError.tooLarge }
                    switch f.number {
                    case 1: address.udp.append(try r.string(f))
                    case 2: address.tcp.append(try r.string(f))
                    case 3: address.tls.append(try r.string(f))
                    case 4: address.tlsHostname = try r.string(f)
                    default: try r.skip(f)
                    }
                }
                serverAddress = address
            default: try reader.skip(tag)
            }
        }
    }
}

private extension GroupSFUUpdate.Peek {
    static func decode(_ field: ArraySlice<UInt8>) throws -> Self {
        var reader = CallingProtoReader(field)
        var value = Self()
        while let tag = try reader.next() {
            switch tag.number {
            case 1: value.eraID = try reader.string(tag)
            case 2: value.maxDevices = try reader.uint32(tag)
            case 3: value.creator = try reader.string(tag)
            case 4, 5:
                guard value.devices.count + value.pendingDevices.count < 4096 else { throw CallingWireError.tooLarge }
                var device = GroupSFUUpdate.Device()
                try reader.message(tag) { f, r in
                    switch f.number {
                    case 1: device.demuxID = try r.fixed32(f)
                    case 2: device.opaqueUserID = try r.string(f)
                    case 3: device.requiresSVC = try r.integer(f) != 0
                    default: try r.skip(f)
                    }
                }
                if tag.number == 4 { value.devices.append(device) }
                else { value.pendingDevices.append(device) }
            case 6:
                var link = value.linkState ?? GroupSFUUpdate.LinkState()
                try reader.message(tag) { f, r in
                    switch f.number {
                    case 1: link.encryptedName = try r.string(f)
                    case 2: link.restrictions = try r.uint32(f)
                    case 3: link.revoked = try r.integer(f) != 0
                    case 4: link.expiration = try r.integer(f)
                    default: try r.skip(f)
                    }
                }
                value.linkState = link
            default: try reader.skip(tag)
            }
        }
        return value
    }
}
