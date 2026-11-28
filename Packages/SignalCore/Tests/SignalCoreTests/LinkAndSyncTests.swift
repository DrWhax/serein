// Link and sync: the transfer archive's crypto and framing, the frames into the database, and
// the whole flow against the mock server (the phone sends an ephemeral backup key, uploads the
// archive, the new device imports it before its session starts).

import CodecCore
import Foundation
import GRDB
import LibSignalClient
import MessageParsing
import SignalMediaDecoder
import SignalProtos
import Synchronization
import Testing
@testable import SignalCore

extension GzipStream: BackupInflater {}

extension InProcessMessageParser {
    /// With the child's streaming gunzip (CodecCore), for backups.
    static func withGzip() -> InProcessMessageParser { InProcessMessageParser(inflater: { GzipStream(allowsZeroPadding: true) }) }
}

/// A file of `data` in a fresh folder (removed with `remove()`).
struct TemporaryFile {
    let url: URL
    init(_ data: Data, name: String = "transfer-archive") throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("signalsafe-archive-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent(name)
        try data.write(to: url)
    }
    func remove() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

/// A small backup as a primary would write it.
struct BackupFixture {
    let ourAci: String
    let aliceAci: String
    let profileKey = Data(SignalCrypto.randomBytes(32))
    let aliceProfileKey = Data(SignalCrypto.randomBytes(32))
    let groupMasterKey = Data(SignalCrypto.randomBytes(32))
    let aliceIdentity = IdentityKeyPair.generate().identityKey.serialize()
    let base: UInt64 = 1_700_000_000_000
    /// More incoming messages in Alice's chat (a history of several megabytes).
    var extraMessages = 0
    /// The media tier's root key, which must be the one the link gave (the phone's, against the
    /// mock server).
    var mediaRootBackupKey = Data(SignalCrypto.randomBytes(32))

    static func uuid(_ s: String) -> Data { UUID(uuidString: s)!.data }

