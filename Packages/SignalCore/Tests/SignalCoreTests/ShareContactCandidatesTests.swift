// Who the share-contact dialog offers and what it would share (SmartShareContactDialog's
// isShareableContact, getShareContactDraft), and how a shared contact is messaged
// (resolveSharedContact).

import Foundation
import GRDB
import Testing
@testable import SignalCore

@Suite struct ShareContactCandidatesTests {
    static let me = "11111111-1111-4111-8111-111111111111"
    static let friend = "22222222-2222-4222-8222-222222222222"
    static let stranger = "33333333-3333-4333-8333-333333333333"
    static let blocked = "44444444-4444-4444-8444-444444444444"
    static let gone = "55555555-5555-4555-8555-555555555555"
    static let recipient = "66666666-6666-4666-8666-666666666666"

    func database() throws -> (SignalDatabase, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("share-contact-\(UUID()).sqlite")
        return (try SignalDatabase(url: url, key: SignalCrypto.randomBytes(32)), url)
    }

    func insert(_ db: Database, id: String, serviceId: String? = nil, e164: String? = nil, json extra: [String: Any] = [:]) throws {
        var json: [String: Any] = ["id": id, "type": "private"]
        if let serviceId { json["serviceId"] = serviceId }
        if let e164 { json["e164"] = e164 }
        json.merge(extra) { _, b in b }
        try db.execute(sql: "INSERT INTO conversations (id, json, type, serviceId, e164) VALUES (?, ?, 'private', ?, ?)",
                       arguments: [id, try MessageStore.jsonString(json), serviceId, e164])
    }

    @Test func candidatesFollowUpstream() throws {
        let (database, url) = try database()
        defer { try? FileManager.default.removeItem(at: url) }
        let list = try database.pool.write { db -> [ShareContactCandidateInfo] in
            try insert(db, id: "me", serviceId: Self.me, e164: "+15555550100", json: ["profileSharing": true])
            try insert(db, id: "recipient", serviceId: Self.recipient, e164: "+15555550106", json: ["profileSharing": true])
            // A Signal connection with a name and an ACI but no number: offered.
            try insert(db, id: "friend", serviceId: Self.friend, json: [
                "profileSharing": true, "profileName": "Fran", "profileFamilyName": "Friend", "systemNickname": "Frannie",
                "nicknameGivenName": "F", "note": "from work",
                "profileAvatar": ["path": "aa/profile", "localKey": Data(count: 64).base64EncodedString(), "size": 10],
                "avatar": ["path": "bb/system", "localKey": Data(count: 64).base64EncodedString(), "size": 10],
            ])
            // Not a connection, no number: not offered. Not a connection with a number: offered.
            try insert(db, id: "stranger", serviceId: Self.stranger, json: ["profileName": "Sam"])
            try insert(db, id: "numberOnly", e164: "+15555550103")
            // Blocked, or removed: not offered.
            try insert(db, id: "blocked", serviceId: Self.blocked, e164: "+15555550104", json: ["profileSharing": true])
            try BlockedList.serviceIds.replaceAll(db, [Self.blocked])
            try insert(db, id: "removed", serviceId: "77777777-7777-4777-8777-777777777777", e164: "+15555550107",
                       json: ["profileSharing": true, "removalStage": "justNotification"])
            // Once found unregistered: shared by number, without the ACI.
            try insert(db, id: "gone", serviceId: Self.gone, e164: "+15555550105",
                       json: ["profileSharing": true, "systemGivenName": "Gina", "systemFamilyName": "Gone", "discoveredUnregisteredAt": 1])
            return try SharedContacts.candidates(db, excluding: "recipient", ourAci: Self.me)
        }
        #expect(Set(list.map(\.conversationId)) == ["friend", "numberOnly", "gone"])

        let friend = try #require(list.first { $0.conversationId == "friend" })
        // getName: the system nickname before the profile name; no number; the registered ACI.
        #expect(friend.draft.givenName == "Frannie" && friend.draft.familyName == nil)
        #expect(friend.draft.numbers.isEmpty && friend.draft.aci == Self.friend)
        #expect(friend.draft.signalNicknameGiven == "F" && friend.draft.note == "from work")
        // getAvatarOptions: the profile avatar, then the system contact's.
        #expect(friend.avatarOptions.map(\.file.path) == ["aa/profile", "bb/system"] && friend.avatarOptions.map(\.isProfile) == [true, false])
        #expect(friend.draft.canBeShared)

        let gone = try #require(list.first { $0.conversationId == "gone" })
        #expect(gone.draft.givenName == "Gina" && gone.draft.familyName == "Gone")
        #expect(gone.draft.aci == nil && gone.draft.numbers == [.init(value: "+15555550105", type: 4)])

        let numberOnly = try #require(list.first { $0.conversationId == "numberOnly" })
        #expect(numberOnly.draft.givenName == nil && numberOnly.title == "+15555550103" && numberOnly.avatarOptions.isEmpty)
    }

