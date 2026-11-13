import Foundation
import GRDB
import Testing
@testable import SignalCore

@Suite struct AttachmentPublicationTests {
    /// These operations are the exact writer-side completion boundary called after download awaits.
    @Test(arguments: ["cancel", "replace", "erase", "expire", "delete", "requeue", "unchanged"])
    func staleCompletionCannotPublishOrDeleteAReplacement(_ change: String) async throws {
        let (database, _) = try LinkedClient.temporaryDatabase()
        let (location, job) = try await database.pool.write { db in
            let conversation = try MessageStore.privateConversation(db, serviceId: "peer")
            let id = try MessageStore.insert(db, .init(conversationId: conversation, type: "incoming", body: "", sentAt: 1,
                source: "peer", sourceDevice: 1, serverGuid: nil, serverTimestamp: nil, unidentified: false))
            var a = MessageAttachment(contentType: "application/octet-stream", size: 3)
            a.pending = true; a.digest = "same-digest"; a.key = "old-key"
            let location = MessageAttachments.Location(messageId: id, type: .attachment, order: 0)
            try MessageAttachments.upsert(db, location, conversationId: conversation, sentAt: 1, receivedAt: 1, messageType: "incoming", a)
            try AttachmentDownloads.add(db, .init(messageId: id, attachmentType: .attachment, signature: a.signature,
                                                  receivedAt: 1, sentAt: 1, attachment: a))
            return (location, try #require(try AttachmentDownloads.next(db, limit: 1, prioritize: [], now: 1).first))
        }
        let gate = AsyncTestGate()
        let completion = Task {
            await gate.hold()
            try await database.pool.write { db in
                try AttachmentDownloadManager.replace(db, job: job) { old in
                    var a = old; a.path = "validated-file"; a.localKey = "local-key"; a.pending = false; return a
                }
                try AttachmentDownloads.remove(db, job)
            }
        }
        do {
            try await gate.waitUntilEntered()
            try await database.pool.write { db in
                switch change {
                case "cancel", "replace":
                    var a = try #require(try MessageAttachments.fetch(db, location))
                    if change == "cancel" { a.pending = false } else { a.key = "replacement-key"; a.size = 1 }
                    let conversation = try #require(try String.fetchOne(db, sql: "SELECT conversationId FROM messages WHERE id = ?", arguments: [job.messageId]))
                    try MessageAttachments.upsert(db, location, conversationId: conversation, sentAt: 1, receivedAt: 1, messageType: "incoming", a)
                case "erase": try MessageStore.updateJSON(db, messageId: job.messageId) { $0["isErased"] = true }
                case "expire": try db.execute(sql: "UPDATE messages SET expirationStartTimestamp = 0, expireTimer = 1 WHERE id = ?", arguments: [job.messageId])
                case "delete": try db.execute(sql: "DELETE FROM messages WHERE id = ?", arguments: [job.messageId])
                case "requeue": try AttachmentDownloads.add(db, job)
                default: break
                }
            }
            await gate.release()
            try await completion.value
            try await database.pool.read { db in
                let a = try MessageAttachments.fetch(db, location)
                #expect((a?.isDownloaded == true) == (change == "unchanged"))
                if change == "replace" { #expect(a?.key == "replacement-key" && a?.size == 1) }
                if change == "requeue" {
                    let next = try #require(try AttachmentDownloads.next(db, limit: 1, prioritize: [], now: 1).first)
                    #expect(next.leaseId != job.leaseId, "old completion removed the replacement job")
                }
            }
        } catch { await gate.release(); _ = await completion.result; throw error }
    }
    @Test func cancellationAfterValidationCannotPublishFromTheWriter() async throws {
        let server = try await MockServerHarness.start()
        do {
            let endpoints = ServiceEndpoints.mockServer(port: server.ready.port, rootCertificateDER: server.ready.certificateAuthorityDER)
            let (database, _) = try LinkedClient.temporaryDatabase()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("publication-\(UUID())")
            let store = try AttachmentStore(root: root)
            defer { try? FileManager.default.removeItem(at: root) }
            let encrypted = try AttachmentCipher.encrypt(Data([1, 2, 3]), keys: Data(repeating: 7, count: 64))
            _ = try await server.json("putCdnBlob", ["cdnKey": "held", "data": encrypted.blob.base64EncodedString()])
            let manager = AttachmentDownloadManager(db: database.pool, http: HTTPClient(rootCertificatesDER: endpoints.rootCertificatesDER),
                                                    endpoints: endpoints, store: store, media: nil)
            let job = try await database.pool.write { db in
                let conversation = try MessageStore.privateConversation(db, serviceId: "peer")
                let id = try MessageStore.insert(db, .init(conversationId: conversation, type: "incoming", body: "", sentAt: 1,
                    source: "peer", sourceDevice: 1, serverGuid: nil, serverTimestamp: nil, unidentified: false))
                var a = MessageAttachment(contentType: "application/octet-stream", size: 3)
                a.pending = true; a.cdnKey = "held"; a.cdnNumber = 3; a.key = Data(repeating: 7, count: 64).base64EncodedString()
                a.digest = encrypted.digest.base64EncodedString()
                try MessageAttachments.upsert(db, .init(messageId: id, type: .attachment, order: 0), conversationId: conversation,
                    sentAt: 1, receivedAt: 1, messageType: "incoming", a)
                try AttachmentDownloads.add(db, .init(messageId: id, attachmentType: .attachment, signature: a.signature,
                                                     receivedAt: 1, sentAt: 1, attachment: a))
                return try #require(try AttachmentDownloads.next(db, limit: 1, prioritize: [], now: 1).first)
            }
            let gate = AsyncTestGate()
            await manager.setBeforePublication { await gate.hold() }
            let running = Task { await manager.run(job) }
            do { try await gate.waitUntilEntered() }
            catch { await gate.release(); running.cancel(); await running.value; throw error }
            running.cancel()
            await gate.release()
            await running.value
            #expect(try await database.pool.read { try MessageAttachments.fetch($0, messageId: job.messageId).first?.1.path } == nil,
                    "cancelled writer published validated bytes")
            await manager.setBeforePublication(nil)
            await manager.run(job)
            let stored = try await database.pool.read { try #require(try MessageAttachments.fetch($0, messageId: job.messageId).first?.1) }
            #expect(try store.plaintext(of: stored) == Data([1, 2, 3]), "uncancelled retry did not publish")
        } catch { await server.stop(); throw error }
        await server.stop()
    }

}