    func frames() -> [BackupProto_Frame] {
        func frame(_ set: (inout BackupProto_Frame) -> Void) -> BackupProto_Frame {
            var f = BackupProto_Frame()
            set(&f)
            return f
        }
        var out: [BackupProto_Frame] = []
        out.append(frame { f in
            var a = BackupProto_AccountData()
            a.profileKey = profileKey
            a.givenName = "Phone"
            a.username = "phone.01"
            var s = BackupProto_AccountData.AccountSettings()
            s.readReceipts = true
            s.linkPreviews = true
            a.accountSettings = s
            f.account = a
        })
        out.append(frame { f in var r = BackupProto_Recipient(); r.id = 1; r.self_p = BackupProto_Self(); f.recipient = r })
        out.append(frame { f in
            var c = BackupProto_Contact()
            c.aci = Self.uuid(aliceAci)
            c.e164 = 15550001
            c.profileKey = aliceProfileKey
            c.profileGivenName = "Alice"
            c.profileSharing = true
            c.identityKey = aliceIdentity
            c.registered = BackupProto_Contact.Registered()
            var r = BackupProto_Recipient(); r.id = 2; r.contact = c; f.recipient = r
        })
        out.append(frame { f in var r = BackupProto_Recipient(); r.id = 3; r.releaseNotes = BackupProto_ReleaseNotes(); f.recipient = r })
        out.append(frame { f in
            var g = BackupProto_Group()
            g.masterKey = groupMasterKey
            g.whitelisted = true
            var snap = BackupProto_Group.GroupSnapshot()
            var title = BackupProto_Group.GroupAttributeBlob(); title.title = "Weekend"; snap.title = title
            snap.version = 3
            for aci in [ourAci, aliceAci] {
                var m = BackupProto_Group.Member(); m.userID = Self.uuid(aci); m.role = aci == aliceAci ? .administrator : .default; snap.members.append(m)
            }
            g.snapshot = snap
            var r = BackupProto_Recipient(); r.id = 4; r.group = g; f.recipient = r
        })
        out.append(frame { f in var c = BackupProto_Chat(); c.id = 1; c.recipientID = 2; c.pinnedOrder = 1; f.chat = c })
        out.append(frame { f in var c = BackupProto_Chat(); c.id = 2; c.recipientID = 4; c.archived = true; f.chat = c })
        out.append(frame { f in var c = BackupProto_Chat(); c.id = 3; c.recipientID = 3; f.chat = c })

        func item(_ chat: UInt64, _ author: UInt64, _ at: UInt64, incoming read: Bool? = nil, _ set: (inout BackupProto_ChatItem) -> Void) -> BackupProto_Frame {
            frame { f in
                var i = BackupProto_ChatItem()
                i.chatID = chat
                i.authorID = author
                i.dateSent = at
                if let read {
                    var d = BackupProto_ChatItem.IncomingMessageDetails(); d.dateReceived = at + 5; d.read = read; d.sealedSender = true; i.incoming = d
                } else if author == 1 {
                    var d = BackupProto_ChatItem.OutgoingMessageDetails()
                    var s = BackupProto_SendStatus(); s.recipientID = 2; s.timestamp = at + 9; s.delivered = BackupProto_SendStatus.Delivered()
                    d.sendStatus = [s]
                    i.outgoing = d
                } else {
                    i.directionless = BackupProto_ChatItem.DirectionlessMessageDetails()
                }
                set(&i)
                f.chatItem = i
            }
        }
        func text(_ body: String) -> BackupProto_StandardMessage {
            var m = BackupProto_StandardMessage(); var t = BackupProto_Text(); t.body = body; m.text = t; return m
        }
        out.append(item(1, 2, base, incoming: false) { $0.standardMessage = text("hello from history") })
        out.append(item(1, 1, base + 1000) { i in
            var m = text("  reply with a quote  ")
            var q = BackupProto_Quote(); q.targetSentTimestamp = base; q.authorID = 2; var qt = BackupProto_Text(); qt.body = "hello from history"; q.text = qt
            q.type = .normal
            m.quote = q
            var r = BackupProto_Reaction(); r.emoji = "👍"; r.authorID = 2; r.sentTimestamp = base + 2000; m.reactions = [r]
            var a = BackupProto_MessageAttachment()
            var p = BackupProto_FilePointer(); p.contentType = "image/png"; p.width = 4; p.height = 3
            var l = BackupProto_FilePointer.LocatorInfo(); l.key = Data(SignalCrypto.randomBytes(64)); l.plaintextHash = Data(SignalCrypto.randomBytes(32))
            l.size = 1234; l.transitCdnKey = "transit-key"; l.transitCdnNumber = 3; p.locatorInfo = l
            a.pointer = p
            m.attachments = [a]
            i.standardMessage = m
        })
        out.append(item(1, 2, base + 3000, incoming: true) { i in
            var u = BackupProto_ChatUpdateMessage(); var t = BackupProto_ExpirationTimerChatUpdate(); t.expiresInMs = 86_400_000
            u.expirationTimerChange = t
            i.updateMessage = u
        })
        out.append(item(1, 2, base + 4000) { i in
            var u = BackupProto_ChatUpdateMessage(); var s = BackupProto_SimpleChatUpdate(); s.type = .joinedSignal; u.simpleUpdate = s
            i.updateMessage = u
        })
        out.append(item(2, 2, base + 5000) { i in
            var u = BackupProto_ChatUpdateMessage(); var g = BackupProto_GroupChangeChatUpdate()
            var c = BackupProto_GroupChangeChatUpdate.Update(); var create = BackupProto_GroupCreationUpdate(); create.updaterAci = Self.uuid(aliceAci)
            c.groupCreationUpdate = create
            var n = BackupProto_GroupChangeChatUpdate.Update(); var name = BackupProto_GroupNameUpdate(); name.updaterAci = Self.uuid(aliceAci)
            name.newGroupName = "Weekend"; n.groupNameUpdate = name
            g.updates = [c, n]
            u.groupChange = g
            i.updateMessage = u
        })
        out.append(item(2, 2, base + 6000, incoming: true) { $0.standardMessage = text("group hello") })
        for k in 0..<extraMessages {
            out.append(item(1, 2, base + 100_000 + UInt64(k), incoming: true) { $0.standardMessage = text("message \(k) " + Data(SignalCrypto.randomBytes(100)).base64EncodedString()) })
        }
        out.append(item(3, 3, base + 7000, incoming: true) { $0.standardMessage = text("release notes") })     // dropped
        out.append(frame { f in var p = BackupProto_StickerPack(); p.packID = Data(SignalCrypto.randomBytes(16)); p.packKey = Data(SignalCrypto.randomBytes(32))
            f.installedStickerPack = p })
        out.append(frame { f in
            var c = BackupProto_ChatFolder(); c.id = UUID().data; c.name = "Close"; c.folderType = .custom; c.includedRecipientIds = [2]; c.showMutedChats = true
            f.chatFolder = c
        })
        return out
    }

    /// BackupInfo, then the frames, delimited and gzipped, zero-padded as primaries pad it
    /// (upstream encoding.node.ts), then encrypted for `ephemeralKey`.
    func archive(ephemeralKey: Data) throws -> Data {
        var info = BackupProto_BackupInfo()
        info.version = 1
        info.backupTimeMs = base + 10_000
        info.mediaRootBackupKey = mediaRootBackupKey
        var plain = Data()
        for record in [try info.serializedBytes() as Data] + (try frames().map { try $0.serializedBytes() as Data }) {
            plain += PlaintextExport.varint(UInt64(record.count)) + record
        }
        let keys = try LinkAndSync.keys(ephemeralKey: ephemeralKey, aci: ourAci)
        let padded = Data(Gzip.compress([UInt8](plain))) + Data(count: LinkAndSync.pieceBytes + 4321)
        return try LinkAndSync.encrypt(padded, mac: keys.mac, aes: keys.aes)
    }
}

@Suite struct LinkAndSyncUnitTests {
    /// The archive file decrypted piece by piece (the plaintext's own sizes around a piece's).
    static func decrypted(_ file: URL, _ keys: (mac: Data, aes: Data)) throws -> (Data, [Int64]) {
        let verified = try LinkAndSync.verify(file, mac: keys.mac)
        var out = Data(), done: [Int64] = []
        try LinkAndSync.decrypt(verified, mac: keys.mac, aes: keys.aes) { piece, at, total in
            out += piece
            done.append(at)
            #expect(total == Int64(try! Data(contentsOf: file).count))
        }
        return (out, done)
    }

