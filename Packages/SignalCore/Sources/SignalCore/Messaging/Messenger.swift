// Outgoing side of messaging: text messages, receipts, typing indicators, read/viewed
// syncs, resends for retry requests, and sync requests to the primary device. Every
// user-visible send is a persistent job inserted in the same transaction as the state
// change that causes it (port of Desktop conversationJobQueue + sendNormalMessage,
// sendReceipts, sendDeleteForEveryone… for the 1:1 subset).

import Foundation
import GRDB
import LibSignalClient
import SignalProtos
import SwiftProtobuf

public final class Messenger: Sendable {
    public let account: Account
    public let database: SignalDatabase
    public let socket: SocketManager
    public let sender: MessageSender
    public let jobs: JobQueue

    public init(account: Account, database: SignalDatabase, socket: SocketManager, trustRoots: [PublicKey], jobs: JobQueue) {
        self.account = account
        self.database = database
        self.socket = socket
        self.jobs = jobs
        sender = MessageSender(account: account, database: database, socket: socket, trustRoots: trustRoots)
    }

    /// Registers the conversation-queue handler; call `jobs.start()` afterwards.
    public func register() async {
        await jobs.register(ConversationJob.queueType, handler: { [self] job in
            try await self.run(try job.decode(ConversationJob.self))
        }, onFailure: { [self] job, error in
            guard let j = try? job.decode(ConversationJob.self), j.type == .normalMessage, let id = j.messageId else { return }
            try? await self.database.pool.write { db in try MessageStore.markFailed(db, messageId: id, error: "\(error)") }
        })
    }

    // MARK: public API

    /// Queues a text message to a 1:1 conversation. Returns the message id and sent timestamp.
    @discardableResult
    public func sendText(_ body: String, to serviceId: String, timestamp: UInt64? = nil) async throws -> (messageId: String, timestamp: UInt64) {
        let sentAt = timestamp ?? UInt64(MessageStore.now())
        let id = try await database.pool.write { db -> String in
            let conversationId = try MessageStore.privateConversation(db, serviceId: serviceId)
            let messageId = try MessageStore.insert(db, .init(
                conversationId: conversationId, type: "outgoing", body: body, sentAt: sentAt, source: self.account.aci,
                sourceDevice: self.account.deviceId, serverGuid: nil, serverTimestamp: nil, unidentified: false,
                extra: ["sendStateByConversationId": [conversationId: ["status": "Pending", "updatedAt": MessageStore.now()]]]))
            try MessageStore.setProfileSharing(db, conversationId: conversationId)
            try JobQueue.insert(db, queueType: ConversationJob.queueType, payload: ConversationJob.normalMessage(conversationId: conversationId, messageId: messageId))
            return messageId
        }
        jobs.poke()
        return (id, sentAt)
    }

    /// Marks every unread incoming message of a conversation read (Desktop markConversationRead):
    /// read sync to our other devices, read receipts to the senders if enabled.
    @discardableResult
    public func markRead(conversationId: String) async throws -> [ReceiptTarget] {
        let targets = try await database.pool.write { db -> [ReceiptTarget] in
            let targets = try MessageStore.markRead(db, conversationId: conversationId)
            guard !targets.isEmpty else { return [] }
            try JobQueue.insert(db, queueType: ConversationJob.queueType, payload: ConversationJob.readSync(targets))
            if try Items.get(db, "read-receipt-setting", as: Bool.self) ?? false {
                try JobQueue.insert(db, queueType: ConversationJob.queueType, payload: ConversationJob.receipts(.read, targets))
            }
            return targets
        }
        jobs.poke()
        return targets
    }

    /// Marks an incoming message viewed (view-once, voice notes): viewed sync and viewed receipt.
    @discardableResult
    public func markViewed(messageId: String) async throws -> ReceiptTarget? {
        let target = try await database.pool.write { db -> ReceiptTarget? in
            guard let target = try MessageStore.markViewed(db, messageId: messageId) else { return nil }
            try JobQueue.insert(db, queueType: ConversationJob.queueType, payload: ConversationJob.viewedSync([target]))
            if try Items.get(db, "read-receipt-setting", as: Bool.self) ?? false {
                try JobQueue.insert(db, queueType: ConversationJob.queueType, payload: ConversationJob.receipts(.viewed, [target]))
            }
            return target
        }
        jobs.poke()
        return target
    }

