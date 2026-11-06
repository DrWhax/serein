// Sticker packs against the mock server's CDN: packs are encrypted by the harness the way
// upstream's sticker creator does (Node crypto), so pack-key derivation and V1 decryption are
// checked against an independent implementation.

import CodecCore
import CryptoKit
import EncodePNG
import Foundation
import GRDB
import SignalProtos
import Testing
@testable import SignalCore

enum StickerFixtures {
    static let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../SignalCodecs/Tests/DifferentialTests/Resources").standardizedFileURL
    static func file(_ path: String) throws -> Data { try Data(contentsOf: resources.appendingPathComponent(path)) }
    static func webp() throws -> Data { try file("WebP/vp80-00-comprehensive-016.webp") }
    static func animatedWebp() throws -> Data { try file("WebP/gif2webp_animation_lossy.webp") }
    static func png() -> Data {
        var px = [UInt8]()
        for y in 0..<64 { for x in 0..<96 { px += [UInt8(x * 2), UInt8(y * 4), 90, 255] } }
        return Data(PNGEncoder.encode(PixelBuffer(width: 96, height: 64, rgba: px)))
    }

    /// The PNG above as a one-frame APNG (acTL + fcTL before IDAT, the default image is frame 0).
    static func apng() -> Data {
        let base = [UInt8](png())
        func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let tb = Array(type.utf8) + body
            return be32(UInt32(body.count)) + tb + be32(crc32(tb))
        }
        let actl = chunk("acTL", be32(1) + be32(0))
        let fctl = chunk("fcTL", be32(0) + be32(96) + be32(64) + be32(0) + be32(0) + [0, 1, 0, 10, 0, 0])
        let ihdrEnd = 8 + 8 + 13 + 4
        return Data(Array(base[..<ihdrEnd]) + actl + fctl + Array(base[ihdrEnd...]))
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            c ^= UInt32(b)
            for _ in 0..<8 { c = (c >> 1) ^ (0xEDB8_8320 & (0 &- (c & 1))) }
        }
        return ~c
    }
}

struct StickerUnitTests {
    @Test func packKeyDerivationMatchesRFC5869() throws {
        let packKey = Data((0..<32).map { UInt8($0) })
        // HKDF-SHA256, salt 0^32, info "Sticker Pack", 64 bytes, from CryptoKit's HMAC.
        let prk = Data(HMAC<SHA256>.authenticationCode(for: packKey, using: SymmetricKey(data: Data(count: 32))))
        let t1 = Data(HMAC<SHA256>.authenticationCode(for: Data("Sticker Pack".utf8) + [1], using: SymmetricKey(data: prk)))
        let t2 = Data(HMAC<SHA256>.authenticationCode(for: t1 + Data("Sticker Pack".utf8) + [2], using: SymmetricKey(data: prk)))
        #expect(try Stickers.derivePackKey(packKey) == t1 + t2)
    }

    @Test func v1DecryptChecksTheMac() throws {
        let keys = AttachmentCipher.generateKeys(), iv = SignalCrypto.randomBytes(16), plaintext = Data("sticker".utf8)
        let body = iv + (try SignalCrypto.aes256CBCEncrypt(key: keys.prefix(32), iv: iv, plaintext))
        var blob = body + SignalCrypto.hmacSHA256(key: keys.suffix(32), body)
        #expect(try AttachmentCipher.decryptV1(blob, keys: keys) == plaintext)
        blob[20] ^= 1
        #expect(throws: AttachmentError.badMAC) { try AttachmentCipher.decryptV1(blob, keys: keys) }
        #expect(throws: AttachmentError.tooShort) { try AttachmentCipher.decryptV1(Data(count: 40), keys: keys) }
    }