    @Test func archivesRoundTripAndTamperingIsRefused() throws {
        let aci = UUID().uuidString.lowercased()
        let key = Data(SignalCrypto.randomBytes(32))
        let keys = try LinkAndSync.keys(ephemeralKey: key, aci: aci)
        let piece = LinkAndSync.pieceBytes
        for size in [0, 12, 16, piece - 17, piece - 16, piece, piece + 5, 3 * piece + 1000] {
            let plaintext = Data(SignalCrypto.randomBytes(size))
            let archive = try LinkAndSync.encrypt(plaintext, mac: keys.mac, aes: keys.aes)
            let file = try TemporaryFile(archive)
            defer { file.remove() }
            let (back, done) = try Self.decrypted(file.url, keys)
            #expect(back == plaintext, "\(size) bytes")
            #expect(done.count == (archive.count - 48 + piece - 1) / piece && done.last == Int64(archive.count - 32))
        }
        let plaintext = Data(SignalCrypto.randomBytes(2 * piece + 100))
        var archive = try LinkAndSync.encrypt(plaintext, mac: keys.mac, aes: keys.aes)
        let file = try TemporaryFile(archive)
        defer { file.remove() }
        // The keys depend on the ACI.
        let other = try LinkAndSync.keys(ephemeralKey: key, aci: UUID().uuidString.lowercased())
        #expect(throws: LinkAndSyncError.badMAC) { _ = try LinkAndSync.verify(file.url, mac: other.mac) }
        // A changed byte anywhere: refused before anything is decrypted.
        for at in [3, 20, piece + 7, archive.count - 40, archive.count - 1] {
            archive[at] ^= 1
            try archive.write(to: file.url)
            #expect(throws: LinkAndSyncError.badMAC, "byte \(at)") { _ = try LinkAndSync.verify(file.url, mac: keys.mac) }
            archive[at] ^= 1
        }
        // Changed between the passes: the second pass refuses it (a byte in the middle: at its
        // end; the MAC or the size: before it decrypts anything).
        try archive.write(to: file.url)
        let verified = try LinkAndSync.verify(file.url, mac: keys.mac)
        for change in [piece + 7, archive.count - 1, -1] {
            var changed = archive
            if change < 0 { changed += Data(count: 16) } else { changed[change] ^= 1 }
            try changed.write(to: file.url)
            var pieces = 0
            #expect(throws: LinkAndSyncError.self) { try LinkAndSync.decrypt(verified, mac: keys.mac, aes: keys.aes) { _, _, _ in pieces += 1 } }
            if change != piece + 7 { #expect(pieces == 0) }
        }
        try Data(count: 40).write(to: file.url)
        #expect(throws: LinkAndSyncError.self) { _ = try LinkAndSync.verify(file.url, mac: keys.mac) }
    }

    /// Pieces of a ciphertext decrypt without padding, each after the one before.
    @Test func cbcPiecesDecryptAsTheWhole() throws {
        let key = Data(SignalCrypto.randomBytes(32)), iv = Data(SignalCrypto.randomBytes(16))
        let plain = Data(SignalCrypto.randomBytes(16 * 100))
        let cipher = try SignalCrypto.aes256CBCEncrypt(key: key, iv: iv, plain)   // 101 blocks: one of padding
        var out = Data(), chain = iv, at = 0
        for blocks in [1, 7, 50, 42] {
            let piece = Data(cipher[at..<(at + 16 * blocks)])
            out += try SignalCrypto.aes256CBCDecryptBlocks(key: key, iv: chain, piece)
            chain = Data(piece.suffix(16))
            at += 16 * blocks
        }
        #expect(out == plain)
        #expect(try SignalCrypto.aes256CBCDecrypt(key: key, iv: chain, Data(cipher[at...])).isEmpty)
        #expect(throws: (any Error).self) { try SignalCrypto.aes256CBCDecryptBlocks(key: key, iv: iv, Data(count: 15)) }
    }

    /// CDN keys are one path segment (upstream encodeURIComponent), whoever sent them.
    @Test func cdnKeysCannotAddPathSegments() throws {
        let base = URL(string: "https://cdn3.example")!
        #expect(try base.cdnAttachment("abc_DEF-1.x").absoluteString == "https://cdn3.example/attachments/abc_DEF-1.x")
        #expect(try base.cdnAttachment("../v1/accounts?x=1#y").absoluteString == "https://cdn3.example/attachments/..%2Fv1%2Faccounts%3Fx%3D1%23y")
        #expect(try URL(string: "https://h/cdn3/")!.cdnAttachment("a/b").absoluteString == "https://h/cdn3/attachments/a%2Fb")
        #expect(throws: (any Error).self) { try base.cdnAttachment("") }
    }

    @Test func transferArchiveResponses() throws {
        #expect(try LinkAndSync.parseArchive(Data(#"{"cdn":3,"key":"abc"}"#.utf8)) == .archive(cdn: 3, key: "abc"))
        #expect(try LinkAndSync.parseArchive(Data(#"{"error":"CONTINUE_WITHOUT_UPLOAD"}"#.utf8)) == .continueWithoutUpload)
        #expect(throws: LinkAndSyncError.relinkRequested) { try LinkAndSync.parseArchive(Data(#"{"error":"RELINK_REQUESTED"}"#.utf8)) }
        #expect(throws: LinkAndSyncError.self) { try LinkAndSync.parseArchive(Data(#"{"cdn":3}"#.utf8)) }
    }

    /// The parser inflates the backup as its pieces come and hands out the records they
    /// complete, BackupInfo first; damage is malformed, and a parser without gunzip (the default)
    /// refuses backups.
    @Test func theParserStreamsBackups() throws {
        var info = BackupProto_BackupInfo()
        info.version = 1
        var frame = BackupProto_Frame()
        var c = BackupProto_Chat(); c.id = 7; frame.chat = c
        var plain = Data()
        let count = 40_000
        for r in [try info.serializedBytes() as Data] + Array(repeating: try frame.serializedBytes() as Data, count: count) {
            plain += PlaintextExport.varint(UInt64(r.count)) + r
        }
        let gzip = Data(Gzip.compress([UInt8](plain)))
        for piece in [1, 1000, 65_536, gzip.count] {
            let parser = InProcessMessageParser.withGzip()
            var got: BackupProto_BackupInfo?, frames: [BackupProto_Frame] = []
            var at = 0, replies = 0
            while at < gzip.count {
                var next = gzip[at..<min(gzip.count, at + piece)]
                at += piece
                while true {
                    let r = try parser.backupRecords(Data(next), infoRead: got != nil, source: "backup:x")
                    next = Data()
                    if let i = r.info { got = i } else if r.frames.isEmpty { break }
                    frames += r.frames
                    replies += 1
                }
            }
            try parser.backupEnd(source: "backup:x")
            #expect(got?.version == 1 && frames.count == count && frames.allSatisfy { $0.chat.id == 7 }, "pieces of \(piece)")
            #expect(replies >= 1)
        }
        func refused(_ bytes: Data) -> Bool {
            let parser = InProcessMessageParser.withGzip()
            do {
                var r = try parser.backupRecords(bytes, infoRead: false, source: "backup:x")
                while r.info != nil || !r.frames.isEmpty { r = try parser.backupRecords(Data(), infoRead: true, source: "backup:x") }
                try parser.backupEnd(source: "backup:x")
                return false
            } catch { return error is MessageParserError }
        }
        #expect(!refused(gzip))
        #expect(!refused(gzip + Data(count: 189_346)))        // primaries' zero padding
        #expect(refused(Data(Gzip.compress([5, 1]))))        // a record cut short
        #expect(refused(Data([1, 2, 3])))                     // not gzip
        #expect(refused(gzip.prefix(gzip.count - 4)))         // the trailer cut short
        #expect(refused(gzip + Data([1])))                    // something after it
        #expect(refused(gzip + Data(count: 100) + Data([1]))) // padding that is not all zeros
        #expect(throws: MessageParserError.self) { _ = try InProcessMessageParser().backupRecords(gzip.prefix(100), infoRead: false, source: "backup:x") }
        #expect(throws: MessageParserError.self) { try InProcessMessageParser.withGzip().backupEnd(source: "backup:x") }      // none open
        #expect(throws: MessageParserError.self) {
            _ = try InProcessMessageParser.withGzip().backupRecords(Data(count: MessageParserLimits.maxBackupPieceBytes + 1), infoRead: false, source: "x")
        }
    }

