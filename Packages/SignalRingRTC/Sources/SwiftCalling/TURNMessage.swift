import CodecCore
import CryptoKit
import Foundation

/// RFC 5766 / 8656, with the long-term credentials used by Signal TURN servers.
/// Only bytes preceding MESSAGE-INTEGRITY can affect a decoded response or its credentials.
struct TURNMessage: Sendable {
    enum Failure: Error { case malformed, integrity, invalidCredentials, timeout, closed, backpressure, alreadyConnected, server(Int) }
    enum Attribute: UInt16 {
        case username = 0x0006, integrity = 0x0008, error = 0x0009, lifetime = 0x000d
        case peer = 0x0012, data = 0x0013, realm = 0x0014, nonce = 0x0015, relayed = 0x0016
        case mapped = 0x0020, transport = 0x0019, passwordAlgorithms = 0x8002, fingerprint = 0x8028
    }
    enum Method: UInt16 { case allocate = 3, refresh = 4, permission = 8 }
    static let cookie: [UInt8] = [0x21, 0x12, 0xa4, 0x42]
    let type: UInt16
    let id: [UInt8]
    private let values: [UInt16: [UInt8]]
    private let signedBytes: [UInt8]?
    private let signature: [UInt8]?

    init(_ datagram: Data) throws {
        guard (20...65_507).contains(datagram.count) else { throw Failure.malformed }
        let bytes = Array(datagram)
        var cursor = ByteSlice(bytes).cursor()
        type = try cursor.u16be()
        let size = try Int(cursor.u16be())
        guard type < 0x4000, size.isMultiple(of: 4), size == bytes.count - 20 else { throw Failure.malformed }
        try cursor.expect(Self.cookie, "TURN cookie")
        id = try cursor.bytes(12).copyBytes()
        var parsed: [UInt16: [UInt8]] = [:]
        var prefix: [UInt8]?, mac: [UInt8]?, count = 0
        while !cursor.isAtEnd {
            count += 1
            guard count <= 128 else { throw Failure.malformed }
            let offset = cursor.position
            let attr = try cursor.u16be()
            let length = try Int(cursor.u16be())
            let field = try cursor.bytes(length)
            try cursor.skip((4 - length % 4) % 4)
            switch attr {
            case Attribute.fingerprint.rawValue:
                guard length == 4, cursor.isAtEnd else { throw Failure.malformed }
                var value = field.cursor()
                guard try value.u32be() == CRC32.checksum(Array(bytes[..<offset])) ^ 0x5354_554e else { throw Failure.integrity }
            case Attribute.integrity.rawValue:
                guard mac == nil, length == 20 else { throw Failure.malformed }
                var signed = Array(bytes[..<offset])
                Self.setSize(&signed, cursor.position - 20)
                prefix = signed
                mac = field.copyBytes()
            default:
                if mac == nil, Attribute(rawValue: attr) != nil {
                    guard parsed[attr] == nil else { throw Failure.malformed }
                    parsed[attr] = field.copyBytes()
                }
            }
        }
        values = parsed
        signedBytes = prefix
        signature = mac
    }

    subscript(_ attr: Attribute) -> [UInt8]? { values[attr.rawValue] }

    func verify(using key: SymmetricKey) throws {
        guard let signedBytes, let signature,
              HMAC<Insecure.SHA1>.isValidAuthenticationCode(signature, authenticating: signedBytes, using: key) else {
            throw Failure.integrity
        }
    }

    func acceptsResponse(key: SymmetricKey?) -> Bool {
        guard let key else { return true }
        // A server can issue an unsigned 401/438 challenge (RFC 8489 §9.2.5).
        // Only a subsequent, authenticated success can authorize a relay operation.
        if signature == nil, type & 0x0110 == 0x0110, errorCode == 401 || errorCode == 438 { return true }
        return (try? verify(using: key)) != nil
    }

    var legacyNonce: [UInt8]? {
        // This client implements the legacy long-term credential exchange. Decline
        // challenges that advertise RFC 8489 security features, to avoid downgrades.
        guard self[.passwordAlgorithms] == nil, let nonce = self[.nonce], (1...763).contains(nonce.count),
              !nonce.starts(with: "obMatJos2".utf8) else { return nil }
        return nonce
    }

    var errorCode: Int? {
        guard let value = self[.error], value.count >= 4, (3...6).contains(value[2]), value[3] < 100 else { return nil }
        return Int(value[2]) * 100 + Int(value[3])
    }

    func lifetime() throws -> UInt32 {
        guard let value = self[.lifetime], value.count == 4 else { throw Failure.malformed }
        var field = ByteSlice(value).cursor()
        return try field.u32be()
    }

    static func newID() -> [UInt8] { (0..<12).map { _ in UInt8.random(in: .min ... .max) } }

    private static func setSize(_ packet: inout [UInt8], _ size: Int) {
        packet[2] = UInt8(truncatingIfNeeded: size >> 8)
        packet[3] = UInt8(truncatingIfNeeded: size)
    }

    static func packet(_ type: UInt16, id: [UInt8], attributes: [(Attribute, [UInt8])], key: SymmetricKey? = nil) throws -> Data {
        guard id.count == 12 else { throw Failure.malformed }
        var packet = [UInt8(type >> 8), UInt8(truncatingIfNeeded: type), 0, 0] + cookie + id
        for (attr, value) in attributes {
            let padding = (4 - value.count % 4) % 4
            guard value.count <= 65_507 - packet.count - 4 - padding else { throw Failure.malformed }
            packet += [UInt8(attr.rawValue >> 8), UInt8(truncatingIfNeeded: attr.rawValue),
                       UInt8(value.count >> 8), UInt8(truncatingIfNeeded: value.count)]
            packet += value
            packet += Array(repeating: 0, count: padding)
        }
        if let key {
            guard packet.count <= 65_507 - 24 else { throw Failure.malformed }
            setSize(&packet, packet.count - 20 + 24)
            let mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: packet, using: key))
            packet += [0, 8, 0, 20] + mac
        } else { setSize(&packet, packet.count - 20) }
        return Data(packet)
    }

    func address(_ attr: Attribute) throws -> ICEBinding.Address {
        guard let bytes = self[attr], bytes.count >= 4, bytes[0] == 0,
              (bytes[1] == 1 && bytes.count == 8) || (bytes[1] == 2 && bytes.count == 20) else { throw Failure.malformed }
        let port = (UInt16(bytes[2]) << 8 | UInt16(bytes[3])) ^ 0x2112
        guard port != 0 else { throw Failure.malformed }
        return .init(ip: zip(bytes.dropFirst(4), Self.cookie + id).map(^), port: port)
    }

    static func xorAddress(_ address: ICEBinding.Address, id: [UInt8]) throws -> [UInt8] {
        guard id.count == 12, address.port != 0, address.ip.count == 4 || address.ip.count == 16 else { throw Failure.malformed }
        let port = address.port ^ 0x2112
        return [0, address.ip.count == 4 ? 1 : 2, UInt8(port >> 8), UInt8(truncatingIfNeeded: port)]
            + zip(address.ip, cookie + id).map(^)
    }
}
