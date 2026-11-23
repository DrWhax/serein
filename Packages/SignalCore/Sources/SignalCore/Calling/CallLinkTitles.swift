// Call-link titles, sealed and opened in the app with libsignal's AES-256-GCM-SIV (RustCrypto's
// aes-gcm-siv, the crate upstream RingRTC uses in lite/call_links/root_key.rs). The calling
// service holds no cipher: it passes the SFU's sealed title through (RingRTC.revealingTitle).

import Foundation
import LibSignalClient
import SignalRingRTC

struct CallLinkTitles: CallLinkTitleCipher {
    enum Failure: Error { case rootKey, tooLong }

    static let maxTitleBytes = 65_536
    private static let nonceBytes = 12, tagBytes = 16, blockBytes = 32

    /// root_key.rs `make_cipher`: HKDF-SHA256 without salt over the 16-byte call-link root,
    /// with V0's or V1's info string.
    private static func cipher(_ rootKey: CallLinkRootKey) throws -> Aes256GcmSiv {
        let root = rootKey.bytes
        guard root.count == 16 || root.count == 21 else { throw Failure.rootKey }
        let info = root.count == 16 ? "20230501-Signal-CallLinkRootKey-AES" : "20251219-Signal-CallLinkRootKey-AES"
        let key = try SignalCrypto.hkdf(32, ikm: Data(root.prefix(16)), info: Data(info.utf8))
        return try Aes256GcmSiv(key: key)
    }

    /// root_key.rs `encrypt`: nonce || seal(title || 0x80 || 0x00*) || tag, padded so the nonce and
    /// plaintext fill whole 32-byte blocks. An empty title is sent as an empty name, as RingRTC does.
    func seal(_ title: String, rootKey: CallLinkRootKey) throws -> Data {
        guard !title.isEmpty else { return Data() }
        guard title.utf8.count <= Self.maxTitleBytes else { throw Failure.tooLong }
        let nonce = SignalCrypto.randomBytes(Self.nonceBytes)
        var plain = Data(title.utf8)
        plain.append(0x80)
        plain.append(Data(repeating: 0, count: (Self.blockBytes - (Self.nonceBytes + plain.count) % Self.blockBytes) % Self.blockBytes))
        return nonce + (try Self.cipher(rootKey).encrypt(plain, nonce: nonce, associatedData: Data()))
    }

    /// root_key.rs `decrypt`: everything before the last 0x80 marker, which must be UTF-8.
    func open(_ encrypted: Data, rootKey: CallLinkRootKey) -> String? {
        guard encrypted.count >= Self.nonceBytes + Self.tagBytes,
              encrypted.count <= Self.maxTitleBytes + Self.nonceBytes + Self.tagBytes + Self.blockBytes,
              let cipher = try? Self.cipher(rootKey) else { return nil }
        let record = Data(encrypted)
        guard let plain = try? cipher.decrypt(record.dropFirst(Self.nonceBytes), nonce: record.prefix(Self.nonceBytes), associatedData: Data()),
              let marker = plain.lastIndex(of: 0x80) else { return nil }
        return String(bytes: plain[..<marker], encoding: .utf8)
    }
}
