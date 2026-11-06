// Storage service read: the mock phone publishes a manifest (account record, a
// verified contact, a group, pins); the client fetches, decrypts and applies it.

import Foundation
import GRDB
import LibSignalClient
import SignalProtos
import Testing
@testable import SignalCore

@Suite(.serialized) struct StorageReadTests {
    @Test func appliesManifestFromPhone() async throws {
        try await LinkedClient.with { c in
            let state = try await c.server.json("setStorageState")
            let version = try #require(state["version"] as? Int)
            let groupMasterKey = try #require((state["groupMasterKey"] as? String).flatMap { Data(base64Encoded: $0) })
            let alice = try await c.accountInfo("alice")

            let result = try #require(try await c.storage.sync())
            #expect(result == StorageSyncResult(version: UInt64(version), contacts: 1, groups: 1, account: true, unknown: 0))

            // ContactRecord
            let a = try await c.conversationJSON(serviceId: c.aliceAci)
            // The record seeds the name on a first sync and asks for a profile fetch, which has the
            // last word: alice's real profile has no family name.
            #expect(a["profileName"] as? String == "Alice" && a["profileFamilyName"] == nil)
            #expect(a["systemGivenName"] as? String == "Ally" && a["note"] as? String == "met at the tea party")
            #expect(a["profileKey"] as? String == alice.profileKey)
            #expect(a["profileSharing"] as? Bool == true && a["markedUnread"] as? Bool == true && a["isArchived"] as? Bool == false)
            #expect(a["e164"] as? String == alice.number)
            #expect(a["storageID"] as? String != nil && a["isPinned"] as? Bool == true)
            try await c.database.pool.read { db throws in
                let identity = try MessageStore.jsonObject(try #require(try String.fetchOne(db, sql: "SELECT json FROM identityKeys WHERE id = ?",
                                                                                            arguments: [c.aliceAci])))
                #expect(identity["publicKey"] as? String == alice.identityKey && identity["verified"] as? Int == VerifiedStatus.verified.rawValue)
                #expect(try String.fetchOne(db, sql: "SELECT e164 FROM conversations WHERE serviceId = ?", arguments: [c.aliceAci]) == alice.number)
            }

            // GroupV2Record
            let groupId = try GroupSecretParams.deriveFromMasterKey(groupMasterKey: GroupMasterKey(contents: groupMasterKey))
                .getPublicParams().getGroupIdentifier().serialize().base64EncodedString()
            let (groupConversation, groupJSON) = try await c.database.pool.read { db in
                let row = try #require(try Row.fetchOne(db, sql: "SELECT id, json FROM conversations WHERE groupId = ?", arguments: [groupId]))
                return (row["id"] as String, row["json"] as String)
            }
            let g = try MessageStore.jsonObject(groupJSON)
            #expect(g["masterKey"] as? String == groupMasterKey.base64EncodedString())
            // Archived in its GroupV2Record, but pinned by the AccountRecord: mergeAccountRecord
            // un-archives pinned conversations.
            #expect(g["isArchived"] as? Bool == false && g["isPinned"] as? Bool == true && g["profileSharing"] as? Bool == true)
            #expect(g["muteExpiresAt"] as? Int64 == 4_102_444_800_000)

            // AccountRecord
            try await c.database.pool.read { db throws in
                #expect(try Items.get(db, "read-receipt-setting", as: Bool.self) == true)
                #expect(try Items.get(db, "typingIndicators", as: Bool.self) == true)
                #expect(try Items.get(db, "linkPreviews", as: Bool.self) == false)
                #expect(try Items.get(db, "universalExpireTimer", as: Int.self) == 3600)
                #expect(try Items.get(db, "preferredReactionEmoji", as: [String].self) == ["👍", "🫖"])
                #expect(try Items.get(db, "manifestVersion", as: UInt64.self) == UInt64(version))
                let aliceConversation = try String.fetchOne(db, sql: "SELECT id FROM conversations WHERE serviceId = ?", arguments: [c.aliceAci])
                #expect(try Items.get(db, "pinnedConversationIds", as: [String].self) == [aliceConversation, groupConversation].compactMap { $0 })
                #expect(try String.fetchOne(db, sql: "SELECT profileName FROM conversations WHERE serviceId = ?", arguments: [c.account.aci]) == "Phone")
            }

