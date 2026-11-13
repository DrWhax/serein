import Foundation
import GRDB
import LibSignalClient
import SignalProtos
import Testing
@testable import SignalCore

@Suite(.serialized) struct CrossSliceSendTests {
    @Test(arguments: ["block", "remove", "identity"])
    func revocationAfterEncryptionStopsTheActualSend(_ change: String) async throws {
        try await LinkedClient.with { c in
            try await c.receiveFromAlice("establish a session")
            let gate = AsyncTestGate()
            let sender = MessageSender(account: c.account, database: c.database, socket: c.socket, trustRoots: c.server.ready.trustRoots,
                                       beforeSubmission: { await gate.hold() })
            let timestamp = TestClock.next()
            let id = try await c.database.pool.write { db in
                let conversation = try MessageStore.privateConversation(db, serviceId: c.aliceAci)
                return try MessageStore.insert(db, .init(conversationId: conversation, type: "outgoing", body: "held", sentAt: timestamp,
                    source: c.account.aci, sourceDevice: 2, serverGuid: nil, serverTimestamp: nil, unidentified: false))
            }
            var data = Signalservice_DataMessage(); data.body = "held"; data.timestamp = timestamp
            var content = Signalservice_Content(); content.dataMessage = data
            let payload = OutgoingPayload(content: content, timestamp: timestamp)
            let sending = Task { try await sender.send(payload, to: c.aliceAci, sealed: false, messageIds: [id]) }
            do {
                try await gate.waitUntilEntered()
                try await c.database.pool.write { db in
                    switch change {
                    case "block": try BlockedList.serviceIds.save(db, [(c.aliceAci, nil)])
                    case "remove": try db.execute(sql: "DELETE FROM messages WHERE id = ?", arguments: [id])
                    default:
                        let key = IdentityKeyPair.generate()
                        _ = try c.account.aciStore().saveIdentity(db, key.identityKey, for: ProtocolAddress(name: c.aliceAci, deviceId: 1))
                        // Approval of a NEW key must not authorize ciphertext made for the OLD key.
                        try ProtocolStore.setApproval(db, serviceId: c.aliceAci, true)
                    }
                }
                await gate.release()
                do { _ = try await sending.value; Issue.record("revoked send reached transport: \(change)") }
                catch SendError.untrustedIdentities where change == "identity" {}
                catch JobError.permanent where change != "identity" {}
                let logged = try await c.database.pool.read {
                    try Int.fetchOne($0, sql: "SELECT count(*) FROM sendLogPayloads WHERE timestamp = ?", arguments: [Int64(timestamp)])
                }
                #expect(logged == 0)
                if change == "block" {
                    try await c.database.pool.write { try BlockedList.serviceIds.save($0, []) }
                    _ = try await sender.send(payload, to: c.aliceAci, sealed: false, messageIds: [id])
                    #expect(try await c.waitForMessage(to: "alice").body == "held", "retry did not make progress")
                }
            } catch { await gate.release(); sending.cancel(); _ = await sending.result; throw error }
        }
    }

    private struct HeldForms: UploadFormSource {
        let socket: SocketManager
        let gate: AsyncTestGate
        func uploadForm(size: Int) async throws -> UploadForm {
            await gate.hold()
            return try await socket.uploadForm(size: size)
        }
    }