    @Test func manifestParsing() throws {
        func sticker(_ id: UInt32, _ emoji: String = "") -> Signalservice_StickerPack.Sticker {
            var s = Signalservice_StickerPack.Sticker()
            s.id = id
            s.emoji = emoji
            return s
        }
        var p = Signalservice_StickerPack()
        p.stickers = [sticker(0, "🐸"), sticker(1), sticker(2)]
        var m = try Stickers.parseManifest(p)
        #expect(m.cover.id == 0 && m.cover.emoji == "🐸" && m.nonCover.map(\.id) == [1, 2] && m.coverIncludedInList && m.stickerCount == 3)
        p.cover = sticker(9)
        m = try Stickers.parseManifest(p)
        #expect(m.nonCover.count == 3 && !m.coverIncludedInList)
        p.stickers = (0..<1100).map { sticker(UInt32($0)) }
        #expect(try Stickers.parseManifest(p).stickerCount == 1024)
        #expect(throws: StickerError.self) { try Stickers.parseManifest(Signalservice_StickerPack()) }
        #expect(Stickers.isPackIdValid("42fb75e1827c0c945cfb5ca0975db03c") && !Stickers.isPackIdValid("42fb75e1827c0c945cfb5ca0975db03") && !Stickers.isPackIdValid("../../etc/passwd/00000000000000000"))
        #expect(Stickers.blessedPacks.allSatisfy { Stickers.isPackIdValid($0.id) && Data(base64Encoded: $0.key)?.count == 32 })
        #expect(Stickers.sniffContentType(try StickerFixtures.webp()) == "image/webp" && Stickers.sniffContentType(StickerFixtures.apng()) == "image/png")
    }
}

@Suite(.serialized) struct StickerFlowTests {
    func makePack(_ c: LinkedClient, images: [Data], corrupt: Int? = nil) async throws -> (id: String, key: String) {
        var args: [String: any Sendable] = ["images": images.map { $0.base64EncodedString() }, "emojis": ["🐸", "🫖", "🎈", "🌀"], "title": "Frogs",
                                            "author": "Pond"]
        if let corrupt { args["corruptSticker"] = corrupt }
        let r = try await c.server.json("createStickerPack", args)
        return (r["packId"] as! String, r["packKey"] as! String)
    }

