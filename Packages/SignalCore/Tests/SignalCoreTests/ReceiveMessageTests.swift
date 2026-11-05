// Integration: the receive pipeline against messages sent by the mock server's
// primary devices (PrimaryDevice.sendText and friends).

import Foundation
import GRDB
import LibSignalClient
import Testing
@testable import SignalCore

@Suite(.serialized) struct ReceiveMessageTests {
    func withClient(_ body: (LinkedClient) async throws -> Void) async throws {
        let server = try await MockServerHarness.start()
        let client = try await LinkedClient.link(server)
        do { try await body(client) } catch {
            await client.close()
            throw error
        }
        await client.close()
    }

    @Test func oneToOneTextIsDecryptedAndStored() async throws {
        try await withClient { c in
            let alice = c.server.ready.alice.aci.lowercased()
            let t1 = TestClock.next(), t2 = TestClock.next()
            try await c.server.call("sendText", ["from": "alice", "text": "hello from alice", "timestamp": t1])
            let first = try await c.log.waitFor("first message") { if case .message(_, _, _, _, t1, _, _, _) = $0 { true } else { false } }
            guard case .message(let id, let conversationId, let sender, _, _, let body, let sealed, _) = first else { return }
            #expect(sender == alice && body == "hello from alice" && !sealed)

            // Second message reuses the session the first PreKey message created (alice keeps sending
            // PreKey messages until we reply, which needs the Phase 2b send path; whisper decrypt is
            // covered by ProtocolStoreTests.sessionLifecycleAndReply).
            try await c.server.call("sendText", ["from": "alice", "text": "second", "timestamp": t2])
            _ = try await c.log.waitFor("second message") { if case .message(_, _, _, _, t2, "second", _, _) = $0 { true } else { false } }

            try await c.database.pool.read { db throws in
                let row = try #require(try Row.fetchOne(db, sql: "SELECT * FROM messages WHERE id = ?", arguments: [id]))
                #expect(row["type"] as String == "incoming" && row["body"] as String == "hello from alice")
                #expect(row["sourceServiceId"] as String == alice && row["sent_at"] as Int64 == Int64(t1))
                #expect(row["conversationId"] as String == conversationId)
                let conv = try #require(try Row.fetchOne(db, sql: "SELECT * FROM conversations WHERE id = ?", arguments: [conversationId]))
                #expect(conv["serviceId"] as String == alice && conv["type"] as String == "private")
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM messages WHERE conversationId = ?", arguments: [conversationId]) == 2)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM unprocessed") == 0)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sessions") == 1)
                // Full-text search is populated by the upstream trigger.
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM messages_fts WHERE messages_fts MATCH 'alice'") == 1)
            }
        }
    }

    @Test func sealedSenderText() async throws {
        try await withClient { c in
            let t = TestClock.next()
            try await c.server.call("sendText", ["from": "alice", "text": "sealed hello", "timestamp": t, "sealed": true])
            let e = try await c.log.waitFor("sealed message") { if case .message(_, _, _, _, t, _, _, _) = $0 { true } else { false } }
            guard case .message(_, _, let sender, _, _, let body, let sealed, _) = e else { return }
            #expect(sealed && body == "sealed hello" && sender == c.server.ready.alice.aci.lowercased())
            #expect(try await c.database.pool.read { try Bool.fetchOne($0, sql: "SELECT json ->> '$.unidentifiedDeliveryReceived' FROM messages WHERE sent_at = ?", arguments: [Int64(t)]) } == true)
        }
    }

    @Test func senderKeyGroupMessage() async throws {
        try await withClient { c in
            let result = try await c.server.json("sendSenderKey", ["from": "alice"])
            let distributionId = try #require(result["distributionId"] as? String)
            _ = try await c.log.waitFor("sender key distribution") {
                if case .senderKeyDistribution(_, _, let id) = $0 { id.uuidString.lowercased() == distributionId.lowercased() } else { false }
            }
            let t = TestClock.next()
            try await c.server.call("sendText", ["from": "alice", "text": "via sender key", "timestamp": t, "sealed": true, "distributionId": distributionId])
            let e = try await c.log.waitFor("sender-key message") { if case .message(_, _, _, _, t, _, _, _) = $0 { true } else { false } }
            guard case .message(_, _, _, _, _, let body, let sealed, _) = e else { return }
            #expect(body == "via sender key" && sealed)
            #expect(try await c.database.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM senderKeys") } == 1)
        }
    }

    @Test func syncTranscriptAndReceipts() async throws {
        try await withClient { c in
            let alice = c.server.ready.alice.aci.lowercased()
            let t = TestClock.next()
            try await c.server.call("sendSyncSent", ["text": "sent from my phone", "timestamp": t, "destination": "alice"])
            let e = try await c.log.waitFor("sent transcript") { if case .sentTranscript(_, _, _, t, _) = $0 { true } else { false } }
            guard case .sentTranscript(let id, _, let destination, _, let body) = e else { return }
            #expect(destination == alice && body == "sent from my phone")

            try await c.server.call("sendReceipt", ["from": "alice", "type": "delivery", "timestamps": [t], "timestamp": TestClock.next()])
            _ = try await c.log.waitFor("delivery receipt") { if case .receipt(.delivery, _, [t], 1) = $0 { true } else { false } }
            try await c.server.call("sendReceipt", ["from": "alice", "type": "read", "timestamps": [t], "timestamp": TestClock.next()])
            _ = try await c.log.waitFor("read receipt") { if case .receipt(.read, _, [t], 1) = $0 { true } else { false } }

            try await c.database.pool.read { db throws in
                let row = try #require(try Row.fetchOne(db, sql: "SELECT type, json ->> '$.sendStateByConversationId' AS states FROM messages WHERE id = ?",
                                                        arguments: [id]))
                #expect(row["type"] as String == "outgoing")
                #expect((row["states"] as String).contains("\"Read\""))
            }
        }
    }

    @Test func typingAndEdit() async throws {
        try await withClient { c in
            let t0 = TestClock.next()
            try await c.server.call("sendTyping", ["from": "alice", "action": "started", "timestamp": t0])
            _ = try await c.log.waitFor("typing") { if case .typing(_, true, t0, nil) = $0 { true } else { false } }

            let t1 = TestClock.next()
            try await c.server.call("sendText", ["from": "alice", "text": "tpyo", "timestamp": t1])
            _ = try await c.log.waitFor("original") { if case .message(_, _, _, _, t1, _, _, _) = $0 { true } else { false } }
            let t2 = TestClock.next()
            try await c.server.call("sendEdit", ["from": "alice", "targetTimestamp": t1, "text": "typo", "timestamp": t2])
            let e = try await c.log.waitFor("edit") { if case .edit(_, _, t1, "typo") = $0 { true } else { false } }
            guard case .edit(let id, _, _, _) = e else { return }

            try await c.database.pool.read { db throws in
                #expect(try String.fetchOne(db, sql: "SELECT body FROM messages WHERE id = ?", arguments: [id]) == "typo")
                #expect(try Int.fetchOne(db, sql: "SELECT json_array_length(json, '$.editHistory') FROM messages WHERE id = ?", arguments: [id]) == 2)
                #expect(try Int64.fetchOne(db, sql: "SELECT sentAt FROM edited_messages WHERE messageId = ?", arguments: [id]) == Int64(t2))
            }
        }
    }

    @Test func decryptionErrorMessages() async throws {
        try await withClient { c in
            let t1 = TestClock.next()
            try await c.server.call("sendDecryptionError", ["from": "alice", "timestamp": t1])
            _ = try await c.log.waitFor("DecryptionErrorMessage in Content") {
                if case .decryptionErrorReported(_, _, t1, 1) = $0 { true } else { false }
            }
            let t2 = TestClock.next()
            try await c.server.call("sendDecryptionError", ["from": "alice", "timestamp": t2, "plaintext": true])
            _ = try await c.log.waitFor("PLAINTEXT_CONTENT DecryptionErrorMessage") {
                if case .decryptionErrorReported(_, _, t2, 1) = $0 { true } else { false }
            }
        }
    }
}
