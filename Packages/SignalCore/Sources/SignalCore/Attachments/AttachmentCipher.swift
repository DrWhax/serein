// Attachment encryption v2 (Desktop ts/AttachmentCrypto.node.ts, in memory):
//   blob = IV(16) ‖ AES-256-CBC(plaintext ‖ zero padding to logPadSize) ‖ HMAC-SHA256(IV ‖ ciphertext)
//   keys = aesKey(32) ‖ macKey(32); digest = SHA-256(blob); plaintextHash = SHA-256(plaintext)
// Optional incremental MAC (libsignal IncrementalMac over the blob, chunk size inferred from the
// ciphertext size) for streaming verification. The pointer's `size` gives the unpadded length.

import Foundation
import LibSignalClient

public enum AttachmentError: Error, Equatable {
    case badKey
    case tooShort
    case badMAC
    case badDigest
    case badPlaintextHash
    case badIncrementalMAC
    case missingDigest
    case sizeMismatch(expected: Int, actual: Int)
}

/// `IntegrityCheckType`: what a downloaded blob is checked against.
public enum AttachmentIntegrity: Sendable, Equatable {
    /// The pointer's digest of the encrypted blob.
    case encrypted(digest: Data)
    /// The plaintext hash (backups, our own re-downloads).
    case plaintext(hash: Data)
    /// Locally re-encrypted files: nothing to check beyond the MAC.
    case local
}

public struct EncryptedAttachment: Sendable, Equatable {
    public var blob: Data
    public var digest: Data
    public var iv: Data
    /// Hex SHA-256 of the plaintext (upstream's `plaintextHash`).
    public var plaintextHash: String
    public var incrementalMac: Data?
    public var chunkSize: Int?
    public var ciphertextSize: Int { blob.count }
}

public struct DecryptedAttachment: Sendable, Equatable {
    public var plaintext: Data
    public var plaintextHash: String
    public var digest: Data
}

public enum AttachmentCipher {
    public static let keySetLength = 64
    public static let ivLength = 16
    public static let macLength = 32

    /// `logPadSize`: the padded plaintext size bucket (at least 541 bytes, steps of 5%).
    public static func logPadSize(_ size: Int) -> Int {
        max(541, Int((pow(1.05, (log(Double(size)) / log(1.05)).rounded(.up))).rounded(.down)))
    }

    /// `getAesCbcCiphertextSize`
    public static func aesCBCCiphertextSize(_ plaintextLength: Int) -> Int { (1 + plaintextLength / 16) * 16 }

    /// `getAttachmentCiphertextSize` (standard tier). Upstream pads the already padded size once
    /// more here; the result only feeds the incremental MAC's chunk-size inference, so it is kept.
    public static func ciphertextSizeForChunking(unpaddedPlaintextSize: Int) -> Int {
        ivLength + aesCBCCiphertextSize(logPadSize(logPadSize(unpaddedPlaintextSize))) + macLength
    }

    public static func generateKeys() -> Data { SignalCrypto.randomBytes(keySetLength) }

    /// Always under a fresh random IV.
    public static func encrypt(_ plaintext: Data, keys: Data = generateKeys(), pad: Bool = true, incrementalMac: Bool = false) throws -> EncryptedAttachment {
        try encrypt(plaintext, keys: keys, iv: SignalCrypto.randomBytes(ivLength), pad: pad, incrementalMac: incrementalMac)
    }

    /// With a given IV: for known-answer tests only (upstream's `dangerousTestOnlyIv`), hence not public.
    static func encrypt(_ plaintext: Data, keys: Data, iv: Data, pad: Bool = true, incrementalMac: Bool = false) throws -> EncryptedAttachment {
        guard keys.count == keySetLength, iv.count == ivLength else { throw AttachmentError.badKey }
        let aesKey = Data(keys.prefix(32)), macKey = Data(keys.suffix(32))
        var padded = plaintext
        if pad { padded.append(Data(count: logPadSize(plaintext.count) - plaintext.count)) }
        let body = iv + (try SignalCrypto.aes256CBCEncrypt(key: aesKey, iv: iv, padded))
        let blob = body + SignalCrypto.hmacSHA256(key: macKey, body)
        var mac: Data?, chunk: Int?
        if incrementalMac {
            let context = try IncrementalMacContext(key: macKey, chunkSize: .chunkOf(UInt32(ciphertextSizeForChunking(unpaddedPlaintextSize: plaintext.count))))
            try context.update(blob)
            mac = try context.finalize()
            chunk = Int(context.chunkSizeInBytes)
        }
        return EncryptedAttachment(blob: blob, digest: SignalCrypto.sha256(blob), iv: iv, plaintextHash: SignalCrypto.sha256(plaintext).hexString,
                                   incrementalMac: mac, chunkSize: chunk)
    }

    /// `decryptAttachmentV2`: checks the MAC, then the integrity source, then (when given) the
    /// incremental MAC, and trims the padding to `size`.
    public static func decrypt(_ blob: Data, keys: Data, size: Int, integrity: AttachmentIntegrity,
                               incrementalMac: Data? = nil, chunkSize: Int? = nil) throws -> DecryptedAttachment {
        try decrypt(blob, keys: keys, trimTo: size, integrity: integrity, incrementalMac: incrementalMac, chunkSize: chunkSize)
    }

