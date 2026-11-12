// Call-link root keys and era ids in Swift (ringrtc src/rust/src/lite/call_links/root_key.rs,
// base16.rs, core/group_call.rs `RingId::from_era_id`), so that the app computes them without
// ringrtc: the key in a call-link URL someone sent is parsed here, by this grammar alone.
// RingRTCTests compare every function with ringrtc's own (its static commands) on random and
// mangled input.

import CryptoKit
import Foundation

/// `callIdFromEra`: an era id of 16 hex digits is the id itself (0 counts as −1, as ringrtc
/// reserves 0); any other string gets the first 8 bytes of its SHA-256, little-endian.
public func callIdFromEra(_ era: String) -> CallId {
    let utf8 = Array(era.utf8)
    if utf8.count == 16, let i = ConsonantBase16.hexU64(utf8) { return i == 0 ? CallId(bitPattern: -1) : i }
    let digest = Array(SHA256.hash(data: utf8))
    var v: UInt64 = 0
    for k in 0..<8 { v |= UInt64(digest[k]) << UInt64(8 * k) }
    return v
}

/// `ConsonantBase16`: bytes as pairs of consonants, `bcdfghkmnpqrstxz` for 0…15.
enum ConsonantBase16 {
    static let alphabet = Array("bcdfghkmnpqrstxz".utf8)
    static let separator = UInt8(ascii: "-")

    /// `format!("{:-^.n}")`: `bytes` in groups of `chunk` bytes joined by "-" (one group if nil).
    static func format(_ bytes: ArraySlice<UInt8>, chunk: Int? = nil) -> String {
        var out = [UInt8]()
        for (i, b) in bytes.enumerated() {
            if let chunk, i > 0, i % chunk == 0 { out.append(separator) }
            out.append(alphabet[Int(b >> 4)])
            out.append(alphabet[Int(b & 0xF)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// `parse_with_separators`: groups of `chunks[i]` bytes, each group after the first preceded
    /// by "-". As in ringrtc, the string may end after any whole group, and once every group is
    /// read a "-" ends the parse (whatever follows it is not read); nil on any other deviation.
    static func parse(_ string: String, chunks: [Int]) -> [UInt8]? {
        let b = Array(string.utf8)
        var sizes = chunks.makeIterator()
        var result: [UInt8] = []
        guard var left = sizes.next() else { return result }
        var i = 0
        while i < b.count {
            let first = b[i]
            i += 1
            if left == 0 {
                guard first == separator, i < b.count else { return nil }
                guard let next = sizes.next() else { break }
                left = next
                continue
            }
            guard let upper = alphabet.firstIndex(of: first), i < b.count, let lower = alphabet.firstIndex(of: b[i]) else { return nil }
            i += 1
            result.append(UInt8(upper << 4 + lower))
            left -= 1
        }
        return result
    }

    /// Rust's `u64::from_str_radix(s, 16)`: an optional "+", then hex digits (either case).
    static func hexU64(_ utf8: [UInt8]) -> UInt64? {
        let digits = utf8.first == UInt8(ascii: "+") ? utf8.dropFirst() : utf8[...]
        guard !digits.isEmpty, digits.count <= 16 else { return nil }
        var v: UInt64 = 0
        for c in digits {
            let d: UInt8
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): d = c - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): d = c - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): d = c - UInt8(ascii: "A") + 10
            default: return nil
            }
            v = v << 4 | UInt64(d)
        }
        return v
    }
}

/// `CallLinkRootKey`: v0 (16 bytes) or v1 (those 16, a version byte, a 4-byte epoch).
public struct CallLinkRootKey: Sendable, Hashable {
    public let bytes: Data
    init(unchecked bytes: Data) { self.bytes = bytes }

    /// `CRN_LEN` (zkgroup's ROOT_KEY_MAX_BYTES_FOR_SHO).
    static let crnLength = 16
    static let v1Length = crnLength + 1 + 4
    static let v1Version: UInt8 = 1
    static let v1InvalidBit: UInt8 = 0x80
    static let roomIdInfo = Data("20230501-Signal-CallLinkRootKey-RoomId".utf8)

    enum Version { case v0, v1 }

