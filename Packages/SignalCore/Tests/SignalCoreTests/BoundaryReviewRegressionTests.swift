import Foundation
import GRDB
import SignalProtos
import Testing
@testable import SignalCore

private actor ReviewRegressionGates {
    var entered = 0
    var drained = false
    func markDrained() { drained = true }
    var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    var open: Set<Int> = []
    func hold() async {
        entered += 1
        let index = entered
        if open.contains(index) { return }
        await withCheckedContinuation { waiting[index] = $0 }
    }
    func release(_ index: Int) { open.insert(index); waiting.removeValue(forKey: index)?.resume() }
    func waitFor(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while entered < count {
            guard ContinuousClock.now < deadline else { throw HarnessError(description: "review gate timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@Suite(.serialized) struct BoundaryReviewRegressionTests {
    @Test func reusedLogIdCannotAuthorizeARevokedStorySnapshot() throws {
        let (database, _) = try LinkedClient.temporaryDatabase()
        let me = UUID().uuidString.lowercased(), peer = UUID().uuidString.lowercased()
        let timestamp = UInt64(MessageStore.now())
        try database.pool.write { db in
            let conversation = try MessageStore.privateConversation(db, serviceId: me)
            let list = try StoryDistributionLists.create(db, name: "review", members: [peer])
            var story = Signalservice_StoryMessage(); story.textAttachment.text = "revoked story"
            _ = try StoryStore.insert(db, .init(conversationId: conversation, source: me, sourceDevice: 1, sentAt: timestamp,
                serverTimestamp: nil, serverGuid: nil, story: story, outgoing: true, distributionListId: list))
            var original = Signalservice_Content(); original.storyMessage = story
            let oldId = try SendLog.record(db, timestamp: timestamp, contentHint: 0, proto: original.serializedData(), urgent: false,
                recipient: peer, devices: [1], messageIds: [], story: true)
            let old = try #require(try SendLog.find(db, recipient: peer, deviceId: 1, timestamp: timestamp))
            let held = try old.payload(for: peer, device: 1)
            try SendLog.authorize(db, #require(held.resendAuthorization), ourAci: me)
            try StoryDistributionLists.update(db, listId: list, members: [])
            #expect(try SendLog.answer(db, requester: peer, deviceId: 1, timestamp: timestamp, answered: 0, ourAci: me) == .nothing)
            try SendLog.deleteRecipient(db, recipient: peer, deviceId: 1, timestamp: timestamp)
            var replacement = Signalservice_Content(); replacement.nullMessage = Signalservice_NullMessage()
            let newId = try SendLog.record(db, timestamp: timestamp, contentHint: 0, proto: replacement.serializedData(), urgent: false,
                recipient: peer, devices: [1], messageIds: [])
            #expect(newId == oldId, "SQLite reuses the deleted maximum rowid")
            #expect(throws: JobError.self, "reused row ID authorized a different payload") {
                try SendLog.authorize(db, #require(held.resendAuthorization), ourAci: me)
            }
            #expect(held.content.storyMessage.textAttachment.text == "revoked story")
        }
    }

    @Test(arguments: [false, true])
    func duplicatePointersPreserveMetadataAndFinishEverySource(_ differentSizes: Bool) throws {
        let (database, _) = try LinkedClient.temporaryDatabase()
        try database.pool.write { db in
            let conversation = try MessageStore.privateConversation(db, serviceId: "peer")
            let message = try MessageStore.insert(db, .init(conversationId: conversation, type: "incoming", body: "", sentAt: 1,
                source: "peer", sourceDevice: 1, serverGuid: nil, serverTimestamp: nil, unidentified: false))
            for index in 0..<2 {
                var a = MessageAttachment(contentType: "application/octet-stream", size: differentSizes ? 3 + index : 3)
                a.pending = true; a.key = "same key"; a.digest = "same digest"
                a.fileName = "file-\(index)"; a.caption = "caption-\(index)"; a.flags = index; a.width = 100 + index
                try MessageAttachments.upsert(db, .init(messageId: message, type: .attachment, order: index), conversationId: conversation,
                    sentAt: 1, receivedAt: 1, messageType: "incoming", a)
                try AttachmentDownloads.add(db, .init(messageId: message, attachmentType: .attachment, signature: a.signature,
                    receivedAt: 1, sentAt: 1, attachment: a))
            }
            func complete(_ job: AttachmentDownloadJob) throws {
                var result = job.attachment
                result.path = "validated-\(result.size)"; result.localKey = "local key"; result.pending = false
                result.width = 888 // Decoder-derived values must not replace per-reference metadata.
                try AttachmentDownloadManager.replace(db, job: job) { _ in result }
                try AttachmentDownloadManager.finish(db, job: job)
            }
            let job = try #require(try AttachmentDownloads.next(db, limit: 6, prioritize: [], now: 1).first)
            try complete(job)
            if differentSizes {
                let next = try #require(try AttachmentDownloads.next(db, limit: 6, prioritize: [], now: 1).first, "remaining source lost its job")
                #expect(next.leaseId != job.leaseId)
                try complete(next)
            }
            let rows = try MessageAttachments.fetch(db, messageId: message).map(\.1)
            #expect(rows.filter(\.isDownloaded).count == 2, "duplicate reference was stranded")
            #expect(rows.allSatisfy { $0.pending == false })
            #expect(rows.map(\.fileName) == ["file-0", "file-1"], "reference metadata was overwritten")
            #expect(rows.map(\.caption) == ["caption-0", "caption-1"])
            #expect(rows.map(\.flags) == [0, 1])
            #expect(rows.map(\.width) == [100, 101])
            #expect(rows.map(\.path) == (differentSizes ? ["validated-3", "validated-4"] : ["validated-3", "validated-3"]))
            #expect(try AttachmentDownloads.count(db) == 0)
        }
    }

    @Test func everyOverlappingRunIsDrained() async throws {
        let server = try await MockServerHarness.start()
        do {
            let endpoints = ServiceEndpoints.mockServer(port: server.ready.port, rootCertificateDER: server.ready.certificateAuthorityDER)
            let (database, _) = try LinkedClient.temporaryDatabase()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("review-download-\(UUID())")
            let store = try AttachmentStore(root: root)
            defer { try? FileManager.default.removeItem(at: root) }
            let encrypted = try AttachmentCipher.encrypt(Data([1, 2, 3]), keys: Data(repeating: 7, count: 64))
            _ = try await server.json("putCdnBlob", ["cdnKey": "review", "data": encrypted.blob.base64EncodedString()])
            let manager = AttachmentDownloadManager(db: database.pool, http: HTTPClient(rootCertificatesDER: endpoints.rootCertificatesDER),
                endpoints: endpoints, store: store, media: nil)
            let job = try await database.pool.write { db in
                let conversation = try MessageStore.privateConversation(db, serviceId: "peer")
                let message = try MessageStore.insert(db, .init(conversationId: conversation, type: "incoming", body: "", sentAt: 1,
                    source: "peer", sourceDevice: 1, serverGuid: nil, serverTimestamp: nil, unidentified: false))
                var a = MessageAttachment(contentType: "application/octet-stream", size: 3)
                a.pending = true; a.cdnKey = "review"; a.cdnNumber = 3
                a.key = Data(repeating: 7, count: 64).base64EncodedString(); a.digest = encrypted.digest.base64EncodedString()
                try MessageAttachments.upsert(db, .init(messageId: message, type: .attachment, order: 0), conversationId: conversation,
                    sentAt: 1, receivedAt: 1, messageType: "incoming", a)
                let job = AttachmentDownloadJob(messageId: message, attachmentType: .attachment, signature: a.signature,
                    receivedAt: 1, sentAt: 1, attachment: a)
                try AttachmentDownloads.add(db, job)
                return job
            }
            let gates = ReviewRegressionGates()
            await manager.setBeforePublication { await gates.hold() }
            try await manager.start()
            try await gates.waitFor(1)
            // Requeue the same key with a new durable lease; both actual runs are now suspended.
            try await manager.add(job)
            try await gates.waitFor(2)
            let tracked = await Array(manager.active.values)
            #expect(await manager.active.count == 2, "replacement overwrote a running task handle")
            await gates.release(1)
            let deadline = ContinuousClock.now + .seconds(5)
            while await manager.active.count == 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(await manager.active.count == 1, "old completion forgot its replacement")
            let stopping = Task { await manager.stopAndWait(); await gates.markDrained() }
            let stoppingDeadline = ContinuousClock.now + .seconds(5)
            while await manager.draining == 0, !(await gates.drained), ContinuousClock.now < stoppingDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await !gates.drained, "shutdown returned before the replacement finished")
            await gates.release(2)
            await stopping.value
            for task in tracked { await task.value }
            #expect(await manager.active.isEmpty)
            #expect(try await database.pool.read { try MessageAttachments.fetch($0, messageId: job.messageId).first?.1.isDownloaded } == false,
                    "untracked replacement published after shutdown")

        } catch { await server.stop(); throw error }
        await server.stop()
    }
}
