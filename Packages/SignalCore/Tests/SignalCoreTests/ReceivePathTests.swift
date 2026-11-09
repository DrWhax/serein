// What the receive path lets in, held to Signal-Desktop's MessageReceiver (unsealEnvelope,
// validateUnsealedEnvelope, innerDecrypt, decryptEnvelope) and to its decryption-error
// handling (util/handleRetry, jobs/helpers/sendResendRequest).

import Foundation
import GRDB
import LibSignalClient
import SignalProtos
import Testing
@testable import SignalCore

@Suite struct ReceivePathTests {
    /// An envelope as the server would deliver it.
    private func envelope(_ c: LinkedClient, type: Signalservice_Envelope.TypeEnum, from source: String? = nil, device: UInt32 = 1,
                          to destination: String? = nil, content: Data, timestamp: UInt64 = TestClock.next(), serverTimestamp: UInt64? = nil,
                          story: Bool = false) -> Signalservice_Envelope {
        var e = Signalservice_Envelope()
        e.type = type
        if type != .unidentifiedSender {
            e.sourceServiceID = source ?? c.aliceAci
            e.sourceDeviceID = device
        }
        e.destinationServiceID = destination ?? c.account.aci
        e.clientTimestamp = timestamp
        e.serverTimestamp = serverTimestamp ?? timestamp
        e.serverGuid = UUID().uuidString.lowercased()
        e.content = content
        e.story = story
        return e
    }

    /// Runs one envelope through the receiver and returns why it failed, if it did.
    private func deliver(_ c: LinkedClient, _ e: Signalservice_Envelope) async throws -> String? {
        let bytes = try e.serializedData()
        c.receiver.queue.sync { c.receiver.handleIncoming(bytes, serverDeliveryTimestamp: e.serverTimestamp, sendAck: {}) }
        let failed = try? await c.log.waitFor(timeout: .milliseconds(300), "failure") {
            if case .failed(let guid, _) = $0 { guid == e.serverGuid } else { false }
        }
        if case .failed(_, let reason)? = failed { return reason }
        return nil
    }

    /// PlaintextContent's wire form: 0xC0, the Content, the 0x80 padding boundary.
    private func plaintextContent(_ content: Signalservice_Content) throws -> Data {
        Data([0xC0]) + (try content.serializedData()) + Data([0x80])
    }

    private func textContent(_ body: String, timestamp: UInt64) -> Signalservice_Content {
        var data = Signalservice_DataMessage()
        data.body = body
        data.timestamp = timestamp
        var content = Signalservice_Content()
        content.dataMessage = data
        return content
    }

    private func count(_ c: LinkedClient, _ sql: String, _ arguments: StatementArguments = []) async throws -> Int {
        try await c.database.pool.read { db in try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0 }
    }

    // MARK: unencrypted content

    /// An envelope marked PLAINTEXT_CONTENT carries no proof of who wrote it. Upstream takes
    /// only a retry request from it; a chat message in a contact's name must not get in.
    @Test func unencryptedEnvelopeCannotCarryAMessage() async throws {
        try await LinkedClient.with { c in
            try await c.receiveFromAlice("a real one")
            let t = TestClock.next()
            let forged = envelope(c, type: .plaintextContent, content: try plaintextContent(textContent("forged by the server", timestamp: t)), timestamp: t)
            let reason = try #require(try await deliver(c, forged))
            #expect(reason.contains("unencrypted"))
            #expect(try await count(c, "SELECT count(*) FROM messages WHERE body = 'forged by the server'") == 0)

            // Nor a sync message "from our phone" (which could rewrite verification, blocks, keys…).
            var sent = Signalservice_SyncMessage.Sent()
            sent.timestamp = t + 1
            sent.destinationServiceID = c.aliceAci
            sent.message = textContent("words put in our mouth", timestamp: t + 1).dataMessage
            var sync = Signalservice_SyncMessage()
            sync.sent = sent
            var content = Signalservice_Content()
            content.syncMessage = sync
            let fromPhone = envelope(c, type: .plaintextContent, from: c.account.aci, device: 1, content: try plaintextContent(content), timestamp: t + 1)
            #expect(try #require(try await deliver(c, fromPhone)).contains("unencrypted"))
            #expect(try await count(c, "SELECT count(*) FROM messages WHERE body = 'words put in our mouth'") == 0)
        }
    }

