// Receive pipeline (port of Desktop MessageReceiver.preload.ts, Phase 2a scope).
//
//   envelope ─► cache in `unprocessed` (commit) ─► ack ─► one write transaction {
//       unseal (sealed sender, certificate checked against the trust roots)
//       decrypt (1:1 whisper / prekey, sender-key, plaintext)
//       unpad, parse Content, dispatch + persist
//       queue follow-up jobs (delivery receipt, resend, contact sync, storage fetch)
//       delete the `unprocessed` row
//   } ─► wake the job queue, emit events
//
// Any failure rolls the transaction back, so session/sender-key state never advances
// without the decrypted result being stored (Desktop's withZone semantics).

import Foundation
import GRDB
import LibSignalClient
import SignalProtos

public enum ReceiveError: Error, Equatable {
    case invalidEnvelope(String)
    case invalidSenderCertificate
    case invalidPadding
    case fromSelf
    case unsupported(String)
}

/// libsignal's ack closure only captures the (thread-safe, Sendable) chat connection
/// handle and an ack id, so it may be called from the receiver queue.
struct ServerAck: @unchecked Sendable { let send: () throws -> Void }

public final class MessageReceiver: ChatConnectionListener, @unchecked Sendable {
    let account: Account
    let database: SignalDatabase
    let trustRoots: [PublicKey]
    let aciStore: ProtocolStore
    let pniStore: ProtocolStore?
    let queue = DispatchQueue(label: "org.signalsafe.MessageReceiver")
    /// Follow-up jobs are inserted in the receive transaction; the queue is woken after commit.
    let jobs: JobQueue?

    public let events: AsyncStream<ReceiveEvent>
    let continuation: AsyncStream<ReceiveEvent>.Continuation

    public init(account: Account, database: SignalDatabase, trustRoots: [PublicKey], jobs: JobQueue? = nil) {
        self.account = account
        self.jobs = jobs
        self.database = database
        self.trustRoots = trustRoots
        aciStore = account.aciStore()
        pniStore = account.pniStore()
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    func emit(_ e: ReceiveEvent) { continuation.yield(e) }

    // MARK: ChatConnectionListener

    public func chatConnection(_ chat: AuthenticatedChatConnection, didReceiveIncomingMessage envelope: Data, serverDeliveryTimestamp: UInt64,
                               sendAck: @escaping () throws -> Void) {
        let ack = ServerAck(send: sendAck)
        queue.async { self.handleIncoming(envelope, serverDeliveryTimestamp: serverDeliveryTimestamp, sendAck: ack.send) }
    }

    public func chatConnectionDidReceiveQueueEmpty(_ chat: AuthenticatedChatConnection) {
        queue.async { self.emit(.queueEmpty) }
    }

    public func connectionWasInterrupted(_ service: AuthenticatedChatConnection, error: Error?) {}

    /// Processes envelopes cached by a previous run (crash between ack and commit).
    public func processCached() {
        queue.async {
            let rows = (try? self.database.pool.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM unprocessed ORDER BY receivedAtCounter")
            }) ?? []
            for row in rows { self.process(id: row["id"], envelope: Self.envelope(from: row)) }
        }
    }

    // MARK: pipeline

    func handleIncoming(_ bytes: Data, serverDeliveryTimestamp: UInt64, sendAck: @escaping () throws -> Void) {
        let envelope: Signalservice_Envelope
        do {
            envelope = try Signalservice_Envelope(serializedBytes: bytes)
        } catch {
            try? sendAck()   // unparseable: never deliverable
            emit(.failed(serverGuid: "", reason: "envelope: \(error)"))
            return
        }
        let id: String
        do {
            id = try database.pool.write { db in try self.cache(envelope, db) }
        } catch {
            // Not acked: the server redelivers it on the next connection.
            emit(.failed(serverGuid: envelope.serverGuid, reason: "cache: \(error)"))
            return
        }
        try? sendAck()
        process(id: id, envelope: envelope)
    }

    func process(id: String, envelope: Signalservice_Envelope) {
        do {
            let events = try database.pool.write { db -> [ReceiveEvent] in
                let events = try self.decryptAndDispatch(envelope, db)
                try db.execute(sql: "DELETE FROM unprocessed WHERE id = ?", arguments: [id])
                return events
            }
            jobs?.poke()
            events.forEach(emit)
        } catch {
            try? database.pool.write { db in try db.execute(sql: "DELETE FROM unprocessed WHERE id = ?", arguments: [id]) }
            emit(.failed(serverGuid: envelope.serverGuid, reason: "\(error)"))
        }
    }

