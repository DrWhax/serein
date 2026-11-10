// Adversarial regression specifications: these assert the desired secure behavior.
import Foundation
import GRDB
import LibSignalClient
import SignalProtos
import Testing
import Synchronization
@testable import SignalCore

@Suite struct AdversarialLifecycleReviewTests {
    @Test func approvalMustNotApproveAReplacementForTheDisplayedKey() async throws {
        try await LinkedClient.with { c in
            let old = IdentityKeyPair.generate().identityKey.serialize().base64EncodedString()
            let replacement = IdentityKeyPair.generate().identityKey.serialize().base64EncodedString()
            try await c.database.pool.write { db in
                _ = try MessageStore.privateConversation(db, serviceId: c.aliceAci)
                try ProtocolStore.save(db, .init(id: c.aliceAci, publicKey: old, firstUse: false,
                    timestamp: MessageStore.now(), verified: 0, nonblockingApproval: false))
            }
            let displayed = try await c.messenger.safetyNumber(with: c.aliceAci)
            try await c.database.pool.write { db in
                try ProtocolStore.save(db, .init(id: c.aliceAci, publicKey: replacement, firstUse: false,
                    timestamp: MessageStore.now(), verified: 0, nonblockingApproval: false))
            }
            let current = try await c.messenger.safetyNumber(with: c.aliceAci)
            #expect(displayed != current)
            await #expect(throws: IdentityReviewError.identityChanged) {
                try await c.messenger.approveIdentities([displayed.identity])
            }
            let row = try #require(try await c.database.pool.read { try ProtocolStore.identityRow($0, serviceId: c.aliceAci) })
            #expect(!row.nonblockingApproval, "The replacement key was never displayed or approved")
            // Verification must reject the same stale fingerprint.
            await #expect(throws: IdentityReviewError.identityChanged) {
                try await c.messenger.setVerified(displayed.identity, true)
            }
            let verified = try await c.messenger.verifiedStatus(c.aliceAci)
            #expect(verified != .verified, "A fingerprint the user never saw must not become verified")
            let wrongAccount = ReviewedIdentity(ourServiceId: UUID().uuidString, ourKey: current.identity.ourKey,
                                                 serviceId: current.identity.serviceId, key: current.identity.key)
            await #expect(throws: IdentityReviewError.identityChanged) { try await c.messenger.setVerified(wrongAccount, true) }
            // A fresh review of B still permits the intended action.
            try await c.messenger.approveIdentities([current.identity])
            try await c.messenger.setVerified(current.identity, true)
            #expect(try await c.messenger.verifiedStatus(c.aliceAci) == .verified)
        }
    }

    @Test func queuedMessageMustNotSendAfterRecipientIsBlocked() async throws {
        try await LinkedClient.with { c in
            try await c.jobs.waitUntilIdle()
            await c.jobs.stop()
            let (_, timestamp) = try await c.messenger.sendText("queued before block", to: c.aliceAci)
            let conversation = try await c.database.pool.write { db in
                try MessageStore.privateConversation(db, serviceId: c.aliceAci)
            }
            try await c.messenger.setBlocked(conversation, true)
            await c.jobs.start()
            try await c.jobs.waitUntilIdle()
            let status = try await c.sendStatus(timestamp, conversationWith: c.aliceAci)
            #expect(status != "Sent", "Queued content must not be sent to a newly blocked recipient")
            let pending = try await c.server.json("pendingMessages", ["account": "alice"])
            #expect((pending["count"] as? Int ?? 0) == 0)
        }
    }

    @Test func transportRechecksARequestPreparedBeforeBlocking() async throws {
        try await LinkedClient.with { c in
            let authorize = c.messenger.sender.authorization(to: c.aliceAci, groupId: Data(), messageIds: [])
            try authorize()
            let conversation = try await c.database.pool.write { try MessageStore.privateConversation($0, serviceId: c.aliceAci) }
            try await c.messenger.setBlocked(conversation, true)
            await #expect(throws: JobError.permanent("recipient blocked")) {
                _ = try await c.socket.authenticatedRequest("PUT", "/v1/messages/\(c.aliceAci)", json: Data("{}".utf8), authorize: authorize)
            }
            // Shared groups have independent block state; blocking a contact is not leaving a group.
            let groupId = Data([1, 2, 3])
            let groupAuthorization = c.messenger.sender.authorization(to: c.aliceAci, groupId: groupId, messageIds: [])
            try groupAuthorization()
            try await c.database.pool.write { try ConversationState.setBlocked($0, serviceId: nil, groupId: groupId.base64EncodedString(), true) }
            #expect(throws: JobError.permanent("group blocked")) { try groupAuthorization() }
        }
    }

    @Test func erasedQueuedMessagesCannotBeSubmitted() async throws {
        try await LinkedClient.with { c in
            try await c.jobs.waitUntilIdle()
            await c.jobs.stopAndWait()
            let (id, _) = try await c.messenger.sendText("never send", to: c.aliceAci)
            let authorize = c.messenger.sender.authorization(to: c.aliceAci, groupId: Data(), messageIds: [id])
            try authorize()
            try await c.database.pool.write { try MessageModifiers.erase($0, id) }
            #expect(throws: JobError.permanent("message removed")) { try authorize() }
            // Deleting it for everyone still goes out (a story is removed here before its deletes).
            var delete = Signalservice_Content()
            delete.dataMessage.delete.targetSentTimestamp = 1
            var update = Signalservice_Content()
            update.syncMessage.sent.isRecipientUpdate = true
            var resent = Signalservice_Content()
            resent.syncMessage.sent.message.body = "never send"
            #expect(OutgoingPayload(content: delete, timestamp: 1).onlyRetracts && OutgoingPayload(content: update, timestamp: 1).onlyRetracts)
            #expect(!OutgoingPayload(content: resent, timestamp: 1).onlyRetracts)
            try c.messenger.sender.authorization(to: c.aliceAci, groupId: Data(), messageIds: [id], retracting: true)()
            await c.jobs.start()
            try await c.jobs.waitUntilIdle()
            let pending = try await c.server.json("pendingMessages", ["account": "alice"])
            #expect((pending["count"] as? Int ?? 0) == 0)
        }
    }

    @Test func restartingQueueMustNotExecuteAnInflightJobTwice() async throws {
        let (database, _) = try LinkedClient.temporaryDatabase()
        let queue = JobQueue(database: database)
        let gate = ReviewJobGate()
        await queue.register("review") { _ in await gate.enter() }
        _ = try await queue.enqueue(queueType: "review", payload: ["test": true])
        await queue.start()
        for _ in 0..<5000 {
            if await gate.count == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await gate.count == 1)
        await queue.stop()
        await queue.start()
        for _ in 0..<100 {
            if await gate.count > 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let executions = await gate.count
        await queue.stop()
        await gate.release()
        #expect(executions == 1, "The old handler is still running when the new loop selects the same persisted job")
        await queue.stopAndWait()
    }

    @Test func shutdownWaitsForTheHandlerAndRejectsConcurrentRestart() async throws {
        let (database, _) = try LinkedClient.temporaryDatabase()
        let queue = JobQueue(database: database)
        let gate = ReviewJobGate()
        await queue.register("review") { _ in await gate.enter() }
        _ = try await queue.enqueue(queueType: "review", payload: true)
        await queue.start()
        for _ in 0..<5000 {
            if await gate.count == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await gate.count == 1)
        let draining = Task { await queue.stopAndWait(); await gate.markDrained() }
        for _ in 0..<5000 {
            if await queue.draining > 0 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await queue.draining > 0)
        await queue.start()
        #expect(await !gate.drained)
        await gate.release()
        await draining.value
        #expect(await gate.drained)
        #expect(await queue.loop == nil)
        #expect(await gate.count == 1)
    }

    @Test func expiredAndErasedMediaCannotBeReused() async throws {
        let (database, _) = try LinkedClient.temporaryDatabase()
        try await database.pool.write { db in
            let peer = UUID().uuidString.lowercased()
            let conversation = try MessageStore.privateConversation(db, serviceId: peer)
            let id = try MessageStore.insert(db, .init(conversationId: conversation, type: "incoming", body: "", sentAt: 100,
                source: peer, sourceDevice: 1, serverGuid: nil, serverTimestamp: nil, unidentified: false))
            var attachment = MessageAttachment(contentType: "image/png", size: 4)
            attachment.path = "test-path"
            attachment.localKey = "key"
            try MessageAttachments.upsert(db, .init(messageId: id, type: .attachment, order: 0), conversationId: conversation,
                sentAt: 100, receivedAt: 100, messageType: "incoming", attachment)
            #expect(try MediaAvailability.permits(db, path: "test-path", messageId: id, now: 100))
            #expect(try !MediaAvailability.permits(db, path: "test-path", messageId: "other", now: 100))
            // expiresAt is derived from the timer/start columns by the schema.
            try db.execute(sql: "UPDATE messages SET expireTimer = 1, expirationStartTimestamp = 100 WHERE id = ?", arguments: [id])
            #expect(try MediaAvailability.permits(db, path: "test-path", messageId: id, now: 1099))
            #expect(try !MediaAvailability.permits(db, path: "test-path", messageId: id, now: 1100))
            #expect(try MediaAvailability.fetch(db, now: 1100).messageIds.isEmpty)
            try MessageModifiers.erase(db, id)
            #expect(try !MediaAvailability.permits(db, path: "test-path", messageId: id, now: 100))
            #expect(try MediaAvailability.fetch(db, now: 100).paths.isEmpty)
        }
    }

    @Test func downloadShutdownDrainsStartupDatabaseWrites() async throws {
        let (database, url) = try LinkedClient.temporaryDatabase()
        let root = url.appendingPathExtension("attachments")
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = URL(string: "https://localhost")!
        let manager = AttachmentDownloadManager(db: database.pool, http: HTTPClient(rootCertificatesDER: []),
            endpoints: ServiceEndpoints(storageURL: endpoint, cdnURLs: [0: endpoint], rootCertificatesDER: []),
            store: try AttachmentStore(root: root), media: nil)
        let locked = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        DispatchQueue.global().async {
            try? database.pool.write { _ in
                locked.withLock { $0 = true }
                release.wait()
            }
        }
        for _ in 0..<5000 {
            if locked.withLock({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(locked.withLock { $0 })
        let startup = Task { try await manager.start() }
        for _ in 0..<5000 {
            if await manager.starting { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await manager.starting)
        let done = Mutex(false)
        let shutdown = Task { await manager.stopAndWait(); done.withLock { $0 = true } }
        for _ in 0..<5000 {
            if await manager.draining > 0 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await manager.draining > 0)
        #expect(!done.withLock { $0 })
        release.signal()
        try await startup.value
        await shutdown.value
        #expect(await !manager.running)
        #expect(await !manager.starting)
        #expect(done.withLock { $0 })
    }
}

private actor ReviewJobGate {
    var count = 0
    var drained = false
    func markDrained() { drained = true }
    var waiters: [CheckedContinuation<Void, Never>] = []
    func enter() async {
        count += 1
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}
