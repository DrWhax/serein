import Foundation

/// Signal includes a legacy placeholder addition alongside candidate removals. A receiver
/// acts on the removed address first. Keep both wire fields when round-tripping the message.
package struct IceCandidateUpdate: Equatable, Sendable {
    package struct Address: Equatable, Sendable {
        package let ip: Data
        package let port: UInt16
    }
    package let addedSDP: String?
    package let removed: Address?

    package init(addedSDP: String) {
        self.addedSDP = addedSDP
        removed = nil
    }

    package init(removingIP ip: Data, port: UInt16) throws {
        guard ip.count == 4 || ip.count == 16 else { throw CallingWireError.malformed }
        removed = Address(ip: ip, port: port)
        addedSDP = "candidate:FAKE 1 tcp 0 127.0.0.1 0 typ host"
    }

    package init(envelope: Data) throws {
        var fields = try CallingProtoReader(envelope)
        var sdp: String?, ip: Data?, port: UInt64?
        var hasRemoval = false
        while let tag = try fields.next() {
            switch tag.number {
            case 2:
                var addition = CallingProtoReader(try fields.bytes(tag))
                while let entry = try addition.next() {
                    if entry.number == 1 { sdp = try addition.string(entry) }
                    else { try addition.skip(entry) }
                }
            case 3:
                hasRemoval = true
                var address = CallingProtoReader(try fields.bytes(tag))
                while let entry = try address.next() {
                    switch entry.number {
                    case 1: ip = try Data(address.bytes(entry))
                    case 2: port = try address.integer(entry)
                    default: try address.skip(entry)
                    }
                }
            default: try fields.skip(tag)
            }
        }
        if hasRemoval {
            guard let ip, ip.count == 4 || ip.count == 16, let port, let exact = UInt16(exactly: port) else {
                throw CallingWireError.malformed
            }
            removed = Address(ip: ip, port: exact)
        } else {
            guard sdp != nil else { throw CallingWireError.malformed }
            removed = nil
        }
        addedSDP = sdp
    }

    package func envelope() -> Data {
        var outer = CallingProtoWriter()
        if let addedSDP {
            var addition = CallingProtoWriter()
            addition.bytes(1, addedSDP.utf8)
            outer.bytes(2, addition.data)
        }
        if let removed {
            var address = CallingProtoWriter()
            address.bytes(1, removed.ip)
            address.integer(2, UInt64(removed.port))
            outer.bytes(3, address.data)
        }
        return outer.data
    }
}