    static func account() -> Account {
        Account(aci: UUID().uuidString.lowercased(), pni: UUID().uuidString.lowercased(), number: "+15550000", deviceId: 2, password: "pw",
                deviceName: "test", aciIdentity: IdentityKeyPair.generate(), pniIdentity: IdentityKeyPair.generate(), aciRegistrationId: 1,
                pniRegistrationId: 2, profileKey: nil, masterKey: nil, accountEntropyPool: nil, readReceipts: false)
    }

    @Test func waveformsRoundTripThroughMessagesAndBackups() throws {
        let (database, url) = try LinkedClient.temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = Self.account()
        try database.pool.write { db in
            try account.save(db)
            let importer = try BackupImporter(db: db, account: account, now: 1)
            let exporter = FrameBuilder(db: db, account: account, now: Date())
            try db.execute(sql: "INSERT INTO messages (id, json, conversationId) VALUES ('voice', '{}', 'chat')")
            let location = MessageAttachments.Location(messageId: "voice", type: .attachment, order: 0)
            let cases: [Data?] = [nil, Data(), Data([0, 63, 255]), Data(0...100)]
            for input in cases {
                var pointer = Signalservice_AttachmentPointer()
                pointer.contentType = "audio/mpeg"
                pointer.audioDurationSeconds = 1.5
                if let input { pointer.audioWaveform = input }
                let expected = input.flatMap { $0.isEmpty ? nil : Data($0.prefix(100)) }

                let attachment = MessageAttachment(pointer: pointer)
                try MessageAttachments.upsert(db, location, conversationId: "chat", sentAt: 1, receivedAt: 1, messageType: "incoming", attachment)
                let stored = try #require(try MessageAttachments.fetch(db, location))
                #expect(stored.audioWaveform == expected)
                let backup = exporter.pointer(stored)
                #expect(backup.hasAudioWaveform == (expected != nil))
                #expect(backup.audioWaveform == expected ?? Data())

                var incomingBackup = backup
                if let input { incomingBackup.audioWaveform = input }
                let restored = importer.attachment(incomingBackup).pointer()
                #expect(restored.hasAudioWaveform == (expected != nil))
                #expect(restored.audioWaveform == expected ?? Data())
                #expect(restored.audioDurationSeconds == 1.5)
            }
        }
    }

