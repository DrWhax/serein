// When our group sender key is replaced (upstream util/sendToGroup: the removed-member check,
// resetSenderKey and the expiry). A member who should no longer read the group must never be
// able to use a key they were given earlier.

import Foundation
import GRDB
import LibSignalClient
import Testing
@testable import SignalCore

@Suite struct SenderKeyTests {
    private struct Group {
        var masterKey: Data
        var conversationId: String
    }

    /// A three-member group with one message already sent through the sender-key path.
    private func group(_ c: LinkedClient) async throws -> Group {
        _ = try await c.server.json("addAccount", ["name": "bob"])
        let g = try await c.server.json("createGroup", ["title": "Three", "members": ["alice", "phone", "bob"]])
        let groupId = try #require(g["id"] as? String), masterKey = try #require(Data(base64Encoded: g["masterKey"] as! String))
        _ = try await c.server.json("sendGroupText", ["groupId": groupId, "text": "welcome", "timestamp": TestClock.next()])
        _ = try await c.log.waitFor("group update") { if case .other("groupUpdated", _) = $0 { return true } else { return false } }
        try await send(c, masterKey, "first")
        let id = try #require(try await c.database.pool.read { db in try String.fetchOne(db, sql: "SELECT id FROM conversations WHERE type = 'group'") })
        return Group(masterKey: masterKey, conversationId: id)
    }

    /// Sends to the group and checks that both members could read it (so they hold our current key).
    private func send(_ c: LinkedClient, _ masterKey: Data, _ text: String) async throws {
        _ = try await c.messenger.sendGroupMessage(text, masterKey: masterKey)
        for name in ["alice", "bob"] {
            let m = try await c.server.json("waitForMessage", ["account": name])
            #expect(m["body"] as? String == text && m["innerType"] as? String == "SenderKey", "\(name)")
        }
        try await c.jobs.waitUntilIdle()
    }

    private func info(_ c: LinkedClient, _ g: Group) async throws -> SenderKeyInfo {
        try await c.database.pool.read { db in
            let json = try MessageStore.jsonObject(try #require(try String.fetchOne(db, sql: "SELECT json FROM conversations WHERE id = ?", arguments: [g.conversationId])))
            return try JSONDecoder().decode(SenderKeyInfo.self, from: JSONSerialization.data(withJSONObject: try #require(json["senderKeyInfo"])))
        }
    }

    /// Our own sender key for the group's distribution: its bytes change when it is replaced.
    private func ourKey(_ c: LinkedClient, _ g: Group) async throws -> Data? {
        let distribution = try await info(c, g).distributionId
        return try await c.database.pool.read { db in
            try Data.fetchOne(db, sql: "SELECT data FROM senderKeys WHERE distributionId = ? AND senderId = ?",
                              arguments: [distribution, "\(c.account.aci).\(c.account.deviceId)"])
        }
    }

    private func edit(_ c: LinkedClient, _ g: Group, _ change: @escaping @Sendable (inout [String: Any]) -> Void) async throws {
        try await c.database.pool.write { db in
            try MessageStore.updateConversationJSON(db, conversationId: g.conversationId) { json in
                var info = json["senderKeyInfo"] as? [String: Any] ?? [:]
                change(&info)
                json["senderKeyInfo"] = info
            }
        }
    }

    @Test func keyIsKeptWhileNothingChanges() async throws {
        try await LinkedClient.with { c in
            let g = try await group(c)
            let before = try #require(try await ourKey(c, g))
            let distribution = try await info(c, g).distributionId
            try await send(c, g.masterKey, "second")
            // Same key: only its chain has advanced one step.
            #expect(try await info(c, g).distributionId == distribution)
            let after = try #require(try await ourKey(c, g))
            #expect(after != before)
            #expect(try Self.signingKey(after) == Self.signingKey(before))
            #expect(try await info(c, g).memberDevices.count == 2)
        }
    }

    /// Someone who held our key is no longer among the recipients: they must not be able to
    /// read what follows.
    @Test func keyIsReplacedWhenAHolderLeft() async throws {
        try await LinkedClient.with { c in
            let g = try await group(c)
            let before = try #require(try await ourKey(c, g))
            let distribution = try await info(c, g).distributionId
            let gone = UUID().uuidString.lowercased()
            try await edit(c, g) { info in
                var devices = info["memberDevices"] as? [[String: Any]] ?? []
                devices.append(["id": 1, "serviceId": gone, "registrationId": 4242])
                info["memberDevices"] = devices
            }
            try await send(c, g.masterKey, "after they left")

            let after = try await info(c, g)
            #expect(after.distributionId == distribution)   // upstream keeps the id and replaces the key
            #expect(!after.memberDevices.contains { $0.serviceId == gone } && after.memberDevices.count == 2)
            let replaced = try #require(try await ourKey(c, g))
            #expect(try Self.signingKey(replaced) != Self.signingKey(before))
        }
    }

    @Test func keyIsReplacedAfterAMembersIdentityChangeAndWhenItExpires() async throws {
        try await LinkedClient.with { c in
            let g = try await group(c)
            var current = try #require(try await ourKey(c, g))

            // A member's safety number changed (what the identity store does for shared groups).
            try await c.database.pool.write { db in try MessageStore.insertKeyChange(db, serviceId: c.aliceAci) }
            #expect(try await info(c, g).needsReset == true)
            try await send(c, g.masterKey, "after the key change")
            var replaced = try #require(try await ourKey(c, g))
            #expect(try Self.signingKey(replaced) != Self.signingKey(current))
            #expect(try await info(c, g).needsReset != true)
            current = replaced

            // Upstream's maximum sender key age.
            try await edit(c, g) { $0["createdAtDate"] = MessageStore.now() - GroupSender.senderKeyExpiry - 1 }
            try await send(c, g.masterKey, "after expiry")
            replaced = try #require(try await ourKey(c, g))
            #expect(try Self.signingKey(replaced) != Self.signingKey(current))
        }
    }

    /// What tells two sender keys apart: a distribution message built from the record carries
    /// its chain id and signing key. Comparing the serialized records would also differ after
    /// an ordinary ratchet step.
    static func signingKey(_ record: Data) throws -> Data {
        // SenderKeyRecord → SenderKeyStateStructure(s); the first state's signing public key is
        // stable for the life of the key. It is 33 bytes starting with 0x05 after a 0x0A 0x21 tag.
        let bytes = [UInt8](record)
        for i in 0..<max(0, bytes.count - 35) where bytes[i] == 0x0A && bytes[i + 1] == 0x21 && bytes[i + 2] == 0x05 {
            return Data(bytes[(i + 2)..<(i + 35)])
        }
        throw HarnessError(description: "no signing key in sender key record")
    }
}