    @Test func unencryptedRetryRequestIsAccepted() async throws {
        try await LinkedClient.with { c in
            let (_, t) = try await c.messenger.sendText("resend me", to: c.aliceAci)
            _ = try await c.waitForMessage(to: "alice")
            try await c.jobs.waitUntilIdle()
            let request = try DecryptionErrorMessage(originalMessageBytes: Data([0]), type: .senderKey, timestamp: t, originalSenderDeviceId: c.account.deviceId)
            let e = envelope(c, type: .plaintextContent, content: PlaintextContent(request).serialize())
            #expect(try await deliver(c, e) == nil)
            _ = try await c.log.waitFor("retry request") { if case .decryptionErrorReported(_, _, t, _) = $0 { true } else { false } }
            let again = try await c.waitForMessage(to: "alice")
            #expect(again.body == "resend me" && again.timestamp == t)
        }
    }

    // MARK: envelope rules

    @Test func envelopeAddressingRules() async throws {
        try await LinkedClient.with { c in
            let pni = try #require(c.account.pniServiceId)
            // Our PNI takes nothing but the pre-key message that opens a session.
            for type in [Signalservice_Envelope.TypeEnum.doubleRatchet, .plaintextContent, .unidentifiedSender] {
                let reason = try #require(try await deliver(c, envelope(c, type: type, to: pni, content: Data([1, 2, 3]))))
                #expect(reason.contains("on PNI"), "\(type): \(reason)")
            }
            // An unsealed envelope never comes *from* a PNI.
            let fromPni = envelope(c, type: .prekeyMessage, from: "PNI:" + UUID().uuidString.lowercased(), content: Data([1, 2, 3]))
            #expect(try #require(try await deliver(c, fromPni)).contains("source is a PNI"))
            // Sealed sender needs the server's timestamp: the certificate expiry is checked against it.
            let undated = envelope(c, type: .unidentifiedSender, content: Data([1, 2, 3]), serverTimestamp: 0)
            #expect(try #require(try await deliver(c, undated)).contains("serverTimestamp"))
            // Addressed to somebody else entirely.
            let stray = envelope(c, type: .doubleRatchet, to: UUID().uuidString.lowercased(), content: Data([1, 2, 3]))
            #expect(try #require(try await deliver(c, stray)).contains("destination"))
            // None of these is a decryption failure worth a retry request.
            #expect(try await count(c, "SELECT count(*) FROM jobs WHERE data LIKE '%ResendRequest%'") == 0)
        }
    }

    /// `story=true` gets an envelope past the sealed-sender access key, so upstream only takes
    /// stories, group story replies and deletes from it.
    @Test func storyFlagOnlyCarriesStories() async throws {
        try await LinkedClient.with { c in
            func dispatch(_ content: Signalservice_Content, story: Bool, timestamp: UInt64) async throws -> [ReceiveEvent] {
                let d = MessageReceiver.Decrypted(sender: c.aliceAci, senderDevice: 1, content: content, sealed: true, groupId: nil)
                let e = envelope(c, type: .unidentifiedSender, content: Data(), timestamp: timestamp, story: story)
                return try await c.database.pool.write { db in try c.receiver.dispatch(d, envelope: e, db) }
            }
            let t = TestClock.next()
            await #expect(throws: ReceiveError.self) { try await dispatch(textContent("not a story", timestamp: t), story: true, timestamp: t) }
            #expect(try await count(c, "SELECT count(*) FROM messages WHERE body = 'not a story'") == 0)
            var receipt = Signalservice_ReceiptMessage()
            receipt.type = .read
            receipt.timestamp = [t]
            var receiptContent = Signalservice_Content()
            receiptContent.receiptMessage = receipt
            await #expect(throws: ReceiveError.self) { try await dispatch(receiptContent, story: true, timestamp: t) }

            // The same message without the flag is an ordinary message.
            _ = try await dispatch(textContent("not a story", timestamp: t), story: false, timestamp: t)
            #expect(try await count(c, "SELECT count(*) FROM messages WHERE body = 'not a story'") == 1)
            // A delete-for-everyone may ride on the flag.
            var delete = Signalservice_DataMessage()
            delete.timestamp = t + 1
            delete.delete.targetSentTimestamp = t
            var deleteContent = Signalservice_Content()
            deleteContent.dataMessage = delete
            _ = try await dispatch(deleteContent, story: true, timestamp: t + 1)
        }
    }

