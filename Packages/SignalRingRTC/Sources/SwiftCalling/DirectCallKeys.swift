import CryptoKit
import Foundation

/// Master key and salt for one sending direction, before the SRTP session-key derivation.
package struct DirectCallKeys: Equatable, Sendable {
    package struct Direction: Equatable, Sendable {
        package let key: SymmetricKey
        package let salt: SymmetricKey
    }

    package let offer: Direction
    package let answer: Direction

    /// RingRTC connection.rs, negotiate_srtp_keys. Both endpoints supply the identity keys
    /// in signaling order, independently of which one holds the local ephemeral private key.
    package init(local: Curve25519.KeyAgreement.PrivateKey, remote: Data,
                 callerIdentity: Data, calleeIdentity: Data) throws {
        // RingRTC binds the exact bytes supplied by its application. Serein supplies raw
        // 32-byte public keys; some embedders supply Signal's 33-byte serialized keys.
        guard (32...33).contains(callerIdentity.count), callerIdentity.count == calleeIdentity.count,
              remote.count == 32 else {
            throw CallingWireError.malformed
        }
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remote)
        let secret = try local.sharedSecretFromKeyAgreement(with: peer)
        if secret == Data(repeating: 0, count: 32) { throw CallingWireError.malformed }
        var info = Data("Signal_Calling_20200807_SignallingDH_SRTPKey_KDF".utf8)
        info.append(callerIdentity)
        info.append(calleeIdentity)
        let material = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(repeating: 0, count: 32),
                                                     sharedInfo: info, outputByteCount: 88)
        let bytes = material.bytes
        offer = Direction(key: SymmetricKey(copying: bytes.extracting(0..<32)),
                          salt: SymmetricKey(copying: bytes.extracting(32..<44)))
        answer = Direction(key: SymmetricKey(copying: bytes.extracting(44..<76)),
                           salt: SymmetricKey(copying: bytes.extracting(76..<88)))
    }
}