    /// The frames land as upstream's import writes them.
    @Test func importsTheFrames() async throws {
        let (db, url) = try LinkedClient.temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = Self.account()
        try await db.pool.write { try account.save($0) }
        let fixture = BackupFixture(ourAci: account.aci, aliceAci: UUID().uuidString.lowercased())
        let key = Data(SignalCrypto.randomBytes(32))
        let file = try TemporaryFile(try fixture.archive(ephemeralKey: key))
        defer { file.remove() }
        let result = try await LinkAndSync.importArchive(file: file.url, ephemeralKey: key, account: account, database: db,
                                                         parser: InProcessMessageParser.withGzip())
        #expect(result.frameErrors == 0)
        #expect(result.messages == 6)
        try await db.pool.read { d in
            let alice = try #require(try Row.fetchOne(d, sql: "SELECT id, json, active_at FROM conversations WHERE serviceId = ?", arguments: [fixture.aliceAci]))
            let aliceId: String = alice["id"]
            let aj = try MessageStore.jsonObject(alice["json"])
            #expect(aj["profileName"] as? String == "Alice" && aj["e164"] as? String == "+15550001" && aj["isPinned"] as? Bool == true)
            #expect(aj["unreadCount"] as? Int == 1 && aj["messageCount"] as? Int == 2 && aj["sentMessageCount"] as? Int == 1)
            #expect((alice["active_at"] as Int64?) ?? 0 >= Int64(fixture.base))
            #expect(try Items.get(d, "pinnedConversationIds", as: [String].self) == [aliceId])
            #expect(try Items.get(d, "read-receipt-setting", as: Bool.self) == true)
            #expect(try String.fetchOne(d, sql: "SELECT id FROM identityKeys WHERE id = ?", arguments: [fixture.aliceAci]) == fixture.aliceAci)
            let group = try #require(try Row.fetchOne(d, sql: "SELECT json FROM conversations WHERE type = 'group'"))
            let gj = try MessageStore.jsonObject(group["json"])
            #expect(gj["name"] as? String == "Weekend" && gj["isArchived"] as? Bool == true && (gj["membersV2"] as? [Any])?.count == 2)

            let messages = try Row.fetchAll(d, sql: "SELECT type, body, json, conversationId FROM messages ORDER BY received_at")
            #expect(messages.map { $0["type"] as String } == ["incoming", "outgoing", "timer-notification", "joined-signal-notification",
                                                             "group-v2-change", "incoming"])
            #expect(messages.first?["body"] as String? == "hello from history")
            let reply = try MessageStore.jsonObject(messages[1]["json"])
            #expect(reply["body"] as? String == "reply with a quote")
            #expect((reply["quote"] as? [String: Any])?["id"] as? Int64 == Int64(fixture.base))
            #expect(((reply["sendStateByConversationId"] as? [String: [String: Any]])?[aliceId]?["status"] as? String) == "Delivered")
            #expect(try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM reactions WHERE emoji = '👍' AND fromId = ?", arguments: [aliceId]) == 1)
            let attachment = try #require(try Row.fetchOne(d, sql: "SELECT transitCdnKey, transitCdnNumber, size, contentType FROM message_attachments"))
            #expect(attachment["transitCdnKey"] as String? == "transit-key" && attachment["size"] as Int == 1234)
            let change = try MessageStore.jsonObject(messages[4]["json"])
            #expect(((change["groupV2Change"] as? [String: Any])?["details"] as? [[String: Any]])?.compactMap { $0["type"] as? String } == ["create", "title"])
            #expect(!messages.contains { ($0["body"] as String?) == "release notes" })
            #expect(try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM sticker_packs WHERE status = 'pending'") == 1)
            #expect(try String.fetchOne(d, sql: "SELECT name FROM chatFolders WHERE name = 'Close'") == "Close")
        }
    }

    /// A history of many megabytes: imported piece by piece as the file is read, with progress
    /// in bytes of the file; cancelled on the way, nothing of it stays.
    @Test func aLongHistoryStreamsAndACancelLeavesNothing() async throws {
        let (db, url) = try LinkedClient.temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = Self.account()
        try await db.pool.write { try account.save($0) }
        var fixture = BackupFixture(ourAci: account.aci, aliceAci: UUID().uuidString.lowercased())
        fixture.extraMessages = 30_000
        let key = Data(SignalCrypto.randomBytes(32))
        let file = try TemporaryFile(try fixture.archive(ephemeralKey: key))
        defer { file.remove() }
        let size = Int64(try Data(contentsOf: file.url).count)
        #expect(size > 2 * Int64(LinkAndSync.pieceBytes))
        // Cancelled after the first piece.
        let progress = LinkAndSyncTests.Progress()
        await #expect(throws: LinkAndSyncError.canceled) {
            _ = try await LinkAndSync.importArchive(file: file.url, ephemeralKey: key, account: account, database: db, parser: InProcessMessageParser.withGzip(),
                                                    isCanceled: { progress.all.count > 1 }, progress: { progress.add($0) })
        }
        #expect(try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM messages") } == 0)
        // Then to the end.
        let steps = LinkAndSyncTests.Progress()
        let result = try await LinkAndSync.importArchive(file: file.url, ephemeralKey: key, account: account, database: db,
                                                         parser: InProcessMessageParser.withGzip(), progress: { steps.add($0) })
        #expect(result.messages == 6 + 30_000 && result.frameErrors == 0)
        let done = steps.all.compactMap { p -> Int64? in if case .importing(let d, let t) = p, t == size { d } else { nil } }
        #expect(done.first == 0 && done.last == size - 32 && done.count > 2 && done == done.sorted())
    }

    /// Dates at the edge of UInt64 (from a primary, or a broken one) never trap the import.
    @Test func extremeDatesDoNotTrap() async throws {
        let (db, url) = try LinkedClient.temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = Self.account()
        try await db.pool.write { try account.save($0) }
        let fixture = BackupFixture(ourAci: account.aci, aliceAci: UUID().uuidString.lowercased())
        let result = try await db.pool.write { d -> BackupImportResult in
            var importer = try BackupImporter(db: d, account: account, now: 1_700_000_000_000)
            for f in fixture.frames().prefix(5) { try importer.process(f) }   // account, self, Alice, release notes, group
            var chat = BackupProto_Frame(); var c = BackupProto_Chat(); c.id = 1; c.recipientID = 2
            c.expirationTimerMs = .max; c.muteUntilMs = .max; chat.chat = c
            try importer.process(chat)
            for (sent, expires, start) in [(UInt64.max, UInt64(1000), UInt64(1)), (UInt64(1_600_000_000_000), .max, UInt64(Int64.max)),
                                           (UInt64(1_600_000_000_000), UInt64(Int64.max), .max)] {
                var f = BackupProto_Frame(); var i = BackupProto_ChatItem()
                i.chatID = 1; i.authorID = 2; i.dateSent = sent; i.expiresInMs = expires; i.expireStartDate = start
                var d = BackupProto_ChatItem.IncomingMessageDetails(); d.dateReceived = .max; d.dateServerSent = .max; i.incoming = d
                var m = BackupProto_StandardMessage(); var t = BackupProto_Text(); t.body = "edge"; m.text = t; i.standardMessage = m
                f.chatItem = i
                try importer.process(f)
            }
            var profile = BackupProto_Frame(); var p = BackupProto_NotificationProfile()
            p.id = UUID().data; p.name = "Edge"; p.createdAtMs = .max; profile.notificationProfile = p
            try importer.process(profile)
            try importer.finish()
            return importer.result
        }
        #expect(result.messages == 2 && result.frameErrors == 1)
    }

    /// A frame that cannot be read is counted and skipped; the rest still land.
    @Test func aBadFrameIsSkipped() async throws {
        let (db, url) = try LinkedClient.temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = Self.account()
        try await db.pool.write { try account.save($0) }
        let result = try await db.pool.write { d -> BackupImportResult in
            var importer = try BackupImporter(db: d, account: account, now: 1)
            var a = BackupProto_Frame(); var ad = BackupProto_AccountData(); ad.profileKey = Data(SignalCrypto.randomBytes(32)); a.account = ad
            try importer.process(a)
            var bad = BackupProto_Frame(); var c = BackupProto_Chat(); c.id = 9; c.recipientID = 99; bad.chat = c   // unknown recipient
            try importer.process(bad)
            try importer.finish()
            return importer.result
        }
        #expect(result.frameErrors == 1)
    }
}