    /// `trimTo` nil keeps the padding (callers that have no size).
    static func decrypt(_ blob: Data, keys: Data, trimTo size: Int?, integrity: AttachmentIntegrity,
                        incrementalMac: Data? = nil, chunkSize: Int? = nil) throws -> DecryptedAttachment {
        guard keys.count == keySetLength else { throw AttachmentError.badKey }
        guard blob.count >= ivLength + 16 + macLength, (blob.count - ivLength - macLength) % 16 == 0 else { throw AttachmentError.tooShort }
        let aesKey = Data(keys.prefix(32)), macKey = Data(keys.suffix(32))
        let body = Data(blob.prefix(blob.count - macLength))
        guard SignalCrypto.constantTimeEqual(SignalCrypto.hmacSHA256(key: macKey, body), Data(blob.suffix(macLength))) else { throw AttachmentError.badMAC }
        let digest = SignalCrypto.sha256(blob)
        if let incrementalMac, let chunkSize, chunkSize > 0 {
            let validator: ValidatingMacContext
            do { validator = try ValidatingMacContext(key: macKey, chunkSize: .bytes(UInt32(chunkSize)), expectingDigest: incrementalMac) } catch {
                throw AttachmentError.badIncrementalMAC
            }
            do {
                _ = try validator.update(blob)
                _ = try validator.finalize()
            } catch { throw AttachmentError.badIncrementalMAC }
        }
        let padded = try SignalCrypto.aes256CBCDecrypt(key: aesKey, iv: Data(body.prefix(ivLength)), Data(body.dropFirst(ivLength)))
        // Upstream trims to the pointer's size and does not object to one that is larger than
        // what is there: it then yields everything, padding included.
        let plaintext = size.map { Data(padded.prefix(max(0, $0))) } ?? padded
        let plaintextHash = SignalCrypto.sha256(plaintext)
        switch integrity {
        case .encrypted(let expected):
            guard !expected.isEmpty else { throw AttachmentError.missingDigest }
            guard SignalCrypto.constantTimeEqual(digest, expected) else { throw AttachmentError.badDigest }
        case .plaintext(let expected):
            guard SignalCrypto.constantTimeEqual(plaintextHash, expected) else { throw AttachmentError.badPlaintextHash }
        case .local:
            break
        }
        return DecryptedAttachment(plaintext: plaintext, plaintextHash: plaintextHash.hexString, digest: digest)
    }

    /// The pointer form used by contact sync: digest required, size optional (no size: the
    /// whole decrypted body, padding included).
    public static func decrypt(_ blob: Data, key: Data, digest: Data?, size: Int?) throws -> Data {
        guard key.count == keySetLength else { throw AttachmentError.badKey }
        guard let digest, !digest.isEmpty else { throw AttachmentError.missingDigest }
        return try decrypt(blob, keys: key, trimTo: size, integrity: .encrypted(digest: digest)).plaintext
    }

    /// `decryptAndReencryptLocally`: verify a download, then encrypt it at rest under a fresh
    /// local key (version 2 local format: the same blob layout, padded, no incremental MAC).
    public static func reencryptLocally(_ blob: Data, keys: Data, size: Int, integrity: AttachmentIntegrity,
                                        incrementalMac: Data? = nil, chunkSize: Int? = nil) throws -> LocalAttachment {
        let decrypted = try decrypt(blob, keys: keys, size: size, integrity: integrity, incrementalMac: incrementalMac, chunkSize: chunkSize)
        let localKey = generateKeys()
        let local = try encrypt(decrypted.plaintext, keys: localKey)
        return LocalAttachment(blob: local.blob, localKey: localKey, plaintextHash: decrypted.plaintextHash, digest: decrypted.digest, size: size)
    }

    /// `decryptAttachmentV1` (sticker manifests and images): IV(16) ‖ AES-256-CBC(PKCS#7) ‖
    /// HMAC-SHA256(IV ‖ ciphertext), no padding to a bucket, no digest.
    public static func decryptV1(_ blob: Data, keys: Data) throws -> Data {
        guard keys.count == keySetLength else { throw AttachmentError.badKey }
        guard blob.count >= 16 + 32 else { throw AttachmentError.tooShort }
        let body = blob.prefix(blob.count - 32)
        let mac = SignalCrypto.hmacSHA256(key: keys.suffix(32), Data(body))
        guard SignalCrypto.constantTimeEqual(mac, Data(blob.suffix(32))) else { throw AttachmentError.badMAC }
        return try SignalCrypto.aes256CBCDecrypt(key: keys.prefix(32), iv: Data(body.prefix(16)), Data(body.dropFirst(16)))
    }

    /// Reads a locally encrypted file back.
    public static func decryptLocal(_ blob: Data, localKey: Data, size: Int) throws -> Data {
        try decrypt(blob, keys: localKey, size: size, integrity: .local).plaintext
    }
}

/// `ReencryptedAttachmentV2`
public struct LocalAttachment: Sendable, Equatable {
    public var blob: Data
    public var localKey: Data
    public var plaintextHash: String
    /// The digest of the downloaded (transit) blob.
    public var digest: Data
    public var size: Int
    public var version: Int { 2 }
}

extension Data {
    var hexString: String {
        let digits = Array("0123456789abcdef")
        var out = ""
        out.reserveCapacity(count * 2)
        for b in self { out.append(digits[Int(b >> 4)]); out.append(digits[Int(b & 0xF)]) }
        return out
    }
}
