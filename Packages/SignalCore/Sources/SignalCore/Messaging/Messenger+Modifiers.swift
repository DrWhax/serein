// Outgoing modifiers: reactions, delete for everyone / admin delete, delete for me, edits, polls,
// pins, view-once opens. Each is applied locally first (as a modifier from this device), then a
// `ModifierSend` job sends the DataMessage (or EditMessage) to the conversation and its
// transcript to our other devices (`conversationQueueJobEnum` Reaction, DeleteForEveryone,
// … in ts/jobs/conversationJobQueue).

import Foundation
import GRDB
import LibSignalClient
import SignalProtos

public enum ModifierError: Error, Equatable {
    case notFound
    case notAllowed(String)
}

extension ConversationJob {
    /// A prepared Content (DataMessage or EditMessage) for a conversation.
    static func modifierSend(conversationId: String, content: Data, timestamp: UInt64) -> Self {
        var j = Self(type: .modifierSend, conversationId: conversationId)
        j.content = content.base64EncodedString()
        j.timestamp = timestamp
        return j
    }
}

extension Messenger {
    struct TargetInfo: Sendable {
        var conversationId: String
        var author: String
        var sentAt: UInt64
        var type: String
        var serverTimestamp: Int64?
        var isGroup: Bool
        var masterKey: Data?
        var revision: Int?
    }