    // MARK: unprocessed cache

    func cache(_ e: Signalservice_Envelope, _ db: Database) throws -> String {
        let id = UUID().uuidString.lowercased()
        let counter = try MessageStore.nextReceivedAt(db)
        try db.execute(
            sql: """
                INSERT INTO unprocessed (id, type, timestamp, attempts, receivedAtCounter, urgent, story, serverGuid, serverTimestamp,
                    isEncrypted, content, messageAgeSec, destinationServiceId, sourceServiceId, sourceDevice, receivedAtDate)
                VALUES (?, ?, ?, 1, ?, ?, ?, ?, ?, 1, ?, 0, ?, ?, ?, ?)
                """,
            arguments: [id, e.type.rawValue, Int64(e.clientTimestamp), counter, e.hasUrgent ? e.urgent : true, e.story, e.serverGuid,
                        Int64(e.serverTimestamp), e.content, Self.destination(e) ?? account.aci, Self.source(e), e.hasSourceDeviceID ? Int(e.sourceDeviceID) : nil,
                        MessageStore.now()])
        return id
    }

    static func envelope(from row: Row) -> Signalservice_Envelope {
        var e = Signalservice_Envelope()
        e.type = Signalservice_Envelope.TypeEnum(rawValue: row["type"]) ?? .unknown
        e.clientTimestamp = UInt64(row["timestamp"] as Int64)
        e.serverGuid = row["serverGuid"]
        e.serverTimestamp = UInt64(row["serverTimestamp"] as Int64)
        e.content = row["content"]
        e.destinationServiceID = row["destinationServiceId"]
        if let s: String = row["sourceServiceId"] { e.sourceServiceID = s }
        if let d: Int = row["sourceDevice"] { e.sourceDeviceID = UInt32(d) }
        e.urgent = row["urgent"]
        e.story = row["story"]
        return e
    }

    static func serviceIdString(binary: Data?, string: String?) -> String? {
        if let b = binary, !b.isEmpty, let s = try? ServiceId.parseFrom(serviceIdBinary: b) { return s.serviceIdString }
        if let s = string, !s.isEmpty, let id = try? ServiceId.parseFrom(serviceIdString: s) { return id.serviceIdString }
        return nil
    }
    static func source(_ e: Signalservice_Envelope) -> String? {
        serviceIdString(binary: e.hasSourceServiceIDBinary ? e.sourceServiceIDBinary : nil, string: e.hasSourceServiceID ? e.sourceServiceID : nil)
    }
    static func destination(_ e: Signalservice_Envelope) -> String? {
        serviceIdString(binary: e.hasDestinationServiceIDBinary ? e.destinationServiceIDBinary : nil,
                        string: e.hasDestinationServiceID ? e.destinationServiceID : nil)
    }

    // MARK: decrypt

    struct Decrypted {
        var sender: String
        var senderDevice: UInt32
        var content: Signalservice_Content
        var sealed: Bool
        var groupId: Data?
    }

    func decryptAndDispatch(_ e: Signalservice_Envelope, _ db: Database) throws -> [ReceiveEvent] {
        if e.type == .serverDeliveryReceipt { return [.serverDeliveryReceipt(timestamp: e.clientTimestamp)] }
        let decrypted = try decrypt(e, db)
        return try dispatch(decrypted, envelope: e, db)
    }

