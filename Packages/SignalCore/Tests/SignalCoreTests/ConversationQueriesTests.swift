import Foundation
import GRDB
import Testing
@testable import SignalCore

@Suite struct ConversationQueriesTests {
    static let me = "11111111-1111-4111-8111-111111111111"
    static let friend = "22222222-2222-4222-8222-222222222222"
    static let stranger = "33333333-3333-4333-8333-333333333333"
    static let member = "44444444-4444-4444-8444-444444444444"
    static let blockedOne = "55555555-5555-4555-8555-555555555555"

    func database() throws -> (SignalDatabase, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("queries-\(UUID()).sqlite")
        return (try SignalDatabase(url: url, key: SignalCrypto.randomBytes(32)), url)
    }

    func insert(_ db: Database, id: String, type: String = "private", serviceId: String? = nil, profileName: String? = nil, name: String? = nil,
                json extra: [String: Any] = [:], activeAt: Int64? = nil) throws {
        var json: [String: Any] = ["id": id, "type": type]
        json.merge(extra) { _, b in b }
        try db.execute(sql: "INSERT INTO conversations (id, json, type, serviceId, profileName, name, active_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
                       arguments: [id, try MessageStore.jsonString(json), type, serviceId, profileName, name, activeAt])
    }

    @Test func composableFollowsUpstreamRules() throws {
        let (database, url) = try database()
        defer { try? FileManager.default.removeItem(at: url) }
        try database.pool.write { db in
            try Items.set(db, "uuid_id", "\(Self.me).4")
            try insert(db, id: "me", serviceId: Self.me)
            try insert(db, id: "friend", serviceId: Self.friend, profileName: "Bea", json: ["profileSharing": true])
            try insert(db, id: "stranger", serviceId: Self.stranger, profileName: "Spam Bot")          // no trust signal
            try insert(db, id: "member", serviceId: Self.member, profileName: "Cai")                   // shares a group
            try insert(db, id: "blocked", serviceId: Self.blockedOne, profileName: "Dee", json: ["profileSharing": true])
            try insert(db, id: "nameless", serviceId: "66666666-6666-4666-8666-666666666666", json: ["profileSharing": true])
            try insert(db, id: "group", type: "group", json: ["name": "Climbers", "membersV2": [["aci": Self.member], ["aci": Self.me]]])
            try insert(db, id: "left", type: "group", json: ["name": "Old group", "left": true])
            try BlockedList.serviceIds.replaceAll(db, [Self.blockedOne])
        }
        let ids = try database.pool.read { try ConversationQueries.composable($0) }.map(\.id)
        #expect(Set(ids) == ["me", "friend", "member", "group"])
        let group = try database.pool.read { try ConversationQueries.conversation($0, id: "group") }
        #expect(group?.kind == .group && group?.membersCount == 2 && group?.title == "Climbers")
        #expect(try database.pool.read { try ConversationQueries.inbox($0) }.isEmpty)    // nothing active yet
    }

    @Test func titlesFollowUpstreamOrder() throws {
        let (database, url) = try database()
        defer { try? FileManager.default.removeItem(at: url) }
        try database.pool.write { db in
            try insert(db, id: "nick", serviceId: Self.friend, profileName: "Column", json: [
                "nicknameGivenName": "Nicky", "systemGivenName": "Sys", "profileName": "Prof", "e164": "+15550001"])
            try insert(db, id: "system", serviceId: Self.member, json: ["systemGivenName": "Ada", "systemFamilyName": "Lovelace", "profileName": "ada99"])
            try insert(db, id: "profile", serviceId: Self.stranger, name: "Synced Name", json: ["profileName": "Grace", "profileFamilyName": "Hopper"])
            try insert(db, id: "number", serviceId: Self.blockedOne, json: ["e164": "+15550002", "username": "user.01"])
            try insert(db, id: "unknown", serviceId: "66666666-6666-4666-8666-666666666666")
        }
        let titles = try database.pool.read { db in
            try ["nick", "system", "profile", "number", "unknown"].map { try ConversationQueries.conversation(db, id: $0)?.title }
        }
        #expect(titles == ["Nicky", "Ada Lovelace", "Grace Hopper", "+15550002", "Unknown contact"])
    }
}
