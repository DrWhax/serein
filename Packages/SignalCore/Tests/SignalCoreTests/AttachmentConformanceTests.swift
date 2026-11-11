// Attachment authentication and processing: production SignalCore against the Lean model in
// Verification/Attachments — `AttachmentCipher.decrypt` on blobs changed in every way
// (`randomDecrypts`: the descriptors are computed here with CryptoKit), and the real download
// pipeline (`AttachmentDownloadManager.run`, over the mock server's CDN) on genuine, substituted,
// forged and oversized responses, then local reads of what was published and of files changed on
// disk (`randomDownloads`); `HTTPClient`'s transfer bound and its certificate pinning.
//
// Run through Tools/verify-attachments.sh, or set SEREIN_ATTACHMENTS_ORACLE to the oracle executable.

import CommonCrypto
import CryptoKit
import Foundation
import GRDB
import LibSignalClient
import Testing
@testable import SignalCore

enum AttachmentsOracle {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../Verification/Attachments").standardized
    static var path: String {
        ProcessInfo.processInfo.environment["SEREIN_ATTACHMENTS_ORACLE"] ?? root.appendingPathComponent(".lake/build/bin/oracle").path
    }
    static var available: Bool { FileManager.default.isExecutableFile(atPath: path) }

    static func call(_ mode: String, _ lines: [String]) throws -> [String] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("serein-attachments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let inURL = dir.appendingPathComponent("in.txt"), outURL = dir.appendingPathComponent("out.txt")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: inURL)
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = [mode]
        p.standardInput = try FileHandle(forReadingFrom: inURL)
        p.standardOutput = try FileHandle(forWritingTo: outURL)
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw IdentityOracle.Failed() }
        return String(decoding: try Data(contentsOf: outURL), as: UTF8.self).split(separator: "\n").map(String.init)
    }
}

func randomBytes(_ r: inout SplitMix, _ n: Int) -> Data { Data((0..<n).map { _ in UInt8(truncatingIfNeeded: r.next()) }) }

func hmac(_ key: Data, _ data: Data) -> Data { Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))) }
func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

/// AES-256-CBC (CommonCrypto, independent of production's libsignal) with a strict PKCS#7 check
/// here: the unpadded plaintext, or nil if the padding is invalid.
func cbcDecrypt(key: Data, iv: Data, _ ciphertext: Data) -> Data? {
    guard ciphertext.count % 16 == 0, !ciphertext.isEmpty else { return nil }
    var out = Data(count: ciphertext.count)
    var moved = 0
    let outCount = out.count
    let status = unsafe out.withUnsafeMutableBytes { o in
        unsafe key.withUnsafeBytes { k in
            unsafe iv.withUnsafeBytes { i in
                unsafe ciphertext.withUnsafeBytes { c in
                    unsafe CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0), k.baseAddress, key.count,
                                   i.baseAddress, c.baseAddress, ciphertext.count, o.baseAddress, outCount, &moved)
                }
            }
        }
    }
    guard status == kCCSuccess, moved == ciphertext.count, let last = out.last, (1...16).contains(last),
          out.suffix(Int(last)).allSatisfy({ $0 == last }) else { return nil }
    return out.prefix(out.count - Int(last))
}

@Suite(.serialized, .enabled(if: AttachmentsOracle.available, "build the oracle: Tools/verify-attachments.sh, or lake build in Verification/Attachments"))
struct AttachmentConformanceTests {
    static var count: Int { ProcessInfo.processInfo.environment["SEREIN_ATTACHMENTS_CASES"].flatMap { Int($0) } ?? 2000 }

    static func errorName(_ e: Error) -> String {
        switch e {
        case AttachmentError.badKey: "badKey"
        case AttachmentError.tooShort: "tooShort"
        case AttachmentError.badMAC: "badMAC"
        case AttachmentError.badIncrementalMAC: "badIncrementalMAC"
        case AttachmentError.missingDigest: "missingDigest"
        case AttachmentError.badDigest: "badDigest"
        case AttachmentError.badPlaintextHash: "badPlaintextHash"
        case is SignalError: "badPadding"
        default: "other:\(e)"
        }
    }

