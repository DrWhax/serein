// Differential tests against Signal-Desktop's own TypeScript crypto.
//
// Resources/Crypto/upstream-vectors.json is produced by Tools/crypto-vectors/generate.sh,
// which runs upstream's unmodified source on fixed and deliberately malformed inputs and
// records its output or its refusal. Each test replays one section against the Swift
// port: same bytes out, and the same accept/reject verdict on every malformed input.

import Foundation
import LibSignalClient
import SignalProtos
import SignalRingRTC
import Testing
@testable import SignalCore

private struct Vectors: Decodable {
    struct MAC: Decodable { var key, data, mac: String }
    struct Hash: Decodable { var data, hash: String }
    struct HKDF: Decodable { var ikm, salt, info, output: String }
    struct CBC: Decodable { var key, iv, plaintext, ciphertext: String }
    struct CBCDecrypt: Decodable { var key, iv, ciphertext: String; var ok: Bool; var plaintext: String? }
    struct CTR: Decodable { var key, counter, plaintext, ciphertext: String }
    struct GCM: Decodable { var key, iv, plaintext, combined: String }
    struct PadBytes: Decodable { var plaintext, padded: String }
    struct Unpad: Decodable { var padded: String; var ok: Bool; var plaintext: String? }
    struct StickerKey: Decodable { var packKey, keys: String }
    struct GV1: Decodable { var groupV1Id, masterKey: String }
    struct Storage: Decodable {
        struct Manifest: Decodable { var version, key: String }
        struct Item: Decodable { var raw: String; var recordIkm: String?; var key: String }
        var masterKey, storageKey: String
        var manifestKeys: [Manifest]
        var itemKeys: [Item]
    }
    struct AccessKey: Decodable { var accessKey, verifier: String }
    struct DeviceName: Decodable {
        struct Case: Decodable { var ephemeralPublic, syntheticIv, ciphertext: String; var ok: Bool; var name: String? }
        var identityPrivateKey: String
        var cases: [Case]
    }
    struct Profile: Decodable {
        struct Name: Decodable { var raw, encrypted, given: String; var family: String? }
        struct Text: Decodable { var raw, encrypted, display: String }
        struct Decrypt: Decodable { var data: String; var ok: Bool; var plaintext: String? }
        var profileKey: String
        var names: [Name]
        var strings: [Text]
        var decrypt: [Decrypt]
    }
    struct InMemory: Decodable {
        struct Unpadded: Decodable { var ciphertext, digest: String }
        struct Padded: Decodable { var ciphertextSize: Int; var digest, plaintextHash: String }
        var size: Int
        var keys, iv: String
        var unpadded: Unpadded
        var padded: Padded
    }
    struct V1Decrypt: Decodable { var keys, blob: String; var ok: Bool; var plaintext: String? }
    struct V2: Decodable {
        var size: Int
        var keys, iv: String
        var ciphertextSize: Int
        var digest, plaintextHash: String
        var incrementalMac: String?
        var chunkSize: Int?
    }
    struct Provisioning: Decodable {
        struct Result: Decodable {
            var aci: String
            var pni, number, provisioningCode, userAgent: String?
            var readReceipts: Bool
            var aciPrivateKey: String
            var pniPrivateKey, profileKey, accountEntropyPool: String?
        }
        struct Case: Decodable { var label, envelope: String; var ok: Bool; var result: Result? }
        var ourPrivateKey: String
        var cases: [Case]
    }

    struct Config: Decodable {
        struct Environment: Decodable {
            var storageUrl, sfuUrl, certificateAuthorityDER, serverPublicParams, genericServerPublicParams: String
            var cdn: [String: String]
            var serverTrustRoots: [String]
        }
        var staging, production: Environment
    }

    struct SafetyNumberCase: Decodable {
        var ourAci, ourKey, theirAci, theirKey, qrData: String
        var numberBlocks: [String]
    }

    var desktopCommit: String
    var config: Config
    var safetyNumber: [SafetyNumberCase]
    var hmacSha256: [MAC]
    var sha256: [Hash]
    var hkdf: [HKDF]
    var aesCbc: [CBC]
    var aesCbcDecrypt: [CBCDecrypt]
    var aesCtr: [CTR]
    var aesGcm: [GCM]
    var logPadSize: [[Int]]
    var attachmentCiphertextSize: [[Int]]
    var padMessage: [[Int]]
    var padMessageBytes: [PadBytes]
    var unpad: [Unpad]
    var stickerPackKey: [StickerKey]
    var groupV1MasterKey: [GV1]
    var storage: Storage
    var accessKeyVerifier: [AccessKey]
    var deviceName: DeviceName
    var profile: Profile
    var attachmentInMemory: [InMemory]
    var attachmentV1Decrypt: [V1Decrypt]
    var attachmentV2: [V2]
    var provisioning: Provisioning