    @Test func installsAPackFromTheCDN() async throws {
        try await LinkedClient.with { c in
            let images = [try StickerFixtures.webp(), StickerFixtures.png(), StickerFixtures.apng(), try StickerFixtures.animatedWebp()]
            let pack = try await makePack(c, images: images)
            try await c.database.pool.write { try Items.set($0, "storageFetchComplete", true) }
            try await c.stickers.install(packId: pack.id, packKey: pack.key, actionSource: .ui)
            let row = try #require(try await c.database.pool.read { db in
                try Row.fetchOne(db, sql: "SELECT * FROM sticker_packs WHERE id = ?", arguments: [pack.id])
                    .map { (status: $0["status"] as String?, title: $0["title"] as String?, author: $0["author"] as String?, count: $0["stickerCount"] as Int?,
                            needsSync: $0["storageNeedsSync"] as Int?) }
            })
            #expect(row.status == "installed" && row.title == "Frogs" && row.author == "Pond" && row.count == 4 && row.needsSync == 1)
            for (i, image) in images.enumerated() {
                #expect(try await c.stickers.stickerData(packId: pack.id, stickerId: i) == image)
            }
            let dims = try await c.database.pool.read { db in
                try Row.fetchAll(db, sql: "SELECT id, width, height, emoji, isCoverOnly FROM stickers WHERE packId = ? ORDER BY id", arguments: [pack.id])
                    .map { "\($0["id"] as Int):\($0["width"] as Int? ?? 0)x\($0["height"] as Int? ?? 0):\($0["emoji"] as String? ?? ""):\($0["isCoverOnly"] as Int? ?? -1)" }
            }
            #expect(dims[1] == "1:96x64:🫖:0" && dims[2] == "2:96x64:🎈:0" && dims.count == 4)
            // The phone hears about it, and storage gets an upload.
            let sync = try await c.server.json("waitForSyncMessage", ["kind": "stickerPackOperation"])
            let op = try #require((sync["stickerPackOperation"] as? [[String: Any]])?.first)
            #expect(op["packId"] as? String == pack.id && op["packKey"] as? String == pack.key && op["type"] as? String == "install")
            // Uninstall: nothing refers to the pack any more, so it and its files go
            // (`maybeDeletePack`); the uninstall tombstone waits for storage.
            try await c.stickers.uninstall(packId: pack.id, actionSource: .ui)
            let after = try await c.database.pool.read { db in
                (try Stickers.status(db, pack.id), try Int.fetchOne(db, sql: "SELECT storageNeedsSync FROM uninstalled_sticker_packs WHERE id = ?", arguments: [pack.id]))
            }
            #expect(after.0 == nil && after.1 == 1)
            await #expect(throws: StickerError.unknownSticker) { try await c.stickers.stickerData(packId: pack.id, stickerId: 0) }
            let removal = try await c.server.json("waitForSyncMessage", ["kind": "stickerPackOperation"])
            #expect((removal["stickerPackOperation"] as? [[String: Any]])?.first?["type"] as? String == "remove")
        }
    }

    @Test func badStickersAreSkippedAndNonImagesRejected() async throws {
        try await LinkedClient.with { c in
            let pack = try await makePack(c, images: [try StickerFixtures.webp(), StickerFixtures.png(), Data("not an image at all".utf8)], corrupt: 1)
            try await c.stickers.download(packId: pack.id, packKey: pack.key, actionSource: .ui)
            let ids = try await c.database.pool.read { db in try Int.fetchAll(db, sql: "SELECT id FROM stickers WHERE packId = ? ORDER BY id", arguments: [pack.id]) }
            #expect(ids == [0])   // 1: bad MAC, 2: the media service refuses it
            #expect(try await c.database.pool.read { try Stickers.status($0, pack.id) } == .downloaded)
            // A pack whose manifest cannot be fetched ends in `error` after 3 attempts.
            let missing = String(repeating: "0f", count: 16), key = Data(count: 32).base64EncodedString()
            for _ in 0..<4 { try? await c.stickers.download(packId: missing, packKey: key, actionSource: .ui) }
            #expect(try await c.database.pool.read { try Stickers.status($0, missing) } == .error)
            await #expect(throws: StickerError.invalidPackId) { try await c.stickers.download(packId: "../x", packKey: key, actionSource: .ui) }
        }
    }

    @Test func incomingStickerMessages() async throws {
        try await LinkedClient.with { c in
            try await c.acceptAlice()
            let images = [try StickerFixtures.webp(), StickerFixtures.png()]
            let pack = try await makePack(c, images: images)
            // A sticker from a pack we do not have: its image is downloaded with the message.
            let t1 = TestClock.next()
            try await c.server.call("sendSticker", ["packId": pack.id, "packKey": pack.key, "stickerId": 1, "data": images[1].base64EncodedString(),
                                                    "contentType": "image/png", "timestamp": t1])
            _ = try await c.log.waitFor { if case .message(_, _, _, _, let t, _, _, _) = $0 { return t == t1 } else { return false } }
            try await c.eventually("sticker downloaded") { db in
                guard let id = try String.fetchOne(db, sql: "SELECT id FROM messages WHERE sent_at = ?", arguments: [Int64(t1)]) else { return false }
                return try MessageAttachments.fetch(db, .init(messageId: id, type: .sticker, order: 0))?.isDownloaded == true
            }
            let first = try await c.database.pool.read { db -> (json: String, status: StickerPackStatus?, refs: Int) in
                let id = try String.fetchOne(db, sql: "SELECT id FROM messages WHERE sent_at = ?", arguments: [Int64(t1)])!
                return (try String.fetchOne(db, sql: "SELECT json ->> '$.sticker' FROM messages WHERE id = ?", arguments: [id]) ?? "",
                        try Stickers.status(db, pack.id), try Int.fetchOne(db, sql: "SELECT count(*) FROM sticker_references WHERE messageId = ?", arguments: [id]) ?? 0)
            }
            #expect(first.json.contains(pack.id) && first.json.contains("\"stickerId\":1") && first.status == .known && first.refs == 1)

            // Once the pack is here, a new sticker message takes its image from the pack.
            try await c.stickers.download(packId: pack.id, packKey: pack.key, actionSource: .ui)
            let t2 = TestClock.next()
            try await c.server.call("sendSticker", ["packId": pack.id, "packKey": pack.key, "stickerId": 0, "data": images[0].base64EncodedString(), "timestamp": t2])
            _ = try await c.log.waitFor { if case .message(_, _, _, _, let t, _, _, _) = $0 { return t == t2 } else { return false } }
            try await c.eventually("sticker resolved from the pack") { db in
                guard let id = try String.fetchOne(db, sql: "SELECT id FROM messages WHERE sent_at = ?", arguments: [Int64(t2)]) else { return false }
                let resolved = try Int.fetchOne(db, sql: "SELECT count(*) FROM sticker_references WHERE messageId = ? AND isUnresolved = 0", arguments: [id]) == 1
                let downloaded = try MessageAttachments.fetch(db, .init(messageId: id, type: .sticker, order: 0))?.isDownloaded == true
                return resolved && downloaded
            }
            let copy = try await c.database.pool.read { db -> MessageAttachment in
                let id = try String.fetchOne(db, sql: "SELECT id FROM messages WHERE sent_at = ?", arguments: [Int64(t2)])!
                return try MessageAttachments.fetch(db, .init(messageId: id, type: .sticker, order: 0))!
            }
            #expect(try c.attachmentStore.plaintext(of: copy) == images[0] && copy.contentType == "image/webp")
            #expect(try await c.database.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM attachment_downloads WHERE attachmentType = 'sticker'") } == 0)
        }
    }

    @Test func sendsAStickerAndFollowsThePhone() async throws {
        try await LinkedClient.with { c in
            let images = [try StickerFixtures.webp(), StickerFixtures.apng()]
            let pack = try await makePack(c, images: images)
            // The phone installs the pack: we follow.
            try await c.server.call("sendStickerPackSync", ["packId": pack.id, "packKey": pack.key, "type": "install"])
            try await c.eventually("installed from the phone") { db in try Stickers.status(db, pack.id) == .installed }
            #expect(try await c.database.pool.read { try Int.fetchOne($0, sql: "SELECT storageNeedsSync FROM sticker_packs WHERE id = ?", arguments: [pack.id]) } == 1)

            let sent = try await c.messenger.sendSticker(packId: pack.id, stickerId: 0, to: c.aliceAci)
            let m = try await c.server.json("waitForMessage", ["account": "alice"])
            let s = try #require(m["sticker"] as? [String: Any])
            #expect(s["packId"] as? String == pack.id && s["packKey"] as? String == pack.key && s["stickerId"] as? Int == 0 && s["emoji"] as? String == "🐸")
            let d = try #require(s["data"] as? [String: Any])
            #expect(d["contentType"] as? String == "image/webp" && d["width"] as? Int != nil)
            let fetched = try await c.server.json("fetchAndDecryptAttachment", ["cdnKey": d["cdnKey"] as! String, "key": d["key"] as! String,
                                                                                "digest": d["digest"] as! String, "size": d["size"] as! Int])
            #expect(Data(base64Encoded: fetched["plaintext"] as! String) == images[0])
            let transcript = try await c.server.json("waitForSyncMessage", ["kind": "sent"])
            #expect(((transcript["sent"] as? [String: Any])?["sticker"] as? [String: Any])?["packId"] as? String == pack.id)
            #expect(try await c.database.pool.read { try Int64.fetchOne($0, sql: "SELECT lastUsed FROM stickers WHERE packId = ? AND id = 0", arguments: [pack.id]) } != nil)
            _ = sent

            let state = try await c.database.pool.read { try Stickers.managerState($0) }
            #expect(state.installed.map(\.id) == [pack.id] && state.received.map(\.id) == [pack.id] && state.blessed.isEmpty)
            #expect(state.installed.first?.stickers.map(\.id) == [0, 1] && state.installed.first?.title == "Frogs")
            #expect(state.recents.map(\.id) == [0])

            // Favourites: stored for storage service, then removed as a tombstone.
            try await c.stickers.setFavorite(packId: pack.id, stickerId: 1, true)
            let fav = try await c.database.pool.read { db in
                try Row.fetchOne(db, sql: "SELECT status, storageNeedsSync, deletedAtTimestampMs FROM favorite_stickers WHERE packId = ? AND stickerId = 1",
                                 arguments: [pack.id]).map { ($0["status"] as String?, $0["storageNeedsSync"] as Int?, $0["deletedAtTimestampMs"] as Int64?) }
            }
            #expect(fav?.0 == "installed" && fav?.1 == 1 && fav?.2 == nil)
            #expect(try await c.database.pool.read { try Stickers.managerState($0) }.favorites.map(\.id) == [1])
            try await c.stickers.setFavorite(packId: pack.id, stickerId: 1, false)
            #expect(try await c.database.pool.read { try Int64.fetchOne($0, sql: "SELECT deletedAtTimestampMs FROM favorite_stickers WHERE packId = ?", arguments: [pack.id]) } != nil)

            // The phone removes the pack.
            try await c.server.call("sendStickerPackSync", ["packId": pack.id, "packKey": pack.key, "type": "remove"])
            try await c.eventually("removed from the phone") { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM uninstalled_sticker_packs WHERE id = ?", arguments: [pack.id]) == 1
            }
        }
    }
}

