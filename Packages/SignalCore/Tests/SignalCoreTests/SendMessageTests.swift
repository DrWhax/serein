// Integration: the 1:1 send pipeline against the mock server. Messages are received
// by the mock contacts' PrimaryDevice (waitForMessage), the sent transcript by our
// own phone (waitForSyncMessage).

import Foundation
import GRDB
import LibSignalClient
import Testing
@testable import SignalCore

struct ReceivedMessage: Decodable {
    var body: String
    var source: String?
    var sourceDevice: Int?
    var envelopeType: String
    var timestamp: UInt64
    var profileKey: String?
}

struct SyncSummary: Decodable {
    struct Sent: Decodable { var destination: String?; var timestamp: UInt64; var body: String?; var unidentified: [Bool] }
    struct ReadEntry: Decodable { var senderAci: String?; var timestamp: UInt64 }
    var kind: String
    var source: String?
    var sent: Sent?
    var read: [ReadEntry]?
    var viewed: [ReadEntry]?
    var requestType: Int?
}

struct AccountInfo: Decodable {
    var aci: String
    var number: String?
    var profileName: String
    var profileKey: String
    var identityKey: String
    var devices: [UInt32]
}

extension LinkedClient {
    func waitForMessage(to account: String) async throws -> ReceivedMessage {
        try await server.decode(ReceivedMessage.self, "waitForMessage", ["account": account])
    }
    func waitForSync(_ kind: String) async throws -> SyncSummary {
        try await server.decode(SyncSummary.self, "waitForSyncMessage", ["account": "phone", "kind": kind])
    }
    func accountInfo(_ name: String) async throws -> AccountInfo {
        try await server.decode(AccountInfo.self, "accountInfo", ["name": name])
    }
    /// alice → us, waits until it is stored (gives us a session and, with `withProfileKey`, her profile key).
    @discardableResult
    func receiveFromAlice(_ text: String, withProfileKey: Bool = false) async throws -> (messageId: String, timestamp: UInt64) {
        let t = TestClock.next()
        try await server.call("sendText", ["from": "alice", "text": text, "timestamp": t, "withProfileKey": withProfileKey])
        let e = try await log.waitFor("message \(t)") { if case .message(_, _, _, _, t, _, _, _) = $0 { true } else { false } }
        guard case .message(let id, _, _, _, _, _, _, _) = e else { throw HarnessError(description: "unexpected \(e)") }
        return (id, t)
    }
    func sendStatus(_ sentAt: UInt64, conversationWith serviceId: String) async throws -> String? {
        let m = try await messageJSON(sentAt: sentAt)
        let conversationId = try await database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM conversations WHERE serviceId = ?", arguments: [serviceId])
        }
        let states = m["sendStateByConversationId"] as? [String: [String: Any]]
        return states?[conversationId ?? ""]?["status"] as? String
    }
}