    @Test func resolutionFollowsUpstream() throws {
        let (database, url) = try database()
        defer { try? FileManager.default.removeItem(at: url) }
        let now: Int64 = 1_800_000_000_000
        try database.pool.write { db in
            try insert(db, id: "friend", serviceId: Self.friend, e164: "+15555550102")
            try insert(db, id: "recent", serviceId: Self.gone, e164: "+15555550105", json: ["discoveredUnregisteredAt": now - 3600 * 1000])
            try insert(db, id: "longAgo", serviceId: Self.stranger, e164: "+15555550103", json: ["discoveredUnregisteredAt": now - 7 * 3600 * 1000])
            try insert(db, id: "pniless", e164: "+15555550108")

            func resolve(aci: String? = nil, numbers: [String] = []) throws -> SharedContacts.Resolution {
                var c = SharedContactInfo(givenName: "X")
                c.aci = aci
                c.numbers = numbers.map { .init(value: $0, type: 4) }
                return try SharedContacts.resolve(db, c, now: now)
            }
            // By ACI: their chat; none yet, the ACI; unregistered in the last six hours, not on Signal.
            #expect(try resolve(aci: Self.friend) == .existing(conversationId: "friend"))
            #expect(try resolve(aci: Self.recipient) == .aci(Self.recipient))
            #expect(try resolve(aci: Self.gone, numbers: ["+15555550102"]) == .notOnSignal)
            #expect(try resolve(aci: Self.stranger) == .existing(conversationId: "longAgo"))
            // By number: a registered chat with one of them; a chat without a service id is not one.
            #expect(try resolve(numbers: ["+15555550199", "+15555550102"]) == .existing(conversationId: "friend"))
            #expect(try resolve(numbers: ["+15555550105"]) == .notOnSignal)
            #expect(try resolve(numbers: ["+15555550108"]) == .notOnSignal)
            #expect(try resolve(numbers: ["+15555550199"]) == .notOnSignal)
        }
    }

    /// The timeline's contact carries its resolution (the card's "Message" button).
    @Test func timelineContactsAreResolved() throws {
        let (database, url) = try database()
        defer { try? FileManager.default.removeItem(at: url) }
        let messages = try database.pool.write { db -> [TimelineMessage] in
            try insert(db, id: "chat", serviceId: Self.recipient)
            try insert(db, id: "friend", serviceId: Self.friend)
            for (i, aci) in [Self.friend, nil].enumerated() {
                var contact: [String: Any] = ["name": ["givenName": "Card \(i)"], "number": [["value": "+1555555019\(i)", "type": 4]]]
                if let aci { contact["aci"] = aci }
                let json: [String: Any] = ["id": "m\(i)", "conversationId": "chat", "type": "incoming", "sent_at": 1000 + i, "received_at": 1000 + i,
                                           "contact": [contact], "sourceServiceId": Self.recipient]
                try db.execute(sql: """
                    INSERT INTO messages (id, json, conversationId, type, sent_at, received_at, sourceServiceId) VALUES (?, ?, 'chat', 'incoming', ?, ?, ?)
                    """, arguments: ["m\(i)", try MessageStore.jsonString(json), 1000 + i, 1000 + i, Self.recipient])
            }
            return try ConversationQueries.messages(db, conversationId: "chat")
        }
        #expect(messages.first { $0.id == "m0" }?.contact?.resolution == .existing(conversationId: "friend"))
        #expect(messages.first { $0.id == "m1" }?.contact?.resolution == .notOnSignal)
    }
}
