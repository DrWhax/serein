import CryptoKit
import Foundation

/// RingRTC call-link titles use AES-256-GCM-SIV with empty associated data (RFC 8452).
struct CallLinkRecordCipher {
    private let encryption: AESBlockCipher
    private let multiplier: UInt128
    private let nonce: [UInt8]

    init(key: SymmetricKey, nonce: [UInt8]) throws {
        guard key.bitCount == 256, nonce.count == 12 else { throw CallingWireError.malformed }
        self.nonce = nonce
        let master = try AESBlockCipher(key)
        var input = SIMD16<UInt8>()
        for i in nonce.indices { input[4 + i] = nonce[i] }
        var derived = [UInt8]()
        for i in 0..<6 {
            input[0] = UInt8(i)
            let block = master.encrypt(input)
            derived += (0..<8).map { block[$0] }
        }
        let auth = derived.prefix(16).reversed().reduce(UInt128.zero) { $0 << 8 | UInt128($1) }
        multiplier = Self.multiplyX(auth)
        encryption = try AESBlockCipher(SymmetricKey(data: derived.suffix(32)))
    }

    // POLYVAL via the GHASH field isomorphism in Appendix A. The integer is the
    // big-endian GHASH element after byte reversal, i.e. a little-endian input.
    private static func multiplyX(_ v: UInt128) -> UInt128 {
        (v >> 1) ^ ((0 &- (v & 1)) & (UInt128(0xe1) << 120))
    }

    private func multiply(_ value: UInt128) -> UInt128 {
        var bits = value
        var v = multiplier
        var z: UInt128 = 0
        for _ in 0..<128 {
            z ^= (0 &- (bits >> 127)) & v
            bits <<= 1
            v = Self.multiplyX(v)
        }
        return z
    }

    private func tag(for bytes: [UInt8]) -> SIMD16<UInt8> {
        var hash: UInt128 = 0
        for start in stride(from: 0, to: bytes.count, by: 16) {
            var block: UInt128 = 0
            for i in 0..<min(16, bytes.count - start) { block |= UInt128(bytes[start + i]) << (8 * i) }
            hash = multiply(hash ^ block)
        }
        hash = multiply(hash ^ (UInt128(bytes.count) << 67))
        var input = SIMD16<UInt8>()
        for i in 0..<16 { input[i] = UInt8(truncatingIfNeeded: hash >> (8 * i)) }
        for i in nonce.indices { input[i] ^= nonce[i] }
        input[15] &= 0x7f
        return encryption.encrypt(input)
    }

    private func crypt(_ input: [UInt8], tag: SIMD16<UInt8>) -> [UInt8] {
        var counter = tag
        counter[15] |= 0x80
        var output = input
        for start in stride(from: 0, to: input.count, by: 16) {
            let key = encryption.encrypt(counter)
            for i in 0..<min(16, input.count - start) { output[start + i] ^= key[i] }
            var carry: UInt16 = 1
            for i in 0..<4 {
                carry += UInt16(counter[i])
                counter[i] = UInt8(truncatingIfNeeded: carry)
                carry >>= 8
            }
        }
        return output
    }

    func seal(_ plain: [UInt8]) -> [UInt8] {
        let tag = tag(for: plain)
        return crypt(plain, tag: tag) + (0..<16).map { tag[$0] }
    }

    func open(_ record: [UInt8]) throws -> [UInt8] {
        guard record.count >= 16 else { throw CallingWireError.malformed }
        var received = SIMD16<UInt8>()
        for i in 0..<16 { received[i] = record[record.count - 16 + i] }
        let plain = crypt(Array(record.dropLast(16)), tag: received)
        let diff = received ^ tag(for: plain)
        guard (0..<16).reduce(UInt8.zero, { $0 | diff[$1] }) == 0 else { throw CallingWireError.malformed }
        return plain
    }
}

package struct CallLinkNameCipher {
    private let key: SymmetricKey
    private static let limit = 65_536

    package init(rootKey: Data) throws {
        guard rootKey.count == 16 || rootKey.count == 21 else { throw CallingWireError.malformed }
        let info = rootKey.count == 16 ? "20230501-Signal-CallLinkRootKey-AES" : "20251219-Signal-CallLinkRootKey-AES"
        key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: rootKey.prefix(16)), info: Data(info.utf8), outputByteCount: 32)
    }

    package func seal(_ title: String) throws -> Data {
        guard !title.isEmpty else { return Data() }
        guard title.utf8.count <= Self.limit else { throw CallingWireError.malformed }
        let nonce = (0..<12).map { _ in UInt8.random(in: .min ... .max) }
        var plain = Array(title.utf8) + [0x80]
        plain += Array(repeating: 0, count: (32 - (12 + plain.count) % 32) % 32)
        return try Data(nonce + CallLinkRecordCipher(key: key, nonce: nonce).seal(plain))
    }

    package func open(_ envelope: Data) throws -> String {
        guard !envelope.isEmpty else { return "" }
        guard (28...(Self.limit + 60)).contains(envelope.count) else { throw CallingWireError.malformed }
        let cipher = try CallLinkRecordCipher(key: key, nonce: Array(envelope.prefix(12)))
        let plain = try cipher.open(Array(envelope.dropFirst(12)))
        guard let marker = plain.lastIndex(of: 0x80), let title = String(bytes: plain[..<marker], encoding: .utf8) else {
            throw CallingWireError.malformed
        }
        return title
    }
}