@Suite(.serialized) struct SendMessageTests {
    @Test func textToNewContactFetchesPreKeysAndSyncsTranscript() async throws {
        try await LinkedClient.with { c in
            let (messageId, t) = try await c.messenger.sendText("hello alice", to: c.aliceAci)
            let got = try await c.waitForMessage(to: "alice")
            #expect(got.body == "hello alice" && got.timestamp == t)
            #expect(got.source == c.account.aci && got.sourceDevice == Int(c.account.deviceId))
            // No profile key for alice yet → no access key → unsealed; the first message to a new session is a PreKey message.
            #expect(got.envelopeType == "PreKey")
            #expect(got.profileKey == c.account.profileKey?.base64EncodedString())

            let transcript = try await c.waitForSync("sent")
            #expect(transcript.sent?.destination == c.aliceAci && transcript.sent?.body == "hello alice" && transcript.sent?.timestamp == t)
            #expect(transcript.sent?.unidentified == [false])
            #expect(transcript.source == c.account.aci)

            try await c.jobs.waitUntilIdle()
            #expect(try await c.sendStatus(t, conversationWith: c.aliceAci) == "Sent")
            try await c.database.pool.read { db throws in
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM jobs") == 0)
                // Send log: the DataMessage to alice's device 1 and the transcript to the phone, both linked to the message.
                let recipients = try Row.fetchAll(db, sql: """
                    SELECT r.recipientServiceId AS s, r.deviceId AS d FROM sendLogRecipients r JOIN sendLogPayloads p ON p.id = r.payloadId
                    WHERE p.timestamp = ? ORDER BY s
                    """, arguments: [Int64(t)]).map { "\($0["s"] as String).\($0["d"] as Int)" }
                #expect(Set(recipients) == ["\(c.aliceAci).1", "\(c.phoneAci).1"])
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sendLogMessageIds WHERE messageId = ?", arguments: [messageId]) == 2)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sessions WHERE serviceId = ?", arguments: [c.aliceAci]) == 1)
            }
            // The certificate was not needed for an unsealed send.
            #expect(try await c.database.pool.read { try Items.get($0, "senderCertificateNoE164", as: String.self) } == nil)
        }
    }

    @Test func sealedSenderOnceProfileKeyIsKnown() async throws {
        try await LinkedClient.with { c in
            try await c.receiveFromAlice("here is my profile key", withProfileKey: true)
            let alice = try await c.accountInfo("alice")
            #expect(try await c.conversationJSON(serviceId: c.aliceAci)["profileKey"] as? String == alice.profileKey)

            let (_, t) = try await c.messenger.sendText("sealed reply", to: c.aliceAci)
            let got = try await c.waitForMessage(to: "alice")
            #expect(got.body == "sealed reply")
            #expect(got.envelopeType == "SealedSender")
            #expect(got.timestamp == t)
            let transcript = try await c.waitForSync("sent")
            #expect(transcript.sent?.unidentified == [true])
            try await c.jobs.waitUntilIdle()
            #expect(try await c.messageJSON(sentAt: t)["unidentifiedDeliveries"] as? [String] == [c.aliceAci])
            // A sender certificate for our own ACI/device was fetched, validated and cached.
            let cert = try await c.messenger.sender.certificates.current()
            #expect(cert.senderUuid.lowercased() == c.account.aci && cert.deviceId == c.account.deviceId)
            #expect(try await c.database.pool.read { db in try Items.get(db, "senderCertificateNoE164", as: SenderCertificates.Cached.self) } != nil)
        }
    }

    @Test func missingDeviceIsAddedAfter409() async throws {
        try await LinkedClient.with { c in
            try await c.receiveFromAlice("session from device 1")
            let added = try await c.server.json("addSecondaryDevice", ["account": "alice"])
            let newDevice = try #require(added["deviceId"] as? Int)

            let (_, t) = try await c.messenger.sendText("to all of alice's devices", to: c.aliceAci)
            let got = try await c.waitForMessage(to: "alice")
            #expect(got.body == "to all of alice's devices" && got.timestamp == t)
            try await c.jobs.waitUntilIdle()
            let devices = try await c.database.pool.read { db in
                try Int.fetchAll(db, sql: "SELECT deviceId FROM sessions WHERE serviceId = ? ORDER BY deviceId", arguments: [c.aliceAci])
            }
            #expect(devices == [1, newDevice])
            #expect(try await c.sendStatus(t, conversationWith: c.aliceAci) == "Sent")
        }
    }

    @Test func staleDevicesAreRefreshedAfter410() async throws {
        try await LinkedClient.with { c in
            try await c.messenger.sendText("before reinstall", to: c.aliceAci)
            _ = try await c.waitForMessage(to: "alice")
            try await c.jobs.waitUntilIdle()

            // alice reinstalls: same ACI, new identity key and registration id.
            let fresh = try await c.server.json("reregister", ["account": "alice"])
            let (_, t) = try await c.messenger.sendText("after reinstall", to: c.aliceAci)
            let got = try await c.waitForMessage(to: "alice")
            #expect(got.body == "after reinstall" && got.timestamp == t && got.envelopeType == "PreKey")
            try await c.jobs.waitUntilIdle()

            let freshKey = fresh["identityKey"] as? String
            try await c.database.pool.read { db throws in
                let identity = try #require(try String.fetchOne(db, sql: "SELECT json ->> '$.publicKey' FROM identityKeys WHERE id = ?", arguments: [c.aliceAci]))
                #expect(identity == freshKey)
                // Safety-number change notification in the conversation.
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM messages WHERE type = 'keychange' AND json ->> '$.key_changed' = ?",
                                         arguments: [c.aliceAci]) == 1)
            }
            #expect(try await c.sendStatus(t, conversationWith: c.aliceAci) == "Sent")
        }
    }

    @Test func verifiedContactWithNewIdentityBlocksSending() async throws {
        try await LinkedClient.with { c in
            try await c.messenger.sendText("before", to: c.aliceAci)
            _ = try await c.waitForMessage(to: "alice")
            try await c.jobs.waitUntilIdle()
            try await c.database.pool.write { db in
                try db.execute(sql: "UPDATE identityKeys SET json = json_set(json, '$.verified', 1) WHERE id = ?", arguments: [c.aliceAci])
            }
            try await c.server.call("reregister", ["account": "alice"])
            let (_, t) = try await c.messenger.sendText("must not be sent", to: c.aliceAci)
            try await c.eventually("send failure") { db in
                try String.fetchOne(db, sql: "SELECT json ->> '$.errors[0].message' FROM messages WHERE sent_at = ?", arguments: [Int64(t)])?
                    .contains("untrustedIdentity") == true
            }
            #expect(try await c.sendStatus(t, conversationWith: c.aliceAci) == "Failed")
        }
    }

    @Test func retryRequestResendsLoggedPayload() async throws {
        try await LinkedClient.with { c in
            let (_, t) = try await c.messenger.sendText("please resend me", to: c.aliceAci)
            _ = try await c.waitForMessage(to: "alice")
            try await c.jobs.waitUntilIdle()

            // alice's device could not decrypt it: DecryptionErrorMessage about our device's message at t.
            try await c.server.call("sendDecryptionError", ["from": "alice", "timestamp": t, "originalDevice": Int(c.account.deviceId)])
            let again = try await c.waitForMessage(to: "alice")
            #expect(again.body == "please resend me" && again.timestamp == t)
        }
    }
}
