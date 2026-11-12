// What SignalCore gives the UI surfaces connected in the app: a contact's About details, a 1:1
// chat's groups in common and the hero's name flags, verified group names, view-once state on
// timeline messages, recipients needing approval, the notification resets, story lists created
// with the app's id, and "Delete all data".

import Foundation
import GRDB
import SignalMediaDecoder
import Synchronization
import Testing
@testable import SignalCore

@Suite struct ConnectedSurfacesTests {
    static let me = "11111111-1111-4111-8111-111111111111"
    static let friend = "22222222-2222-4222-8222-222222222222"
    static let other = "33333333-3333-4333-8333-333333333333"

    func database() throws -> (SignalDatabase, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("surfaces-\(UUID()).sqlite")
        return (try SignalDatabase(url: url, key: SignalCrypto.randomBytes(32)), url)
    }

    func insert(_ db: Database, id: String, type: String = "private", serviceId: String? = nil, json extra: [String: Any] = [:]) throws {
        var json: [String: Any] = ["id": id, "type": type]
        json.merge(extra) { _, b in b }
        try db.execute(sql: "INSERT INTO conversations (id, json, type, serviceId) VALUES (?, ?, ?, ?)",
                       arguments: [id, try MessageStore.jsonString(json), type, serviceId])
    }

    /// Two groups with the friend (one left), one without; the friend with a nickname, a note, an
    /// about and a profile name.
    func seed(_ database: SignalDatabase) throws {
        try database.pool.write { db in
            try Items.set(db, "uuid_id", "\(Self.me).2")
            try insert(db, id: "me", serviceId: Self.me)
            try insert(db, id: "friend", serviceId: Self.friend, json: [
                "profileName": "Bea", "profileFamilyName": "Arthur", "nicknameGivenName": "B", "note": "met at the climbing gym",
                "about": "on belay", "aboutEmoji": "🧗", "profileSharing": true, "e164": "+15550001"])
            try insert(db, id: "other", serviceId: Self.other, json: ["profileName": "Cai"])
            try insert(db, id: "zebras", type: "group", json: ["name": "Zebras", "membersV2": [["aci": Self.friend], ["aci": Self.me]]])
            try insert(db, id: "apes", type: "group", json: ["name": "Apes", "membersV2": [["aci": Self.friend], ["aci": Self.me]]])
            try insert(db, id: "left", type: "group", json: ["name": "Old", "left": true, "membersV2": [["aci": Self.friend]]])
            try insert(db, id: "cats", type: "group", json: ["name": "Cats", "membersV2": [["aci": Self.other], ["aci": Self.me]]])
        }
    }

    @Test func aboutAContact() throws {
        let (database, url) = try database()
        defer { try? FileManager.default.removeItem(at: url) }
        try seed(database)
        let info = try database.pool.read { try ConversationQueries.contactAbout($0, serviceId: Self.friend, ourAci: Self.me) }
        #expect(info.conversationId == "friend")
        #expect(info.title == "B")                                  // the nickname wins
        #expect(info.titleNoNickname == "Bea Arthur")               // shown beside it
        #expect(info.note == "met at the climbing gym" && info.about == "on belay" && info.aboutEmoji == "🧗")
        #expect(info.e164 == "+15550001" && info.profileSharing && !info.isBlocked && !info.isVerified)
        #expect(info.sharedGroupNames == ["Apes", "Zebras"])        // not the group they left, sorted
        #expect(info.isSignalConnection && info.hasNickname && info.hasProfileName)

        try database.pool.write { try BlockedList.serviceIds.replaceAll($0, [Self.friend]) }
        let blocked = try database.pool.read { try ConversationQueries.contactAbout($0, serviceId: Self.friend, ourAci: Self.me) }
        #expect(blocked.isBlocked && !blocked.isSignalConnection)
    }

    @Test func detailsCarryGroupsInCommonAndNameFlags() throws {
        let (database, url) = try database()
        defer { try? FileManager.default.removeItem(at: url) }
        try seed(database)
        let friend = try #require(try database.pool.read { try ConversationQueries.details($0, conversationId: "friend") })
        #expect(friend.groupsInCommon == ["apes", "zebras"])
        #expect(friend.hasProfileName && friend.hasNickname && !friend.isInSystemContacts)
        let other = try #require(try database.pool.read { try ConversationQueries.details($0, conversationId: "other") })
        #expect(other.groupsInCommon == ["cats"] && !other.hasNickname)
    }