    /// Typing indicators are ephemeral: sent directly (online-only, never queued or logged).
    public func sendTyping(to serviceId: String, started: Bool, timestamp: UInt64? = nil) async throws {
        var typing = Signalservice_TypingMessage()
        typing.timestamp = timestamp ?? UInt64(MessageStore.now())
        typing.action = started ? .started : .stopped
        var content = Signalservice_Content()
        content.typingMessage = typing
        try await sender.send(OutgoingPayload(content: content, timestamp: typing.timestamp, contentHint: .implicit, urgent: false, online: true),
                              to: serviceId, logged: false)
    }

    /// Asks the primary device for contacts, blocked list, configuration and keys
    /// (Desktop sendRequest*SyncMessage after linking).
    public func requestSync(_ types: [Signalservice_SyncMessage.Request.TypeEnum] = [.contacts, .blocked, .configuration, .keys]) async throws {
        try await jobs.enqueue(queueType: ConversationJob.queueType, payload: ConversationJob.syncRequest(types.map(\.rawValue)))
    }

    // MARK: job execution

    func run(_ job: ConversationJob) async throws {
        switch job.type {
        case .normalMessage: try await sendNormalMessage(job)
        case .receipts: try await sendReceipts(job)
        case .readSync, .viewedSync: try await sendReadOrViewedSync(job)
        case .resend: try await resend(job)
        case .syncRequest: try await sendSyncRequests(job)
        }
    }

    func sendNormalMessage(_ job: ConversationJob) async throws {
        guard let messageId = job.messageId, let conversationId = job.conversationId else { throw JobError.permanent("malformed job") }
        guard let (body, sentAt, serviceId) = try await database.pool.read({ db in try MessageStore.outgoingText(db, messageId: messageId) }) else {
            throw JobError.permanent("message \(messageId) gone")
        }
        var data = Signalservice_DataMessage()
        data.body = body
        data.timestamp = sentAt
        if let pk = account.profileKey { data.profileKey = pk }
        var content = Signalservice_Content()
        content.dataMessage = data
        let result: SendResult
        do {
            result = try await sender.send(OutgoingPayload(content: content, timestamp: sentAt), to: serviceId, messageIds: [messageId])
        } catch let e as SendError {
            throw JobError.permanent("\(e)")
        }
        try await database.pool.write { db in
            try MessageStore.markSent(db, messageId: messageId, conversationId: conversationId, unidentified: result.sealed ? [serviceId] : [])
        }
        try await sendTranscript(data, destination: serviceId, timestamp: sentAt, sealed: result.sealed, messageId: messageId)
    }

    /// SyncMessage.Sent to our other devices (Desktop sendSyncMessage).
    func sendTranscript(_ message: Signalservice_DataMessage, destination: String, timestamp: UInt64, sealed: Bool, messageId: String) async throws {
        var sent = Signalservice_SyncMessage.Sent()
        sent.destinationServiceIDBinary = try ServiceId.parseFrom(serviceIdString: destination).serviceIdBinary
        sent.timestamp = timestamp
        sent.message = message
        sent.expirationStartTimestamp = timestamp
        var status = Signalservice_SyncMessage.Sent.UnidentifiedDeliveryStatus()
        status.destinationServiceIDBinary = sent.destinationServiceIDBinary
        status.unidentified = sealed
        sent.unidentifiedStatus = [status]
        var sync = Self.syncMessage()
        sync.sent = sent
        try await sendToSelf(sync, timestamp: timestamp, urgent: true, messageIds: [messageId])
    }

    func sendReceipts(_ job: ConversationJob) async throws {
        guard let kind = job.receiptsType, let receipts = job.receipts else { throw JobError.permanent("malformed job") }
        let bySender = Dictionary(grouping: receipts, by: \.senderAci)
        for (senderAci, targets) in bySender.sorted(by: { $0.key < $1.key }) {
            var receipt = Signalservice_ReceiptMessage()
            receipt.type = kind == .delivery ? .delivery : kind == .read ? .read : .viewed
            receipt.timestamp = targets.map(\.timestamp)
            var content = Signalservice_Content()
            content.receiptMessage = receipt
            do {
                try await sender.send(OutgoingPayload(content: content, timestamp: UInt64(MessageStore.now()), contentHint: .resendable, urgent: false),
                                      to: senderAci, messageIds: targets.map(\.messageId))
            } catch SendError.unregistered {
                continue   // nobody left to tell
            }
        }
    }

