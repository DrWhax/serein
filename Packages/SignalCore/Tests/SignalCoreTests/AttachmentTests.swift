// Phase 4 step 3: attachment v2 crypto, incremental MAC, local re-encryption, CDN3 TUS upload
// and the download manager, against upstream's in-tree mock server.

import EncodePNG
import CodecCore
import Foundation
import MediaXPCInterface
import GRDB
import LibSignalClient
import Testing
@testable import SignalCore

@Suite struct AttachmentCipherTests {
    /// ts/test-node/util/logPadding_test.node.ts: the first buckets.
    @Test func logPadSize() {
        #expect(AttachmentCipher.logPadSize(1) == 541)
        #expect(AttachmentCipher.logPadSize(541) == 541)
        #expect(AttachmentCipher.logPadSize(542) == 568)
        // Monotonic, never below the size, at most ~5% over.
        var previous = 0
        for size in stride(from: 600, to: 2_000_000, by: 997) {
            let p = AttachmentCipher.logPadSize(size)
            #expect(p >= size && p >= previous && Double(p) <= Double(size) * 1.051)
            previous = p
        }
    }

    @Test func roundTripsWithPaddingAndIntegrity() throws {
        let plaintext = Data((0..<10_000).map { UInt8($0 & 0xFF) })
        let e = try AttachmentCipher.encrypt(plaintext)
        #expect(e.blob.count == 16 + AttachmentCipher.aesCBCCiphertextSize(AttachmentCipher.logPadSize(10_000)) + 32)
        // Wrong key, digest, plaintext hash and truncated blobs all fail.
        let k = AttachmentCipher.generateKeys()
        let enc = try AttachmentCipher.encrypt(plaintext, keys: k)
        let d = try AttachmentCipher.decrypt(enc.blob, keys: k, size: plaintext.count, integrity: .encrypted(digest: enc.digest))
        #expect(d.plaintext == plaintext && d.plaintextHash == enc.plaintextHash && d.digest == enc.digest)
        #expect(throws: AttachmentError.badMAC) { try AttachmentCipher.decrypt(enc.blob, keys: AttachmentCipher.generateKeys(), size: 1, integrity: .local) }
        #expect(throws: AttachmentError.badDigest) {
            try AttachmentCipher.decrypt(enc.blob, keys: k, size: plaintext.count, integrity: .encrypted(digest: Data(repeating: 1, count: 32)))
        }
        #expect(throws: AttachmentError.badPlaintextHash) {
            try AttachmentCipher.decrypt(enc.blob, keys: k, size: plaintext.count, integrity: .plaintext(hash: Data(repeating: 1, count: 32)))
        }
        var tampered = enc.blob
        tampered[40] ^= 1
        #expect(throws: AttachmentError.badMAC) { try AttachmentCipher.decrypt(tampered, keys: k, size: plaintext.count, integrity: .local) }
    }

    @Test func incrementalMacValidates() throws {
        let plaintext = Data((0..<300_000).map { UInt8(($0 * 7) & 0xFF) })
        let k = AttachmentCipher.generateKeys()
        let e = try AttachmentCipher.encrypt(plaintext, keys: k, incrementalMac: true)
        let mac = try #require(e.incrementalMac), chunk = try #require(e.chunkSize)
        #expect(chunk > 0)
        _ = try AttachmentCipher.decrypt(e.blob, keys: k, size: plaintext.count, integrity: .encrypted(digest: e.digest), incrementalMac: mac, chunkSize: chunk)
        var bad = mac
        bad[0] ^= 1
        #expect(throws: AttachmentError.badIncrementalMAC) {
            try AttachmentCipher.decrypt(e.blob, keys: k, size: plaintext.count, integrity: .encrypted(digest: e.digest), incrementalMac: bad, chunkSize: chunk)
        }
    }

    @Test func reencryptsLocally() throws {
        let plaintext = Data("hello attachments".utf8)
        let k = AttachmentCipher.generateKeys()
        let e = try AttachmentCipher.encrypt(plaintext, keys: k)
        let local = try AttachmentCipher.reencryptLocally(e.blob, keys: k, size: plaintext.count, integrity: .encrypted(digest: e.digest))
        #expect(local.localKey != k && local.blob != e.blob)
        #expect(try AttachmentCipher.decryptLocal(local.blob, localKey: local.localKey, size: plaintext.count) == plaintext)
    }

    @Test func storeRejectsForeignPaths() throws {
        let store = try AttachmentStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("att-\(UUID())"))
        let path = try store.write(Data([1, 2, 3]))
        #expect(try store.read(path) == Data([1, 2, 3]))
        for bad in ["../etc/passwd", "ab/../../x", "zz/" + String(repeating: "a", count: 64), "ab"] {
            #expect(throws: AttachmentStoreError.self) { try store.url(bad) }
        }
    }

    @Test func quarantinesExports() throws {
        let store = try AttachmentStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("att-\(UUID())"))
        let saved = try store.storeLocally(Data("doc".utf8))
        var a = MessageAttachment(contentType: "text/plain", size: 3)
        a.path = saved.path
        a.localKey = saved.localKey.base64EncodedString()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID()).txt")
        try store.export(a, to: out)
        #expect(try Data(contentsOf: out) == Data("doc".utf8))
        let q = try out.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(q?["LSQuarantineAgentName"] as? String == "Signal")
    }

    @Test func mediaQualityLevel() throws {
        #expect(CountryCallingCode.of("+14155550100") == 1)
        #expect(CountryCallingCode.of("+447700900123") == 44)
        #expect(CountryCallingCode.of("+351912345678") == 351)
        #expect(CountryCallingCode.of("14155550100") == nil)
        let (db, _) = try LinkedClient.temporaryDatabase()
        try db.pool.write { db in
            try Items.set(db, "remoteConfig", ["desktop.mediaQuality.levels": RemoteConfig.Value(name: "desktop.mediaQuality.levels", enabled: true,
                                                                                                value: "1:2,44:1,*:1", enabledAt: nil)])
            #expect(try MediaQuality.level(db, e164: "+14155550100") == .two)
            #expect(try MediaQuality.level(db, e164: "+447700900123") == .one)
            #expect(try MediaQuality.level(db, e164: nil) == .one)
        }
    }

    @Test func autoDownloadPolicy() {
        let s = AttachmentPolicy.AutoDownload()
        var voice = MessageAttachment(contentType: "audio/aac", size: 50_000)
        voice.flags = MessageAttachment.flagVoiceMessage
        var off = s
        off.audio = false
        #expect(AttachmentPolicy.shouldAutoDownload(voice, type: .attachment, settings: off, maxAutoDownload: 200 << 20))
        #expect(!AttachmentPolicy.shouldAutoDownload(MessageAttachment(contentType: "audio/mp3", size: 50_000), type: .attachment, settings: off,
                                                     maxAutoDownload: 200 << 20))
        #expect(!AttachmentPolicy.shouldAutoDownload(MessageAttachment(contentType: "image/png", size: 300 << 20), type: .attachment, settings: s,
                                                     maxAutoDownload: 200 << 20))
        #expect(AttachmentDownloadManager.backoff(attempt: 1) == 30_000)
        #expect(AttachmentDownloadManager.backoff(attempt: 2) == 300_000)
        #expect(AttachmentDownloadManager.backoff(attempt: 3) == 3_000_000)
        #expect(AttachmentDownloadManager.backoff(attempt: 9) == 6 * 3_600_000)
    }
}

