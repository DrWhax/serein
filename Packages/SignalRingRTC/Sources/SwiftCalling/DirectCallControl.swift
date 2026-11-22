import Foundation

/// Accumulated direct-call state sent inside authenticated RTP data packets (rtp_data.proto).
/// A peer can repeat or omit individual entries. Presence of a false media flag matters.
struct DirectCallControl: Equatable, Sendable {
    static let payloadType: UInt8 = 101
    static let ssrc: UInt32 = 13
    struct Hangup: Equatable { var id: UInt64?; var reason: UInt32?; var deviceID: UInt32? }
    struct SenderStatus: Equatable { var id: UInt64?; var video: Bool?; var screen: Bool?; var audio: Bool? }
    struct ReceiverStatus: Equatable { var id: UInt64?; var bitrate: UInt64? }
    var acceptedID: UInt64?
    var hangup: Hangup?
    var sender: SenderStatus?
    var sequence: UInt64?
    var receiver: ReceiverStatus?

    init() {}

    init(payload: Data) throws {
        var fields = try CallingProtoReader(payload)
        while let tag = try fields.next() {
            switch tag.number {
            case 1:
                var accepted = CallingProtoReader(try fields.bytes(tag))
                while let field = try accepted.next() {
                    if field.number == 1 { acceptedID = try accepted.integer(field) }
                    else { try accepted.skip(field) }
                }
            case 2:
                var message = CallingProtoReader(try fields.bytes(tag))
                var value = hangup ?? Hangup()
                while let field = try message.next() {
                    switch field.number {
                    case 1: value.id = try message.integer(field)
                    case 2, 3:
                        guard let number = try UInt32(exactly: message.integer(field)) else { throw CallingWireError.malformed }
                        if field.number == 2 { value.reason = number } else { value.deviceID = number }
                    default: try message.skip(field)
                    }
                }
                hangup = value
            case 3:
                var message = CallingProtoReader(try fields.bytes(tag))
                var value = sender ?? SenderStatus()
                while let field = try message.next() {
                    switch field.number {
                    case 1: value.id = try message.integer(field)
                    case 2: value.video = try message.integer(field) != 0
                    case 3: value.screen = try message.integer(field) != 0
                    case 4: value.audio = try message.integer(field) != 0
                    default: try message.skip(field)
                    }
                }
                sender = value
            case 4: sequence = try fields.integer(tag)
            case 5:
                var message = CallingProtoReader(try fields.bytes(tag))
                var value = receiver ?? ReceiverStatus()
                while let field = try message.next() {
                    switch field.number {
                    case 1: value.id = try message.integer(field)
                    case 2: value.bitrate = try message.integer(field)
                    default: try message.skip(field)
                    }
                }
                receiver = value
            default: try fields.skip(tag)
            }
        }
    }

    func payload() -> Data {
        var fields = CallingProtoWriter()
        if let acceptedID {
            var value = CallingProtoWriter()
            value.integer(1, acceptedID)
            fields.bytes(1, value.data)
        }
        if let hangup {
            var value = CallingProtoWriter()
            if let id = hangup.id { value.integer(1, id) }
            if let reason = hangup.reason { value.integer(2, UInt64(reason)) }
            if let deviceID = hangup.deviceID { value.integer(3, UInt64(deviceID)) }
            fields.bytes(2, value.data)
        }
        if let sender {
            var value = CallingProtoWriter()
            if let id = sender.id { value.integer(1, id) }
            if let video = sender.video { value.integer(2, video ? 1 : 0) }
            if let screen = sender.screen { value.integer(3, screen ? 1 : 0) }
            if let audio = sender.audio { value.integer(4, audio ? 1 : 0) }
            fields.bytes(3, value.data)
        }
        if let sequence { fields.integer(4, sequence) }
        if let receiver {
            var value = CallingProtoWriter()
            if let id = receiver.id { value.integer(1, id) }
            if let bitrate = receiver.bitrate { value.integer(2, bitrate) }
            fields.bytes(5, value.data)
        }
        return fields.data
    }
}
