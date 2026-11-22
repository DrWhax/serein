import Foundation

/// The `v4` field of both Offer and Answer in RingRTC's signaling.proto.
/// Preserve proto2 presence and the preference order of each direction's codecs.
package struct DirectCallParameters: Equatable, Sendable {
    package var publicKey: Data?
    package var iceUfrag: String?
    package var icePassword: String?
    package var maxBitrateBps: UInt64?
    package var encoders: [UInt64?] = []
    package var decoders: [UInt64?] = []

    package init() {}

    package init(envelope: Data) throws {
        self.init()
        var outer = try CallingProtoReader(envelope)
        var seenV4 = false
        while let tag = try outer.next() {
            guard tag.number == 4 else { try outer.skip(tag); continue }
            var fields = CallingProtoReader(try outer.bytes(tag))
            seenV4 = true
            while let field = try fields.next() {
                switch field.number {
                case 1: publicKey = try Data(fields.bytes(field))
                case 2: iceUfrag = try fields.string(field)
                case 3: icePassword = try fields.string(field)
                case 5: maxBitrateBps = try fields.integer(field)
                case 6, 7:
                    guard encoders.count + decoders.count < 128 else { throw CallingWireError.tooLarge }
                    var codec = CallingProtoReader(try fields.bytes(field))
                    var type: UInt64?
                    while let entry = try codec.next() {
                        if entry.number == 1 { type = try codec.integer(entry) }
                        else { try codec.skip(entry) }
                    }
                    if field.number == 6 { encoders.append(type) } else { decoders.append(type) }
                default: try fields.skip(field)
                }
            }
        }
        guard seenV4 else { throw CallingWireError.unsupportedVersion }
    }

    package func envelope() -> Data {
        var fields = CallingProtoWriter()
        if let publicKey { fields.bytes(1, publicKey) }
        if let iceUfrag { fields.bytes(2, iceUfrag.utf8) }
        if let icePassword { fields.bytes(3, icePassword.utf8) }
        if let maxBitrateBps { fields.integer(5, maxBitrateBps) }
        for (field, codecs) in [(UInt32(6), encoders), (7, decoders)] {
            for type in codecs {
                var codec = CallingProtoWriter()
                if let type { codec.integer(1, type) }
                fields.bytes(field, codec.data)
            }
        }
        var outer = CallingProtoWriter()
        outer.bytes(4, fields.data)
        return outer.data
    }
}
