// Project Wycheproof against SignalCore's primitive wrappers (Support/Crypto.swift): the
// known edge cases of each primitive (bad padding, modified tags, odd lengths, special
// values) rather than the constructions built on them, which UpstreamVectorTests covers.
// AES-CBC is the one that matters most: it comes from our own patch to libsignal.

import Foundation
import Testing
@testable import SignalCore

@Suite struct WycheproofTests {
    private struct Group {
        var parameters: [String: Any]
        var tests: [[String: Any]]
        func int(_ key: String) -> Int? { (parameters[key] as? NSNumber)?.intValue }
    }

    private func groups(_ file: String) throws -> [Group] {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Resources/Wycheproof/\(file).json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return (json["testGroups"] as? [[String: Any]] ?? []).map { Group(parameters: $0, tests: $0["tests"] as? [[String: Any]] ?? []) }
    }

    private func hex(_ test: [String: Any], _ key: String) -> Data { Data(hexString: test[key] as? String ?? "") }
    private func label(_ test: [String: Any]) -> String { "tcId \(test["tcId"] ?? "?"): \(test["comment"] ?? "")" }

    /// AES-256-CBC with PKCS#7 padding: every valid vector both ways, and every invalid one
    /// (wrong padding bytes, padding longer than a block, missing final block…) refused.
    @Test func aes256CBC() throws {
        var valid = 0, invalid = 0
        for group in try groups("aes_cbc_pkcs5_test") where group.int("keySize") == 256 {
            for t in group.tests {
                let key = hex(t, "key"), iv = hex(t, "iv"), message = hex(t, "msg"), ciphertext = hex(t, "ct")
                switch t["result"] as? String {
                case "valid":
                    #expect(try SignalCrypto.aes256CBCEncrypt(key: key, iv: iv, message) == ciphertext, "\(label(t))")
                    #expect(try SignalCrypto.aes256CBCDecrypt(key: key, iv: iv, ciphertext) == message, "\(label(t))")
                    valid += 1
                case "invalid":
                    #expect(throws: (any Error).self, "\(label(t))") { try SignalCrypto.aes256CBCDecrypt(key: key, iv: iv, ciphertext) }
                    invalid += 1
                default:
                    Issue.record("unexpected result in \(label(t))")
                }
            }
        }
        #expect(valid == 24 && invalid == 48)
    }

    /// AES-256-GCM in the only shape we use: 96-bit nonce, 128-bit tag, no associated data.
    @Test func aes256GCM() throws {
        var valid = 0, invalid = 0, withAssociatedData = 0
        for group in try groups("aes_gcm_test") where group.int("keySize") == 256 && group.int("ivSize") == 96 && group.int("tagSize") == 128 {
            for t in group.tests {
                guard hex(t, "aad").isEmpty else { withAssociatedData += 1; continue }
                let key = hex(t, "key"), nonce = hex(t, "iv"), message = hex(t, "msg")
                let combined = nonce + hex(t, "ct") + hex(t, "tag")
                switch t["result"] as? String {
                case "valid":
                    #expect(try SignalCrypto.aes256GCMDecrypt(key: key, combined) == message, "\(label(t))")
                    #expect(try SignalCrypto.aes256GCMEncrypt(key: key, nonce: nonce, message) == combined, "\(label(t))")
                    valid += 1
                case "invalid":
                    #expect(throws: SignalCryptoError.badMAC, "\(label(t))") { try SignalCrypto.aes256GCMDecrypt(key: key, combined) }
                    invalid += 1
                default:
                    Issue.record("unexpected result in \(label(t))")
                }
            }
        }
        #expect(valid >= 10 && invalid >= 20, "valid \(valid), invalid \(invalid), skipped (associated data) \(withAssociatedData)")
        // Other nonce sizes are not something the wrapper will take.
        #expect(throws: (any Error).self) { try SignalCrypto.aes256GCMEncrypt(key: Data(count: 32), nonce: Data(count: 16), Data()) }
    }

    @Test func hkdfSHA256() throws {
        var valid = 0, invalid = 0
        for group in try groups("hkdf_sha256_test") {
            for t in group.tests {
                let size = (t["size"] as? NSNumber)?.intValue ?? 0
                switch t["result"] as? String {
                case "valid":
                    #expect(try SignalCrypto.hkdf(size, ikm: hex(t, "ikm"), info: hex(t, "info"), salt: hex(t, "salt")) == hex(t, "okm"), "\(label(t))")
                    valid += 1
                case "invalid":   // more output than HKDF can give
                    #expect(throws: (any Error).self, "\(label(t))") { try SignalCrypto.hkdf(size, ikm: hex(t, "ikm"), info: hex(t, "info"), salt: hex(t, "salt")) }
                    invalid += 1
                default:
                    Issue.record("unexpected result in \(label(t))")
                }
            }
        }
        #expect(valid == 83 && invalid == 3)
    }

    /// HMAC-SHA256, full and truncated to 128 bits (the device-name synthetic IV), compared
    /// the way the code compares MACs.
    @Test func hmacSHA256() throws {
        var valid = 0, invalid = 0
        for group in try groups("hmac_sha256_test") {
            let tagBytes = (group.int("tagSize") ?? 256) / 8
            for t in group.tests {
                let ours = SignalCrypto.hmacSHA256(key: hex(t, "key"), hex(t, "msg")).prefix(tagBytes)
                let matches = SignalCrypto.constantTimeEqual(Data(ours), hex(t, "tag"))
                switch t["result"] as? String {
                case "valid": #expect(matches, "\(label(t))"); valid += 1
                case "invalid": #expect(!matches, "\(label(t))"); invalid += 1
                default: Issue.record("unexpected result in \(label(t))")
                }
            }
        }
        #expect(valid == 66 && invalid == 108)
    }
}
