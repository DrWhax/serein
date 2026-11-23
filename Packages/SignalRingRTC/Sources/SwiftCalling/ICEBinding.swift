import CodecCore
import CryptoKit
import Foundation

/// Short-term authenticated STUN Binding used by ICE. The packet's fingerprint covers
/// the final length, while the HMAC covers a header ending at MESSAGE-INTEGRITY.
struct ICEBinding {
    enum Failure: Error { case malformed, authentication, unsupportedAttribute }
    enum Role: Equatable { case controlling(UInt64), controlled(UInt64) }
    struct Address: Equatable {
        let ip: [UInt8]
        let port: UInt16
    }

    let isResponse: Bool
    let errorCode: Int?
    let transaction: [UInt8]
    let username: String?
    let role: Role?
    let priority: UInt32?
    let nominated: Bool
    let mapped: Address?
    private static let cookie: [UInt8] = [0x21, 0x12, 0xa4, 0x42]
    private static let fingerprintMask: UInt32 = 0x5354_554e

    init(packet: [UInt8], password: SymmetricKey) throws {
        guard packet.count <= 65_552 else { throw Failure.malformed }
        let input = ByteSlice(packet)
        var c = input.cursor()
        let type = try c.u16be()
        guard type == 0x0001 || type == 0x0101 || type == 0x0111 else { throw Failure.malformed }
        isResponse = type != 0x0001
        let length = try Int(c.u16be())
        guard length.isMultiple(of: 4), packet.count == 20 + length else { throw Failure.malformed }
        try c.expect(Self.cookie, "STUN cookie")
        transaction = try c.bytes(12).copyBytes()
        var username: String?, role: Role?, priority: UInt32?, mapped: Address?
        var code: Int?
        var nominated = false, authenticated = false, fingerprint = false
        while !c.isAtEnd {
            let offset = c.position
            let attribute = try c.u16be()
            let size = try Int(c.u16be())
            let value = try c.bytes(size)
            try c.skip((4 - size % 4) % 4)
            var field = value.cursor()
            if attribute == 0x8028 {
                guard size == 4, c.isAtEnd, authenticated else { throw Failure.malformed }
                var crc = CRC32()
                var prefix = input.cursor()
                crc.update(try prefix.bytes(offset))
                guard try field.u32be() == crc.value ^ Self.fingerprintMask else { throw Failure.authentication }
                fingerprint = true
                continue
            }
            // RFC 8489 ignores attributes after MESSAGE-INTEGRITY except the fingerprint.
            guard !authenticated else { continue }
            switch attribute {
            case 0x0008:
                guard size == 20 else { throw Failure.malformed }
                var prefix = Array(packet[..<offset])
                Self.setLength(&prefix, bodyBytes: c.position - 20)
                guard HMAC<Insecure.SHA1>.isValidAuthenticationCode(value.copyBytes(), authenticating: prefix, using: password)
                else { throw Failure.authentication }
                authenticated = true
            case 0x0006:
                guard username == nil, let decoded = String(validating: value.copyBytes(), as: UTF8.self) else { throw Failure.malformed }
                username = decoded
            case 0x0024:
                guard priority == nil, size == 4 else { throw Failure.malformed }
                priority = try field.u32be()
            case 0x0025:
                guard !nominated, size == 0 else { throw Failure.malformed }
                nominated = true
            case 0xc001:
                // Signal WebRTC uses the Google ICE nomination attribute with V4 peers.
                guard !nominated, size == 4, try field.u32be() > 0 else { throw Failure.malformed }
                nominated = true
            case 0x0009:
                guard code == nil, size >= 4 else { throw Failure.malformed }
                try field.skip(2)
                let family = try Int(field.u8() & 7)
                let detail = try Int(field.u8())
                guard (3...6).contains(family), detail < 100 else { throw Failure.malformed }
                code = 100 * family + detail
            case 0x8029, 0x802a:
                guard role == nil, size == 8 else { throw Failure.malformed }
                let tie = try field.u64be()
                role = attribute == 0x8029 ? .controlled(tie) : .controlling(tie)
            case 0x0020:
                guard mapped == nil else { throw Failure.malformed }
                _ = try field.u8()
                let family = try field.u8()
                let port = try field.u16be() ^ 0x2112
                guard (family == 1 && size == 8) || (family == 2 && size == 20) else { throw Failure.malformed }
                let mask = Self.cookie + transaction
                mapped = Address(ip: zip(field.rest().copyBytes(), mask).map(^), port: port)
            default:
                guard attribute >= 0x8000 else { throw Failure.unsupportedAttribute }
            }
        }
        guard authenticated && fingerprint else { throw Failure.authentication }
        guard (type == 0x0111) == (code != nil) else { throw Failure.malformed }
        guard isResponse ? mapped != nil || code != nil : username != nil else { throw Failure.malformed }
        self.errorCode = code
        self.username = username
        self.role = role
        self.priority = priority
        self.nominated = nominated
        self.mapped = mapped
    }