    @Test func nothingFromABlockedSenderIsProcessed() async throws {
        try await LinkedClient.with { c in
            let (_, sentAt) = try await c.messenger.sendText("to alice", to: c.aliceAci)
            _ = try await c.waitForMessage(to: "alice")
            try await c.jobs.waitUntilIdle()
            try await c.database.pool.write { db in try BlockedList.serviceIds.save(db, [(id: c.aliceAci, blockedAt: MessageStore.now())]) }

            func dispatch(_ content: Signalservice_Content) async throws -> [ReceiveEvent] {
                let d = MessageReceiver.Decrypted(sender: c.aliceAci, senderDevice: 1, content: content, sealed: true, groupId: nil)
                let e = envelope(c, type: .unidentifiedSender, content: Data())
                return try await c.database.pool.write { db in try c.receiver.dispatch(d, envelope: e, db) }
            }
            var receipt = Signalservice_ReceiptMessage()
            receipt.type = .read
            receipt.timestamp = [sentAt]
            var content = Signalservice_Content()
            content.receiptMessage = receipt
            #expect(try await dispatch(content).isEmpty)
            #expect(try await c.sendStatus(sentAt, conversationWith: c.aliceAci) == "Sent")   // not "Read"
            var call = Signalservice_Content()
            call.callMessage = Signalservice_CallMessage()
            #expect(try await dispatch(call).isEmpty)
            var typing = Signalservice_Content()
            typing.typingMessage.action = .started
            #expect(try await dispatch(typing).isEmpty)
        }
    }

    // MARK: decryption errors

    /// A message we cannot decrypt is not silently lost: the sender is asked for it again
    /// (unencrypted, as the session may be the problem) and the chat shows a delivery issue.
    @Test func undecryptableMessageAsksTheSenderToResend() async throws {
        try await LinkedClient.with { c in
            try await c.receiveFromAlice("first")
            // Our side of the session is gone (a restored backup, a lost write…).
            try await c.database.pool.write { db in try db.execute(sql: "DELETE FROM sessions WHERE serviceId = ?", arguments: [c.aliceAci]) }
            let t = TestClock.next()
            try await c.server.call("sendText", ["from": "alice", "text": "you cannot read this", "timestamp": t])

            let request = try await c.server.json("waitForDecryptionError", ["account": "alice"])
            #expect((request["timestamp"] as? Int).map(UInt64.init) == t)
            #expect(request["senderDevice"] as? Int == 1)   // alice's device, whose message failed
            #expect(request["source"] as? String == c.account.aci)
            try await c.jobs.waitUntilIdle()
            #expect(try await count(c, "SELECT count(*) FROM messages WHERE body = 'you cannot read this'") == 0)
            // An unsealed message has no content hint: upstream shows the delivery issue at once.
            try await c.eventually("delivery issue") { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM messages WHERE type = 'delivery-issue' AND sourceServiceId = ?", arguments: [c.aliceAci]) == 1
            }
        }
    }

    @Test func retryRequestsAreLimitedAndSkippedWhereUpstreamSkipsThem() async throws {
        try await LinkedClient.with { c in
            @Sendable func failure(_ error: Error, sender: String? = nil, toPni: Bool = false) -> MessageReceiver.DecryptionFailure {
                .init(sender: sender ?? c.aliceAci, senderDevice: 1, ciphertext: Data([0]), type: .senderKey, contentHint: nil, groupId: nil,
                      toPni: toPni, underlying: error)
            }
            func requests(after body: @Sendable (Database) throws -> Void) async throws -> Int {
                try await c.database.pool.write { db in
                    try db.execute(sql: "DELETE FROM jobs")
                    try body(db)
                    return try Int.fetchOne(db, sql: "SELECT count(*) FROM jobs WHERE data LIKE '%ResendRequest%'") ?? 0
                }
            }
            let e = envelope(c, type: .doubleRatchet, content: Data([0]))
            let broken = SignalError.invalidMessage("bad mac")
            // Upstream RETRY_LIMIT: five requests for one message, then no more.
            let limited = try await requests { db in for _ in 0..<8 { try c.receiver.requestResend(db, failure(broken), envelope: e) } }
            #expect(limited == 5)

            let other = envelope(c, type: .doubleRatchet, content: Data([0]))
            let duplicate = try await requests { db in try c.receiver.requestResend(db, failure(SignalError.duplicatedMessage("again")), envelope: other) }
            let onPni = try await requests { db in try c.receiver.requestResend(db, failure(broken, toPni: true), envelope: other) }
            let fromPni = try await requests { db in
                try c.receiver.requestResend(db, failure(broken, sender: "PNI:" + UUID().uuidString.lowercased()), envelope: other)
            }
            let blocked = try await requests { db in
                try BlockedList.serviceIds.save(db, [(id: c.aliceAci, blockedAt: nil)])
                try c.receiver.requestResend(db, failure(broken), envelope: other)
            }
            #expect(duplicate == 0 && onPni == 0 && fromPni == 0 && blocked == 0)
        }
    }

