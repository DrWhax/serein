// Attachment encryption v2 (Desktop AttachmentCrypto.node.ts decryptAttachmentV2,
// non-streaming subset): blob = IV(16) ‖ AES-256-CBC ciphertext ‖ HMAC-SHA256(IV ‖ ciphertext),
// key = aesKey(32) ‖ macKey(32), digest = SHA-256(blob). The plaintext is padded; the
// pointer's size gives the real length.

import Foundation

public enum AttachmentError: Error, Equatable {
    case badKey
    case tooShort
    case badMAC
    case badDigest
    case missingDigest
    case sizeMismatch(expected: Int, actual: Int)
}

public enum AttachmentCipher {
    public static func decrypt(_ blob: Data, key: Data, digest: Data?, size: Int?) throws -> Data {
        guard key.count == 64 else { throw AttachmentError.badKey }
        guard blob.count >= 16 + 16 + 32, (blob.count - 16 - 32) % 16 == 0 else { throw AttachmentError.tooShort }
        guard let digest, !digest.isEmpty else { throw AttachmentError.missingDigest }
        guard SignalCrypto.constantTimeEqual(SignalCrypto.sha256(blob), digest) else { throw AttachmentError.badDigest }
        let aesKey = key.prefix(32), macKey = key.suffix(32)
        let body = blob.prefix(blob.count - 32)
        let mac = blob.suffix(32)
        guard SignalCrypto.constantTimeEqual(SignalCrypto.hmacSHA256(key: Data(macKey), Data(body)), Data(mac)) else { throw AttachmentError.badMAC }
        let plaintext = try SignalCrypto.aes256CBCDecrypt(key: Data(aesKey), iv: Data(body.prefix(16)), Data(body.dropFirst(16)))
        guard let size else { return plaintext }
        guard size <= plaintext.count else { throw AttachmentError.sizeMismatch(expected: size, actual: plaintext.count) }
        return Data(plaintext.prefix(size))
    }

    /// Encrypts with random keys (tests and, later, uploads). Returns (blob, key, digest).
    public static func encrypt(_ plaintext: Data, key: Data = SignalCrypto.randomBytes(64), iv: Data = SignalCrypto.randomBytes(16)) throws
        -> (blob: Data, key: Data, digest: Data)
    {
        guard key.count == 64 else { throw AttachmentError.badKey }
        let ciphertext = try SignalCrypto.aes256CBCEncrypt(key: Data(key.prefix(32)), iv: iv, plaintext)
        let body = iv + ciphertext
        let blob = body + SignalCrypto.hmacSHA256(key: Data(key.suffix(32)), body)
        return (blob, key, SignalCrypto.sha256(blob))
    }
}