    func decrypt(_ e: Signalservice_Envelope, _ db: Database) throws -> Decrypted {
        let ctx = DatabaseStoreContext(db)
        let destination = Self.destination(e) ?? account.aci
        let store: ProtocolStore
        if let pniStore, destination == pniStore.ourServiceId { store = pniStore } else if destination == account.aci { store = aciStore } else {
            throw ReceiveError.invalidEnvelope("destination \(destination)")
        }
        let local = try ProtocolAddress(name: store.ourServiceId, deviceId: account.deviceId)
        guard e.hasContent else { throw ReceiveError.invalidEnvelope("no content") }

        switch e.type {
        case .unidentifiedSender:
            let usmc = try UnidentifiedSenderMessageContent(message: e.content, identityStore: store, context: ctx)
            let certificate = usmc.senderCertificate
            guard certificate.validate(trustRoots: trustRoots, time: e.serverTimestamp) else { throw ReceiveError.invalidSenderCertificate }
            let sender = certificate.senderUuid.lowercased()
            let device = certificate.deviceId
            if sender == account.aci, device == account.deviceId { throw ReceiveError.fromSelf }
            let from = try ProtocolAddress(name: sender, deviceId: device)
            let plaintext = try decryptInner(type: usmc.messageType, usmc.contents, from: from, local: local, store: store, ctx)
            return Decrypted(sender: sender, senderDevice: device, content: try parseContent(plaintext), sealed: true, groupId: usmc.groupId)
        case .doubleRatchet, .prekeyMessage, .plaintextContent:
            guard let sender = Self.source(e), e.hasSourceDeviceID else { throw ReceiveError.invalidEnvelope("missing source") }
            let from = try ProtocolAddress(name: sender, deviceId: e.sourceDeviceID)
            let type: CiphertextMessage.MessageType = e.type == .doubleRatchet ? .whisper : e.type == .prekeyMessage ? .preKey : .plaintext
            let plaintext = try decryptInner(type: type, e.content, from: from, local: local, store: store, ctx)
            return Decrypted(sender: sender, senderDevice: e.sourceDeviceID, content: try parseContent(plaintext), sealed: false, groupId: nil)
        default:
            throw ReceiveError.unsupported("envelope type \(e.type.rawValue)")
        }
    }

    func decryptInner(type: CiphertextMessage.MessageType, _ bytes: Data, from: ProtocolAddress, local: ProtocolAddress, store: ProtocolStore,
                      _ ctx: DatabaseStoreContext) throws -> Data {
        switch type {
        case .whisper:
            return try signalDecrypt(message: SignalMessage(bytes: bytes), from: from, to: local, sessionStore: store, identityStore: store, context: ctx)
        case .preKey:
            return try signalDecryptPreKey(message: PreKeySignalMessage(bytes: bytes), from: from, localAddress: local, sessionStore: store,
                                           identityStore: store, preKeyStore: store, signedPreKeyStore: store, kyberPreKeyStore: store, context: ctx)
        case .senderKey:
            return try groupDecrypt(bytes, from: from, store: store, context: ctx)
        case .plaintext:
            return try PlaintextContent(bytes: bytes).body
        default:
            throw ReceiveError.unsupported("ciphertext type \(type)")
        }
    }

    func parseContent(_ padded: Data) throws -> Signalservice_Content {
        try Signalservice_Content(serializedBytes: Self.unpad(padded))
    }

    /// Signal transport padding: plaintext ‖ 0x80 ‖ 0x00*.
    static func unpad(_ data: Data) throws -> Data {
        var end = data.endIndex
        while end > data.startIndex {
            let b = data[end - 1]
            if b == 0x80 { return data[data.startIndex..<(end - 1)] }
            guard b == 0 else { throw ReceiveError.invalidPadding }
            end -= 1
        }
        throw ReceiveError.invalidPadding
    }

    // MARK: dispatch