@Suite(.serialized) struct AttachmentFlowTests {
    static func png() -> Data {
        var px = [UInt8]()
        for y in 0..<120 { for x in 0..<200 { px += [UInt8(x), UInt8(y * 2), 128, 255] } }
        return Data(PNGEncoder.encode(PixelBuffer(width: 200, height: 120, rgba: px)))
    }

    /// Desktop → alice: encrypted at rest, uploaded to CDN3 over TUS, pointer sent; alice's side
    /// (an independent decrypt of upstream's format) gets the exact bytes back.
    @Test func sendsAnImage() async throws {
        try await LinkedClient.with { c in
            let image = Self.png()
            let (messageId, ts) = try await c.messenger.sendMessage("look", attachments: [OutgoingAttachment(data: image, contentType: "image/png", fileName: "a.png")],
                                                                    to: c.aliceAci)
            let received = try await c.server.json("waitForMessage", ["account": "alice"])
            #expect(received["body"] as? String == "look" && (received["timestamp"] as? Int).map(UInt64.init) == ts)
            let pointers = try #require(received["attachments"] as? [[String: Any]])
            let p = try #require(pointers.first)
            #expect(p["cdnNumber"] as? Int == 3 && p["contentType"] as? String == "image/png" && p["size"] as? Int == image.count)
            #expect(p["width"] as? Int == 200 && p["height"] as? Int == 120 && (p["blurHash"] as? String)?.count == 28)
            let cdnKey = try #require(p["cdnKey"] as? String), keyB64 = try #require(p["key"] as? String), digestB64 = try #require(p["digest"] as? String)
            let decrypted = try await c.server.json("fetchAndDecryptAttachment", ["cdnKey": cdnKey, "key": keyB64, "digest": digestB64, "size": image.count])
            #expect(Data(base64Encoded: decrypted["plaintext"] as! String) == image)
            #expect(decrypted["paddedLength"] as? Int == AttachmentCipher.logPadSize(image.count))
            // Stored with its transit pointer and a 150 px thumbnail.
            let rows = try await c.database.pool.read { try MessageAttachments.fetch($0, messageId: messageId) }
            let a = try #require(rows.first?.1)
            #expect(a.cdnKey == cdnKey && a.isDownloaded && a.uploadTimestamp != nil)
            let thumb = try #require(a.thumbnail)
            let png = try AttachmentCipher.decryptLocal(c.attachmentStore.read(thumb.path), localKey: Data(base64Encoded: thumb.localKey)!, size: thumb.size)
            #expect(png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        }
    }

    /// alice → Desktop: the pointer is stored, the download job runs, and the file is kept
    /// re-encrypted at rest.
    @Test func downloadsAnIncomingAttachment() async throws {
        try await LinkedClient.with { c in
            try await c.acceptAlice()
            let image = Self.png()
            let ts = TestClock.next()
            _ = try await c.server.json("sendAttachment", ["from": "alice", "data": image.base64EncodedString(), "contentType": "image/png", "timestamp": ts])
            _ = try await c.log.waitFor { if case .message(_, _, _, _, let t, _, _, _) = $0 { return t == ts } else { return false } }
            try await c.eventually("attachment downloaded") { db in
                guard let id = try String.fetchOne(db, sql: "SELECT id FROM messages WHERE sent_at = ?", arguments: [Int64(ts)]) else { return false }
                return try MessageAttachments.fetch(db, messageId: id).first?.1.isDownloaded == true
            }
            let a = try await c.database.pool.read { db -> MessageAttachment in
                let id = try String.fetchOne(db, sql: "SELECT id FROM messages WHERE sent_at = ?", arguments: [Int64(ts)])!
                return try MessageAttachments.fetch(db, messageId: id).first!.1
            }
            #expect(try c.attachmentStore.plaintext(of: a) == image)
            #expect(a.pending == false && a.width == 200 && a.height == 120 && a.blurHash?.count == 28 && a.thumbnail != nil)
            #expect(try await c.database.pool.read { try AttachmentDownloads.count($0) } == 0)
            // The file on disk is not the transit blob.
            let onDisk = try c.attachmentStore.read(a.path!)
            #expect(!onDisk.isEmpty && onDisk.range(of: image.prefix(64)) == nil)
        }
    }

    /// An attachment from a chat we have not accepted is not fetched by itself; "Download"
    /// queues it (`requestDownload`), cancelling leaves it unpending with nothing queued, and a
    /// second request downloads it.
    @Test func manualDownloadAndCancel() async throws {
        try await LinkedClient.with { c in
            let image = Self.png()
            let ts = TestClock.next()
            _ = try await c.server.json("sendAttachment", ["from": "alice", "data": image.base64EncodedString(), "contentType": "image/png", "timestamp": ts])
            _ = try await c.log.waitFor { if case .message(_, _, _, _, let t, _, _, _) = $0 { return t == ts } else { return false } }
            func state() async throws -> (MessageAttachments.Location, MessageAttachment, Int) {
                try await c.database.pool.read { db in
                    let id = try String.fetchOne(db, sql: "SELECT id FROM messages WHERE sent_at = ?", arguments: [Int64(ts)])!
                    let (loc, a) = try MessageAttachments.fetch(db, messageId: id).first!
                    return (loc, a, try AttachmentDownloads.count(db))
                }
            }
            var (loc, a, queued) = try await state()
            #expect(!a.isDownloaded && a.pending != true && queued == 0)
            await c.downloads.stop()
            try await c.downloads.requestDownload([loc])
            (loc, a, queued) = try await state()
            #expect(a.pending == true && queued == 1)
            try await c.downloads.cancelDownloads(messageId: loc.messageId)
            (loc, a, queued) = try await state()
            #expect(a.pending == false && queued == 0 && !a.isDownloaded)
            try await c.downloads.start()
            try await c.downloads.requestDownload([loc])
            let messageId = loc.messageId
            try await c.eventually("attachment downloaded") { db in
                try MessageAttachments.fetch(db, messageId: messageId).first?.1.isDownloaded == true
            }
        }
    }
}