/// The sticker creator's pack: decrypts back to the manifest and images; the multipart form.
@Suite struct StickerPackUploadTests {
    @Test func encryptsManifestAndImagesWithThePackKey() throws {
        let a = Data("sticker-a".utf8), b = Data("sticker-b".utf8)
        let draft = StickerPackDraft(title: "Cats", author: "Alice", stickers: [.init(data: a, emoji: "😺"), .init(data: b, emoji: nil), .init(data: a, emoji: "😸")],
                                     cover: b)
        let packKey = Data(repeating: 7, count: 32)
        let pack = try StickerPackUpload.encrypt(draft, packKey: packKey)
        #expect(pack.packKey == String(repeating: "07", count: 32))
        #expect(pack.images.count == 2)                       // a, b (deduplicated; the cover is b)
        #expect(try Stickers.decrypt(pack.images[0], packKey: packKey) == a)
        let manifest = try Signalservice_StickerPack(serializedBytes: try Stickers.decrypt(pack.manifest, packKey: packKey))
        #expect(manifest.title == "Cats" && manifest.author == "Alice" && manifest.stickers.count == 3 && manifest.cover.id == 1)
        #expect(manifest.stickers.map(\.emoji) == ["😺", "", "😸"])
    }

    @Test func multipartForm() {
        let form = StickerUploadForm(acl: "private", algorithm: "AWS4", credential: "cred", date: "20261106", id: 0, key: "stickers/x/manifest.proto",
                                     policy: "pol", signature: "sig")
        let (body, type) = StickerPackUpload.multipart(form, Data([1, 2, 3]), boundary: "BOUND")
        let text = String(decoding: body, as: UTF8.self)
        #expect(type == "multipart/form-data; boundary=BOUND")
        #expect(text.hasPrefix("--BOUND\r\nContent-Disposition: form-data; name=\"key\"\r\n\r\nstickers/x/manifest.proto\r\n--BOUND"))
        #expect(text.hasSuffix("\r\n--BOUND--\r\n"))
        #expect(StickerPackUpload.shareURL(packId: "ab", packKey: "cd").absoluteString == "https://signal.art/addstickers/#pack_id=ab&pack_key=cd")
    }
}