    static let shared: Vectors = {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Resources/Crypto/upstream-vectors.json")
        return try! JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }()
}

private func bytes(_ hex: String) -> Data { Data(hexString: hex) }

/// The plaintext pattern generate.mjs uses for attachments.
private func pattern(_ size: Int) -> Data {
    Data((0..<size).map { UInt8(truncatingIfNeeded: $0 * 131 + ($0 >> 8) * 17 + 89) })
}

/// The Swift side's verdict on one input: its output, or nil when it refused.
private func attempt<T>(_ body: () throws -> T) -> T? { try? body() }

@Suite struct UpstreamVectorTests {
    private let v = Vectors.shared

    // MARK: trust anchors

    /// The pinned CA, the sealed-sender trust roots and the zkgroup parameters are Desktop's,
    /// per environment, and nothing else is trusted alongside them.
    @Test func environmentConstants() throws {
        for (env, expected) in [(SignalEnvironment.staging, v.config.staging), (.production, v.config.production)] {
            let endpoints = env.endpoints
            #expect(endpoints.rootCertificatesDER == [try #require(Data(base64Encoded: expected.certificateAuthorityDER))])
            #expect(endpoints.storageURL.absoluteString == expected.storageUrl)
            #expect(Dictionary(uniqueKeysWithValues: endpoints.cdnURLs.map { ("\($0.key)", $0.value.absoluteString) }) == expected.cdn)
            #expect(env.sfuURL.absoluteString == expected.sfuUrl)
            #expect(env.serverTrustRootsBase64 == expected.serverTrustRoots)
            #expect(try env.serverTrustRoots().map { $0.serialize().base64EncodedString() } == expected.serverTrustRoots)
            #expect(env.serverPublicParams.base64EncodedString() == expected.serverPublicParams)
            #expect(env.genericServerPublicParams.base64EncodedString() == expected.genericServerPublicParams)
        }
        #expect(v.config.staging.serverTrustRoots != v.config.production.serverTrustRoots)
    }

    // MARK: safety numbers

    @Test func safetyNumbers() throws {
        #expect(v.safetyNumber.count >= 3)
        for c in v.safetyNumber {
            let ours = try SafetyNumbers.generate(ourAci: c.ourAci, ourKey: try PublicKey(bytes(c.ourKey)), theirAci: c.theirAci,
                                                  theirKey: try PublicKey(bytes(c.theirKey)))
            #expect(ours.numberBlocks == c.numberBlocks)
            #expect(ours.qrData.hex == c.qrData)
            #expect(ours.numberBlocks.count == 12 && ours.numberBlocks.allSatisfy { $0.count == 5 })
        }
        // Both people read the same sixty digits.
        #expect(v.safetyNumber[0].numberBlocks == v.safetyNumber[1].numberBlocks)
        #expect(v.safetyNumber[0].numberBlocks != v.safetyNumber[2].numberBlocks)
    }

    // MARK: primitives