    func dispatch(_ d: Decrypted, envelope e: Signalservice_Envelope, _ db: Database) throws -> [ReceiveEvent] {
        var events: [ReceiveEvent] = []
        let ctx = DatabaseStoreContext(db)
        let c = d.content
        if c.hasSenderKeyDistributionMessage {
            let skdm = try SenderKeyDistributionMessage(bytes: c.senderKeyDistributionMessage)
            try processSenderKeyDistributionMessage(skdm, from: try ProtocolAddress(name: d.sender, deviceId: d.senderDevice), store: aciStore, context: ctx)
            events.append(.senderKeyDistribution(sender: d.sender, senderDevice: d.senderDevice, distributionId: skdm.distributionId))
        }
        let fromOurDevice = d.sender == account.aci

        switch c.content {
        case .dataMessage(let m):
            if fromOurDevice { throw ReceiveError.invalidEnvelope("DataMessage from our own account") }
            events += try handleDataMessage(m, d, e, db)
        case .syncMessage(let s):
            guard fromOurDevice else { throw ReceiveError.invalidEnvelope("SyncMessage from \(d.sender)") }
            events += try handleSyncMessage(s, d, db)
        case .receiptMessage(let r):
            let kind: ReceiptKind = r.type == .read ? .read : r.type == .viewed ? .viewed : .delivery
            let n = try MessageStore.applyReceipt(db, kind: kind, from: d.sender, timestamps: r.timestamp)
            events.append(.receipt(kind: kind, sender: d.sender, timestamps: r.timestamp, updatedMessages: n))
        case .typingMessage(let t):
            events.append(.typing(sender: d.sender, started: t.action == .started, timestamp: t.timestamp, groupId: t.hasGroupID ? t.groupID : nil))
        case .editMessage(let edit):
            guard edit.hasDataMessage else { throw ReceiveError.invalidEnvelope("EditMessage without dataMessage") }
            let conversation = edit.dataMessage.hasGroupV2 && edit.dataMessage.groupV2.hasMasterKey
                ? try MessageStore.groupConversation(db, masterKey: edit.dataMessage.groupV2.masterKey).id
                : try MessageStore.privateConversation(db, serviceId: d.sender)
            let ctx = ModifierContext(sender: d.sender, timestamp: edit.dataMessage.timestamp, serverTimestamp: e.serverTimestamp, conversationId: conversation,
                                      source: .someoneElse)
            let pending = PendingModifier(kind: .edit, targetAuthor: d.sender, targetSentAt: edit.targetSentTimestamp, context: ctx,
                                          payload: try edit.serializedBytes(), storedAt: MessageStore.now())
            if let id = try MessageModifiers.apply(db, pending, ourAci: account.aci) {
                events.append(.edit(messageId: id, sender: d.sender, targetTimestamp: edit.targetSentTimestamp, body: edit.dataMessage.body))
            }
        case .decryptionErrorMessage(let bytes):
            let dem = try DecryptionErrorMessage(bytes: bytes)
            // Only errors about a message this device sent can be answered from our send log.
            if dem.deviceId == account.deviceId {
                let ratchetKey = dem.ratchetKey?.serialize()
                try JobQueue.insert(db, queueType: ConversationJob.queueType,
                                    payload: ConversationJob.resend(requester: d.sender, device: d.senderDevice, timestamp: dem.timestamp,
                                                                    ratchetKey: ratchetKey, wasSenderKey: ratchetKey == nil))
            }
            events.append(.decryptionErrorReported(sender: d.sender, senderDevice: d.senderDevice, timestamp: dem.timestamp, deviceId: dem.deviceId))
        case .storyMessage: events.append(.other(kind: "story", sender: d.sender))
        case .callMessage(let call):
            // Signalling is handled by CallingService (handleCallingMessage); nothing is stored.
            let destination = Self.destination(e) ?? account.aci
            events.append(.callMessage(CallMessageEnvelope(sender: d.sender, senderDevice: d.senderDevice,
                                                           destinationIsPni: pniStore.map { destination == $0.ourServiceId } ?? false,
                                                           timestamp: e.clientTimestamp, serverTimestamp: e.serverTimestamp, receivedAt: MessageStore.now(),
                                                           serverGuid: e.serverGuid, message: call)))
        case .nullMessage: events.append(.other(kind: "null", sender: d.sender))
        case .none:
            if !c.hasSenderKeyDistributionMessage && !c.hasPniSignatureMessage { throw ReceiveError.invalidEnvelope("empty Content") }
        }
        return events
    }

