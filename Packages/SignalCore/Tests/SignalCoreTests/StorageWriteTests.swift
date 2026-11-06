// Storage service write-back. The mock phone decrypts what we upload with its own (JS)
// storage-service code, so these tests check our encryption, manifest layout and record
// encoding against an independent implementation, not against our own decrypt.

import CryptoKit
import Foundation
import GRDB
import SignalProtos
import Testing
@testable import SignalCore

@Suite(.serialized) struct StorageWriteTests {
    struct PhoneStorage {
        var version: Int
        var records: [[String: Any]]
        var orphaned: Int

        func records(type: Int) -> [[String: Any]] { records.filter { $0["type"] as? Int == type } }
        func payloads(_ type: Int, _ key: String) -> [[String: Any]] { records(type: type).compactMap { ($0["record"] as? [String: Any])?[key] as? [String: Any] } }
        var account: [String: Any]? { payloads(4, "account").first }
        func contact(aci: String) -> [String: Any]? {
            let raw = StorageLocal.uuidBytes(aci)!.base64EncodedString()
            return payloads(1, "contact").first { $0["aciBinary"] as? String == raw }
        }
        func group(masterKey: String) -> [String: Any]? { payloads(3, "groupV2").first { $0["masterKey"] as? String == masterKey } }
    }

    /// Polls the phone's view of storage until `until` holds.
    func phoneStorage(_ c: LinkedClient, timeout: Duration = .seconds(20), until: (PhoneStorage) -> Bool) async throws -> PhoneStorage {
        let deadline = ContinuousClock.now + timeout
        var after = -1
        var last: PhoneStorage?
        while ContinuousClock.now < deadline {
            let r = try await c.server.json("storageRecords", ["after": after, "timeout": 5000])
            let s = PhoneStorage(version: r["version"] as? Int ?? 0, records: r["records"] as? [[String: Any]] ?? [], orphaned: r["orphaned"] as? Int ?? -1)
            if until(s) { return s }
            last = s
            after = s.version
        }
        Issue.record("phone storage never matched; last version \(last?.version ?? -1)")
        throw StorageServiceError.conflict
    }

    static let packA = String(repeating: "aa", count: 16), packC = String(repeating: "cc", count: 16), profileId = String(repeating: "5a", count: 16)