    /// A blob changed in one of many ways, with its pointer's integrity source, size and
    /// incremental MAC: the descriptors (computed here) against production's result.
    @Test func randomDecrypts() throws {
        var r = SplitMix(s: 79)
        var lines: [String] = [], swift: [String] = [], content: [String] = []
        for _ in 0..<Self.count {
            let plaintext = randomBytes(&r, r.coin(10) ? 0 : r.below(2000))
            let keys = randomBytes(&r, 64)
            let wantIncremental = r.coin(3)
            let e = try AttachmentCipher.encrypt(plaintext, keys: keys, incrementalMac: wantIncremental)
            var blob = e.blob
            var modified = false
            switch r.below(8) {
            case 0:   // a byte changed
                let i = r.below(blob.count)
                blob[i] ^= UInt8(1 + r.below(255))
                modified = true
            case 1:   // truncated
                blob = blob.prefix(r.below(blob.count))
                modified = true
            case 2:   // extended
                blob += randomBytes(&r, r.coin() ? 16 : 1 + r.below(40))
                modified = true
            case 3:   // a body changed and its tag recomputed (by someone with the keys): only the digest or hash can tell
                var body = blob.prefix(blob.count - 32)
                body[r.below(body.count)] ^= 1
                blob = body + hmac(keys.suffix(32), body)
                modified = true
            default: break
            }
            let useKeys = r.coin(12) ? randomBytes(&r, 64) : (r.coin(20) ? keys.prefix(63) : keys)
            // The size: the plaintext's, smaller, or larger (even past what the blob holds).
            let size = [plaintext.count, max(0, plaintext.count - r.below(20)), plaintext.count + r.below(100), plaintext.count + 5000][r.below(4)]
            // The integrity source.
            let padded = plaintext + Data(count: AttachmentCipher.logPadSize(plaintext.count) - plaintext.count)
            let trimmed = Data(padded.prefix(size))
            let integrity: AttachmentIntegrity, integrityCode: String
            switch r.below(6) {
            case 0, 1:
                let d = r.coin(4) ? randomBytes(&r, 32) : e.digest
                integrity = .encrypted(digest: d)
                integrityCode = "d:0:\(sha256(blob) == d ? 1 : 0)"
            case 2:
                integrity = .encrypted(digest: Data())
                integrityCode = "d:1:0"
            case 3, 4:
                let h = r.coin(4) ? randomBytes(&r, 32) : sha256(trimmed)
                integrity = .plaintext(hash: h)
                integrityCode = "h:?"
                _ = h
            default:
                integrity = .local
                integrityCode = "m"
            }
            // The incremental MAC: absent, valid, changed, or a chunk size beyond any pointer.
            var mac = e.incrementalMac, chunk = e.chunkSize
            var incCode = mac == nil ? "none" : (modified ? "bad" : "ok")
            if mac != nil {
                switch r.below(5) {
                case 0:
                    mac![r.below(mac!.count)] ^= 1
                    incCode = "bad"
                case 1:
                    chunk = Int(UInt32.max) + 1 + r.below(10)
                    incCode = "huge"
                case 2:
                    chunk = 0
                    incCode = "none"
                default: break
                }
            }
            let keyOK = useKeys.count == 64
            let shaped = blob.count >= 64 && (blob.count - 48) % 16 == 0
            let macOK = keyOK && blob.count >= 32 && hmac(useKeys.suffix(32), blob.prefix(blob.count - 32)) == blob.suffix(32)
            if !macOK || !shaped { incCode = mac == nil || (chunk ?? 0) <= 0 ? "none" : incCode }
            let plain = shaped && keyOK ? cbcDecrypt(key: useKeys.prefix(32), iv: blob.prefix(16), Data(blob.dropFirst(16).dropLast(32))) : nil
            // The plaintext hash is of what decryption gives, trimmed to the size.
            var code = integrityCode
            if case .plaintext(let h) = integrity { code = "h:\(plain.map { sha256(Data($0.prefix(size))) == h } == true ? 1 : 0)" }
            lines.append("\(keyOK ? 1 : 0) \(blob.count) \(macOK ? 1 : 0) \(incCode) \(code) \(size) \(plain.map { String($0.count) } ?? "x")")
            do {
                let d = try AttachmentCipher.decrypt(blob, keys: useKeys, size: size, integrity: integrity, incrementalMac: mac, chunkSize: chunk)
                swift.append("ok:\(d.plaintext.count)")
                if d.plaintext != Data(padded.prefix(size)) && !modified { content.append("plaintext is not the original's prefix (size \(size))") }
            } catch {
                swift.append(Self.errorName(error))
            }
        }
        for c in content.prefix(3) { Issue.record("content: \(c)") }
        compare(lines, model: try AttachmentsOracle.call("decrypt", lines), swift: swift)
    }

