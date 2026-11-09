// Symmetric primitives used by Signal's application-layer formats (provisioning
// envelope, device names, profiles, attachments). Only authenticated protocol bytes
// reach these, never untrusted media.
//
// No pointer code (builds under -strict-memory-safety with zero `unsafe`):
//   HMAC / SHA-256          CryptoKit
//   AES-256-CBC (PKCS#7)    libsignal signal_crypto (Aes256Cbc, Tools/vendor-patches/libsignal-aes-cbc.patch)
//   AES-256-CTR             libsignal signal_crypto (Aes256Ctr32)
//   AES-256-GCM             CryptoKit
//   HKDF-SHA256             libsignal hkdf
//   random bytes            SystemRandomNumberGenerator (arc4random_buf, the kernel CSPRNG)

import CryptoKit
import Foundation
import LibSignalClient

public enum SignalCryptoError: Error, Equatable {
    case badMAC
    case badLength(String)
}

public enum SignalCrypto {
    public static func randomBytes(_ n: Int) -> Data {
        var rng = SystemRandomNumberGenerator()
        var out = Data(capacity: n)
        while out.count < n {
            let word = rng.next()
            for shift in stride(from: 0, to: 64, by: 8) where out.count < n { out.append(UInt8(truncatingIfNeeded: word >> UInt64(shift))) }
        }
        return out
    }

    public static func hmacSHA256(key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    public static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    /// Constant-time comparison for MACs.
    public static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }

    static func checkLengths(key: Data, iv: Data) throws {
        guard key.count == 32 else { throw SignalCryptoError.badLength("AES key \(key.count)") }
        guard iv.count == 16 else { throw SignalCryptoError.badLength("IV \(iv.count)") }
    }

    public static func aes256CBCEncrypt(key: Data, iv: Data, _ plaintext: Data) throws -> Data {
        try checkLengths(key: key, iv: iv)
        return try Aes256Cbc.encrypt(plaintext, key: key, iv: iv)
    }

    public static func aes256CBCDecrypt(key: Data, iv: Data, _ ciphertext: Data) throws -> Data {
        try checkLengths(key: key, iv: iv)
        return try Aes256Cbc.decrypt(ciphertext, key: key, iv: iv)
    }

    /// AES-256-CTR: 96-bit nonce ‖ 32-bit big-endian counter taken from `iv`
    /// (identical to a 128-bit counter for messages under 2^32 blocks, which is all Signal uses).
    public static func aes256CTR(key: Data, iv: Data, _ data: Data) throws -> Data {
        try checkLengths(key: key, iv: iv)
        let startCounter = iv.suffix(4).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard startCounter + UInt64((data.count + 15) / 16) <= UInt64(UInt32.max) + 1 else {
            throw SignalCryptoError.badLength("CTR counter would wrap")
        }
        var out = data
        try Aes256Ctr32(key: key, nonce: iv).process(&out)
        return out
    }
}

extension SignalCrypto {
    /// AES-256-GCM in Signal's wire layout: nonce(12) ‖ ciphertext ‖ tag(16)
    /// (profiles, storage service manifests and records).
    public static func aes256GCMDecrypt(key: Data, _ combined: Data) throws -> Data {
        guard key.count == 32 else { throw SignalCryptoError.badLength("AES key \(key.count)") }
        guard combined.count >= 12 + 16 else { throw SignalCryptoError.badLength("GCM message \(combined.count)") }
        do {
            return try AES.GCM.open(try AES.GCM.SealedBox(combined: combined), using: SymmetricKey(data: key))
        } catch {
            throw SignalCryptoError.badMAC
        }
    }

    /// Always under a fresh random nonce: a caller cannot supply one (a repeated nonce under
    /// one key breaks GCM completely).
    public static func aes256GCMEncrypt(key: Data, _ plaintext: Data) throws -> Data {
        try aes256GCMEncrypt(key: key, nonce: randomBytes(12), plaintext)
    }

    /// With a given nonce: for known-answer tests only, hence not public.
    static func aes256GCMEncrypt(key: Data, nonce: Data, _ plaintext: Data) throws -> Data {
        guard key.count == 32 else { throw SignalCryptoError.badLength("AES key \(key.count)") }
        let n = try AES.GCM.Nonce(data: nonce)
        guard let combined = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: n).combined else {
            throw SignalCryptoError.badLength("GCM nonce")
        }
        return combined
    }

    /// HKDF-SHA256 (RFC 5869).
    public static func hkdf(_ length: Int, ikm: Data, info: Data, salt: Data = Data()) throws -> Data {
        try LibSignalClient.hkdf(outputLength: length, inputKeyMaterial: ikm, salt: salt, info: info)
    }
}

extension Data {
    public var hex: String {
        let digits = Array("0123456789abcdef")
        return String(flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 0xF)]] })
    }
}