    /// `try_from(&[u8])`: v0 by length, or v1 by length and version; neither may have a
    /// repeated chunk in its first 16 bytes.
    static func version(of bytes: [UInt8]) -> Version? {
        switch bytes.count {
        case crnLength:
            return hasRepeatedChunk(bytes[...]) ? nil : .v0
        case v1Length:
            guard bytes[crnLength] & ~v1InvalidBit == v1Version, !hasRepeatedChunk(bytes[..<crnLength]) else { return nil }
            return .v1
        default:
            return nil
        }
    }

    /// `has_repeated_chunk`: an even-odd pair of bytes with four equal hex digits (0x5555).
    static func hasRepeatedChunk(_ bytes: ArraySlice<UInt8>) -> Bool {
        var i = bytes.startIndex
        while i + 1 < bytes.endIndex {
            if (UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8) % 0x1111 == 0 { return true }
            i += 2
        }
        return false
    }

    /// The version, or `invalidResponse` for bytes that are no key.
    func checkedVersion() throws -> Version {
        guard let v = Self.version(of: [UInt8](bytes)) else { throw RingRTCError.native("invalid root key") }
        return v
    }

    /// `CallLinkRootKey::try_from(&str)`: the v0 form (8 groups of 2 bytes), else the v1 form
    /// (4, 4, 4, 4, 1, 4).
    public static func parse(_ string: String) throws -> CallLinkRootKey {
        for (chunks, version) in [([2, 2, 2, 2, 2, 2, 2, 2], Version.v0), ([4, 4, 4, 4, 1, 4], .v1)] {
            if let b = ConsonantBase16.parse(string, chunks: chunks), Self.version(of: b) == version { return CallLinkRootKey(unchecked: Data(b)) }
        }
        throw RingRTCError.native("invalid root key string")
    }

    public static func fromBytes(_ bytes: Data) throws -> CallLinkRootKey {
        let key = CallLinkRootKey(unchecked: bytes)
        _ = try key.checkedVersion()
        return key
    }

    static func randomBytes(_ n: Int) -> [UInt8] {
        var rng = SystemRandomNumberGenerator()
        return (0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) }
    }

    /// `generate`: a v1 key without its epoch (the server adds it), its 16 random bytes
    /// redrawn until no chunk repeats.
    public static func generate() throws -> CallLinkRootKey {
        var crn = randomBytes(crnLength)
        while hasRepeatedChunk(crn[...]) { crn = randomBytes(crnLength) }
        return CallLinkRootKey(unchecked: Data(crn + [v1Version | v1InvalidBit, 0, 0, 0, 0]))
    }

    /// `generate_admin_passkey`: 16 random bytes.
    public static func generateAdminPassKey() throws -> Data { Data(randomBytes(16)) }

    /// `to_formatted_string`: the form in call-link URLs (`bcdf-ghkm-…`).
    public func formatted() throws -> String {
        let b = [UInt8](bytes)
        switch try checkedVersion() {
        case .v0: return ConsonantBase16.format(b[...], chunk: 2)
        case .v1:
            return ConsonantBase16.format(b[..<Self.crnLength], chunk: 4) + "-" + ConsonantBase16.format(b[Self.crnLength...Self.crnLength])
                + "-" + ConsonantBase16.format(b[(Self.crnLength + 1)...])
        }
    }

    /// `derive_room_id`: HKDF-SHA256 of the first 16 bytes (no salt) to 32 bytes, i.e. one
    /// HMAC block: PRK = HMAC(zeros, ikm), T(1) = HMAC(PRK, info ‖ 1). (Spelled out with HMAC,
    /// whose codes are byte sequences: CryptoKit hands HKDF's output only to unsafe closures.)
    public func deriveRoomId() throws -> Data {
        _ = try checkedVersion()
        let prk = HMAC<SHA256>.authenticationCode(for: bytes.prefix(Self.crnLength), using: SymmetricKey(data: Data(count: 32)))
        return Data(HMAC<SHA256>.authenticationCode(for: Self.roomIdInfo + [1], using: SymmetricKey(data: Data(prk))))
    }

    public func toUnredactedString() throws -> String { try formatted() }

    /// `to_redacted_string`: the first two bytes, the rest starred, for logs.
    public var redacted: String {
        guard let v = try? checkedVersion() else { return "[REDACTED]" }
        let head = ConsonantBase16.format([UInt8](bytes.prefix(2))[...])
        switch v {
        case .v0: return head + "-****-****-****-****-****-****-****"
        case .v1: return head + "****-********-********-********-**-********"
        }
    }
}