@Suite(.serialized) struct LinkAndSyncTests {
    func config(_ server: MockServerHarness) -> SignalClient.Config {
        SignalClient.Config(net: Net.localTestServer(userAgent: "SignalSafe-Tests", chatPort: UInt16(server.ready.port),
                                                     rootCertificateDer: server.ready.certificateAuthorityDER),
                            endpoints: .mockServer(port: server.ready.port, rootCertificateDER: server.ready.certificateAuthorityDER),
                            trustRoots: server.ready.trustRoots, serverPublicParams: Data(base64Encoded: server.ready.serverPublicParams)!,
                            genericServerPublicParams: Data(base64Encoded: server.ready.genericServerPublicParams)!,
                            backupServerPublicParams: Data(base64Encoded: server.ready.backupServerPublicParams)!)
    }

    final class Progress: Sendable {
        let steps = Mutex<[LinkAndSyncProgress]>([])
        func add(_ p: LinkAndSyncProgress) { steps.withLock { $0.append(p) } }
        var all: [LinkAndSyncProgress] { steps.withLock { $0 } }
    }

    @Test func historyArrivesBeforeTheSessionStarts() async throws {
        let server = try await MockServerHarness.start()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("signalsafe-sync-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ephemeral = Data(SignalCrypto.randomBytes(32))
        var fixture = BackupFixture(ourAci: server.ready.phone.aci.lowercased(), aliceAci: server.ready.alice.aci.lowercased())
        fixture.mediaRootBackupKey = Data(base64Encoded: server.ready.phone.mediaRootBackupKey!)!
        try await server.call("putCdnBlob", ["cdnKey": "transfer-archive", "data": try fixture.archive(ephemeralKey: ephemeral).base64EncodedString()])
        try await server.call("setLinkAndSync", ["ephemeralBackupKey": ephemeral.base64EncodedString(),
                                                 "archive": ["cdn": 3, "key": "transfer-archive"] as [String: any Sendable]])
        let client = try SignalClient(config: config(server), directory: dir, keyStore: FixedKeyStore(key: SignalCrypto.randomBytes(32)),
                                      media: MediaDecoder(), parser: InProcessMessageParser.withGzip())
        // A download left from before that is not this archive: the server sends the whole
        // archive (the mock CDN ignores the Range request) and it replaces what was there.
        let archiveFile = await client.transferArchiveFile
        try Data(SignalCrypto.randomBytes(5000)).write(to: archiveFile)
        let (urls, sink) = AsyncStream<String>.makeStream()
        let phone = Task { for await url in urls { return try await server.call("provision", ["url": url]) }; throw HarnessError(description: "no url") }
        let progress = Progress()
        let account = try await client.link(deviceName: "SignalSafe sync test", onURL: { url in
            #expect(url.contains("capabilities=nopni%2Cnopni2%2Cbackup5"))
            sink.yield(url)
            sink.finish()
        }, onSync: { progress.add($0) })
        _ = try await phone.value
        #expect(account.aci == fixture.ourAci)
        #expect(progress.all.first == .waiting)
        guard case .finished(let result) = progress.all.last else { Issue.record("no import: \(progress.all)"); return }
        #expect(result.messages == 6 && result.frameErrors == 0)
        #expect(progress.all.contains { if case .downloading(let done, let total) = $0 { done == total && total > 0 } else { false } })
        #expect(!FileManager.default.fileExists(atPath: archiveFile.path))
        let body = try await client.database.pool.read { try String.fetchOne($0, sql: "SELECT body FROM messages WHERE body = 'hello from history'") }
        #expect(body == "hello from history")
        // The key is gone and the session works as after any link.
        #expect(try await client.hasLinkAndSync() == false)
        let events = await client.events()
        let t = TestClock.next()
        try await server.call("sendText", ["from": "alice", "text": "after the sync", "timestamp": t])
        for await e in events {
            if case .message(_, _, _, _, t, let b, _, _) = e { #expect(b == "after the sync"); break }
        }
        await client.shutdown()
        await server.stop()
    }

    @Test func thePrimaryCanSkipTheTransfer() async throws {
        let server = try await MockServerHarness.start()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("signalsafe-sync-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        try await server.call("setLinkAndSync", ["ephemeralBackupKey": Data(SignalCrypto.randomBytes(32)).base64EncodedString(),
                                                 "archive": ["error": "CONTINUE_WITHOUT_UPLOAD"]])
        let client = try SignalClient(config: config(server), directory: dir, keyStore: FixedKeyStore(key: SignalCrypto.randomBytes(32)),
                                      media: MediaDecoder(), parser: InProcessMessageParser.withGzip())
        let (urls, sink) = AsyncStream<String>.makeStream()
        let phone = Task { for await url in urls { return try await server.call("provision", ["url": url]) }; throw HarnessError(description: "no url") }
        let progress = Progress()
        _ = try await client.link(deviceName: "SignalSafe sync test", onURL: { url in sink.yield(url); sink.finish() }, onSync: { progress.add($0) })
        _ = try await phone.value
        #expect(progress.all == [.waiting, .skipped])
        #expect(try await client.hasLinkAndSync() == false)
        await client.shutdown()
        await server.stop()
    }

    /// Cancelled (here before the download begins): nothing is imported, the download is gone,
    /// and link throws so that the app unlinks and deletes the data.
    @Test func aCancelledTransferUnlinks() async throws {
        let server = try await MockServerHarness.start()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("signalsafe-sync-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ephemeral = Data(SignalCrypto.randomBytes(32))
        var fixture = BackupFixture(ourAci: server.ready.phone.aci.lowercased(), aliceAci: server.ready.alice.aci.lowercased())
        fixture.mediaRootBackupKey = Data(base64Encoded: server.ready.phone.mediaRootBackupKey!)!
        try await server.call("putCdnBlob", ["cdnKey": "transfer-archive", "data": try fixture.archive(ephemeralKey: ephemeral).base64EncodedString()])
        try await server.call("setLinkAndSync", ["ephemeralBackupKey": ephemeral.base64EncodedString(),
                                                 "archive": ["cdn": 3, "key": "transfer-archive"] as [String: any Sendable]])
        let client = try SignalClient(config: config(server), directory: dir, keyStore: FixedKeyStore(key: SignalCrypto.randomBytes(32)),
                                      media: MediaDecoder(), parser: InProcessMessageParser.withGzip())
        let (urls, sink) = AsyncStream<String>.makeStream()
        let phone = Task { for await url in urls { return try await server.call("provision", ["url": url]) }; throw HarnessError(description: "no url") }
        let progress = Progress()
        let control = LinkAndSyncControl()
        await #expect(throws: LinkAndSyncError.canceled) {
            _ = try await client.link(deviceName: "SignalSafe sync test", onURL: { url in sink.yield(url); sink.finish() }, onSync: { p in
                progress.add(p)
                if p == .waiting { control.cancel() }
            }, control: control)
        }
        _ = try await phone.value
        #expect(progress.all.last == .canceled)
        #expect(try await client.database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM messages") } == 0)
        #expect(!FileManager.default.fileExists(atPath: await client.transferArchiveFile.path))
        await client.shutdown()
        await server.stop()
    }

    /// No archive on the CDN (404, upstream "no backup on the server"): linked without history.
    @Test func aMissingArchiveLinksWithoutHistory() async throws {
        let server = try await MockServerHarness.start()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("signalsafe-sync-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        try await server.call("setLinkAndSync", ["ephemeralBackupKey": Data(SignalCrypto.randomBytes(32)).base64EncodedString(),
                                                 "archive": ["cdn": 3, "key": "not-there"] as [String: any Sendable]])
        let client = try SignalClient(config: config(server), directory: dir, keyStore: FixedKeyStore(key: SignalCrypto.randomBytes(32)),
                                      media: MediaDecoder(), parser: InProcessMessageParser.withGzip())
        let (urls, sink) = AsyncStream<String>.makeStream()
        let phone = Task { for await url in urls { return try await server.call("provision", ["url": url]) }; throw HarnessError(description: "no url") }
        let progress = Progress()
        _ = try await client.link(deviceName: "SignalSafe sync test", onURL: { url in sink.yield(url); sink.finish() }, onSync: { progress.add($0) })
        _ = try await phone.value
        #expect(progress.all.last == .skipped)
        #expect(try await client.hasLinkAndSync() == false)
        await client.shutdown()
        await server.stop()
    }