    /// The download pipeline over the mock CDN: genuine, another upload's, forged, oversized or
    /// truncated responses; pointers with or without a digest or plaintext hash, sizes against the
    /// incoming limit. What is published, and what reads of it (and of the file changed) give.
    @Test func randomDownloads() async throws {
        let server = try await MockServerHarness.start()
        do {
            try await downloads(server)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    func downloads(_ server: MockServerHarness) async throws {
        let (database, _) = try LinkedClient.temporaryDatabase()
        let endpoints = ServiceEndpoints.mockServer(port: server.ready.port, rootCertificateDER: server.ready.certificateAuthorityDER)
        let http = HTTPClient(rootCertificatesDER: endpoints.rootCertificatesDER)
        let store = try AttachmentStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("serein-att-\(UUID())"))
        let manager = AttachmentDownloadManager(db: database.pool, http: http, endpoints: endpoints, store: store, media: nil)
        let conversation = try await database.pool.write { try MessageStore.privateConversation($0, serviceId: UUID().uuidString.lowercased()) }
        var r = SplitMix(s: 83)
        var lines: [String] = [], swift: [String] = [], issues: [String] = []
        for _ in 0..<max(20, Self.count / 10) {
            let plaintext = randomBytes(&r, r.below(3000))
            let keys = randomBytes(&r, 64)
            let e = try AttachmentCipher.encrypt(plaintext, keys: keys)
            let other = try AttachmentCipher.encrypt(randomBytes(&r, plaintext.count), keys: randomBytes(&r, 64))
            let size = r.coin(8) ? plaintext.count + 1 + r.below(50) : (r.coin(8) ? max(0, plaintext.count - 1 - r.below(50)) : plaintext.count)
            let pad = AttachmentCipher.logPadSize(plaintext.count), bucket = AttachmentCipher.logPadSize(size)
            let cap = 16 + (1 + bucket / 16) * 16 + 32 + 65536
            let maxSize = r.coin(6) ? r.below(max(1, size)) : 200_000
            // The response.
            let response: Data, genuine: String
            switch r.below(8) {
            case 0: response = other.blob; genuine = "other"
            case 1: response = randomBytes(&r, e.blob.count); genuine = "forged"
            case 2: response = e.blob + randomBytes(&r, cap - e.blob.count + 1 + r.below(1000)); genuine = "forged"
            case 3: response = e.blob.prefix(r.below(e.blob.count)); genuine = "forged"
            default: response = e.blob; genuine = "own"
            }
            let hasDigest = !r.coin(5), hasHash = !hasDigest && r.coin()
            let cdnKey = UUID().uuidString.lowercased()
            _ = try await server.json("putCdnBlob", ["cdnKey": cdnKey, "data": response.base64EncodedString()])
            var a = MessageAttachment(contentType: "application/octet-stream", size: size)
            a.cdnKey = cdnKey
            a.cdnNumber = 3
            a.key = keys.base64EncodedString()
            if hasDigest { a.digest = (r.coin(6) ? randomBytes(&r, 32) : e.digest).base64EncodedString() }
            if hasHash { a.plaintextHash = e.plaintextHash }
            a.pending = true
            let wrongDigest = hasDigest && a.digest != e.digest.base64EncodedString()
            let attachment = a
            // The model names the pointer's upload "own"; a wrong digest names another.
            lines.append("\(maxSize) | \(size) \(plaintext.count) \(pad) \(bucket) \(hasDigest ? 1 : 0) \(hasHash ? 1 : 0) | \(response.count) "
                         + (wrongDigest && genuine == "own" ? "other" : genuine))
            let job = try await database.pool.write { db -> AttachmentDownloadJob in
                try Items.set(db, "remoteConfig", ["global.attachments.maxReceiveBytes": RemoteConfig.Value(name: "global.attachments.maxReceiveBytes",
                                                                                                           enabled: true, value: "\(maxSize)", enabledAt: nil)])
                let id = try MessageStore.insert(db, .init(conversationId: conversation, type: "incoming", body: "", sentAt: UInt64(MessageStore.now()),
                                                           source: nil, sourceDevice: nil, serverGuid: nil, serverTimestamp: nil, unidentified: false))
                try MessageAttachments.upsert(db, .init(messageId: id, type: .attachment, order: 0), conversationId: conversation, sentAt: 1,
                                              receivedAt: 1, messageType: "incoming", attachment)
                return AttachmentDownloadJob(messageId: id, attachmentType: .attachment, signature: attachment.signature, receivedAt: 1, sentAt: 1,
                                             attachment: attachment)
            }
            await manager.run(job)
            let stored = try await database.pool.read { db in try MessageAttachments.fetch(db, messageId: job.messageId).first?.1 }
            guard let stored else { swift.append("missing"); continue }
            if stored.path != nil {
                let read = try? store.plaintext(of: stored)
                swift.append("published:\(read?.count ?? -1)")
                if read != Data((plaintext + Data(count: pad - plaintext.count)).prefix(size)) { issues.append("published plaintext differs (size \(size))") }
                // Changed on disk: the local MAC refuses it.
                if let path = stored.path {
                    var bytes = try store.read(path)
                    bytes[r.below(bytes.count)] ^= 1
                    try bytes.write(to: try store.url(path))
                    if (try? store.plaintext(of: stored)) != nil { issues.append("a changed file was read") }
                }
            } else if stored.wasTooBig == true {
                swift.append("tooBig")
            } else if stored.error == true {
                swift.append("error")
            } else {
                swift.append("pending")
            }
        }
        for i in issues.prefix(3) { Issue.record("content: \(i)") }
        compare(lines, model: try AttachmentsOracle.call("download", lines), swift: swift)
    }

    /// The transfer bound stops at the limit whatever the length declared.
    @Test func boundedTransfer() async throws {
        func stream(_ n: Int) -> AsyncStream<UInt8> {
            AsyncStream { c in
                for i in 0..<n { c.yield(UInt8(truncatingIfNeeded: i)) }
                c.finish()
            }
        }
        #expect(try await HTTPClient.collect(stream(1000), limit: 1000).count == 1000)
        await #expect(throws: HTTPError.tooLarge(1001)) { _ = try await HTTPClient.collect(stream(5000), limit: 1000) }
        await #expect(throws: HTTPError.tooLarge(1)) { _ = try await HTTPClient.collect(stream(1), limit: 0) }
    }

    /// A client pinned to other roots refuses the mock server's certificate.
    @Test func pinningRefusesOtherRoots() async throws {
        let server = try await MockServerHarness.start()
        let endpoints = ServiceEndpoints.mockServer(port: server.ready.port, rootCertificateDER: server.ready.certificateAuthorityDER)
        let pinned = HTTPClient(rootCertificatesDER: [SignalEnvironment.signalRootCertificateDER])
        let ok = HTTPClient(rootCertificatesDER: endpoints.rootCertificatesDER)
        let url = endpoints.cdnURLs[3]!.appendingPathComponent("attachments").appendingPathComponent("none")
        let refused = await (try? pinned.send("GET", url, accept: [404])) == nil
        let reached = await (try? ok.send("GET", url, accept: [404])) != nil
        await server.stop()
        #expect(refused, "a client pinned to Signal's root connected to the mock server")
        #expect(reached, "the correctly pinned client could not reach the mock server")
    }
}