    @Test func aGroupNameIsVerifiedOnlyByItsHash() throws {
        let (database, url) = try database()
        defer { try? FileManager.default.removeItem(at: url) }
        try seed(database)
        #expect(GroupNames.isVerified(name: "Apes", hash: GroupNames.verifiedHash("Apes")))
        #expect(!GroupNames.isVerified(name: "Apes!", hash: GroupNames.verifiedHash("Apes")))     // renamed by someone else
        #expect(!GroupNames.isVerified(name: "Apes", hash: nil) && !GroupNames.isVerified(name: "", hash: GroupNames.verifiedHash("")))
        // computeGroupNameHash: base64(SHA-256(name)).
        #expect(GroupNames.verifiedHash("abc") == "ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=")
        try database.pool.write { db in
            try MessageStore.updateConversationJSON(db, conversationId: "apes") { $0["groupVerifiedNameHash"] = GroupNames.verifiedHash("Apes") }
        }
        let apes = try #require(try database.pool.read { try ConversationQueries.details($0, conversationId: "apes") })
        let zebras = try #require(try database.pool.read { try ConversationQueries.details($0, conversationId: "zebras") })
        #expect(apes.isGroupNameVerified && !zebras.isGroupNameVerified)
    }

    @Test func viewOnceMessagesSayWhetherTheyWereOpened() throws {
        let (database, url) = try database()
        defer { try? FileManager.default.removeItem(at: url) }
        try seed(database)
        try database.pool.write { db in
            for (id, extra) in [("fresh", ["isViewOnce": true]), ("opened", ["isViewOnce": true, "isErased": true, "readStatus": ReadStatus.viewed.rawValue]),
                                ("plain", [:])] as [(String, [String: Any])] {
                var json: [String: Any] = ["id": id, "conversationId": "friend", "type": "incoming"]
                json.merge(extra) { _, b in b }
                try db.execute(sql: "INSERT INTO messages (id, conversationId, type, json, sent_at, received_at, sourceServiceId) VALUES (?, 'friend', 'incoming', ?, 1, 1, ?)",
                               arguments: [id, try MessageStore.jsonString(json), Self.friend])
            }
        }
        let messages = try database.pool.read { try ConversationQueries.messages($0, conversationId: "friend") }
        let byId = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        #expect(byId["fresh"]?.isViewOnce == true && byId["fresh"]?.isErased == false && byId["fresh"]?.isViewed == false)
        #expect(byId["opened"]?.isViewOnce == true && byId["opened"]?.isErased == true && byId["opened"]?.isViewed == true)
        #expect(byId["plain"]?.isViewOnce == false)
    }

    @Test func storyListsTakeTheAppsId() throws {
        let (database, url) = try database()
        defer { try? FileManager.default.removeItem(at: url) }
        let id = try database.pool.write { try StoryDistributionLists.create($0, id: "chosen-id", name: "Climbers", members: [Self.friend]) }
        let generated = try database.pool.write { try StoryDistributionLists.create($0, name: "Others", members: []) }
        #expect(id == "chosen-id" && generated != id && UUID(uuidString: generated) != nil)
    }

    @Test func deleteAllDataRemovesTheFolderAndTheKey() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("delete-all-\(UUID())", isDirectory: true)
        let keys = RecordingKeyStore()
        let client = try SignalClient(config: try .signal(.staging, userAgent: "SignalSafe-Tests"), directory: folder, keyStore: keys, media: MediaDecoder())
        try Data("attachment".utf8).write(to: folder.appendingPathComponent("file.bin"))
        #expect(FileManager.default.fileExists(atPath: folder.path))
        // No stored account: nothing to unlink on the server, the data still goes.
        await client.deleteAllData(keyStore: keys)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(keys.deleted.withLock { $0 })
    }
}

/// A database key that remembers being deleted.
final class RecordingKeyStore: DatabaseKeyStore {
    let key = SignalCrypto.randomBytes(32)
    let deleted = Mutex(false)
    func loadOrCreateKey() throws -> Data { key }
    func deleteKey() throws { deleted.withLock { $0 = true } }
}