    func handleDataMessage(_ m: Signalservice_DataMessage, _ d: Decrypted, _ e: Signalservice_Envelope, _ db: Database) throws -> [ReceiveEvent] {
        guard m.timestamp == e.clientTimestamp || !e.hasClientTimestamp else {
            throw ReceiveError.invalidEnvelope("timestamp mismatch \(m.timestamp) != \(e.clientTimestamp)")
        }
        if try MessageStore.find(db, author: d.sender, sentAt: m.timestamp) != nil { return [] }   // duplicate
        let conversation: String
        var groupId: Data? = nil
        var events: [ReceiveEvent] = []
        if m.hasGroupV2, m.groupV2.hasMasterKey {
            guard m.groupV2.masterKey.count == 32 else { throw ReceiveError.invalidEnvelope("bad group master key") }
            let g = try MessageStore.groupConversation(db, masterKey: m.groupV2.masterKey)
            conversation = g.id
            groupId = g.groupId
            events.append(.groupContext(masterKey: m.groupV2.masterKey, revision: Int(m.groupV2.revision),
                                        groupChange: m.groupV2.hasGroupChange ? m.groupV2.groupChange : nil, sender: d.sender, timestamp: m.timestamp))
            // A group update (a change and nothing else) is not a chat message (`isGroupUpdate`).
            if m.groupV2.hasGroupChange && m.body.isEmpty && m.attachments.isEmpty && !m.hasQuote && !m.hasSticker && m.contact.isEmpty {
                if m.hasProfileKey { try MessageStore.setProfileKey(db, serviceId: d.sender, m.profileKey) }
                return events
            }
        } else {
            conversation = try MessageStore.privateConversation(db, serviceId: d.sender)
        }
        // Blocked contacts and groups (MessageReceiver isBlocked / isGroupBlocked): dropped.
        if try MessageModifiers.isBlocked(db, conversationId: conversation, sender: d.sender) { return [] }
        if m.hasProfileKey { try MessageStore.setProfileKey(db, serviceId: d.sender, m.profileKey) }
        let isGroupMessage = m.hasGroupV2 && m.groupV2.hasMasterKey
        // Timer and profile-key updates are not chat messages.
        if m.flags & ConversationState.expirationTimerUpdateFlag != 0 {
            try ConversationState.applyIncomingTimer(db, conversationId: conversation, seconds: m.expireTimer, version: m.expireTimerVersion, from: d.sender,
                                                     sentAt: m.timestamp, isGroup: isGroupMessage, isUpdate: true)
            return events + [.other(kind: "timerUpdate:\(m.timestamp)", sender: d.sender)]
        }
        if m.flags & ConversationState.profileKeyUpdateFlag != 0 { return events + [.other(kind: "profileKeyUpdate:\(m.timestamp)", sender: d.sender)] }
        if m.hasExpireTimer || m.hasExpireTimerVersion {
            try ConversationState.applyIncomingTimer(db, conversationId: conversation, seconds: m.expireTimer, version: m.expireTimerVersion, from: d.sender,
                                                     sentAt: m.timestamp, isGroup: isGroupMessage, isUpdate: false)
        }
        let ctx = ModifierContext(sender: d.sender, timestamp: m.timestamp, serverTimestamp: e.serverTimestamp, conversationId: conversation, source: .someoneElse)
        let mods = try MessageModifiers.modifiers(of: m, context: ctx)
        if !mods.isEmpty {
            for mod in mods { try MessageModifiers.apply(db, mod, ourAci: account.aci) }
            // A pin also makes a message of its own (the notification), others none.
            return events + [.other(kind: "modifier:\(m.timestamp)", sender: d.sender)]
        }
        var extra: [String: Any] = [:]
        if m.isViewOnce { extra["isViewOnce"] = true }
        if m.hasPollCreate, let poll = MessageModifiers.pollJSON(m.pollCreate) { extra["poll"] = poll }
        let id = try MessageStore.insert(db, .init(conversationId: conversation, type: "incoming", body: m.body, sentAt: m.timestamp,
                                                   source: d.sender, sourceDevice: d.senderDevice, serverGuid: e.serverGuid,
                                                   serverTimestamp: e.serverTimestamp, unidentified: d.sealed, extra: extra))
        try MessageStore.storeIncomingAttachments(db, messageId: id, conversationId: conversation, sentAt: Int64(m.timestamp),
                                                  attachments: m.attachments)
        if m.hasSticker {
            try MessageStore.storeSticker(db, messageId: id, conversationId: conversation, sentAt: Int64(m.timestamp), messageType: "incoming", m.sticker)
        }
        try MessageStore.storePreviews(db, messageId: id, conversationId: conversation, sentAt: Int64(m.timestamp), messageType: "incoming",
                                       body: m.body, m.preview)
        // The message's own timer starts when it is read.
        try ConversationState.setMessageTimer(db, messageId: id, seconds: m.expireTimer, startedAt: nil)
        try MessageModifiers.applyPending(db, author: d.sender, sentAt: m.timestamp, ourAci: account.aci)
        // Delivery receipt (Desktop sends one for every delivered message), committed with the message.
        try JobQueue.insert(db, queueType: ConversationJob.queueType, payload: ConversationJob.receipts(
            .delivery, [ReceiptTarget(messageId: id, conversationId: conversation, senderAci: d.sender, timestamp: m.timestamp)]))
        return events + [.message(messageId: id, conversationId: conversation, sender: d.sender, senderDevice: d.senderDevice, timestamp: m.timestamp,
                                  body: m.body, sealed: d.sealed, groupId: groupId ?? d.groupId)]
    }