    @Test(arguments: ["block", "remove", "identity"])
    func revocationDuringUploadStopsTheSendJob(_ change: String) async throws {
        try await LinkedClient.with { c in
            try await c.receiveFromAlice("establish a session")
            await c.jobs.stopAndWait()
            let gate = AsyncTestGate()
            let services = AttachmentServices(store: c.attachmentStore,
                uploader: AttachmentUploader(http: HTTPClient(rootCertificatesDER: c.endpoints.rootCertificatesDER),
                                             forms: HeldForms(socket: c.socket, gate: gate)), media: nil)
            let messenger = Messenger(account: c.account, database: c.database, socket: c.socket, trustRoots: c.server.ready.trustRoots,
                                      jobs: JobQueue(database: c.database), attachments: services)
            let (id, timestamp) = try await messenger.sendMessage("upload held",
                attachments: [.init(data: Data([1, 2, 3]), contentType: "application/octet-stream")], to: c.aliceAci)
            let conversation = try await c.database.pool.read { try #require(try String.fetchOne($0,
                sql: "SELECT conversationId FROM messages WHERE id = ?", arguments: [id])) }
            let sending = Task { try await messenger.run(.normalMessage(conversationId: conversation, messageId: id)) }
            do {
                try await gate.waitUntilEntered()
                try await c.database.pool.write { db in
                    switch change {
                    case "block": try BlockedList.serviceIds.save(db, [(c.aliceAci, nil)])
                    case "remove": try db.execute(sql: "DELETE FROM messages WHERE id = ?", arguments: [id])
                    default:
                        _ = try c.account.aciStore().saveIdentity(db, IdentityKeyPair.generate().identityKey,
                            for: ProtocolAddress(name: c.aliceAci, deviceId: 1))
                    }
                }
                await gate.release()
                do { try await sending.value; Issue.record("revoked upload was sent: \(change)") }
                catch JobError.permanent {}
                #expect(try await c.database.pool.read { try Int.fetchOne($0,
                    sql: "SELECT count(*) FROM sendLogPayloads WHERE timestamp = ?", arguments: [Int64(timestamp)]) } == 0)
            } catch { await gate.release(); sending.cancel(); _ = await sending.result; throw error }
        }
    }

    @Test func groupResendRetainsMembershipAndBlockBoundary() async throws {
        try await LinkedClient.with { c in
            try await c.receiveFromAlice("establish a session")
            let keys = try GroupKeys(masterKey: Data(repeating: 71, count: 32))
            let conversation = try await c.database.pool.write { db in
                let id = try GroupStore.conversation(db, keys: keys).conversationId
                var state = GroupV2State()
                state.membersV2 = [c.account.aci, c.aliceAci].map { GroupMember(aci: $0, role: 1, joinedAtVersion: 0) }
                try GroupStore.save(db, conversationId: id, state: state, ourAci: c.account.aci)
                return id
            }
            let timestamp = TestClock.next()
            var data = Signalservice_DataMessage(); data.body = "group replay"; data.timestamp = timestamp
            var group = Signalservice_GroupContextV2(); group.masterKey = keys.masterKey; group.revision = 1
            data.groupV2 = group
            var content = Signalservice_Content(); content.dataMessage = data
            var payload = OutgoingPayload(content: content, timestamp: timestamp); payload.groupId = keys.groupId
            _ = try await c.messenger.sender.send(payload, to: c.aliceAci, sealed: false)
            #expect(try await c.waitForMessage(to: "alice").body == "group replay")
            let job = ConversationJob.resend(requester: c.aliceAci, device: 1, timestamp: timestamp, ratchetKey: nil, wasSenderKey: false)
            try await c.database.pool.write { try BlockedList.serviceIds.save($0, [(c.aliceAci, nil)]) }
            await #expect(throws: JobError.self) { try await c.messenger.resend(job) }
            try await c.database.pool.write { try BlockedList.serviceIds.save($0, []) }
            try await c.database.pool.write { db in
                var state = GroupV2State()
                state.membersV2 = [GroupMember(aci: c.account.aci, role: 1, joinedAtVersion: 0)]
                try GroupStore.save(db, conversationId: conversation, state: state, ourAci: c.account.aci)
            }
            await #expect(throws: SendError.notAMember(c.aliceAci)) { try await c.messenger.resend(job) }
            try await c.database.pool.write { try BlockedList.groups.save($0, [(keys.groupId.base64EncodedString(), nil)]) }
            await #expect(throws: JobError.self) { try await c.messenger.resend(job) }
        }
    }

    @Test func resendContextIsDurableAndLegacyRowsFailClosed() throws {
        let (db, _) = try LinkedClient.temporaryDatabase()
        var content = Signalservice_Content(); content.senderKeyDistributionMessage = Data([1, 2, 3])
        let bytes = try content.serializedData(), group = Data(repeating: 7, count: 32)
        try db.pool.write { db in
            let id = try SendLog.record(db, timestamp: 1, contentHint: 0, proto: bytes, urgent: true,
                recipient: "peer", devices: [1], messageIds: [], now: 1, groupId: group, story: true)
            let logged = try #require(try SendLog.find(db, recipient: "peer", deviceId: 1, timestamp: 1, now: 1))
            #expect(try logged.payload(for: "peer", device: 1).groupId == group)
            #expect(try logged.payload(for: "peer", device: 1).story)
            try db.execute(sql: "DELETE FROM serein_sendLogAuthorization WHERE payloadId = ?", arguments: [id])
            #expect(try SendLog.answer(db, requester: "peer", deviceId: 1, timestamp: 1, answered: 0, ourAci: "me", now: 1) == .nothing)
        }
    }
    @Test(arguments: ["replace", "logout"])
    func retainedMessengerCannotApproveAfterAccountReplacement(_ change: String) async throws {
        try await LinkedClient.with { c in
            try await c.receiveFromAlice("review this key")
            let review = try await c.messenger.safetyNumber(with: c.aliceAci).identity
            await c.jobs.stopAndWait()
            let before = try await c.database.pool.read { try ProtocolStore.identityRow($0, serviceId: c.aliceAci) }
            try await c.database.pool.write { db in
                if change == "logout" { try Items.remove(db, "uuid_id") }
                else { var next = c.account; next.aciIdentity = .generate(); try next.save(db) }
            }
            await #expect(throws: IdentityReviewError.identityChanged) { try await c.messenger.approveIdentities([review]) }
            await #expect(throws: IdentityReviewError.identityChanged) { try await c.messenger.setVerified(review, true) }
            let after = try await c.database.pool.read { try ProtocolStore.identityRow($0, serviceId: c.aliceAci) }
            #expect(before?.nonblockingApproval == after?.nonblockingApproval)
            #expect(before?.verifiedStatus == after?.verifiedStatus)
        }
    }

    @Test func resendLookupIsRepeatedAfterEncryption() async throws {
        try await LinkedClient.with { c in
            try await c.receiveFromAlice("establish a session")
            let timestamp = TestClock.next()
            var data = Signalservice_DataMessage(); data.body = "logged"; data.timestamp = timestamp
            var content = Signalservice_Content(); content.dataMessage = data
            _ = try await c.messenger.sender.send(.init(content: content, timestamp: timestamp), to: c.aliceAci, sealed: false)
            _ = try await c.waitForMessage(to: "alice")
            let logged = try await c.database.pool.read { try #require(try SendLog.find($0, recipient: c.aliceAci, deviceId: 1, timestamp: timestamp)) }
            let gate = AsyncTestGate()
            let sender = MessageSender(account: c.account, database: c.database, socket: c.socket, trustRoots: c.server.ready.trustRoots,
                                       beforeSubmission: { await gate.hold() })
            let payload = try logged.payload(for: c.aliceAci, device: 1)
            let sending = Task { try await sender.send(payload, to: c.aliceAci, sealed: false, logged: false) }
            do {
                try await gate.waitUntilEntered()
                try await c.database.pool.write { try SendLog.deleteRecipient($0, recipient: c.aliceAci, deviceId: 1, timestamp: timestamp) }
                await gate.release()
                do { _ = try await sending.value; Issue.record("resend used a revoked log lookup") }
                catch JobError.permanent {}
            } catch { await gate.release(); sending.cancel(); _ = await sending.result; throw error }
        }
    }

}