    @Test func hashesAndKDF() throws {
        for c in v.hmacSha256 { #expect(SignalCrypto.hmacSHA256(key: bytes(c.key), bytes(c.data)).hex == c.mac) }
        for c in v.sha256 { #expect(SignalCrypto.sha256(bytes(c.data)).hex == c.hash) }
        for c in v.hkdf { #expect(try SignalCrypto.hkdf(96, ikm: bytes(c.ikm), info: bytes(c.info), salt: bytes(c.salt)).hex == c.output) }
    }

    @Test func aesCBC() throws {
        for c in v.aesCbc {
            #expect(try SignalCrypto.aes256CBCEncrypt(key: bytes(c.key), iv: bytes(c.iv), bytes(c.plaintext)).hex == c.ciphertext)
            #expect(try SignalCrypto.aes256CBCDecrypt(key: bytes(c.key), iv: bytes(c.iv), bytes(c.ciphertext)).hex == c.plaintext)
        }
        // Malformed ciphertexts and broken PKCS#7 padding: same verdict, same bytes.
        for c in v.aesCbcDecrypt {
            let ours = attempt { try SignalCrypto.aes256CBCDecrypt(key: bytes(c.key), iv: bytes(c.iv), bytes(c.ciphertext)) }
            #expect(ours?.hex == c.plaintext, "ciphertext \(c.ciphertext.prefix(32))… upstream ok=\(c.ok)")
        }
    }

    @Test func aesCTRAndGCM() throws {
        for c in v.aesCtr {
            #expect(try SignalCrypto.aes256CTR(key: bytes(c.key), iv: bytes(c.counter), bytes(c.plaintext)).hex == c.ciphertext)
        }
        for c in v.aesGcm {
            #expect(try SignalCrypto.aes256GCMEncrypt(key: bytes(c.key), nonce: bytes(c.iv), bytes(c.plaintext)).hex == c.combined)
            #expect(try SignalCrypto.aes256GCMDecrypt(key: bytes(c.key), bytes(c.combined)).hex == c.plaintext)
        }
    }

    // MARK: padding and sizes

    /// Every 5% bucket boundary up to 4 GiB: the bucket is computed in floating point on
    /// both sides (V8's pow/log there, libm's here), so each edge is checked.
    @Test func attachmentPaddingBuckets() {
        #expect(v.logPadSize.count > 1000)
        for pair in v.logPadSize { #expect(AttachmentCipher.logPadSize(pair[0]) == pair[1], "size \(pair[0])") }
        for row in v.attachmentCiphertextSize {
            #expect(AttachmentCipher.aesCBCCiphertextSize(row[0]) == row[1])
            #expect(AttachmentCipher.ciphertextSizeForChunking(unpaddedPlaintextSize: row[0]) == row[2], "size \(row[0])")
        }
    }

    @Test func transportPadding() throws {
        for pair in v.padMessage {
            #expect(MessageSender.pad(Data(repeating: 0x41, count: pair[0])).count == pair[1], "length \(pair[0])")
        }
        for c in v.padMessageBytes {
            #expect(MessageSender.pad(bytes(c.plaintext)).hex == c.padded)
            #expect(try MessageReceiver.unpad(bytes(c.padded)).hex == c.plaintext)
        }
        for c in v.unpad {
            let ours = attempt { try MessageReceiver.unpad(bytes(c.padded)) }
            // The one deliberate difference: upstream hands back input that has no 0x80
            // terminator at all (empty or all zeros) unchanged; we refuse it.
            if c.ok, !bytes(c.padded).contains(0x80) {
                #expect(ours == nil, "padded \(c.padded)")
                continue
            }
            #expect(ours.map { Data($0).hex } == c.plaintext, "padded \(c.padded) upstream ok=\(c.ok)")
        }
    }

    // MARK: key derivation

    @Test func derivedKeys() throws {
        for c in v.stickerPackKey { #expect(try Stickers.derivePackKey(bytes(c.packKey)).hex == c.keys) }
        for c in v.groupV1MasterKey { #expect(try StorageService.masterKey(groupV1Id: bytes(c.groupV1Id)).hex == c.masterKey) }
        for c in v.accessKeyVerifier { #expect(ProfileService.accessKeyVerifier(bytes(c.accessKey)).hex == c.verifier) }

        let storageKey = StorageService.deriveStorageKey(masterKey: bytes(v.storage.masterKey))
        #expect(storageKey.hex == v.storage.storageKey)
        for c in v.storage.manifestKeys {
            #expect(StorageService.manifestKey(storageKey: storageKey, version: UInt64(c.version)!).hex == c.key, "version \(c.version)")
        }
        for c in v.storage.itemKeys {
            let key = try StorageService.itemKey(storageKey: storageKey, recordIkm: c.recordIkm.map(bytes), raw: bytes(c.raw))
            #expect(key.hex == c.key, "raw \(c.raw) recordIkm \(c.recordIkm != nil)")
        }
    }

    /// ringrtc is the reference for room ids; SignalCore re-derives them for storage sync.
    @Test func callLinkRoomId() throws {
        for _ in 0..<32 {
            let rootKey = try CallLinkRootKey.generate()
            #expect(try StorageRecords.roomId(rootKey: rootKey.bytes) == rootKey.deriveRoomId().hexString)
        }
    }

    // MARK: device names

    @Test func deviceNames() throws {
        let identity = try PrivateKey(bytes(v.deviceName.identityPrivateKey))
        #expect(v.deviceName.cases.contains { $0.ok } && v.deviceName.cases.contains { !$0.ok })
        for c in v.deviceName.cases {
            var proto = Signalservice_DeviceName()
            proto.ephemeralPublic = bytes(c.ephemeralPublic)
            proto.syntheticIv = bytes(c.syntheticIv)
            proto.ciphertext = bytes(c.ciphertext)
            let serialized = try proto.serializedData()
            let ours = attempt { try DeviceNameCipher.decrypt(serialized, identityPrivateKey: identity) }
            #expect(ours == c.name, "upstream ok=\(c.ok)")
        }
    }

    // MARK: profiles

    @Test func profileFields() throws {
        let key = bytes(v.profile.profileKey)
        for c in v.profile.names {
            let (given, family) = try ProfileService.decryptName(bytes(c.encrypted), profileKey: key)
            let expectedGiven = c.given.isEmpty ? nil : String(decoding: bytes(c.given), as: UTF8.self)
            let expectedFamily = c.family.map { String(decoding: bytes($0), as: UTF8.self) }
            #expect(given == expectedGiven, "raw \(c.raw)")
            #expect(family == expectedFamily, "raw \(c.raw)")
            // Our upload form picks the same padding bucket for the same name.
            if let expectedGiven, bytes(c.raw) == Data(([expectedGiven] + (expectedFamily.map { [$0] } ?? [])).joined(separator: "\0").utf8) {
                #expect(try ProfileService.encryptName(given: expectedGiven, family: expectedFamily, profileKey: key).count == c.encrypted.count / 2)
            }
        }
        for c in v.profile.strings {
            let expected = c.display.isEmpty ? nil : String(decoding: bytes(c.display), as: UTF8.self)
            #expect(try ProfileService.decryptString(bytes(c.encrypted), profileKey: key) == expected, "raw \(c.raw)")
        }
        for c in v.profile.decrypt {
            let ours = attempt { try ProfileService.decryptPadded(bytes(c.data), profileKey: key) }
            #expect(ours?.hex == c.plaintext, "\(c.data.count / 2) bytes, upstream ok=\(c.ok)")
        }
    }

    // MARK: attachments

    @Test func attachmentsInMemory() throws {
        for c in v.attachmentInMemory {
            let plaintext = pattern(c.size)
            let unpadded = try AttachmentCipher.encrypt(plaintext, keys: bytes(c.keys), iv: bytes(c.iv), pad: false)
            #expect(unpadded.blob.hex == c.unpadded.ciphertext, "size \(c.size)")
            #expect(unpadded.digest.hex == c.unpadded.digest)
            #expect(try AttachmentCipher.decryptV1(bytes(c.unpadded.ciphertext), keys: bytes(c.keys)) == plaintext)

            let padded = try AttachmentCipher.encrypt(plaintext, keys: bytes(c.keys), iv: bytes(c.iv))
            #expect(padded.blob.count == c.padded.ciphertextSize, "size \(c.size)")
            #expect(padded.digest.hex == c.padded.digest, "size \(c.size)")
            #expect(padded.plaintextHash == c.padded.plaintextHash)
        }
        for c in v.attachmentV1Decrypt {
            let ours = attempt { try AttachmentCipher.decryptV1(bytes(c.blob), keys: bytes(c.keys)) }
            #expect(ours?.hex == c.plaintext, "\(c.blob.count / 2) bytes, upstream ok=\(c.ok)")
        }
    }

    /// The streaming v2 form with its incremental MAC. The digest is SHA-256 over the whole
    /// blob, so equal digests mean byte-identical ciphertext.
    @Test func attachmentsV2() throws {
        for c in v.attachmentV2 {
            let plaintext = pattern(c.size)
            let ours = try AttachmentCipher.encrypt(plaintext, keys: bytes(c.keys), iv: bytes(c.iv), incrementalMac: true)
            #expect(ours.blob.count == c.ciphertextSize, "size \(c.size)")
            #expect(ours.digest.hex == c.digest, "size \(c.size)")
            #expect(ours.plaintextHash == c.plaintextHash)
            #expect(ours.incrementalMac?.hex == c.incrementalMac, "size \(c.size)")
            #expect(ours.chunkSize == c.chunkSize, "size \(c.size)")

            let back = try AttachmentCipher.decrypt(ours.blob, keys: bytes(c.keys), size: c.size, integrity: .encrypted(digest: bytes(c.digest)),
                                                    incrementalMac: c.incrementalMac.map(bytes), chunkSize: c.chunkSize)
            #expect(back.plaintext == plaintext)
        }
    }

    // MARK: provisioning

    @Test func provisioningEnvelopes() throws {
        let cipher = ProvisioningCipher(privateKey: try PrivateKey(bytes(v.provisioning.ourPrivateKey)))
        #expect(v.provisioning.cases.first { $0.label == "valid" }?.ok == true)
        for c in v.provisioning.cases {
            let ours = attempt { try cipher.decrypt(envelope: bytes(c.envelope)) }
            #expect((ours != nil) == c.ok, "\(c.label)")
            guard let ours, let expected = c.result else { continue }
            #expect(ours.aci == expected.aci)
            #expect("PNI:\(ours.pni)" == expected.pni)
            #expect(ours.number == expected.number)
            #expect(ours.provisioningCode == expected.provisioningCode)
            #expect(ours.userAgent == expected.userAgent)
            #expect(ours.readReceipts == expected.readReceipts)
            #expect(ours.aciIdentityKeyPrivate.hex == expected.aciPrivateKey)
            #expect(ours.pniIdentityKeyPrivate.hex == expected.pniPrivateKey)
            #expect(ours.profileKey.hex == expected.profileKey)
            #expect(ours.accountEntropyPool == expected.accountEntropyPool)
        }
    }
}