    func targetInfo(_ messageId: String) async throws -> TargetInfo {
        try await database.pool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT conversationId, sourceServiceId, sent_at, type, json FROM messages WHERE id = ?", arguments: [messageId]),
                  let author: String = row["sourceServiceId"] else { throw ModifierError.notFound }
            let json = try MessageStore.jsonObject(row["json"])
            let conversationId: String = row["conversationId"]
            let group = try GroupStore.load(db, conversationId: conversationId)
            return TargetInfo(conversationId: conversationId, author: author, sentAt: UInt64(row["sent_at"] as Int64), type: row["type"],
                              serverTimestamp: (json["serverTimestamp"] as? NSNumber)?.int64Value, isGroup: group != nil, masterKey: group?.keys.masterKey,
                              revision: group?.state?.revision)
        }
    }

    func baseDataMessage(_ t: TargetInfo, timestamp: UInt64) -> Signalservice_DataMessage {
        var data = Signalservice_DataMessage()
        data.timestamp = timestamp
        if let pk = account.profileKey { data.profileKey = pk }
        if let mk = t.masterKey {
            var ctx = Signalservice_GroupContextV2()
            ctx.masterKey = mk
            ctx.revision = UInt32(t.revision ?? 0)
            data.groupV2 = ctx
        }
        return data
    }

    /// Applies locally (as this device) and queues the send.
    func queueModifier(_ t: TargetInfo, data: Signalservice_DataMessage, local: [PendingModifier.Kind: Data]) async throws {
        var content = Signalservice_Content()
        content.dataMessage = data
        let payload = try content.serializedBytes() as Data
        let ourAci = account.aci
        try await database.pool.write { db in
            let ctx = ModifierContext(sender: ourAci, timestamp: data.timestamp, serverTimestamp: UInt64(MessageStore.now()), conversationId: t.conversationId,
                                      source: .thisDevice)
            for (kind, p) in local {
                try MessageModifiers.apply(db, PendingModifier(kind: kind, targetAuthor: t.author, targetSentAt: t.sentAt, context: ctx, payload: p,
                                                               storedAt: MessageStore.now()), ourAci: ourAci, keepIfMissing: false)
            }
            try JobQueue.insert(db, queueType: ConversationJob.queueType,
                                payload: ConversationJob.modifierSend(conversationId: t.conversationId, content: payload, timestamp: data.timestamp))
        }
        jobs.poke()
    }

    // MARK: reactions

    /// `enqueueReactionForSend`
    public func react(to messageId: String, emoji: String, remove: Bool = false, timestamp: UInt64? = nil) async throws {
        let t = try await targetInfo(messageId)
        var r = Signalservice_DataMessage.Reaction()
        r.emoji = emoji
        r.remove = remove
        r.targetAuthorAciBinary = StorageLocal.uuidBytes(t.author) ?? Data()
        r.targetSentTimestamp = t.sentAt
        var data = baseDataMessage(t, timestamp: timestamp ?? UInt64(MessageStore.now()))
        data.reaction = r
        try await queueModifier(t, data: data, local: [.reaction: try r.serializedBytes()])
    }

    // MARK: deletes

    /// `sendDeleteForEveryoneMessage`: our own message (or, as a group admin, anyone's) within
    /// the allowed age.
    public func deleteForEveryone(_ messageId: String, timestamp: UInt64? = nil) async throws {
        let t = try await targetInfo(messageId)
        let ourAci = account.aci
        let admin = t.author != ourAci
        let ok = try await database.pool.read { db -> Bool in
            if admin {
                guard let g = try GroupStore.load(db, conversationId: t.conversationId), g.state?.isAdmin(ourAci) == true else { return false }
            }
            let age = abs(MessageStore.now() - (t.serverTimestamp ?? Int64(t.sentAt)))
            return age <= (try MessageModifiers.deleteMaxAge(db, admin: admin))
        }
        guard ok else { throw ModifierError.notAllowed("delete for everyone") }
        var data = baseDataMessage(t, timestamp: timestamp ?? UInt64(MessageStore.now()))
        if admin {
            var d = Signalservice_DataMessage.AdminDelete()
            d.targetAuthorAciBinary = StorageLocal.uuidBytes(t.author) ?? Data()
            d.targetSentTimestamp = t.sentAt
            data.adminDelete = d
        } else {
            var d = Signalservice_DataMessage.Delete()
            d.targetSentTimestamp = t.sentAt
            data.delete = d
        }
        try await queueModifier(t, data: data, local: [admin ? .adminDelete : .delete: Data()])
    }

    /// `getMessagesCanDeleteForEveryone`: whether every one of `messageIds` can be deleted for
    /// everyone — ours, actually sent to someone, within the age limit; or, as a group admin,
    /// anyone's within the admin limit (`needsAdminDelete`). `isDeletingOwnMessages`: all ours.
    public func canDeleteForEveryone(_ messageIds: [String]) async throws -> (canDeleteForEveryone: Bool, needsAdminDelete: Bool, isDeletingOwnMessages: Bool) {
        let ourAci = account.aci
        return try await database.pool.read { db in
            var can = !messageIds.isEmpty, admin = false, own = true
            for id in messageIds {
                guard let row = try Row.fetchOne(db, sql: "SELECT conversationId, type, sent_at, sourceServiceId, json FROM messages WHERE id = ?",
                                                 arguments: [id]) else { return (false, false, false) }
                let json = (try? MessageStore.jsonObject(row["json"] ?? "{}")) ?? [:]
                let outgoing = (row["type"] as String?) == "outgoing"
                if !outgoing { own = false }
                if json["deletedForEveryone"] as? Bool == true { can = false; continue }
                let sentAt: Int64 = row["sent_at"] ?? 0
                let age = abs(MessageStore.now() - ((json["serverTimestamp"] as? NSNumber)?.int64Value ?? sentAt))
                if outgoing {
                    let states = json["sendStateByConversationId"] as? [String: [String: Any]] ?? [:]
                    let sent = states.values.contains { ($0["status"] as? String).flatMap(SendStatus.init(rawValue:)).map { $0.rank >= SendStatus.sent.rank } ?? false }
                    let limit = try MessageModifiers.deleteMaxAge(db, admin: false)
                    if !sent || age > limit { can = false }
                } else {
                    let conversationId: String = row["conversationId"]
                    let limit = try MessageModifiers.deleteMaxAge(db, admin: true)
                    guard let g = try GroupStore.load(db, conversationId: conversationId), g.state?.isAdmin(ourAci) == true, age <= limit
                    else { can = false; continue }
                    admin = true
                }
            }
            return (can, can && admin, own)
        }
    }

    /// `deleteForMe`: removes the messages here and tells our other devices.
    public func deleteForMe(_ messageIds: [String]) async throws {
        let ourAci = account.aci
        let sync = try await database.pool.write { db -> Signalservice_SyncMessage.DeleteForMe in
            var byConversation: [String: [Signalservice_AddressableMessage]] = [:]
            for id in messageIds {
                guard let c = try String.fetchOne(db, sql: "SELECT conversationId FROM messages WHERE id = ?", arguments: [id]),
                      let a = try DeleteForMe.addressable(db, messageId: id) else { continue }
                byConversation[c, default: []].append(a)
                try DeleteForMe.deleteMessage(db, id)
            }
            var d = Signalservice_SyncMessage.DeleteForMe()
            d.messageDeletes = try byConversation.compactMap { c, msgs in
                guard let ident = try DeleteForMe.identifier(db, conversationId: c) else { return nil }
                var md = Signalservice_SyncMessage.DeleteForMe.MessageDeletes()
                md.conversation = ident
                md.messages = msgs
                return md
            }
            _ = ourAci
            return d
        }
        guard !sync.messageDeletes.isEmpty else { return }
        var s = Self.syncMessage()
        s.deleteForMe = sync
        try await sendToSelf(s, timestamp: UInt64(MessageStore.now()), urgent: false, messageIds: [])
    }

    // MARK: edits

    /// `sendEditedMessage`: a new body for one of our messages (attachments unchanged).
    public func edit(_ messageId: String, newBody: String, timestamp: UInt64? = nil) async throws {
        let t = try await targetInfo(messageId)
        guard t.author == account.aci, t.type == "outgoing" else { throw ModifierError.notAllowed("edit someone else's message") }
        guard abs(MessageStore.now() - (t.serverTimestamp ?? Int64(t.sentAt))) <= MessageModifiers.maxEditAge else { throw ModifierError.notAllowed("too old to edit") }
        var data = baseDataMessage(t, timestamp: timestamp ?? UInt64(MessageStore.now()))
        data.body = newBody
        data.attachments = try await uploadAttachments(messageId: messageId)
        var edit = Signalservice_EditMessage()
        edit.targetSentTimestamp = t.sentAt
        edit.dataMessage = data
        var content = Signalservice_Content()
        content.editMessage = edit
        let payload = try content.serializedBytes() as Data
        let editBytes = try edit.serializedBytes() as Data
        let ourAci = account.aci, editTimestamp = data.timestamp
        try await database.pool.write { db in
            let ctx = ModifierContext(sender: ourAci, timestamp: editTimestamp, serverTimestamp: UInt64(MessageStore.now()), conversationId: t.conversationId,
                                      source: .thisDevice)
            try MessageModifiers.apply(db, PendingModifier(kind: .edit, targetAuthor: ourAci, targetSentAt: t.sentAt, context: ctx,
                                                           payload: editBytes, storedAt: MessageStore.now()), ourAci: ourAci, keepIfMissing: false)
            try JobQueue.insert(db, queueType: ConversationJob.queueType,
                                payload: ConversationJob.modifierSend(conversationId: t.conversationId, content: payload, timestamp: editTimestamp))
        }
        jobs.poke()
    }

    // MARK: polls

    /// `enqueuePollCreateForSend`
    @discardableResult
    public func createPoll(question: String, options: [String], allowMultiple: Bool, conversationId: String, timestamp: UInt64? = nil) async throws -> String {
        var p = Signalservice_DataMessage.PollCreate()
        p.question = question
        p.options = options
        p.allowMultiple = allowMultiple
        guard MessageModifiers.pollJSON(p) != nil else { throw ModifierError.notAllowed("poll needs a question and 2–10 options") }
        let pollBytes = try p.serializedBytes() as Data
        let sentAt = timestamp ?? UInt64(MessageStore.now())
        let ourAci = account.aci, device = account.deviceId
        let id = try await database.pool.write { db -> String in
            let states = try Self.pendingSendStates(db, conversationId: conversationId, ourAci: ourAci)
            let poll = MessageModifiers.pollJSON(try Signalservice_DataMessage.PollCreate(serializedBytes: pollBytes)) ?? [:]
            let messageId = try MessageStore.insert(db, .init(conversationId: conversationId, type: "outgoing", body: "", sentAt: sentAt, source: ourAci,
                                                              sourceDevice: device, serverGuid: nil, serverTimestamp: nil, unidentified: false,
                                                              extra: ["poll": poll, "sendStateByConversationId": states]))
            try JobQueue.insert(db, queueType: ConversationJob.queueType, payload: ConversationJob.normalMessage(conversationId: conversationId, messageId: messageId))
            return messageId
        }
        jobs.poke()
        return id
    }

    static func pendingSendStates(_ db: Database, conversationId: String, ourAci: String) throws -> [String: Any] {
        var states: [String: Any] = [:]
        if let g = try GroupStore.load(db, conversationId: conversationId), let state = g.state {
            for m in state.membersV2 where m.aci != ourAci {
                states[try MessageStore.privateConversation(db, serviceId: m.aci)] = ["status": "Pending", "updatedAt": MessageStore.now()]
            }
        } else {
            states[conversationId] = ["status": "Pending", "updatedAt": MessageStore.now()]
        }
        return states
    }

    /// The poll of an outgoing message, for its DataMessage.
    func pollCreate(messageId: String) async throws -> Signalservice_DataMessage.PollCreate? {
        struct Poll: Decodable { var question: String; var options: [String]; var allowMultiple: Bool? }
        guard let s = try await database.pool.read({ try String.fetchOne($0, sql: "SELECT json ->> '$.poll' FROM messages WHERE id = ?", arguments: [messageId]) }),
              let poll = try? JSONDecoder().decode(Poll.self, from: Data(s.utf8)) else { return nil }
        var p = Signalservice_DataMessage.PollCreate()
        p.question = poll.question
        p.options = poll.options
        p.allowMultiple = poll.allowMultiple ?? false
        return p
    }

    /// `enqueuePollVoteForSend`: our vote (no options = retract); each vote counts up.
    public func vote(on messageId: String, optionIndexes: [Int], timestamp: UInt64? = nil) async throws {
        let t = try await targetInfo(messageId)
        let ourAci = account.aci
        let previous = try await database.pool.write { db -> UInt32 in
            guard let s = try String.fetchOne(db, sql: "SELECT json ->> '$.poll' FROM messages WHERE id = ?", arguments: [messageId]),
                  let poll = try MessageStore.jsonObject(s) as [String: Any]?, let votes = poll["votes"] as? [[String: Any]] else { return 0 }
            let me = try MessageStore.privateConversation(db, serviceId: ourAci)
            return (votes.first { $0["fromConversationId"] as? String == me }?["voteCount"] as? NSNumber)?.uint32Value ?? 0
        }
        var v = Signalservice_DataMessage.PollVote()
        v.targetAuthorAciBinary = StorageLocal.uuidBytes(t.author) ?? Data()
        v.targetSentTimestamp = t.sentAt
        v.optionIndexes = optionIndexes.map { UInt32($0) }
        v.voteCount = previous + 1
        var data = baseDataMessage(t, timestamp: timestamp ?? UInt64(MessageStore.now()))
        data.pollVote = v
        try await queueModifier(t, data: data, local: [.pollVote: try v.serializedBytes()])
    }

    /// `enqueuePollTerminateForSend`: ends one of our polls.
    public func endPoll(_ messageId: String, timestamp: UInt64? = nil) async throws {
        let t = try await targetInfo(messageId)
        guard t.author == account.aci else { throw ModifierError.notAllowed("only the poll's author ends it") }
        var p = Signalservice_DataMessage.PollTerminate()
        p.targetSentTimestamp = t.sentAt
        var data = baseDataMessage(t, timestamp: timestamp ?? UInt64(MessageStore.now()))
        data.pollTerminate = p
        try await queueModifier(t, data: data, local: [.pollTerminate: Data()])
    }

    // MARK: pins

    /// `sendPinMessage` (nil duration: forever).
    public func pin(_ messageId: String, durationSeconds: UInt32? = nil, timestamp: UInt64? = nil) async throws {
        let t = try await targetInfo(messageId)
        var p = Signalservice_DataMessage.PinMessage()
        p.targetAuthorAciBinary = StorageLocal.uuidBytes(t.author) ?? Data()
        p.targetSentTimestamp = t.sentAt
        if let durationSeconds { p.pinDurationSeconds = durationSeconds } else { p.pinDurationForever = true }
        var data = baseDataMessage(t, timestamp: timestamp ?? UInt64(MessageStore.now()))
        data.pinMessage = p
        try await queueModifier(t, data: data, local: [.pin: try p.serializedBytes()])
    }

    public func unpin(_ messageId: String, timestamp: UInt64? = nil) async throws {
        let t = try await targetInfo(messageId)
        var p = Signalservice_DataMessage.UnpinMessage()
        p.targetAuthorAciBinary = StorageLocal.uuidBytes(t.author) ?? Data()
        p.targetSentTimestamp = t.sentAt
        var data = baseDataMessage(t, timestamp: timestamp ?? UInt64(MessageStore.now()))
        data.unpinMessage = p
        try await queueModifier(t, data: data, local: [.unpin: Data()])
    }

    // MARK: view-once

    /// `markViewOnceMessageViewed`: erased here, viewOnceOpen to our devices, a viewed receipt
    /// to the sender.
    public func openViewOnce(_ messageId: String) async throws {
        let t = try await targetInfo(messageId)
        let ourAci = account.aci
        let erased = try await database.pool.write { db -> Bool in
            guard let target = try MessageModifiers.target(db, author: t.author, sentAt: t.sentAt) else { return false }
            return try MessageModifiers.eraseViewOnce(db, target)
        }
        guard erased else { return }
        var open = Signalservice_SyncMessage.ViewOnceOpen()
        open.senderAciBinary = StorageLocal.uuidBytes(t.author) ?? Data()
        open.timestamp = t.sentAt
        var s = Self.syncMessage()
        s.viewOnceOpen = open
        try await sendToSelf(s, timestamp: UInt64(MessageStore.now()), urgent: false, messageIds: [])
        if t.author != ourAci, try await database.pool.read({ try Items.get($0, "read-receipt-setting", as: Bool.self) }) ?? false {
            try await jobs.enqueue(queueType: ConversationJob.queueType, payload: ConversationJob.receipts(
                .viewed, [ReceiptTarget(messageId: messageId, conversationId: t.conversationId, senderAci: t.author, timestamp: t.sentAt)]))
        }
    }

    // MARK: the send job

    /// Sends a prepared Content to the conversation's recipients, then the transcript.
    func sendModifier(_ job: ConversationJob) async throws {
        guard let conversationId = job.conversationId, let b64 = job.content, let bytes = Data(base64Encoded: b64), let timestamp = job.timestamp else {
            throw JobError.permanent("malformed job")
        }
        let content = try Signalservice_Content(serializedBytes: bytes)
        let ourAci = account.aci
        let target = try await database.pool.read { db -> (group: GroupStore.Stored?, serviceId: String?) in
            (try GroupStore.load(db, conversationId: conversationId),
             try String.fetchOne(db, sql: "SELECT serviceId FROM conversations WHERE id = ?", arguments: [conversationId]))
        }
        var sent = Signalservice_SyncMessage.Sent()
        sent.timestamp = timestamp
        if let group = target.group, let state = group.state {
            let recipients = state.membersV2.map(\.aci).filter { $0 != ourAci }
            let result = try await groupSender.send(OutgoingPayload(content: content, timestamp: timestamp), keys: group.keys, recipients: recipients, messageIds: [])
            let delivered = Set(result.senderKeyRecipients + result.normalRecipients).subtracting(result.unregistered)
            sent.unidentifiedStatus = delivered.compactMap { aci in
                var st = Signalservice_SyncMessage.Sent.UnidentifiedDeliveryStatus()
                guard let b = try? ServiceId.parseFrom(serviceIdString: aci).serviceIdBinary else { return nil }
                st.destinationServiceIDBinary = b
                st.unidentified = result.senderKeyRecipients.contains(aci)
                return st
            }
        } else if let serviceId = target.serviceId {
            if serviceId != ourAci {
                let result: SendResult
                do {
                    result = try await sender.send(OutgoingPayload(content: content, timestamp: timestamp), to: serviceId, messageIds: [])
                } catch let e as SendError {
                    if case .untrustedIdentities = e { throw e }   // handled by `run`
                    throw JobError.permanent("\(e)")
                }
                var st = Signalservice_SyncMessage.Sent.UnidentifiedDeliveryStatus()
                st.destinationServiceIDBinary = try ServiceId.parseFrom(serviceIdString: serviceId).serviceIdBinary
                st.unidentified = result.sealed
                sent.unidentifiedStatus = [st]
            }
            sent.destinationServiceIDBinary = try ServiceId.parseFrom(serviceIdString: serviceId).serviceIdBinary
        } else {
            throw JobError.permanent("conversation \(conversationId) has no recipients")
        }
        switch content.content {
        case .dataMessage(let m): sent.message = m
        case .editMessage(let e): sent.editMessage = e
        default: return
        }
        var sync = Self.syncMessage()
        sync.sent = sent
        try await sendToSelf(sync, timestamp: timestamp, urgent: false, messageIds: [])
    }
}
