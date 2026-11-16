// Same-name warnings, held to upstream's getContactSpoofingWarningSelector,
// getSafeConversationWithSameTitle, getCollisionsFromMemberships and
// hasUnacknowledgedCollisions.

import Foundation
import GRDB
import Testing
@testable import SignalCore

@Suite struct ContactSpoofingTests {
    /// A private conversation with a profile or system name; with an incoming message it is a
    /// message request (unless the name is a system contact's).
    private func person(_ db: Database, _ aci: String, profileName: String? = nil, system: String? = nil, incoming: Bool = false) throws -> String {
        let id = try MessageStore.privateConversation(db, serviceId: aci)
        try MessageStore.updateConversationJSON(db, conversationId: id) { j in
            if let profileName { j["profileName"] = profileName }
            if let system { j["systemGivenName"] = system }
        }
        if incoming {
            try MessageStore.insert(db, .init(conversationId: id, type: "incoming", body: "hello", sentAt: TestClock.next(), source: aci,
                                              sourceDevice: 1, serverGuid: nil, serverTimestamp: nil, unidentified: true))
        }
        return id
    }

    private func check(_ c: LinkedClient, _ id: String) async throws -> ContactSpoofingCheck? {
        try await c.database.pool.read { try ContactSpoofing.check($0, conversationId: id, ourAci: c.account.aci) }
    }

    @Test func aMessageRequestNamedLikeAContactIsFlagged() async throws {
        try await LinkedClient.with { c in
            let strangerAci = UUID().uuidString.lowercased()
            let (friend, stranger, other) = try await c.database.pool.write { db in
                (try person(db, UUID().uuidString.lowercased(), system: "Zelda Spoofcheck"),
                 try person(db, strangerAci, profileName: "Zelda Spoofcheck", incoming: true),
                 try person(db, UUID().uuidString.lowercased(), profileName: "Mallory Spoofcheck", incoming: true))
            }
            #expect(try await check(c, stranger) == .directConversationWithSameTitle(safeConversationId: friend))
            #expect(try await check(c, friend) == nil)   // accepted
            #expect(try await check(c, other) == nil)    // nobody else has the name
            let people = try await c.database.spoofingCandidates(conversationIds: [stranger, friend])
            #expect(people.map(\.title) == ["Zelda Spoofcheck", "Zelda Spoofcheck"])
            #expect(people.map(\.isSignalConnection) == [false, true])
            try await c.database.pool.write { try BlockedList.serviceIds.save($0, [(strangerAci, nil)]) }
            #expect(try await check(c, stranger) == nil)   // blocked
        }
    }

    @Test func groupMembersSharingANameAreFlaggedUntilAcknowledged() async throws {
        try await LinkedClient.with { c in
            let ourAci = c.account.aci
            let keys = try GroupKeys(masterKey: Data(repeating: 9, count: 32))
            let x = UUID().uuidString.lowercased(), y = UUID().uuidString.lowercased(), z = UUID().uuidString.lowercased()
            @Sendable func save(_ db: Database, _ members: [String]) throws -> String {
                let id = try GroupStore.conversation(db, keys: keys).conversationId
                var state = GroupV2State()
                state.membersV2 = ([ourAci] + members).map { GroupMember(aci: $0, role: 1, joinedAtVersion: 0) }
                try GroupStore.save(db, conversationId: id, state: state, ourAci: ourAci)
                return id
            }
            let (group, xId, yId) = try await c.database.pool.write { db in
                let xId = try person(db, x, profileName: "Quinn Twin"), yId = try person(db, y, profileName: "Quinn Twin")
                _ = try person(db, z, profileName: "Someone Else")
                return (try save(db, [x, y, z]), xId, yId)
            }
            let first = try #require(try await check(c, group))
            #expect(first == .multipleGroupMembersWithSameTitle(collisions: ["Quinn Twin": [xId, yId]], acknowledged: [:]))
            #expect(first.isRenderable)
            try await c.database.acknowledgeNameCollisions(conversationId: group, collisions: ["Quinn Twin": [xId, yId]])
            #expect(try await check(c, group)?.isRenderable == false)
            // Someone else joins under the name: the warning is back.
            let w = UUID().uuidString.lowercased()
            _ = try await c.database.pool.write { db in
                _ = try person(db, w, profileName: "Quinn Twin")
                return try save(db, [x, y, z, w])
            }
            #expect(try await check(c, group)?.isRenderable == true)
            // All of them system contacts: no collision.
            try await c.database.pool.write { db in for a in [x, y, w] { _ = try person(db, a, system: "Quinn Twin") } }
            #expect(try await check(c, group) == nil)
        }
    }
}