    @Test func mergesEveryRecordType() async throws {
        try await LinkedClient.with { c in
            try await c.server.call("setStorageState")
            try await c.server.call("setStorageRecords")
            let result = try #require(try await c.storage.sync())
            #expect(result.contacts == 1 && result.groups == 1 && result.account)
            #expect(result.other == 7 && result.unknown == 1 && result.errors == 0)
            let aliceAci = c.aliceAci
            try await c.database.pool.read { db throws in
                let alice = try #require(try String.fetchOne(db, sql: "SELECT id FROM conversations WHERE serviceId = ?", arguments: [aliceAci]))
                // Story lists (+ My Story, created locally)
                let list = try #require(try Row.fetchOne(db, sql: "SELECT * FROM storyDistributions WHERE id = '2f8d8d6e-7b55-4c3b-9c1e-1a2b3c4d5e6f'"))
                #expect(list["name"] as String? == "Close friends" && list["allowsReplies"] as Int64? == 1 && list["storageID"] as String? != nil)
                #expect(try String.fetchAll(db, sql: "SELECT serviceId FROM storyDistributionMembers WHERE listId = ?", arguments: [list["id"] as String]) == [aliceAci])
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM storyDistributions WHERE id = ?", arguments: [StorageLocal.myStoryId]) == 1)
                // Sticker packs: installed one waiting for its download, uninstalled one
                let pack = try #require(try Row.fetchOne(db, sql: "SELECT * FROM sticker_packs WHERE id = ?", arguments: [Self.packA]))
                // Its download is queued for the sticker service, which may already have tried
                // (this pack is not on the mock CDN).
                #expect(["pending", "error"].contains(pack["status"] as String? ?? "") && pack["position"] as Int64? == 2
                        && pack["key"] as String? == Data(repeating: 0xbb, count: 32).base64EncodedString() && pack["storageID"] as String? != nil)
                #expect(try Int64.fetchOne(db, sql: "SELECT uninstalledAt FROM uninstalled_sticker_packs WHERE id = ?", arguments: [Self.packC]) ?? 0 > 0)
                #expect(try String.fetchOne(db, sql: "SELECT status FROM favorite_stickers WHERE packId = ? AND stickerId = 3", arguments: [Self.packA]) == "known")
                // Call link tombstone, room id per ringrtc (HKDF-SHA256, CryptoKit here)
                // RFC 5869 with no salt: PRK = HMAC(0^32, ikm), OKM = HMAC(PRK, info ‖ 0x01).
                let prk = Data(HMAC<SHA256>.authenticationCode(for: Data(repeating: 0x11, count: 16), using: SymmetricKey(data: Data(count: 32))))
                let room = Data(HMAC<SHA256>.authenticationCode(for: Data("20230501-Signal-CallLinkRootKey-RoomId".utf8) + [1],
                                                                using: SymmetricKey(data: prk))).hexString
                #expect(try Int64.fetchOne(db, sql: "SELECT addedAt FROM defunctCallLinks WHERE roomId = ?", arguments: [room]) ?? 0 > 0)
                // Chat folders: "Tea" with alice, plus the All Chats folder
                let folder = try #require(try Row.fetchOne(db, sql: "SELECT * FROM chatFolders WHERE name = 'Tea'"))
                #expect(folder["includedConversationIds"] as String? == "[\"\(alice)\"]" && folder["includeAllGroupChats"] as Int64? == 1)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM chatFolders WHERE folderType = 1") == 1)
                // Notification profile
                let profile = try #require(try Row.fetchOne(db, sql: "SELECT * FROM notificationProfiles WHERE id = ?", arguments: [Self.profileId]))
                #expect(profile["name"] as String? == "Work" && profile["emoji"] as String? == "💼" && profile["color"] as Int64? == 0xff00ff00)
                #expect(profile["allowedMembersJson"] as String? == "[\"\(alice)\"]" && profile["scheduleStartTime"] as Int64? == 900)
                let days = try JSONSerialization.jsonObject(with: Data((profile["scheduleDaysEnabledJson"] as String? ?? "{}").utf8)) as? [String: Bool]
                #expect(days == ["1": true, "2": true, "3": true, "4": true, "5": true, "6": false, "7": false])
                // AccountRecord fields kept for write-back
                #expect(try Items.get(db, "payments", as: StorageRecords.Payments.self)?.enabled == true)
                #expect(try Items.get(db, "subscriberCurrencyCode", as: String.self) == "EUR")
                #expect(try Items.get(db, "backupTier", as: UInt64.self) == 200)
                #expect(try Items.get(db, "usernameLinkColor", as: Int.self) == 5)
                #expect(try Items.get(db, "notificationProfileOverride", as: StorageRecords.NotificationProfileOverride.self)?.disabledAtMs ?? 0 > 0)
                // HIDDEN_STICKER_PACK is kept by storageID only
                #expect(try Items.get(db, "storage-service-unknown-records", as: [StorageIDRecord].self)?.map(\.itemType) == [10])
            }
        }
    }

    @Test func uploadsLocalChangesAndKeepsEverythingElse() async throws {
        try await LinkedClient.with { c in
            try await c.server.call("setStorageState")
            try await c.server.call("setStorageRecords")
            try await c.storage.sync()
            let alice = try await c.accountInfo("alice"), phone = try await c.accountInfo("phone")
            let aliceAci = c.aliceAci, account = c.account
            let oldAliceID = try await c.conversationJSON(serviceId: aliceAci)["storageID"] as? String
            // Local changes, captured for storage (archive alice, rename a profile, read receipts off).
            try await c.database.pool.write { db in
                let id = try MessageStore.privateConversation(db, serviceId: aliceAci)
                try MessageStore.updateConversationJSON(db, conversationId: id) { $0["isArchived"] = true }
                try StorageWriteBack.conversationChanged(db, conversationId: id)
                try db.execute(sql: "UPDATE notificationProfiles SET name = 'Deep work' WHERE id = ?", arguments: [Self.profileId])
                try StorageWriteBack.recordChanged(db, .notificationProfile(id: Self.profileId))
                try Items.set(db, "read-receipt-setting", false)
                try StorageWriteBack.accountChanged(db, account: account)
            }
            c.jobs.poke()

            let s = try await phoneStorage(c) { s in
                s.contact(aci: aliceAci)?["archived"] as? Bool == true && s.account?["readReceipts"] as? Bool != true
                    && s.payloads(9, "notificationProfile").first?["name"] as? String == "Deep work"
            }
            // The contact keeps everything the phone put there.
            let a = try #require(s.contact(aci: aliceAci))
            #expect(a["profileKey"] as? String == alice.profileKey && a["identityKey"] as? String == alice.identityKey && a["identityState"] as? Int == 1)
            // Names come from alice's fetched profile (no family name), as after upstream's getProfiles.
            #expect(a["givenName"] as? String == "Alice" && a["familyName"] as? String == "" && a["systemGivenName"] as? String == "Ally")
            #expect(a["note"] as? String == "met at the tea party" && a["whitelisted"] as? Bool == true && a["markedUnread"] as? Bool == true)
            // So does the account record, including what this client never shows.
            let acct = try #require(s.account)
            #expect(acct["profileKey"] as? String == phone.profileKey && acct["givenName"] as? String == "Phone")
            #expect((acct["payments"] as? [String: Any])?["enabled"] as? Bool == true)
            #expect((acct["payments"] as? [String: Any])?["entropy"] as? String == Data(repeating: 7, count: 32).base64EncodedString())
            #expect(acct["donorSubscriberId"] as? String == Data(repeating: 9, count: 32).base64EncodedString())
            #expect(acct["donorSubscriberCurrencyCode"] as? String == "EUR" && acct["backupTier"] as? Int == 200)
            #expect((acct["usernameLink"] as? [String: Any])?["color"] as? Int == 5)
            #expect((acct["pinnedConversations"] as? [Any])?.count == 2 && acct["universalExpireTimer"] as? Int == 3600)
            // Other records: My Story and All Chats were added, the unknown type passed through.
            let lists = s.payloads(5, "storyDistributionList").compactMap { $0["identifier"] as? String }
            #expect(Set(lists) == [Data(count: 16).base64EncodedString(), StorageLocal.uuidBytes("2f8d8d6e-7b55-4c3b-9c1e-1a2b3c4d5e6f")!.base64EncodedString()])
            #expect(s.payloads(8, "chatFolder").count == 2 && s.records(type: 6).count == 2 && s.records(type: 11).count == 1 && s.records(type: 7).count == 1)
            #expect(s.payloads(10, "hiddenStickerPack").first?["packId"] as? String == Data(repeating: 0xdd, count: 16).base64EncodedString())
            #expect(s.orphaned == 0)
            // Locally: new storageID, no longer needing sync.
            try await c.eventually("alice uploaded under a new storageID") { db in
                let json = try MessageStore.jsonObject(try String.fetchOne(db, sql: "SELECT json FROM conversations WHERE serviceId = ?", arguments: [aliceAci]) ?? "{}")
                return json["storageID"] as? String != oldAliceID && json["needsStorageServiceSync"] as? Bool == false
            }
            // Uploading again with nothing changed writes nothing.
            #expect(try await c.storage.upload() == nil)
        }
    }

    @Test func conflictWithPhoneWriteIsMergedAndRetried() async throws {
        try await LinkedClient.with { c in
            let state = try await c.server.json("setStorageState")
            let masterKey = try #require(state["groupMasterKey"] as? String)
            try await c.storage.sync()
            // Let the follow-up upload (My Story, All Chats) finish first.
            _ = try await phoneStorage(c) { $0.payloads(5, "storyDistributionList").count == 1 }
            try await c.eventually("no queued upload") { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM jobs WHERE queueType = ?", arguments: [StorageService.uploadQueueType]) == 0
            }
            // The phone changes alice; we change the group without having seen that write.
            try await c.server.call("updateAliceRecord", ["markedUnread": false, "nickname": "Al"])
            let groupId = try GroupKeys(masterKey: Data(base64Encoded: masterKey)!).groupIdBase64
            try await c.database.pool.write { db in
                let id = try #require(try String.fetchOne(db, sql: "SELECT id FROM conversations WHERE groupId = ?", arguments: [groupId]))
                try MessageStore.updateConversationJSON(db, conversationId: id) { $0["markedUnread"] = true; $0["needsStorageServiceSync"] = true }
            }
            let result = try #require(try await c.storage.upload(fromSync: true))
            #expect(result.conflicts == 1)

            let s = try await phoneStorage(c) { $0.group(masterKey: masterKey)?["markedUnread"] as? Bool == true }
            let a = try #require(s.contact(aci: c.aliceAci))
            #expect((a["nickname"] as? [String: Any])?["given"] as? String == "Al" && a["markedUnread"] as? Bool != true)
            let aj = try await c.conversationJSON(serviceId: c.aliceAci)
            #expect(aj["nicknameGivenName"] as? String == "Al" && aj["markedUnread"] as? Bool == false)
            #expect(s.orphaned == 0)
        }
    }

    @Test func unknownFieldsSurviveMergeAndRegeneration() async throws {
        try await LinkedClient.with { c in
            var contact = Signalservice_ContactRecord()
            contact.aciBinary = StorageLocal.uuidBytes(c.aliceAci)!
            contact.givenName = "Alice"
            // Field 999 (varint 42), unknown to every proto version we have.
            let unknown = Data([0xB8, 0x3E, 0x2A])
            try contact.merge(serializedBytes: unknown)
            #expect(contact.unknownFields.data == unknown)
            let storage = c.storage, aliceAci = c.aliceAci, record = contact
            let regenerated = try await c.database.pool.write { db -> Signalservice_ContactRecord in
                let ctx = try storage.context(db, version: 7)
                _ = try StorageRecords.mergeContact(db, record, storageID: Data(repeating: 1, count: 16).base64EncodedString(), ctx: ctx)
                let row = try #require(try StorageLocal.conversations(db, where: "serviceId = ?", arguments: [aliceAci]).first)
                return try StorageRecords.toContactRecord(db, row, binary: true)
            }
            #expect(regenerated.unknownFields.data == unknown && regenerated.givenName == "Alice")
        }
    }

    @Test func itemAndManifestCrypto() throws {
        let storageKey = StorageService.deriveStorageKey(masterKey: Data(repeating: 3, count: 32))
        var record = Signalservice_StorageRecord()
        var contact = Signalservice_ContactRecord()
        contact.e164 = "+15555550100"
        record.contact = contact
        for ikm in [nil, Data(repeating: 9, count: 32)] {
            let raw = Data(repeating: 5, count: 16)
            let item = try StorageService.encryptItem(record, raw: raw, storageKey: storageKey, recordIkm: ikm)
            #expect(try StorageService.decryptItem(item, storageKey: storageKey, recordIkm: ikm) == record)
            // Wrong key derivation (ikm vs legacy) or a flipped bit fails as cannotDecrypt.
            #expect(throws: StorageServiceError.self) { try StorageService.decryptItem(item, storageKey: storageKey, recordIkm: ikm == nil ? Data(repeating: 1, count: 32) : nil) }
            var tampered = item
            tampered.value[20] ^= 1
            #expect(throws: StorageServiceError.self) { try StorageService.decryptItem(tampered, storageKey: storageKey, recordIkm: ikm) }
        }
        var m = Signalservice_ManifestRecord()
        m.version = 4
        var sealed = Signalservice_StorageManifest()
        sealed.version = 4
        sealed.value = try SignalCrypto.aes256GCMEncrypt(key: StorageService.manifestKey(storageKey: storageKey, version: 4), m.serializedBytes())
        #expect(try StorageService.decryptManifest(sealed, storageKey: storageKey).version == 4)
        // A manifest whose outer version disagrees with the encrypted one is rejected.
        sealed.version = 5
        #expect(throws: StorageServiceError.self) { try StorageService.decryptManifest(sealed, storageKey: storageKey) }
    }
}
