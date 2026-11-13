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
    public let groupSender: GroupSender
    /// Resend requests answered so far (`SendLog.retryLimit`).
    let retries = RetryLimiter()
    /// Attachment storage, upload and the media service (nil: text only).
    public let attachments: AttachmentServices?
    /// Sends that stopped because a recipient's identity key needs the user's approval
    /// (upstream `conversationStoppedByMissingVerification`).
    public let identityStops: AsyncStream<IdentityStop>
    let identityStopSink: AsyncStream<IdentityStop>.Continuation

    public init(account: Account, database: SignalDatabase, socket: SocketManager, trustRoots: [PublicKey], jobs: JobQueue,
                attachments: AttachmentServices? = nil) {
        self.account = account
        self.database = database
        self.socket = socket
        self.jobs = jobs
        self.attachments = attachments
        (identityStops, identityStopSink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        sender = MessageSender(account: account, database: database, socket: socket, trustRoots: trustRoots)
        groupSender = GroupSender(account: account, database: database, socket: socket, sender: sender)
    }

    /// Registers the conversation-queue handler; call `jobs.start()` afterwards.
    public func register() async {
        await failOrphanedSends()
        await jobs.register(ConversationJob.queueType, handler: { [self] job in
            try await self.run(try job.decode(ConversationJob.self))
        }, onFailure: { [self] job, error in
            guard let j = try? job.decode(ConversationJob.self) else { return }
            if j.type == .resendRequest, let from = j.requester, let device = j.requesterDevice {
                // `failoverToLocalReset`: the request never went out.
                try? await self.automaticSessionReset(sender: from, device: device)
            }
            guard j.type == .normalMessage, let id = j.messageId else { return }
            try? await self.database.pool.write { db in try MessageStore.markFailed(db, messageId: id, error: "\(error)") }
        })
    }

    /// Before the queue starts: messages still "sending" with no job to send them fail (retryable).
    func failOrphanedSends() async {
        do {
            let repaired = try await database.pool.write { db -> Int in
                let rows = try Row.fetchAll(db, sql: "SELECT data FROM jobs WHERE queueType = ?", arguments: [ConversationJob.queueType])
                let queued = Set(rows.compactMap { row -> String? in
                    guard let data = (row["data"] as String?)?.data(using: .utf8) else { return nil }
                    return (try? JSONDecoder().decode(ConversationJob.self, from: data))?.messageId
                })
                return try MessageStore.failOrphanedSends(db, queued: queued)
            }
            if repaired > 0 { SignalClient.diagnose("sends with no job left marked failed: \(repaired)") }
        } catch {
            SignalClient.diagnose("orphaned sends check failed: \(error)")
        }
    }

    // MARK: public API

    /// Queues a text message to a 1:1 conversation. Returns the message id and sent timestamp.
    @discardableResult
    public func sendText(_ body: String, to serviceId: String, timestamp: UInt64? = nil) async throws -> (messageId: String, timestamp: UInt64) {
        try await sendMessage(body, attachments: [], to: serviceId, timestamp: timestamp)
    }

    /// Queues a message with attachments: each is encrypted at rest now (with its dimensions
    /// and blurhash from the media service for images) and uploaded by the send job.
    @discardableResult
    public func sendMessage(_ body: String, attachments outgoing: [OutgoingAttachment], preview: LinkPreviewDraft? = nil, quoting: String? = nil,
                            bodyRanges: [MessageBodyRange] = [], to serviceId: String, timestamp: UInt64? = nil, highQuality: Bool = false,
                            viewOnce: Bool = false, contact: SharedContactInfo? = nil, contactAvatar: OutgoingAttachment? = nil) async throws
        -> (messageId: String, timestamp: UInt64)
    {
        let (body, bodyRanges, preview) = try Self.viewOnceDraft(viewOnce, body: body, bodyRanges: bodyRanges, preview: preview, quoting: quoting, attachments: outgoing)
        let sentAt = timestamp ?? UInt64(MessageStore.now())
        var preparing: [MessageAttachment] = []
        if !outgoing.isEmpty {
            guard let services = attachments else { throw AttachmentDownloadError.missingPointer }
            let number = account.number
            // `scaleImageToLevel`: a high-quality send uses level three, otherwise the remote
            // config's level for our number.
            let level = highQuality ? .three : try await database.pool.read { try MediaQuality.level($0, e164: number) }
            for o in outgoing { preparing.append(try await services.prepare(o, level: level)) }
        }
        let prepared = preparing
        if let contact, !contact.canBeShared { throw SharedContactError.needsNameAndAciOrNumber }
        let avatar = try await prepareContactAvatar(contactAvatar)
        let previewImage = try await preparePreviewImage(preview)
        let quoteThumbnail = await prepareQuoteThumbnail(quoting)
        let id = try await database.pool.write { db -> String in
            let conversationId = try MessageStore.privateConversation(db, serviceId: serviceId)
            // `maybeApplyUniversalTimer`: a new chat starts with the universal timer.
            if let universal = try Items.get(db, "universalExpireTimer", as: Int.self), universal > 0,
               try ConversationState.timer(db, conversationId: conversationId).seconds == nil,
               try Int.fetchOne(db, sql: "SELECT count(*) FROM messages WHERE conversationId = ?", arguments: [conversationId]) == 0 {
                try MessageStore.updateConversationJSON(db, conversationId: conversationId) { $0["expireTimer"] = universal }
                try ConversationState.insertTimerNotification(db, conversationId: conversationId, seconds: UInt32(universal), from: self.account.aci, sentAt: sentAt - 1)
            }
            let messageId = try MessageStore.insert(db, .init(
                conversationId: conversationId, type: "outgoing", body: body, sentAt: sentAt, source: self.account.aci,
                sourceDevice: self.account.deviceId, serverGuid: nil, serverTimestamp: nil, unidentified: false,
                extra: try Self.outgoingExtra(db, Self.withContact(contact, hasAvatar: avatar != nil, Self.withViewOnce(viewOnce, Self.withBodyRanges(
                    ["sendStateByConversationId": [conversationId: ["status": "Pending", "updatedAt": MessageStore.now()]]], bodyRanges, body: body))),
                                              quoting: quoting, ourAci: self.account.aci)))
            try Self.storeContactAvatar(db, avatar, messageId: messageId, conversationId: conversationId, sentAt: Int64(sentAt))
            if !prepared.isEmpty {
                let receivedAt = try Int64.fetchOne(db, sql: "SELECT received_at FROM messages WHERE id = ?", arguments: [messageId]) ?? MessageStore.now()
                for (i, a) in prepared.enumerated() {
                    try MessageAttachments.upsert(db, .init(messageId: messageId, type: .attachment, order: i), conversationId: conversationId,
                                                  sentAt: Int64(sentAt), receivedAt: receivedAt, messageType: "outgoing", a)
                }
                try MessageAttachments.updateMessageFlags(db, messageId: messageId)
            }
            if let preview { try Self.storeOutgoingPreview(db, messageId: messageId, conversationId: conversationId, sentAt: Int64(sentAt), preview, previewImage) }
            try Self.storeQuoteThumbnail(db, quoteThumbnail, messageId: messageId, conversationId: conversationId, sentAt: sentAt)
            try MessageStore.setProfileSharing(db, conversationId: conversationId)
            try JobQueue.insert(db, queueType: ConversationJob.queueType, payload: ConversationJob.normalMessage(conversationId: conversationId, messageId: messageId))
            return messageId
        }
        jobs.poke()
        return (id, sentAt)
    }

    /// A view-once send (`enqueueMessageForSend` with isViewOnce, `isViewOnceEligible`): exactly
    /// one image or video and no quote. Its text, ranges and link preview are dropped, as
    /// upstream's composer drops them.
    static func viewOnceDraft(_ viewOnce: Bool, body: String, bodyRanges: [MessageBodyRange], preview: LinkPreviewDraft?, quoting: String?,
                              attachments: [OutgoingAttachment]) throws -> (String, [MessageBodyRange], LinkPreviewDraft?) {
        guard viewOnce else { return (body, bodyRanges, preview) }
        guard attachments.count == 1, attachments[0].contentType.hasPrefix("image/") || attachments[0].contentType.hasPrefix("video/"), quoting == nil
        else { throw ViewOnceSendError.ineligible }
        return ("", [], nil)
    }

    /// `enqueueSharedContactForSend`: the contact in the message's `contact`.
    static func withContact(_ contact: SharedContactInfo?, hasAvatar: Bool, _ extra: [String: Any]) -> [String: Any] {
        guard let contact else { return extra }
        var out = extra
        out["contact"] = [SharedContacts.json(contact, hasAvatar: hasAvatar)]
        return out
    }

    /// `copyAvatarForMessage`: the contact's avatar, encrypted at rest like an attachment (already
    /// a small image, so not transcoded).
    func prepareContactAvatar(_ avatar: OutgoingAttachment?) async throws -> MessageAttachment? {
        guard let avatar, let services = attachments else { return nil }
        return try await services.prepare(avatar, transcode: false)
    }

    static func storeContactAvatar(_ db: Database, _ avatar: MessageAttachment?, messageId: String, conversationId: String, sentAt: Int64) throws {
        guard let avatar else { return }
        let receivedAt = try Int64.fetchOne(db, sql: "SELECT received_at FROM messages WHERE id = ?", arguments: [messageId]) ?? MessageStore.now()
        try MessageAttachments.upsert(db, .init(messageId: messageId, type: .contact, order: 0), conversationId: conversationId, sentAt: sentAt,
                                      receivedAt: receivedAt, messageType: "outgoing", avatar)
    }

    /// The stored shared contact's proto, its avatar uploaded (`toContactProto`).
    func contactProto(messageId: String) async throws -> Signalservice_DataMessage.Contact? {
        let raw = try await database.pool.read { db in try String.fetchOne(db, sql: "SELECT json FROM messages WHERE id = ?", arguments: [messageId]) }
        guard let raw, let json = (try MessageStore.jsonObject(raw)["contact"] as? [[String: Any]])?.first else { return nil }
        let avatar = try await uploadAttachments(messageId: messageId, type: .contact).first
        return SharedContacts.proto(json, avatar: avatar)
    }

    static func withViewOnce(_ viewOnce: Bool, _ extra: [String: Any]) -> [String: Any] {
        guard viewOnce else { return extra }
        var out = extra
        out["isViewOnce"] = true
        return out
    }

    /// Whether a stored outgoing message is view-once.
    func isViewOnce(_ messageId: String) async throws -> Bool {
        try await database.pool.read { db in
            guard let json = try String.fetchOne(db, sql: "SELECT json FROM messages WHERE id = ?", arguments: [messageId]) else { return false }
            return try MessageStore.jsonObject(json)["isViewOnce"] as? Bool == true
        }
    }

    /// `eraseMessageContents(message, 'view-once-sent')`: once every recipient has a view-once
    /// message, our copy is erased (before that, a retry still needs its media).
    func eraseSentViewOnce(_ messageId: String) async throws {
        try await database.pool.write { db in
            guard let json = try String.fetchOne(db, sql: "SELECT json FROM messages WHERE id = ?", arguments: [messageId]) else { return }
            let o = try MessageStore.jsonObject(json)
            guard o["isViewOnce"] as? Bool == true, o["isErased"] as? Bool != true else { return }
            let states = (o["sendStateByConversationId"] as? [String: [String: Any]] ?? [:]).values.compactMap { $0["status"] as? String }
            guard !states.contains(where: { $0 == SendStatus.pending.rawValue || $0 == SendStatus.failed.rawValue }) else { return }
            try MessageModifiers.erase(db, messageId)
        }
    }

    /// The new message's stored fields plus its body ranges (only those inside the body).
    static func withBodyRanges(_ extra: [String: Any], _ ranges: [MessageBodyRange], body: String) -> [String: Any] {
        let valid = MessageBodyRange.valid(ranges, bodyLength: body.utf16.count)
        guard !valid.isEmpty else { return extra }
        var out = extra
        out["bodyRanges"] = valid.map(\.json)
        return out
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

    /// `retryMessageSend`: a failed outgoing message is sent again (its failed recipients back
    /// to pending, the error cleared). Group members that already have it drop the duplicate
    /// (same sender and timestamp).
    public func retrySend(messageId: String) async throws {
        try await database.pool.write { db in
            guard let conversationId = try String.fetchOne(db, sql: "SELECT conversationId FROM messages WHERE id = ? AND type = 'outgoing'",
                                                           arguments: [messageId]) else { return }
            try MessageStore.updateJSON(db, messageId: messageId) { json in
                var states = json["sendStateByConversationId"] as? [String: [String: Any]] ?? [:]
                for (k, v) in states where (v["status"] as? String) == SendStatus.failed.rawValue {
                    var v = v
                    v["status"] = SendStatus.pending.rawValue
                    v["updatedAt"] = MessageStore.now()
                    states[k] = v
                }
                json["sendStateByConversationId"] = states
                json["errors"] = nil
            }
            try JobQueue.insert(db, queueType: ConversationJob.queueType, payload: ConversationJob.normalMessage(conversationId: conversationId, messageId: messageId))
        }
        jobs.poke()
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

    /// A typing indicator to a group's members (with the group id), online-only like 1:1 ones.
    public func sendGroupTyping(masterKey: Data, started: Bool, timestamp: UInt64? = nil) async throws {
        let keys = try GroupKeys(masterKey: masterKey)
        guard let state = try await database.pool.read({ try GroupStore.find($0, groupId: keys.groupId)?.state }) else { return }
        var typing = Signalservice_TypingMessage()
        typing.timestamp = timestamp ?? UInt64(MessageStore.now())
        typing.action = started ? .started : .stopped
        typing.groupID = keys.groupId
        var content = Signalservice_Content()
        content.typingMessage = typing
        _ = try await groupSender.send(OutgoingPayload(content: content, timestamp: typing.timestamp, contentHint: .implicit, urgent: false, online: true),
                                       keys: keys, recipients: state.membersV2.map(\.aci))
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
        case .resendRequest: try await sendResendRequest(job)
        case .syncRequest: try await sendSyncRequests(job)
        case .fetchLatest: try await sendFetchLatest(job)
        case .stickerPackSync: try await sendStickerPackSync(job)
        case .verifiedSync: try await sendToSelf(try await verifiedSyncMessage(job), timestamp: UInt64(MessageStore.now()), urgent: false, messageIds: [])
        case .modifierSend:
            do { try await sendModifier(job) } catch SendError.untrustedIdentities(let ids) {
                throw try await stoppedByIdentity(ids, conversationId: job.conversationId, messageId: nil)
            }
        }
    }

    /// Queues a message to a Groups v2 conversation (members from the stored group state).
    @discardableResult
    public func sendGroupMessage(_ body: String, attachments outgoing: [OutgoingAttachment] = [], preview: LinkPreviewDraft? = nil, quoting: String? = nil,
                                 bodyRanges: [MessageBodyRange] = [], masterKey: Data, timestamp: UInt64? = nil, highQuality: Bool = false,
                                 viewOnce: Bool = false, contact: SharedContactInfo? = nil, contactAvatar: OutgoingAttachment? = nil)
        async throws -> (messageId: String, timestamp: UInt64)
    {
        let (body, bodyRanges, preview) = try Self.viewOnceDraft(viewOnce, body: body, bodyRanges: bodyRanges, preview: preview, quoting: quoting, attachments: outgoing)
        let sentAt = timestamp ?? UInt64(MessageStore.now())
        var preparing: [MessageAttachment] = []
        if !outgoing.isEmpty {
            guard let services = attachments else { throw AttachmentDownloadError.missingPointer }
            let number = account.number
            // `scaleImageToLevel`: a high-quality send uses level three, otherwise the remote
            // config's level for our number.
            let level = highQuality ? .three : try await database.pool.read { try MediaQuality.level($0, e164: number) }
            for o in outgoing { preparing.append(try await services.prepare(o, level: level)) }
        }
        let prepared = preparing
        if let contact, !contact.canBeShared { throw SharedContactError.needsNameAndAciOrNumber }
        let avatar = try await prepareContactAvatar(contactAvatar)
        let previewImage = try await preparePreviewImage(preview)
        let quoteThumbnail = await prepareQuoteThumbnail(quoting)
        let keys = try GroupKeys(masterKey: masterKey)
        let ourAci = account.aci
        let id = try await database.pool.write { db -> String in
            let group = try GroupStore.conversation(db, keys: keys)
            guard let state = group.state, state.isMember(ourAci) else { throw GroupsServiceError.notAMember }
            var states: [String: Any] = [:]
            for m in state.membersV2 where m.aci != ourAci {
                states[try MessageStore.privateConversation(db, serviceId: m.aci)] = ["status": "Pending", "updatedAt": MessageStore.now()]
            }
            let messageId = try MessageStore.insert(db, .init(
                conversationId: group.conversationId, type: "outgoing", body: body, sentAt: sentAt, source: ourAci, sourceDevice: self.account.deviceId,
                serverGuid: nil, serverTimestamp: nil, unidentified: false,
                extra: try Self.outgoingExtra(db, Self.withContact(contact, hasAvatar: avatar != nil,
                                                                   Self.withViewOnce(viewOnce, Self.withBodyRanges(["sendStateByConversationId": states], bodyRanges, body: body))),
                                              quoting: quoting, ourAci: ourAci)))
            try Self.storeContactAvatar(db, avatar, messageId: messageId, conversationId: group.conversationId, sentAt: Int64(sentAt))
            if !prepared.isEmpty {
                let receivedAt = try Int64.fetchOne(db, sql: "SELECT received_at FROM messages WHERE id = ?", arguments: [messageId]) ?? MessageStore.now()
                for (i, a) in prepared.enumerated() {
                    try MessageAttachments.upsert(db, .init(messageId: messageId, type: .attachment, order: i), conversationId: group.conversationId,
                                                  sentAt: Int64(sentAt), receivedAt: receivedAt, messageType: "outgoing", a)
                }
                try MessageAttachments.updateMessageFlags(db, messageId: messageId)
            }
            if let preview {
                try Self.storeOutgoingPreview(db, messageId: messageId, conversationId: group.conversationId, sentAt: Int64(sentAt), preview, previewImage)
            }
            try Self.storeQuoteThumbnail(db, quoteThumbnail, messageId: messageId, conversationId: group.conversationId, sentAt: sentAt)
            try JobQueue.insert(db, queueType: ConversationJob.queueType,
                                payload: ConversationJob.normalMessage(conversationId: group.conversationId, messageId: messageId))
            return messageId
        }
        jobs.poke()
        return (id, sentAt)
    }

    func sendGroupNormalMessage(messageId: String, group: GroupStore.Stored) async throws {
        try sender.authorization(to: nil, groupId: group.keys.groupId, messageIds: [messageId])()
        guard let state = group.state else { throw JobError.permanent("group without state") }
        let fetched = try await database.pool.read { db -> (String, Int64)? in
            try Row.fetchOne(db, sql: "SELECT body, sent_at FROM messages WHERE id = ?", arguments: [messageId]).map { (($0["body"] as String?) ?? "", $0["sent_at"]) }
        }
        guard let (body, sentAtMs) = fetched else { throw JobError.permanent("message \(messageId) gone") }
        let sentAt = UInt64(sentAtMs)
        var data = Signalservice_DataMessage()
        data.body = body
        data.bodyRanges = try await storedBodyRanges(messageId: messageId)
        data.timestamp = sentAt
        if let pk = account.profileKey { data.profileKey = pk }
        var context = Signalservice_GroupContextV2()
        context.masterKey = group.keys.masterKey
        context.revision = UInt32(state.revision)
        data.groupV2 = context
        data.attachments = try await uploadAttachments(messageId: messageId)
        if let sticker = try await uploadSticker(messageId: messageId) { data.sticker = sticker }
        data.preview = try await uploadPreviews(messageId: messageId)
        if let poll = try await pollCreate(messageId: messageId) { data.pollCreate = poll }
        if let quote = try await quoteProto(messageId: messageId) { data.quote = quote }
        let viewOnce = try await isViewOnce(messageId)
        if viewOnce { data.isViewOnce = true }
        if let contact = try await contactProto(messageId: messageId) { data.contact = [contact] }
        try await stampTimer(&data, messageId: messageId)
        var content = Signalservice_Content()
        content.dataMessage = data
        let ourAci = account.aci
        let recipients = state.membersV2.map(\.aci).filter { $0 != ourAci }
        let result: GroupSendResult
        do {
            result = try await groupSender.send(OutgoingPayload(content: content, timestamp: sentAt), keys: group.keys, recipients: recipients,
                                                messageIds: [messageId])
        } catch SendError.untrustedIdentities(let ids) {
            throw try await stoppedByIdentity(ids, conversationId: group.conversationId, messageId: messageId)
        }
        let delivered = Set(result.senderKeyRecipients + result.normalRecipients).subtracting(result.unregistered)
        try await database.pool.write { db in
            try MessageStore.updateJSON(db, messageId: messageId) { json in
                for aci in delivered {
                    if let cid = try? MessageStore.privateConversation(db, serviceId: aci) { MessageStore.setSendStatus(&json, conversationId: cid, .sent) }
                }
                // Members we blocked were not sent to: not left waiting (a send still waiting with
                // no job fails at the next start).
                if var states = json["sendStateByConversationId"] as? [String: Any] {
                    for aci in result.blocked {
                        if let cid = try? MessageStore.privateConversation(db, serviceId: aci) { states[cid] = nil }
                    }
                    json["sendStateByConversationId"] = states
                }
                json["unidentifiedDeliveries"] = Array(result.senderKeyRecipients)
            }
        }
        // The members have it: a failed transcript to our other devices must not fail (and resend)
        // the message, as for 1:1 messages.
        do {
            try await sendGroupTranscript(data, recipients: Array(delivered), sealed: Set(result.senderKeyRecipients), timestamp: sentAt, messageId: messageId)
        } catch {
            SignalClient.diagnose("group sync transcript failed: \(String(describing: error).prefix(120))")
        }
        if viewOnce { try await eraseSentViewOnce(messageId) }
    }

    /// SyncMessage.Sent for a group message: no destination, one status per recipient.
    func sendGroupTranscript(_ message: Signalservice_DataMessage, recipients: [String], sealed: Set<String>, timestamp: UInt64, messageId: String) async throws {
        var sent = Signalservice_SyncMessage.Sent()
        sent.timestamp = timestamp
        sent.message = message
        sent.expirationStartTimestamp = timestamp
        sent.unidentifiedStatus = try recipients.sorted().map { aci in
            var status = Signalservice_SyncMessage.Sent.UnidentifiedDeliveryStatus()
            status.destinationServiceIDBinary = try ServiceId.parseFrom(serviceIdString: aci).serviceIdBinary
            status.unidentified = sealed.contains(aci)
            return status
        }
        var sync = Self.syncMessage()
        sync.sent = sent
        try await sendToSelf(sync, timestamp: timestamp, urgent: true, messageIds: [messageId])
    }

    func sendNormalMessage(_ job: ConversationJob) async throws {
        guard let messageId = job.messageId, let conversationId = job.conversationId else { throw JobError.permanent("malformed job") }
        if let group = try await database.pool.read({ db in try GroupStore.load(db, conversationId: conversationId) }) {
            return try await sendGroupNormalMessage(messageId: messageId, group: group)
        }
        guard let (body, sentAt, serviceId) = try await database.pool.read({ db in try MessageStore.outgoingText(db, messageId: messageId) }) else {
            throw JobError.permanent("message \(messageId) gone")
        }
        try sender.authorization(to: serviceId, groupId: Data(), messageIds: [messageId])()
        var data = Signalservice_DataMessage()
        data.body = body
        data.bodyRanges = try await storedBodyRanges(messageId: messageId)
        data.timestamp = sentAt
        if let pk = account.profileKey { data.profileKey = pk }
        data.attachments = try await uploadAttachments(messageId: messageId)
        if let sticker = try await uploadSticker(messageId: messageId) { data.sticker = sticker }
        data.preview = try await uploadPreviews(messageId: messageId)
        if let poll = try await pollCreate(messageId: messageId) { data.pollCreate = poll }
        if let quote = try await quoteProto(messageId: messageId) { data.quote = quote }
        let viewOnce = try await isViewOnce(messageId)
        if viewOnce { data.isViewOnce = true }
        if let contact = try await contactProto(messageId: messageId) { data.contact = [contact] }
        try await stampTimer(&data, messageId: messageId)
        var content = Signalservice_Content()
        content.dataMessage = data
        let result: SendResult
        do {
            result = try await sender.send(OutgoingPayload(content: content, timestamp: sentAt), to: serviceId, messageIds: [messageId])
        } catch SendError.untrustedIdentities(let ids) {
            throw try await stoppedByIdentity(ids, conversationId: conversationId, messageId: messageId)
        } catch let e as SendError {
            throw JobError.permanent("\(e)")
        }
        try await database.pool.write { db in
            try MessageStore.markSent(db, messageId: messageId, conversationId: conversationId, unidentified: result.sealed ? [serviceId] : [])
        }
        // The recipient has it: a failed transcript to our other devices must not fail (and
        // resend) the message. Upstream logs it; the devices catch up from storage and receipts.
        do {
            try await sendTranscript(data, destination: serviceId, timestamp: sentAt, sealed: result.sealed, messageId: messageId)
        } catch {
            SignalClient.diagnose("sync transcript failed: \(String(describing: error).prefix(120))")
        }
        if viewOnce { try await eraseSentViewOnce(messageId) }
    }

    /// `uploadAttachment` for every attachment of an outgoing message that has no usable CDN
    /// pointer yet (pointers stay reusable for 3 days); returns the pointers in order.
    func uploadAttachments(messageId: String, type: MessageAttachmentType = .attachment) async throws -> [Signalservice_AttachmentPointer] {
        let rows = try await database.pool.read { db in
            try MessageAttachments.fetch(db, messageId: messageId).filter { $0.0.type == type && $0.0.editHistoryIndex == -1 }
        }
        guard !rows.isEmpty else { return [] }
        guard let services = attachments else { throw JobError.permanent("no attachment services") }
        var pointers: [Signalservice_AttachmentPointer] = []
        let now = UInt64(MessageStore.now())
        for (loc, a) in rows {
            if let ts = a.uploadTimestamp, a.cdnKey != nil, now - ts < AttachmentServices.reuseWindow {
                pointers.append(a.pointer())
                continue
            }
            let uploaded = try await services.upload(a)
            try await database.pool.write { db in
                guard let row = try Row.fetchOne(db, sql: "SELECT conversationId, sent_at, received_at FROM messages WHERE id = ?", arguments: [messageId])
                else { return }
                try MessageAttachments.upsert(db, loc, conversationId: row["conversationId"], sentAt: row["sent_at"], receivedAt: row["received_at"],
                                              messageType: "outgoing", uploaded)
            }
            pointers.append(uploaded.pointer())
        }
        return pointers
    }

    /// The conversation's timer on an outgoing message; its countdown starts at send.
    func stampTimer(_ data: inout Signalservice_DataMessage, messageId: String) async throws {
        let sentAt = Int64(data.timestamp)
        let stamped = try await database.pool.write { db -> Signalservice_DataMessage in
            var d = Signalservice_DataMessage()
            guard let c = try String.fetchOne(db, sql: "SELECT conversationId FROM messages WHERE id = ?", arguments: [messageId]) else { return d }
            try ConversationState.stamp(db, conversationId: c, into: &d)
            if d.expireTimer > 0, try Int64.fetchOne(db, sql: "SELECT expirationStartTimestamp FROM messages WHERE id = ?", arguments: [messageId]) == nil {
                try ConversationState.setMessageTimer(db, messageId: messageId, seconds: d.expireTimer, startedAt: sentAt)
            }
            return d
        }
        if stamped.expireTimer > 0 { data.expireTimer = stamped.expireTimer }
        if stamped.hasExpireTimerVersion { data.expireTimerVersion = stamped.expireTimerVersion }
    }

    /// The preview's image, kept at rest like an attachment (already sized by the media service,
    /// so not transcoded again).
    func preparePreviewImage(_ preview: LinkPreviewDraft?) async throws -> MessageAttachment? {
        guard let image = preview?.image, let services = attachments else { return nil }
        return try await services.prepare(OutgoingAttachment(data: image.data, contentType: image.contentType), transcode: false)
    }

    static func storeOutgoingPreview(_ db: Database, messageId: String, conversationId: String, sentAt: Int64, _ p: LinkPreviewDraft,
                                     _ image: MessageAttachment?) throws {
        try MessageStore.updateJSON(db, messageId: messageId) { json in
            json["preview"] = [MessageStore.previewJSON(url: p.url, title: p.title, description: p.description, date: p.date)]
        }
        if let image {
            let receivedAt = try Int64.fetchOne(db, sql: "SELECT received_at FROM messages WHERE id = ?", arguments: [messageId]) ?? MessageStore.now()
            try MessageAttachments.upsert(db, .init(messageId: messageId, type: .preview, order: 0), conversationId: conversationId, sentAt: sentAt,
                                          receivedAt: receivedAt, messageType: "outgoing", image)
            try MessageAttachments.updateMessageFlags(db, messageId: messageId)
        }
    }

    /// DataMessage.preview for an outgoing message (images uploaded when needed).
    func uploadPreviews(messageId: String) async throws -> [Signalservice_Preview] {
        struct Stored: Decodable { var url: String; var title: String?; var description: String?; var date: Int64? }
        let stored = try await database.pool.read { db -> [Stored] in
            guard let s = try String.fetchOne(db, sql: "SELECT json ->> '$.preview' FROM messages WHERE id = ?", arguments: [messageId]) else { return [] }
            return (try? JSONDecoder().decode([Stored].self, from: Data(s.utf8))) ?? []
        }
        guard !stored.isEmpty else { return [] }
        let images = try await uploadAttachments(messageId: messageId, type: .preview)
        return stored.enumerated().map { i, p in
            var out = Signalservice_Preview()
            out.url = p.url
            if let t = p.title { out.title = t }
            if let d = p.description { out.description_p = d }
            if let date = p.date { out.date = UInt64(date) }
            if i == 0, let image = images.first { out.image = image }
            return out
        }
    }

    /// DataMessage.Sticker for an outgoing sticker message (its image uploaded when needed).
    func uploadSticker(messageId: String) async throws -> Signalservice_DataMessage.Sticker? {
        struct Meta: Decodable { var packId: String; var packKey: String; var stickerId: Int; var emoji: String? }
        let meta = try await database.pool.read { db -> Meta? in
            guard let s = try String.fetchOne(db, sql: "SELECT json ->> '$.sticker' FROM messages WHERE id = ?", arguments: [messageId]) else { return nil }
            return try JSONDecoder().decode(Meta.self, from: Data(s.utf8))
        }
        guard let meta, let id = Data(hex: meta.packId), let key = Data(base64Encoded: meta.packKey),
              let pointer = try await uploadAttachments(messageId: messageId, type: .sticker).first else { return nil }
        var sticker = Signalservice_DataMessage.Sticker()
        sticker.packID = id
        sticker.packKey = key
        sticker.stickerID = UInt32(meta.stickerId)
        if let emoji = meta.emoji { sticker.emoji = emoji }
        sticker.data = pointer
        return sticker
    }

    /// `sendStickerMessage` to a contact (`serviceId`) or a group (`masterKey`): the local
    /// sticker image is sent as is (no transcoding); a WebP passes libsignal's WebpSanitizer
    /// first, and the media service supplies its dimensions and blurhash.
    @discardableResult
    public func sendSticker(packId: String, stickerId: Int, to serviceId: String? = nil, masterKey: Data? = nil, timestamp: UInt64? = nil) async throws
        -> (messageId: String, timestamp: UInt64)
    {
        guard let services = attachments else { throw JobError.permanent("no attachment services") }
        guard let (local, packKey) = try await database.pool.read({ db -> ((path: String, localKey: String, size: Int, emoji: String?, width: Int?, height: Int?), String)? in
            guard let l = try Stickers.localSticker(db, packId: packId, stickerId: stickerId),
                  let key = try String.fetchOne(db, sql: "SELECT key FROM sticker_packs WHERE id = ?", arguments: [packId]) else { return nil }
            return (l, key)
        }), let localKey = Data(base64Encoded: local.localKey) else { throw StickerError.unknownSticker }
        let data = try AttachmentCipher.decryptLocal(services.store.read(local.path), localKey: localKey, size: local.size)
        let contentType = Stickers.sniffContentType(data) ?? "image/webp"
        if contentType == "image/webp" { try sanitizeWebp(input: SignalInputStreamAdapter(data)) }
        var a = MessageAttachment(contentType: contentType, size: data.count)
        a.clientUuid = UUID().uuidString.lowercased()
        let stored = try services.store.storeLocally(data)
        a.path = stored.path
        a.localKey = stored.localKey.base64EncodedString()
        a.plaintextHash = stored.plaintextHash
        a.version = 2
        a.width = local.width
        a.height = local.height
        if let info = try? await services.media?.imageInfo(data).validated() {
            a.width = info.width
            a.height = info.height
            a.blurHash = info.blurHash
        }
        let sentAt = timestamp ?? UInt64(MessageStore.now())
        let prepared = a
        let ourAci = account.aci, ourDevice = account.deviceId
        let id = try await database.pool.write { db -> String in
            let conversationId: String
            if let masterKey { conversationId = try MessageStore.groupConversation(db, masterKey: masterKey).id } else if let serviceId {
                conversationId = try MessageStore.privateConversation(db, serviceId: serviceId)
            } else { throw JobError.permanent("no recipient") }
            var sticker: [String: Any] = ["packId": packId, "stickerId": stickerId, "packKey": packKey]
            if let emoji = local.emoji { sticker["emoji"] = emoji }
            let messageId = try MessageStore.insert(db, .init(
                conversationId: conversationId, type: "outgoing", body: "", sentAt: sentAt, source: ourAci, sourceDevice: ourDevice, serverGuid: nil,
                serverTimestamp: nil, unidentified: false,
                extra: ["sticker": sticker, "sendStateByConversationId": [conversationId: ["status": "Pending", "updatedAt": MessageStore.now()]]]))
            let receivedAt = try Int64.fetchOne(db, sql: "SELECT received_at FROM messages WHERE id = ?", arguments: [messageId]) ?? MessageStore.now()
            try MessageAttachments.upsert(db, .init(messageId: messageId, type: .sticker, order: 0), conversationId: conversationId, sentAt: Int64(sentAt),
                                          receivedAt: receivedAt, messageType: "outgoing", prepared)
            try MessageAttachments.updateMessageFlags(db, messageId: messageId)
            try Stickers.savePackMetadata(db, packId: packId, packKey: packKey, messageId: messageId, stickerId: stickerId)
            // useSticker: recents
            try db.execute(sql: "UPDATE stickers SET lastUsed = ? WHERE packId = ? AND id = ?", arguments: [MessageStore.now(), packId, stickerId])
            try db.execute(sql: "UPDATE sticker_packs SET lastUsed = ? WHERE id = ?", arguments: [MessageStore.now(), packId])
            if masterKey == nil { try MessageStore.setProfileSharing(db, conversationId: conversationId) }
            try JobQueue.insert(db, queueType: ConversationJob.queueType, payload: ConversationJob.normalMessage(conversationId: conversationId, messageId: messageId))
            return messageId
        }
        jobs.poke()
        return (id, sentAt)
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
            } catch SendError.untrustedIdentities {
                continue   // upstream cancels receipts to an untrusted identity
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

    /// `sendStickerPackSync`
    func sendStickerPackSync(_ job: ConversationJob) async throws {
        guard let op = job.stickerPack, let id = Data(hex: op.packId), let key = Data(base64Encoded: op.packKey) else { throw JobError.permanent("malformed job") }
        var o = Signalservice_SyncMessage.StickerPackOperation()
        o.packID = id
        o.packKey = key
        o.type = op.install ? .install : .remove
        var sync = Self.syncMessage()
        sync.stickerPackOperation = [o]
        try await sendToSelf(sync, timestamp: UInt64(MessageStore.now()), urgent: false, messageIds: [])
    }

    func sendFetchLatest(_ job: ConversationJob) async throws {
        for raw in job.requestTypes ?? [] {
            guard let type = Signalservice_SyncMessage.FetchLatest.TypeEnum(rawValue: raw) else { continue }
            var fetch = Signalservice_SyncMessage.FetchLatest()
            fetch.type = type
            var sync = Self.syncMessage()
            sync.fetchLatest = fetch
            try await sendToSelf(sync, timestamp: UInt64(MessageStore.now()), urgent: false, messageIds: [])
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
        let answered = retries.count(requester: requester, deviceId: device, timestamp: timestamp)
        guard answered < SendLog.retryLimit else { return }
        let ourAci = account.aci
        let answer = try await database.pool.write { db -> SendLog.ResendAnswer in
            if job.wasSenderKey != true, let ratchetKey {
                let address = try ProtocolAddress(name: requester, deviceId: device)
                let ctx = DatabaseStoreContext(db)
                if let session = try self.sender.store.loadSession(for: address, context: ctx), try session.currentRatchetKeyMatches(ratchetKey) {
                    session.archiveCurrentState()
                    try self.sender.store.storeSession(session, for: address, context: ctx)
                }
            }
            return try SendLog.answer(db, requester: requester, deviceId: device, timestamp: timestamp, answered: answered, ourAci: ourAci)
        }
        switch answer {
        case .resend(let logged):
            try await sender.send(logged.payload(for: requester, device: device), to: requester, messageIds: logged.messageIds, logged: false)
        case .nothing:
            return
        case .nullMessage:
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

/// A view-once send that is not eligible (`isViewOnceEligible`).
public enum ViewOnceSendError: Error, Equatable {
    /// Not exactly one image or video, or a reply.
    case ineligible
}

/// A contact that cannot be shared (`canShareContact`).
public enum SharedContactError: Error, Equatable {
    case needsNameAndAciOrNumber
}