    /// A resendable message (the sender keeps it and will send it again): nothing is shown
    /// while we wait; a delivery issue appears only if it has not come within the hour.
    @Test func resendableMessageWaitsBeforeShowingADeliveryIssue() async throws {
        try await LinkedClient.with { c in
            try await c.receiveFromAlice("first")
            let e = envelope(c, type: .unidentifiedSender, content: Data([0]))
            try await c.database.pool.write { db in
                let failure = MessageReceiver.DecryptionFailure(sender: c.aliceAci, senderDevice: 1, ciphertext: Data([0]), type: .senderKey,
                                                                contentHint: .resendable, groupId: nil, toPni: false,
                                                                underlying: SignalError.invalidMessage("no sender key"))
                try c.receiver.requestResend(db, failure, envelope: e)
            }
            c.jobs.poke()
            let request = try await c.server.json("waitForDecryptionError", ["account": "alice"])
            #expect((request["timestamp"] as? Int).map(UInt64.init) == e.clientTimestamp)
            try await c.jobs.waitUntilIdle()

            let waiting = try await c.database.pool.read { db in try RetryPlaceholders.items(db) }
            #expect(waiting.count == 1 && waiting.first?.sentAt == e.clientTimestamp && waiting.first?.senderAci == c.aliceAci)
            #expect(try await count(c, "SELECT count(*) FROM messages WHERE type = 'delivery-issue'") == 0)

            let maintenance = Maintenance(database: c.database, store: nil, keyTransparency: nil)
            try await maintenance.runOnce(now: MessageStore.now() + RetryPlaceholders.lifespan / 2)
            #expect(try await count(c, "SELECT count(*) FROM messages WHERE type = 'delivery-issue'") == 0)   // still within the hour
            try await maintenance.runOnce(now: MessageStore.now() + RetryPlaceholders.lifespan + 1000)
            #expect(try await count(c, "SELECT count(*) FROM messages WHERE type = 'delivery-issue' AND sourceServiceId = ?", [c.aliceAci]) == 1)
            #expect(try await c.database.pool.read { db in try RetryPlaceholders.items(db) }.isEmpty)
        }
    }

    /// The resent message arrives: it takes the place where it first failed, unless the chat
    /// has been opened in the meantime (then it simply comes last, where the reader is).
    @Test func resentMessageTakesItsOriginalPlace() async throws {
        try await LinkedClient.with { c in
            try await c.receiveFromAlice("first")
            let conversationId = try await c.database.pool.write { db in try MessageStore.privateConversation(db, serviceId: c.aliceAci) }
            func arrive(_ body: String, opened: Bool) async throws -> Int64? {
                let t = TestClock.next()
                try await c.database.pool.write { db in
                    try RetryPlaceholders.add(db, .init(conversationId: conversationId, sentAt: t, receivedAt: 1_000, receivedAtCounter: 5,
                                                        senderAci: c.aliceAci, wasOpened: nil))
                }
                if opened { try await c.messenger.conversationOpened(conversationId) }
                let d = MessageReceiver.Decrypted(sender: c.aliceAci, senderDevice: 1, content: textContent(body, timestamp: t), sealed: true, groupId: nil)
                let e = envelope(c, type: .unidentifiedSender, content: Data(), timestamp: t)
                _ = try await c.database.pool.write { db in try c.receiver.dispatch(d, envelope: e, db) }
                return try await c.database.pool.read { db in try Int64.fetchOne(db, sql: "SELECT received_at FROM messages WHERE body = ?", arguments: [body]) }
            }
            #expect(try await arrive("resent, unread chat", opened: false) == 5)
            let later = try #require(try await arrive("resent, chat was opened", opened: true))
            #expect(later > 5)
            #expect(try await c.database.pool.read { db in try RetryPlaceholders.items(db) }.isEmpty)   // either way we stop waiting
        }
    }

    /// When the sender cannot be asked, the session with that device is reset instead: once
    /// an hour at most, and the chat says so each time.
    @Test func automaticSessionResetIsRateLimited() async throws {
        try await LinkedClient.with { c in
            try await c.receiveFromAlice("first")
            func live() async throws -> Int {
                try await c.database.pool.read { db in try c.messenger.sender.activeDevices(db, serviceId: c.aliceAci).count }
            }
            #expect(try await live() == 1)
            try await c.messenger.automaticSessionReset(sender: c.aliceAci, device: 1)
            // Archived, and the NullMessage that follows opened a new one.
            #expect(try await c.server.json("pendingMessages", ["account": "alice"])["count"] as? Int == 0)
            #expect(try await live() == 1)
            let first = try await c.database.pool.read { db in try Data.fetchOne(db, sql: "SELECT record FROM sessions WHERE serviceId = ?", arguments: [c.aliceAci]) }
            try await c.messenger.automaticSessionReset(sender: c.aliceAci, device: 1)
            let second = try await c.database.pool.read { db in try Data.fetchOne(db, sql: "SELECT record FROM sessions WHERE serviceId = ?", arguments: [c.aliceAci]) }
            #expect(first == second)   // no second reset within the hour
            #expect(try await count(c, "SELECT count(*) FROM messages WHERE type = 'chat-session-refreshed'") == 2)
        }
    }
}