    static func request(transaction: [UInt8], username: String, role: Role, priority: UInt32,
                        nominate: Bool, password: SymmetricKey) throws -> [UInt8] {
        guard transaction.count == 12, (1...513).contains(username.utf8.count) else { throw Failure.malformed }
        var packet = [0, 1, 0, 0] + cookie + transaction
        try append(0x0006, Array(username.utf8), to: &packet)
        try append(0x0024, networkBytes(priority), to: &packet)
        switch role {
        case .controlled(let tie):
            guard !nominate else { throw Failure.malformed }
            try append(0x8029, networkBytes(tie), to: &packet)
        case .controlling(let tie):
            try append(0x802a, networkBytes(tie), to: &packet)
        }
        if nominate { try append(0x0025, [], to: &packet) }
        return try finish(packet, password: password)
    }

    func response(mapped address: Address, password: SymmetricKey) throws -> [UInt8] {
        guard !isResponse, address.ip.count == 4 || address.ip.count == 16 else { throw Failure.malformed }
        var packet = [1, 1, 0, 0] + Self.cookie + transaction
        let port = Self.networkBytes(address.port ^ 0x2112)
        let xorIP = zip(address.ip, Self.cookie + transaction).map(^)
        try Self.append(0x0020, [0, address.ip.count == 4 ? 1 : 2] + port + xorIP, to: &packet)
        return try Self.finish(packet, password: password)
    }

    private static func networkBytes<T: FixedWidthInteger & UnsignedInteger>(_ value: T) -> [UInt8] {
        stride(from: T.bitWidth - 8, through: 0, by: -8).map { UInt8(truncatingIfNeeded: value >> $0) }
    }

    private static func setLength(_ packet: inout [UInt8], bodyBytes: Int) {
        packet[2] = UInt8(truncatingIfNeeded: bodyBytes >> 8)
        packet[3] = UInt8(truncatingIfNeeded: bodyBytes)
    }

    private static func append(_ type: UInt16, _ bytes: [UInt8], to packet: inout [UInt8]) throws {
        guard let count = UInt16(exactly: bytes.count) else { throw Failure.malformed }
        packet += networkBytes(type) + networkBytes(count) + bytes
        packet += Array(repeating: 0, count: (4 - bytes.count % 4) % 4)
    }

    private static func finish(_ headerAndAttributes: [UInt8], password: SymmetricKey) throws -> [UInt8] {
        var packet = headerAndAttributes
        setLength(&packet, bodyBytes: packet.count - 20 + 24)
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: packet, using: password)
        try append(0x0008, Array(mac), to: &packet)
        setLength(&packet, bodyBytes: packet.count - 20 + 8)
        try append(0x8028, networkBytes(CRC32.checksum(packet) ^ fingerprintMask), to: &packet)
        return packet
    }
}