            // Same manifest version: nothing to do.
            #expect(try await c.storage.sync() == nil)
        }
    }

    @Test func fetchLatestSyncTriggersIncrementalRead() async throws {
        try await LinkedClient.with { c in
            try await c.server.call("setStorageState")
            #expect(try await c.storage.sync() != nil)
            #expect(try await c.conversationJSON(serviceId: c.aliceAci)["isArchived"] as? Bool == false)

            // The phone archives alice and sends SyncMessage.FetchLatest(STORAGE_MANIFEST).
            let updated = try await c.server.json("updateStorageState", ["archiveAlice": true])
            let version = try #require(updated["version"] as? Int)
            try await c.eventually("manifest \(version) applied") { db in
                // ≥: a pending upload of ours may land right after the phone's write (409, merge, retry).
                try Items.get(db, "manifestVersion", as: Int.self) ?? 0 >= version
            }
            #expect(try await c.conversationJSON(serviceId: c.aliceAci)["isArchived"] as? Bool == true)
        }
    }

    @Test func keyDerivations() throws {
        let master = Data(repeating: 1, count: 32)
        let storageKey = StorageService.deriveStorageKey(masterKey: master)
        #expect(storageKey == SignalCrypto.hmacSHA256(key: master, Data("Storage Service Encryption".utf8)))
        // libsignal's SVR-key derivation names the same key.
        let svrStorageKey = try SvrKey(contents: master).deriveStorageServiceKey()
        #expect(storageKey == svrStorageKey)
        let raw = Data(repeating: 9, count: 16)
        #expect(try StorageService.itemKey(storageKey: storageKey, recordIkm: nil, raw: raw)
                == SignalCrypto.hmacSHA256(key: storageKey, Data("Item_\(raw.base64EncodedString())".utf8)))
        let ikm = Data(repeating: 3, count: 32)
        let expectedItemKey = try hkdf(outputLength: 32, inputKeyMaterial: ikm, salt: Data(), info: Data("20240801_SIGNAL_STORAGE_SERVICE_ITEM_".utf8) + raw)
        #expect(try StorageService.itemKey(storageKey: storageKey, recordIkm: ikm, raw: raw) == expectedItemKey)
    }
}

@Suite(.serialized) struct ContactSyncTests {
    @Test func contactsSyncFromPhone() async throws {
        try await LinkedClient.with { c in
            let alice = try await c.accountInfo("alice")
            try await c.messenger.requestSync([.contacts])
            _ = try await c.log.waitFor("contacts sync") { if case .sync("contacts", _) = $0 { true } else { false } }
            try await c.eventually("alice from contact sync") { db in
                try Row.fetchOne(db, sql: "SELECT name, e164 FROM conversations WHERE serviceId = ?", arguments: [c.aliceAci])
                    .map { $0["name"] as String? == "Alice" && $0["e164"] as String? == alice.number } ?? false
            }
        }
    }

    @Test func streamGrammar() throws {
        func entry(_ name: String, avatar: Data? = nil) throws -> Data {
            var d = Signalservice_ContactDetails()
            d.aci = UUID().uuidString.lowercased()
            d.name = name
            if let avatar { d.avatar.length = UInt32(avatar.count); d.avatar.contentType = "image/png" }
            let bytes: Data = try d.serializedBytes()
            var out = Data()
            var n = bytes.count
            repeat { out.append(UInt8(n & 0x7F) | (n >= 0x80 ? 0x80 : 0)); n >>= 7 } while n > 0
            return out + bytes + (avatar ?? Data())
        }
        let stream = try entry("A", avatar: Data(repeating: 0xAB, count: 300)) + entry(String(repeating: "B", count: 200))
        #expect(try ContactSync.parse(stream).map(\.name) == ["A", String(repeating: "B", count: 200)])
        #expect(try ContactSync.parse(Data()).isEmpty)
        // Truncated body, truncated avatar, over-long varint.
        #expect(throws: ContactSyncError.self) { try ContactSync.parse(stream.dropLast()) }
        #expect(throws: ContactSyncError.self) { try ContactSync.parse(try entry("A", avatar: Data(repeating: 1, count: 10)).dropLast(3)) }
        #expect(throws: ContactSyncError.varintTooLong(offset: 5)) { try ContactSync.parse(Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01])) }
    }

    @Test func attachmentCipher() throws {
        let plain = Data("contact blob".utf8)
        let key = AttachmentCipher.generateKeys()
        let e = try AttachmentCipher.encrypt(plain, keys: key)
        let (blob, digest) = (e.blob, e.digest)
        #expect(try AttachmentCipher.decrypt(blob, key: key, digest: digest, size: plain.count) == plain)
        var bad = blob
        bad[20] ^= 1
        // Upstream checks the MAC first, then the digest.
        #expect(throws: AttachmentError.badMAC) { try AttachmentCipher.decrypt(bad, key: key, digest: digest, size: nil) }
        #expect(throws: AttachmentError.badDigest) { try AttachmentCipher.decrypt(blob, key: key, digest: SignalCrypto.sha256(bad), size: nil) }
        #expect(throws: AttachmentError.missingDigest) { try AttachmentCipher.decrypt(blob, key: key, digest: nil, size: nil) }
        // Padded to 541 bytes: a size past the padded plaintext is an error.
        #expect(throws: AttachmentError.sizeMismatch(expected: 10_000, actual: 541)) {
            try AttachmentCipher.decrypt(blob, key: key, digest: digest, size: 10_000)
        }
    }
}
