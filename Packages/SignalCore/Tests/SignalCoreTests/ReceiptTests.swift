// Integration: delivery / read / viewed receipts in both directions, read and viewed
// syncs to our own phone, and typing indicators.

import Foundation
import GRDB
import LibSignalClient
import Testing
@testable import SignalCore

struct ReceivedReceipt: Decodable {
    var type: String
    var timestamps: [UInt64]
    var source: String?
    var envelopeType: String
}

struct ReceivedTyping: Decodable {
    var source: String?
    var action: String
    var timestamp: UInt64
    var envelopeType: String
}

extension LinkedClient {
    func waitForReceipt(to account: String) async throws -> ReceivedReceipt {
        try await server.decode(ReceivedReceipt.self, "waitForReceipt", ["account": account])
    }
    func setReadReceipts(_ on: Bool) async throws {
        try await database.pool.write { db in try Items.set(db, "read-receipt-setting", on) }
    }
}

@Suite(.serialized) struct ReceiptTests {
    @Test func incomingMessageGetsDeliveryReceipt() async throws {
        try await LinkedClient.with { c in
            let (_, t) = try await c.receiveFromAlice("did you get this?")
            let receipt = try await c.waitForReceipt(to: "alice")
            #expect(receipt.type == "delivery" && receipt.timestamps == [t] && receipt.source == c.account.aci)
        }
    }

    @Test func markReadSendsReadReceiptAndReadSync() async throws {
        try await LinkedClient.with { c in
            try await c.setReadReceipts(true)
            let (messageId, t) = try await c.receiveFromAlice("read me", withProfileKey: true)
            #expect(try await c.waitForReceipt(to: "alice").type == "delivery")

            let conversationId = try #require(try await c.database.pool.read { db in
                try String.fetchOne(db, sql: "SELECT conversationId FROM messages WHERE id = ?", arguments: [messageId])
            })
            #expect(try await c.conversationJSON(serviceId: c.aliceAci)["unreadCount"] as? Int == 1)
            let targets = try await c.messenger.markRead(conversationId: conversationId)
            #expect(targets.map(\.timestamp) == [t])

            let read = try await c.waitForReceipt(to: "alice")
            #expect(read.type == "read" && read.timestamps == [t])
            // Sealed: alice's profile key is known.
            #expect(read.envelopeType == "SealedSender")
            let sync = try await c.waitForSync("read")
            #expect(sync.read?.first?.senderAci == c.aliceAci && sync.read?.first?.timestamp == t)

            try await c.database.pool.read { db throws in
                let row = try #require(try Row.fetchOne(db, sql: "SELECT readStatus, seenStatus FROM messages WHERE id = ?", arguments: [messageId]))
                #expect(row["readStatus"] as Int == ReadStatus.read.rawValue && row["seenStatus"] as Int == SeenStatus.seen.rawValue)
            }
            #expect(try await c.conversationJSON(serviceId: c.aliceAci)["unreadCount"] as? Int == 0)
        }
    }

    @Test func readSyncOnlyWhenReadReceiptsAreOff() async throws {
        try await LinkedClient.with { c in
            try await c.setReadReceipts(false)
            let (messageId, t) = try await c.receiveFromAlice("quietly read")
            #expect(try await c.waitForReceipt(to: "alice").type == "delivery")
            let conversationId = try #require(try await c.database.pool.read { db in
                try String.fetchOne(db, sql: "SELECT conversationId FROM messages WHERE id = ?", arguments: [messageId])
            })
            try await c.messenger.markRead(conversationId: conversationId)
            let sync = try await c.waitForSync("read")
            #expect(sync.read?.first?.timestamp == t)
            try await c.jobs.waitUntilIdle()
            // Only the read sync was queued, so alice has no further receipt.
            let pending = try await c.server.json("receiptQueueSize", ["account": "alice"])
            #expect(pending["size"] as? Int == 0)
        }
    }

    @Test func markViewedSendsViewedReceipt() async throws {
        try await LinkedClient.with { c in
            try await c.setReadReceipts(true)
            let (messageId, t) = try await c.receiveFromAlice("voice note stand-in")
            #expect(try await c.waitForReceipt(to: "alice").type == "delivery")
            let target = try await c.messenger.markViewed(messageId: messageId)
            #expect(target?.timestamp == t)
            let viewed = try await c.waitForReceipt(to: "alice")
            #expect(viewed.type == "viewed" && viewed.timestamps == [t])
            let sync = try await c.waitForSync("viewed")
            #expect(sync.viewed?.first?.timestamp == t)
        }
    }

    @Test func receiptsForOurMessageAdvanceSendState() async throws {
        try await LinkedClient.with { c in
            let (_, t) = try await c.messenger.sendText("tell me when you read it", to: c.aliceAci)
            _ = try await c.waitForMessage(to: "alice")
            try await c.jobs.waitUntilIdle()
            #expect(try await c.sendStatus(t, conversationWith: c.aliceAci) == "Sent")
            for (kind, status) in [("delivery", "Delivered"), ("read", "Read"), ("viewed", "Viewed")] {
                try await c.server.call("sendReceipt", ["from": "alice", "type": kind, "timestamps": [t], "timestamp": TestClock.next()])
                _ = try await c.log.waitFor("\(kind) receipt") {
                    if case .receipt(let k, _, let ts, let n) = $0 { k.rawValue == kind && ts == [t] && n == 1 } else { false }
                }
                #expect(try await c.sendStatus(t, conversationWith: c.aliceAci) == status)
            }
        }
    }

    @Test func typingIndicatorsBothWays() async throws {
        try await LinkedClient.with { c in
            try await c.receiveFromAlice("session first", withProfileKey: true)
            let t1 = TestClock.next()
            try await c.messenger.sendTyping(to: c.aliceAci, started: true, timestamp: t1)
            let started = try await c.server.decode(ReceivedTyping.self, "waitForTyping", ["account": "alice"])
            #expect(started.action == "started" && started.timestamp == t1 && started.source == c.account.aci)
            try await c.messenger.sendTyping(to: c.aliceAci, started: false)
            #expect(try await c.server.decode(ReceivedTyping.self, "waitForTyping", ["account": "alice"]).action == "stopped")
            // Typing messages are never written to the send log.
            #expect(try await c.database.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sendLogPayloads WHERE timestamp = ?", arguments: [Int64(t1)]) } == 0)

            let t2 = TestClock.next()
            try await c.server.call("sendTyping", ["from": "alice", "action": "started", "timestamp": t2])
            _ = try await c.log.waitFor("typing from alice") { if case .typing(_, true, t2, _) = $0 { true } else { false } }
        }
    }
}
