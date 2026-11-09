// Guards for properties that known-answer tests cannot show (docs/crypto-review.md): where
// primitives may be called from, and that nothing outside tests chooses an IV or nonce.
// A new call site makes one of these fail, which is the prompt to review it and add it here.

import Foundation
import Testing
@testable import SignalCore

@Suite struct CryptoHygieneTests {
    /// Sources/SignalCore, found from this file's location.
    private static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/SignalCore")

    /// File name → its text with comments removed.
    private func code() throws -> [String: String] {
        var out: [String: String] = [:]
        let files = FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        for url in files where url.pathExtension == "swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            out[url.lastPathComponent] = lines.map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }.joined(separator: "\n")
        }
        #expect(out.count > 50)
        return out
    }

    private func files(using pattern: String, in code: [String: String]) -> Set<String> {
        Set(code.filter { $0.value.contains(pattern) }.keys)
    }

    /// CBC has no integrity of its own: each decrypt must sit behind a verified MAC, or a
    /// padding oracle opens. The reviewed call sites all check the MAC first.
    @Test func cbcDecryptOnlyBehindAReviewedMAC() throws {
        let code = try code()
        #expect(files(using: "aes256CBCDecrypt(", in: code) == ["Crypto.swift", "ProvisioningCipher.swift", "AttachmentCipher.swift"])
        for file in ["ProvisioningCipher.swift", "AttachmentCipher.swift"] {
            let text = try #require(code[file])
            // In every function, the comparison comes before the decryption.
            for body in text.components(separatedBy: "func ").dropFirst() where body.contains("aes256CBCDecrypt(") {
                let mac = try #require(body.range(of: "constantTimeEqual("), "\(file): CBC decrypt without a MAC check")
                let decrypt = try #require(body.range(of: "aes256CBCDecrypt("))
                #expect(mac.lowerBound < decrypt.lowerBound, "\(file): decrypts before checking the MAC")
            }
        }
    }

    /// MACs and digests are only ever compared in constant time, never with ==.
    @Test func macsAreComparedInConstantTime() throws {
        let code = try code()
        let comparing = files(using: "hmacSHA256(", in: code).subtracting(["Crypto.swift"])
        for file in comparing {
            let text = try #require(code[file])
            for line in text.split(separator: "\n") where line.contains("hmacSHA256(") && (line.contains(" == ") || line.contains(" != ")) {
                #expect(line.contains("constantTimeEqual("), "\(file): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(!comparing.isEmpty)
    }

    /// Nothing but the wrappers and tests picks an IV or nonce, and raw primitives stay in
    /// the files that were reviewed.
    @Test func noCallerChoosesAnIVAndPrimitivesStayPut() throws {
        let code = try code()
        #expect(files(using: "aes256GCMEncrypt(key:", in: code).allSatisfy { file in
            file == "Crypto.swift" || !(code[file] ?? "").contains("nonce:")
        })
        for (file, text) in code where file != "AttachmentCipher.swift" {
            for line in text.split(separator: "\n") where line.contains("AttachmentCipher.encrypt(") {
                #expect(!line.contains("iv:"), "\(file) passes an IV: \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(files(using: "import CryptoKit", in: code) == ["Crypto.swift", "OptionalResources.swift", "ConversationQueries.swift"])
        #expect(files(using: "aes256CTR(", in: code) == ["Crypto.swift", "ProvisioningCipher.swift"])
        #expect(files(using: "Aes256Cbc.", in: code).union(files(using: "Aes256Ctr32(", in: code)) == ["Crypto.swift"])
        // One source of random bytes, and it is the system generator.
        let crypto = try #require(code["Crypto.swift"])
        #expect(crypto.contains("SystemRandomNumberGenerator()"))
        #expect(files(using: "arc4random", in: code).isEmpty && files(using: "srand", in: code).isEmpty && files(using: "drand48", in: code).isEmpty)
    }

    /// The comparison itself: equal only for identical bytes, and no early exit on a mismatch
    /// position (every byte takes part).
    @Test func constantTimeEqualSemantics() {
        let a = SignalCrypto.randomBytes(32)
        #expect(SignalCrypto.constantTimeEqual(a, a))
        #expect(!SignalCrypto.constantTimeEqual(a, a.prefix(31)))
        #expect(!SignalCrypto.constantTimeEqual(Data(), a))
        #expect(SignalCrypto.constantTimeEqual(Data(), Data()))
        for i in 0..<32 {
            var b = a
            b[i] ^= 0x80
            #expect(!SignalCrypto.constantTimeEqual(a, b))
        }
        // A slice with a non-zero start index compares by content.
        #expect(SignalCrypto.constantTimeEqual((Data([9]) + a).dropFirst(), a))
    }

    /// Fresh randomness per encryption: two encryptions of the same input never share an IV,
    /// nonce or ephemeral key.
    @Test func everyEncryptionIsRandomised() throws {
        let key = SignalCrypto.randomBytes(32), message = Data("same input".utf8)
        let gcm = try (0..<50).map { _ in try SignalCrypto.aes256GCMEncrypt(key: key, message) }
        #expect(Set(gcm.map { $0.prefix(12) }).count == 50)
        let keys = AttachmentCipher.generateKeys()
        let attachments = try (0..<50).map { _ in try AttachmentCipher.encrypt(message, keys: keys).blob }
        #expect(Set(attachments.map { $0.prefix(16) }).count == 50)
        #expect(Set((0..<50).map { _ in AttachmentCipher.generateKeys() }).count == 50)
        let identity = IdentityKeyPairForTests.shared
        let names = try (0..<20).map { _ in try DeviceNameCipher.encrypt("Serein", identityPublicKey: identity.publicKey) }
        #expect(Set(names).count == 20)
        #expect(Set((0..<200).map { _ in SignalCrypto.randomBytes(16) }).count == 200)
        #expect(SignalCrypto.randomBytes(0).isEmpty && SignalCrypto.randomBytes(33).count == 33)
    }
}

import LibSignalClient
private enum IdentityKeyPairForTests { static let shared = IdentityKeyPair.generate() }
