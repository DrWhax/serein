// ProvisionEnvelope decryption (port of Desktop ts/textsecure/ProvisioningCipher.node.ts).
//
//   envelope := ProvisionEnvelope{ publicKey: ephemeral X25519 (33 bytes), body }
//   body     := version:u8{1} iv:16 ciphertext mac:32
//   keys     := HKDF(X25519(ours, ephemeral), info = "TextSecure Provisioning Message") → aes:32 ‖ mac:32
//   mac      == HMAC-SHA256(mac key, version ‖ iv ‖ ciphertext)
//   plaintext = AES-256-CBC-PKCS7(aes key, iv, ciphertext) = ProvisionMessage

import Foundation
import LibSignalClient
import SignalProtos

public enum ProvisioningError: Error, Equatable {
    case malformedEnvelope(String)
    case badMAC
    case missingField(String)
}

public struct ProvisioningCipher: Sendable {
    public let privateKey: PrivateKey
    public var publicKey: PublicKey { privateKey.publicKey }
    static let info = Data("TextSecure Provisioning Message".utf8)

    public init(privateKey: PrivateKey = .generate()) { self.privateKey = privateKey }

    public func decrypt(envelope bytes: Data) throws -> Signalservice_ProvisionMessage {
        let env = try Signalservice_ProvisionEnvelope(serializedBytes: bytes)
        guard env.hasPublicKey, env.hasBody else { throw ProvisioningError.malformedEnvelope("missing publicKey/body") }
        let body = env.body
        guard body.count >= 1 + 16 + 16 + 32 else { throw ProvisioningError.malformedEnvelope("body of \(body.count) bytes") }
        guard body.first == 1 else { throw ProvisioningError.malformedEnvelope("version \(body.first ?? 0)") }
        let theirs = try PublicKey(env.publicKey)
        let keys = try hkdf(outputLength: 64, inputKeyMaterial: privateKey.keyAgreement(with: theirs), salt: Data(), info: Self.info)
        let signed = body.prefix(body.count - 32)
        guard SignalCrypto.constantTimeEqual(SignalCrypto.hmacSHA256(key: keys.suffix(32), Data(signed)), Data(body.suffix(32))) else {
            throw ProvisioningError.badMAC
        }
        let iv = Data(body[body.startIndex + 1..<body.startIndex + 17])
        let ciphertext = Data(body[body.startIndex + 17..<body.endIndex - 32])
        let plaintext = try SignalCrypto.aes256CBCDecrypt(key: keys.prefix(32), iv: iv, ciphertext)
        return try Signalservice_ProvisionMessage(serializedBytes: plaintext)
    }

    /// The primary-device side (for tests): encrypts a ProvisionMessage to `recipient`.
    public static func encrypt(_ message: Signalservice_ProvisionMessage, to recipient: PublicKey) throws -> Data {
        let ephemeral = PrivateKey.generate()
        let keys = try hkdf(outputLength: 64, inputKeyMaterial: ephemeral.keyAgreement(with: recipient), salt: Data(), info: info)
        let iv = SignalCrypto.randomBytes(16)
        let ciphertext = try SignalCrypto.aes256CBCEncrypt(key: keys.prefix(32), iv: iv, try message.serializedData())
        let signed = Data([1]) + iv + ciphertext
        var env = Signalservice_ProvisionEnvelope()
        env.publicKey = ephemeral.publicKey.serialize()
        env.body = signed + SignalCrypto.hmacSHA256(key: keys.suffix(32), signed)
        return try env.serializedData()
    }

    /// `sgnl://linkdevice?uuid=…&pub_key=…` shown as the QR code. Values are
    /// percent-encoded strictly (base64 '+' would otherwise decode as a space).
    public func linkURL(address: String, capabilities: [String] = ["nopni", "nopni2"]) -> String {
        func enc(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? s
        }
        return "sgnl://linkdevice?uuid=\(enc(address))&pub_key=\(enc(publicKey.serialize().base64EncodedString()))&capabilities=\(enc(capabilities.joined(separator: ",")))"
    }
}

/// Encrypted device names (Desktop Crypto.node.ts encryptDeviceName/decryptDeviceName).
public enum DeviceNameCipher {
    public static func encrypt(_ name: String, identityPublicKey: PublicKey) throws -> Data {
        let plaintext = Data(name.utf8)
        let ephemeral = PrivateKey.generate()
        let master = ephemeral.keyAgreement(with: identityPublicKey)
        let key1 = SignalCrypto.hmacSHA256(key: master, Data("auth".utf8))
        let syntheticIV = SignalCrypto.hmacSHA256(key: key1, plaintext).prefix(16)
        let key2 = SignalCrypto.hmacSHA256(key: master, Data("cipher".utf8))
        let cipherKey = SignalCrypto.hmacSHA256(key: key2, Data(syntheticIV))
        var proto = Signalservice_DeviceName()
        proto.ephemeralPublic = ephemeral.publicKey.serialize()
        proto.syntheticIv = Data(syntheticIV)
        proto.ciphertext = try SignalCrypto.aes256CTR(key: cipherKey, iv: Data(count: 16), plaintext)
        return try proto.serializedData()
    }

    public static func decrypt(_ bytes: Data, identityPrivateKey: PrivateKey) throws -> String {
        let proto = try Signalservice_DeviceName(serializedBytes: bytes)
        guard proto.hasEphemeralPublic, proto.hasSyntheticIv, proto.hasCiphertext, proto.syntheticIv.count == 16 else {
            throw ProvisioningError.missingField("DeviceName")
        }
        let master = identityPrivateKey.keyAgreement(with: try PublicKey(proto.ephemeralPublic))
        let key2 = SignalCrypto.hmacSHA256(key: master, Data("cipher".utf8))
        let cipherKey = SignalCrypto.hmacSHA256(key: key2, proto.syntheticIv)
        let plaintext = try SignalCrypto.aes256CTR(key: cipherKey, iv: Data(count: 16), proto.ciphertext)
        let key1 = SignalCrypto.hmacSHA256(key: master, Data("auth".utf8))
        guard SignalCrypto.constantTimeEqual(SignalCrypto.hmacSHA256(key: key1, plaintext).prefix(16), proto.syntheticIv) else {
            throw ProvisioningError.badMAC
        }
        return String(decoding: plaintext, as: UTF8.self)
    }
}