    /// A photo the primary backed up to the paid media tier, with no transit copy: fetched from
    /// the media tier (the day's backup credential, the media folder and the CDN's read headers
    /// through libsignal's unauthenticated connection), its layer removed, then checked and kept
    /// as any download is, its thumbnail made by the media service.
    @Test func aPhotoComesFromTheMediaTier() async throws {
        let server = try await MockServerHarness.start()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("signalsafe-sync-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = AttachmentFlowTests.png()
        _ = try await server.call("linkAndSyncHistory", ["messages": 2, "mediaPhotos": [png.base64EncodedString()]])
        let client = try SignalClient(config: config(server), directory: dir, keyStore: FixedKeyStore(key: SignalCrypto.randomBytes(32)),
                                      media: MediaDecoder(), parser: InProcessMessageParser.withGzip())
        let (urls, sink) = AsyncStream<String>.makeStream()
        let phone = Task { for await url in urls { return try await server.call("provision", ["url": url]) }; throw HarnessError(description: "no url") }
        let progress = Progress()
        _ = try await client.link(deviceName: "SignalSafe sync test", onURL: { url in sink.yield(url); sink.finish() }, onSync: { progress.add($0) })
        _ = try await phone.value
        guard case .finished(let result) = progress.all.last else { Issue.record("no import: \(progress.all)"); return }
        #expect(result.messages == 3 && result.frameErrors == 0)
        func photo() async throws -> (MessageAttachments.Location, MessageAttachment) {
            try await client.database.pool.read { db in
                let id = try #require(try String.fetchOne(db, sql: "SELECT messageId FROM message_attachments LIMIT 1"))
                return try #require(try MessageAttachments.fetch(db, messageId: id).first)
            }
        }
        let (loc, before) = try await photo()
        #expect(before.backupCdnNumber == 3 && before.cdnKey == nil && !before.isDownloaded, "\(before)")
        #expect(try await client.database.pool.read { try BackupMediaTier.isEnabled($0) })
        let session = try #require(await client.session)
        try await session.downloads.requestDownload([loc])
        var after = before
        for _ in 0..<200 where !after.isDownloaded {
            try await Task.sleep(for: .milliseconds(50))
            after = try await photo().1
        }
        #expect(after.isDownloaded && after.plaintextHash == SignalCrypto.sha256(png).hexString)
        #expect(after.thumbnail != nil && after.width == 200)
        await client.shutdown()
        await server.stop()
    }
}
