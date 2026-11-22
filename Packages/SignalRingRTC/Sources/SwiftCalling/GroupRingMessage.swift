import Foundation

/// CallMessage in RingRTC's signaling.proto. Fields are optional proto2 messages.
package enum GroupSignalingMessage: Equatable, Sendable {
    case ring(GroupRingMessage)
    case device(Data)
    case unknown

    package init(_ data: Data) throws {
        var reader = try CallingProtoReader(data)
        var intention: RingFields?, response: RingFields?, device: Data?
        while let tag = try reader.next() {
            switch tag.number {
            case 1:
                let field = try reader.bytes(tag)
                if device == nil { device = Data(field) } else { device?.append(contentsOf: field) }
            case 2:
                if intention == nil { intention = RingFields() }
                try intention?.merge(reader.bytes(tag))
            case 3:
                if response == nil { response = RingFields() }
                try response?.merge(reader.bytes(tag))
            default: try reader.skip(tag)
            }
        }
        // CallManager classifies intention before response before device-to-device.
        if let fields = intention ?? response {
            guard let group = fields.group, let id = fields.id, let type = fields.type else { self = .unknown; return }
            let kind: GroupRingMessage.Kind
            if intention != nil, let value = GroupRingMessage.Intention(rawValue: type) { kind = .intention(value) }
            else if intention == nil, let value = GroupRingMessage.Response(rawValue: type) { kind = .response(value) }
            else { self = .unknown; return }
            self = .ring(.init(group: group, id: id, kind: kind))
        } else if let device { self = .device(device) }
        else { self = .unknown }
    }

    private struct RingFields {
        var group: Data?
        var type: UInt64?
        var id: Int64?

        mutating func merge(_ field: ArraySlice<UInt8>) throws {
            var reader = CallingProtoReader(field)
            while let tag = try reader.next() {
                switch tag.number {
                case 1: group = Data(try reader.bytes(tag))
                case 2: type = try reader.integer(tag)
                case 3: id = Int64(bitPattern: try reader.fixed64(tag))
                default: try reader.skip(tag)
                }
            }
        }
    }
}

package struct GroupRingMessage: Equatable, Sendable {
    package enum Intention: UInt64, Sendable { case ring, cancelled }
    package enum Response: UInt64, Sendable { case ringing, accepted, declined, busy }
    package enum Kind: Equatable, Sendable { case intention(Intention), response(Response) }

    package let group: Data
    package let id: Int64
    package let kind: Kind

    package init(group: Data, id: Int64, kind: Kind) {
        self.group = group
        self.id = id
        self.kind = kind
    }

    package func encode() -> Data {
        var inner = CallingProtoWriter()
        inner.bytes(1, group)
        let field: UInt32
        switch kind {
        case .intention(let type): field = 2; inner.integer(2, type.rawValue)
        case .response(let type): field = 3; inner.integer(2, type.rawValue)
        }
        inner.fixed64(3, UInt64(bitPattern: id))
        var message = CallingProtoWriter()
        message.bytes(field, inner.data)
        return message.data
    }
}
