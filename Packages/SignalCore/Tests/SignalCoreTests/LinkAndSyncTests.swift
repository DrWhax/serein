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

extension InProcessMessageParser {
    /// With the service's gunzip (CodecCore), for backups.
    static func withGzip() -> InProcessMessageParser {
        InProcessMessageParser(inflate: { Data(try Gzip.decompress(ByteSlice([UInt8]($0)), maxOutput: MessageParserLimits.maxBackupBytes)) })
    }
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
        out.append(item(3, 3, base + 7000, incoming: true) { $0.standardMessage = text("release notes") })     // dropped
        out.append(frame { f in var p = BackupProto_StickerPack(); p.packID = Data(SignalCrypto.randomBytes(16)); p.packKey = Data(SignalCrypto.randomBytes(32))
            f.installedStickerPack = p })
        out.append(frame { f in
            var c = BackupProto_ChatFolder(); c.id = UUID().data; c.name = "Close"; c.folderType = .custom; c.includedRecipientIds = [2]; c.showMutedChats = true
            f.chatFolder = c
        })
        return out
    }

    /// BackupInfo, then the frames, delimited and gzipped, then encrypted for `ephemeralKey`.
    func archive(ephemeralKey: Data) throws -> Data {
        var info = BackupProto_BackupInfo()
        info.version = 1
        info.backupTimeMs = base + 10_000
        info.mediaRootBackupKey = Data(SignalCrypto.randomBytes(32))
        var plain = Data()
        for record in [try info.serializedBytes() as Data] + (try frames().map { try $0.serializedBytes() as Data }) {
            plain += PlaintextExport.varint(UInt64(record.count)) + record
        }
        let keys = try LinkAndSync.keys(ephemeralKey: ephemeralKey, aci: ourAci)
        return try LinkAndSync.encrypt(Data(Gzip.compress([UInt8](plain))), mac: keys.mac, aes: keys.aes)
    }
}

@Suite struct LinkAndSyncUnitTests {
    @Test func archivesRoundTripAndTamperingIsRefused() throws {
        let aci = UUID().uuidString.lowercased()
        let key = Data(SignalCrypto.randomBytes(32))
        let keys = try LinkAndSync.keys(ephemeralKey: key, aci: aci)
        let plaintext = Data("backup bytes".utf8)
        var archive = try LinkAndSync.encrypt(plaintext, mac: keys.mac, aes: keys.aes)
        #expect(try LinkAndSync.decrypt(archive, mac: keys.mac, aes: keys.aes) == plaintext)
        // The keys depend on the ACI.
        let other = try LinkAndSync.keys(ephemeralKey: key, aci: UUID().uuidString.lowercased())
        #expect(throws: LinkAndSyncError.badMAC) { try LinkAndSync.decrypt(archive, mac: other.mac, aes: other.aes) }
        archive[20] ^= 1
        #expect(throws: LinkAndSyncError.badMAC) { try LinkAndSync.decrypt(archive, mac: keys.mac, aes: keys.aes) }
        #expect(throws: LinkAndSyncError.self) { try LinkAndSync.decrypt(Data(count: 40), mac: keys.mac, aes: keys.aes) }
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

    /// The parser inflates the archive and hands its frames out by run; damage is malformed,
    /// and a parser without gunzip (the default) refuses backups.
    @Test func theParserOpensArchivesAndHandsOutRuns() throws {
        var info = BackupProto_BackupInfo()
        info.version = 1
        var frame = BackupProto_Frame()
        var c = BackupProto_Chat(); c.id = 7; frame.chat = c
        var plain = Data()
        for r in [try info.serializedBytes() as Data] + Array(repeating: try frame.serializedBytes() as Data, count: 3) {
            plain += PlaintextExport.varint(UInt64(r.count)) + r
        }
        let parser = InProcessMessageParser.withGzip()
        let (got, runs) = try parser.backupArchive(Data(Gzip.compress([UInt8](plain))), source: "backup:x")
        #expect(got.version == 1 && runs == 1)
        #expect(try parser.backupRun(0, source: "backup:x").map(\.chat.id) == [7, 7, 7])
        #expect(try parser.backupRun(1, source: "backup:x").isEmpty)
        #expect(throws: MessageParserError.self) { try parser.backupArchive(Data(Gzip.compress([5, 1])), source: "backup:x") }   // truncated
        #expect(throws: MessageParserError.self) { try parser.backupArchive(Data([1, 2, 3]), source: "backup:x") }               // not gzip
        #expect(throws: MessageParserError.self) { try InProcessMessageParser().backupArchive(Data(Gzip.compress([UInt8](plain))), source: "backup:x") }
        #expect(throws: MessageParserError.self) { try InProcessMessageParser.withGzip().backupRun(0, source: "backup:x") }      // none open
    }

    static func account() -> Account {
        Account(aci: UUID().uuidString.lowercased(), pni: UUID().uuidString.lowercased(), number: "+15550000", deviceId: 2, password: "pw",
                deviceName: "test", aciIdentity: IdentityKeyPair.generate(), pniIdentity: IdentityKeyPair.generate(), aciRegistrationId: 1,
                pniRegistrationId: 2, profileKey: nil, masterKey: nil, accountEntropyPool: nil, readReceipts: false)
    }

    /// The frames land as upstream's import writes them.
    @Test func importsTheFrames() async throws {
        let (db, url) = try LinkedClient.temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let account = Self.account()
        try await db.pool.write { try account.save($0) }
        let fixture = BackupFixture(ourAci: account.aci, aliceAci: UUID().uuidString.lowercased())
        let key = Data(SignalCrypto.randomBytes(32))
        let result = try await LinkAndSync.importArchive(try fixture.archive(ephemeralKey: key), ephemeralKey: key, account: account, database: db,
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
                            genericServerPublicParams: Data(base64Encoded: server.ready.genericServerPublicParams)!)
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
        let fixture = BackupFixture(ourAci: server.ready.phone.aci.lowercased(), aliceAci: server.ready.alice.aci.lowercased())
        try await server.call("putCdnBlob", ["cdnKey": "transfer-archive", "data": try fixture.archive(ephemeralKey: ephemeral).base64EncodedString()])
        try await server.call("setLinkAndSync", ["ephemeralBackupKey": ephemeral.base64EncodedString(),
                                                 "archive": ["cdn": 3, "key": "transfer-archive"] as [String: any Sendable]])
        let client = try SignalClient(config: config(server), directory: dir, keyStore: FixedKeyStore(key: SignalCrypto.randomBytes(32)),
                                      media: MediaDecoder(), parser: InProcessMessageParser.withGzip())
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
}