    func handleSyncMessage(_ s: Signalservice_SyncMessage, _ d: Decrypted, _ db: Database) throws -> [ReceiveEvent] {
        var events: [ReceiveEvent] = []
        if case .viewOnceOpen(let v)? = s.content, let author = MessageModifiers.aci(v.senderAciBinary, v.senderAci) {
            let ctx = ModifierContext(sender: account.aci, timestamp: v.timestamp, serverTimestamp: 0, conversationId: "", source: .sync)
            try MessageModifiers.apply(db, PendingModifier(kind: .viewOnceOpen, targetAuthor: author, targetSentAt: v.timestamp, context: ctx,
                                                           payload: Data(), storedAt: MessageStore.now()), ourAci: account.aci)
            events.append(.sync(kind: "viewOnceOpen", senderDevice: d.senderDevice))
        }
        if case .messageRequestResponse(let r)? = s.content, let type = MessageRequestResponse(rawValue: r.type.rawValue) {
            var conversation: String? = nil
            if r.hasGroupID {
                conversation = try String.fetchOne(db, sql: "SELECT id FROM conversations WHERE groupId = ?", arguments: [r.groupID.base64EncodedString()])
            } else if let aci = MessageModifiers.aci(r.threadAciBinary, r.threadAci) {
                conversation = try MessageStore.privateConversation(db, serviceId: aci)
            }
            if let conversation { try ConversationState.applyResponse(db, conversationId: conversation, type, ourAci: account.aci) }
            events.append(.sync(kind: "messageRequestResponse", senderDevice: d.senderDevice))
        }
        if case .verified(let v)? = s.content {
            try Identity.applyVerifiedSync(db, v, account: account)
            events.append(.sync(kind: "verified", senderDevice: d.senderDevice))
        }
        if case .deleteForMe(let dfm)? = s.content {
            try DeleteForMe.apply(db, dfm, ourAci: account.aci)
            events.append(.sync(kind: "deleteForMe", senderDevice: d.senderDevice))
        }
        // StickerPackOperation (install / remove on another of our devices).
        for op in s.stickerPackOperation where op.packID.count == 16 {
            try JobQueue.insert(db, queueType: StickerPackOperationJob.queueType,
                                payload: StickerPackOperationJob(packId: op.packID.hexString, packKey: op.packKey.base64EncodedString(),
                                                                 install: op.type == .install))
            events.append(.sync(kind: "stickerPackOperation", senderDevice: d.senderDevice))
        }
        for r in s.read {
            guard let sender = Self.serviceIdString(binary: r.hasSenderAciBinary ? r.senderAciBinary : nil, string: r.hasSenderAci ? r.senderAci : nil) else { continue }
            _ = try MessageStore.applyReadSync(db, sender: sender, timestamp: r.timestamp, viewed: false)
        }
        for v in s.viewed {
            guard let sender = Self.serviceIdString(binary: v.hasSenderAciBinary ? v.senderAciBinary : nil, string: v.hasSenderAci ? v.senderAci : nil) else { continue }
            _ = try MessageStore.applyReadSync(db, sender: sender, timestamp: v.timestamp, viewed: true)
        }
        if !s.read.isEmpty { events.append(.sync(kind: "read", senderDevice: d.senderDevice)) }
        if !s.viewed.isEmpty { events.append(.sync(kind: "viewed", senderDevice: d.senderDevice)) }

        switch s.content {
        case .contacts(let c):
            if c.hasBlob {
                try JobQueue.insert(db, queueType: ContactSync.queueType,
                                    payload: ContactSync.Job(pointer: try c.blob.serializedBytes() as Data, complete: c.complete))
            }
            return events + [.sync(kind: "contacts", senderDevice: d.senderDevice)]
        case .configuration(let c):
            if c.hasReadReceipts { try Items.set(db, "read-receipt-setting", c.readReceipts) }
            if c.hasTypingIndicators { try Items.set(db, "typingIndicators", c.typingIndicators) }
            if c.hasLinkPreviews { try Items.set(db, "linkPreviews", c.linkPreviews) }
            if c.hasUnidentifiedDeliveryIndicators { try Items.set(db, "sealedSenderIndicators", c.unidentifiedDeliveryIndicators) }
            return events + [.sync(kind: "configuration", senderDevice: d.senderDevice)]
        case .keys(let k):
            if k.hasAccountEntropyPool, AccountEntropyPool.isValid(k.accountEntropyPool) {
                try Items.set(db, "accountEntropyPool", k.accountEntropyPool)
                try Items.set(db, "masterKey", try AccountEntropyPool.deriveSvrKey(k.accountEntropyPool).base64EncodedString())
            } else if k.hasMaster, k.master.count == 32 {
                try Items.set(db, "masterKey", k.master.base64EncodedString())
            }
            if k.hasMediaRootBackupKey { try Items.set(db, "backupMediaRootKey", k.mediaRootBackupKey.base64EncodedString()) }
            // `syncAfterNewKey`: storage written under the new key is fetched again.
            if k.hasAccountEntropyPool || k.hasMaster { try JobQueue.insert(db, queueType: StorageService.queueType, payload: StorageService.Job()) }
            return events + [.sync(kind: "keys", senderDevice: d.senderDevice)]
        case .fetchLatest(let f):
            if f.type == .storageManifest { try JobQueue.insert(db, queueType: StorageService.queueType, payload: StorageService.Job()) }
            return events + [.sync(kind: "fetchLatest", senderDevice: d.senderDevice)]
        case .callEvent(let ce):
            // `onCallEventSync`: a call on another of our devices (updateCallHistoryFromRemoteEvent).
            if let details = try? CallHistoryProto.details(ce, eventSource: "onCallEventSync", eventTimestamp: MessageStore.now()) {
                try CallHistoryStore.apply(db, details)
            }
            return events + [.callHistoryChanged, .sync(kind: "callEvent", senderDevice: d.senderDevice)]
        case .callLogEvent(let le):
            try CallHistoryStore.applyLogEvent(db, le, now: MessageStore.now())
            return events + [.callHistoryChanged, .sync(kind: "callLogEvent", senderDevice: d.senderDevice)]
        case .callLinkUpdate(let u):
            // `onCallLinkUpdateSync`
            // (Type DELETE was superseded by the storage service.)
            guard u.hasRootKey, u.rootKey.count >= 16 else { return events + [.sync(kind: "callLinkUpdate", senderDevice: d.senderDevice)] }
            try CallLinkStore.applyUpdateSync(db, rootKey: u.rootKey, adminKey: u.hasAdminPasskey && !u.adminPasskey.isEmpty ? u.adminPasskey : nil,
                                              now: MessageStore.now())
            return events + [.callHistoryChanged, .sync(kind: "callLinkUpdate", senderDevice: d.senderDevice)]
        case .blocked(let b):
            try BlockedList.numbers.replaceAll(db, b.numbers)
            try BlockedList.serviceIds.replaceAll(db, b.acisBinary.compactMap { Self.serviceIdString(binary: $0, string: nil) } + b.acis)
            try BlockedList.groups.replaceAll(db, b.groupIds.map { $0.base64EncodedString() })
            return events + [.sync(kind: "blocked", senderDevice: d.senderDevice)]
        case .sent(let sent):
            let destination = Self.serviceIdString(binary: sent.hasDestinationServiceIDBinary ? sent.destinationServiceIDBinary : nil,
                                                   string: sent.hasDestinationServiceID ? sent.destinationServiceID : nil)
            if sent.hasEditMessage, sent.editMessage.hasDataMessage {
                let em = sent.editMessage.dataMessage
                let conv = em.hasGroupV2 && em.groupV2.hasMasterKey ? try MessageStore.groupConversation(db, masterKey: em.groupV2.masterKey).id
                    : try destination.map { try MessageStore.privateConversation(db, serviceId: $0) } ?? ""
                let ctx = ModifierContext(sender: account.aci, timestamp: em.timestamp, serverTimestamp: 0, conversationId: conv, source: .sync)
                try MessageModifiers.apply(db, PendingModifier(kind: .edit, targetAuthor: account.aci, targetSentAt: sent.editMessage.targetSentTimestamp,
                                                               context: ctx, payload: try sent.editMessage.serializedBytes(), storedAt: MessageStore.now()),
                                           ourAci: account.aci)
                return [.sync(kind: "sentEdit", senderDevice: d.senderDevice)]
            }
            guard sent.hasMessage else { return [.sync(kind: "sent", senderDevice: d.senderDevice)] }
            let m = sent.message
            let conversation: String
            if m.hasGroupV2, m.groupV2.hasMasterKey {
                conversation = try MessageStore.groupConversation(db, masterKey: m.groupV2.masterKey).id
            } else if let destination {
                conversation = try MessageStore.privateConversation(db, serviceId: destination)
            } else {
                throw ReceiveError.invalidEnvelope("sent transcript without destination")
            }
            if try MessageStore.find(db, author: account.aci, sentAt: sent.timestamp) != nil { return [] }
            if m.flags & ConversationState.expirationTimerUpdateFlag != 0 {
                try ConversationState.applyIncomingTimer(db, conversationId: conversation, seconds: m.expireTimer, version: m.expireTimerVersion,
                                                         from: account.aci, sentAt: sent.timestamp, isGroup: m.hasGroupV2, isUpdate: true)
                return [.sync(kind: "sentTimer", senderDevice: d.senderDevice)]
            }
            let syncCtx = ModifierContext(sender: account.aci, timestamp: sent.timestamp, serverTimestamp: 0, conversationId: conversation, source: .sync)
            let syncMods = try MessageModifiers.modifiers(of: m, context: syncCtx)
            if !syncMods.isEmpty {
                for mod in syncMods { try MessageModifiers.apply(db, mod, ourAci: account.aci) }
                return [.sync(kind: "sentModifier", senderDevice: d.senderDevice)]
            }
            var sendState: [String: Any] = [:]
            if let destination, !(m.hasGroupV2) {
                sendState[conversation] = ["status": "Sent", "updatedAt": MessageStore.now()]
                _ = destination
            }
            let id = try MessageStore.insert(db, .init(conversationId: conversation, type: "outgoing", body: m.body, sentAt: sent.timestamp,
                                                       source: account.aci, sourceDevice: d.senderDevice, serverGuid: nil, serverTimestamp: nil,
                                                       unidentified: false,
                                                       extra: ["sendStateByConversationId": sendState,
                                                               "expirationStartTimestamp": sent.hasExpirationStartTimestamp ? sent.expirationStartTimestamp : sent.timestamp]
                                                           .merging(m.isViewOnce ? ["isViewOnce": true] : [:]) { a, _ in a }
                                                           .merging(m.hasPollCreate ? ["poll": MessageModifiers.pollJSON(m.pollCreate) as Any] : [:]) { a, _ in a }))
            if m.hasSticker {
                try MessageStore.storeSticker(db, messageId: id, conversationId: conversation, sentAt: Int64(sent.timestamp), messageType: "outgoing", m.sticker)
            }
            try MessageStore.storePreviews(db, messageId: id, conversationId: conversation, sentAt: Int64(sent.timestamp), messageType: "outgoing",
                                           body: m.body, m.preview)
            try MessageStore.storeIncomingAttachments(db, messageId: id, conversationId: conversation, sentAt: Int64(sent.timestamp), attachments: m.attachments)
            try ConversationState.setMessageTimer(db, messageId: id, seconds: m.expireTimer,
                                                  startedAt: Int64(sent.hasExpirationStartTimestamp ? sent.expirationStartTimestamp : sent.timestamp))
            try MessageModifiers.applyPending(db, author: account.aci, sentAt: sent.timestamp, ourAci: account.aci)
            return [.sentTranscript(messageId: id, conversationId: conversation, destination: destination ?? "", timestamp: sent.timestamp, body: m.body)]
        case .some(let other):
            return events + [.sync(kind: String(describing: other).components(separatedBy: "(").first ?? "unknown", senderDevice: d.senderDevice)]
        case .none:
            return events.isEmpty ? [.sync(kind: "empty", senderDevice: d.senderDevice)] : events
        }
    }
}