    func sendReadOrViewedSync(_ job: ConversationJob) async throws {
        guard let receipts = job.receipts else { throw JobError.permanent("malformed job") }
        var sync = Self.syncMessage()
        if job.type == .readSync {
            sync.read = try receipts.map { r in
                var read = Signalservice_SyncMessage.Read()
                read.senderAciBinary = try Aci.parseFrom(serviceIdString: r.senderAci).rawUUID.data
                read.timestamp = r.timestamp
                return read
            }
        } else {
            sync.viewed = try receipts.map { r in
                var viewed = Signalservice_SyncMessage.Viewed()
                viewed.senderAciBinary = try Aci.parseFrom(serviceIdString: r.senderAci).rawUUID.data
                viewed.timestamp = r.timestamp
                return viewed
            }
        }
        try await sendToSelf(sync, timestamp: UInt64(MessageStore.now()), urgent: false, messageIds: receipts.map(\.messageId))
    }

    func sendSyncRequests(_ job: ConversationJob) async throws {
        for raw in job.requestTypes ?? [] {
            guard let type = Signalservice_SyncMessage.Request.TypeEnum(rawValue: raw) else { continue }
            var request = Signalservice_SyncMessage.Request()
            request.type = type
            var sync = Self.syncMessage()
            sync.request = request
            try await sendToSelf(sync, timestamp: UInt64(MessageStore.now()), urgent: true, messageIds: [])
        }
    }

    /// Answers a DecryptionErrorMessage (Desktop onRetryRequest): if the failed message was
    /// a 1:1 message on the session the requester still has, that session is archived so the
    /// next send starts a fresh one; then the logged payload is sent again (same timestamp)
    /// or, if it is no longer in the send log, a NullMessage establishes the new session.
    func resend(_ job: ConversationJob) async throws {
        guard let requester = job.requester, let device = job.requesterDevice, let timestamp = job.timestamp else {
            throw JobError.permanent("malformed job")
        }
        let ratchetKey = try job.ratchetKey.flatMap { Data(base64Encoded: $0) }.map { try PublicKey($0) }
        let logged = try await database.pool.write { db -> SentProto? in
            if job.wasSenderKey != true, let ratchetKey {
                let address = try ProtocolAddress(name: requester, deviceId: device)
                let ctx = DatabaseStoreContext(db)
                if let session = try self.sender.store.loadSession(for: address, context: ctx), try session.currentRatchetKeyMatches(ratchetKey) {
                    session.archiveCurrentState()
                    try self.sender.store.storeSession(session, for: address, context: ctx)
                }
            }
            return try SendLog.find(db, recipient: requester, deviceId: device, timestamp: timestamp)
        }
        if let logged {
            let content = try Signalservice_Content(serializedBytes: logged.proto)
            try await sender.send(OutgoingPayload(content: content, timestamp: logged.timestamp, contentHint: ContentHint(rawValue: logged.contentHint),
                                                  urgent: logged.urgent), to: requester, messageIds: logged.messageIds, logged: false)
        } else {
            var content = Signalservice_Content()
            content.nullMessage = Signalservice_NullMessage()
            try await sender.send(OutgoingPayload(content: content, timestamp: UInt64(MessageStore.now()), contentHint: .implicit, urgent: false),
                                  to: requester, logged: false)
        }
    }

    // MARK: helpers

    func sendToSelf(_ sync: Signalservice_SyncMessage, timestamp: UInt64, urgent: Bool, messageIds: [String]) async throws {
        var content = Signalservice_Content()
        content.syncMessage = sync
        try await sender.send(OutgoingPayload(content: content, timestamp: timestamp, contentHint: .implicit, urgent: urgent),
                              to: account.aci, sealed: false, messageIds: messageIds)
    }

    /// Sync messages carry 1–512 random padding bytes (Desktop createSyncMessage).
    static func syncMessage() -> Signalservice_SyncMessage {
        var sync = Signalservice_SyncMessage()
        var rng = SystemRandomNumberGenerator()
        sync.padding = SignalCrypto.randomBytes(Int.random(in: 1...512, using: &rng))
        return sync
    }
}

extension UUID {
    /// The 16 raw bytes, big-endian (RFC 4122 order).
    var data: Data {
        let u = uuid
        return Data([u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15])
    }
}
