// Sending stories and their replies (upstream util/sendStoryMessage, jobs/helpers/
// sendStory, sendStoryReaction / reply in the conversation job):
// - a story to distribution lists is one row per list; every recipient of any list gets
//   one StoryMessage (sealed, `story=true`), allowed to reply if any of its lists allows;
//   our other devices get one SyncMessage.Sent with the story and every recipient's lists;
// - a group story is a row in the group, sent to each member with the group context, and
//   its own transcript;
// - a reply to a 1:1 story is a normal message with storyContext; to a group story, a
//   group message sent with `story=true`. A reaction is a reply carrying the emoji.

import Foundation
import GRDB
import LibSignalClient
import SignalProtos

/// What a story shows: text (with an optional link preview) or a picture / video.
public enum OutgoingStoryContent: Sendable {
    case text(Signalservice_TextAttachment)
    case file(OutgoingAttachment)

    /// A text story from the creator's fields (no protobuf types needed by the caller).
    public static func text(_ s: StoryText) -> OutgoingStoryContent {
        var t = Signalservice_TextAttachment()
        if let text = s.text, !text.isEmpty { t.text = text }
        t.textStyle = Signalservice_TextAttachment.Style(rawValue: s.textStyle) ?? .default
        if let c = s.textForegroundColor { t.textForegroundColor = c }
        if let c = s.textBackgroundColor { t.textBackgroundColor = c }
        if !s.gradientColors.isEmpty {
            var g = Signalservice_TextAttachment.Gradient()
            g.angle = UInt32(clamping: s.gradientAngle ?? 0)
            g.colors = s.gradientColors
            g.positions = s.gradientPositions
            if let first = s.gradientColors.first { g.startColor = first }
            if let last = s.gradientColors.last { g.endColor = last }
            t.gradient = g
        } else if let c = s.color {
            t.color = c
        }
        return .text(t)
    }
}

extension Messenger {
    /// Sends a story to the given lists and groups; returns the stories' message ids.
    @discardableResult
    public func sendStory(_ content: OutgoingStoryContent, listIds: [String], groupMasterKeys: [Data] = [], timestamp: UInt64? = nil) async throws
        -> [String]
    {
        let sentAt = timestamp ?? UInt64(MessageStore.now())
        var prepared: MessageAttachment?
        if case .file(let o) = content {
            guard let services = attachments else { throw AttachmentDownloadError.missingPointer }
            let number = account.number
            let level = try await database.pool.read { try MediaQuality.level($0, e164: number) }
            prepared = try await services.prepare(o, level: level)
        }
        let ourAci = account.aci
        let deviceId = account.deviceId
        var story = Signalservice_StoryMessage()
        if let pk = account.profileKey { story.profileKey = pk }
        if case .text(let t) = content { story.textAttachment = t }
        let draft = story
        let attachment = prepared

        // Rows, recipients per list, group members.
        struct Plan {
            var listStories: [(id: String, list: StoryDistributionLists.List, recipients: [String])] = []
            var groupStories: [(id: String, group: GroupStore.Stored, members: [String])] = []
        }
        let plan = try await database.pool.write { db -> Plan in
            try StorageRecords.ensureMyStory(db)
            var plan = Plan()
            let connections = try StoryDistributionLists.signalConnections(db)
            let ours = try MessageStore.privateConversation(db, serviceId: ourAci)
            func addAttachment(_ id: String, conversationId: String) throws {
                guard let attachment else { return }
                let receivedAt = try Int64.fetchOne(db, sql: "SELECT received_at FROM messages WHERE id = ?", arguments: [id]) ?? MessageStore.now()
                try MessageAttachments.upsert(db, .init(messageId: id, type: .attachment, order: 0), conversationId: conversationId, sentAt: Int64(sentAt),
                                              receivedAt: receivedAt, messageType: "story", attachment)
                try MessageAttachments.updateMessageFlags(db, messageId: id)
            }
            for listId in listIds {
                guard let list = try StoryDistributionLists.list(db, id: listId), list.deletedAt == nil else { continue }
                let recipients = StoryDistributionLists.recipients(db, list: list, signalConnections: connections).filter { $0 != ourAci }
                var s = draft
                s.allowsReplies = list.allowsReplies
                var states: [String: Any] = [:]
                for r in recipients { states[try MessageStore.privateConversation(db, serviceId: r)] = ["status": "Pending", "updatedAt": MessageStore.now()] }
                guard let id = try StoryStore.insert(db, .init(conversationId: ours, source: ourAci, sourceDevice: deviceId, sentAt: sentAt, story: s,
                                                               outgoing: true, distributionListId: list.id, sendState: states)) else { continue }
                try addAttachment(id, conversationId: ours)
                plan.listStories.append((id, list, recipients))
            }
            for masterKey in groupMasterKeys {
                let keys = try GroupKeys(masterKey: masterKey)
                let group = try GroupStore.conversation(db, keys: keys)
                guard let state = group.state, state.isMember(ourAci) else { throw GroupsServiceError.notAMember }
                let members = state.membersV2.map(\.aci).filter { $0 != ourAci }
                var s = draft
                s.allowsReplies = true
                var context = Signalservice_GroupContextV2()
                context.masterKey = keys.masterKey
                context.revision = UInt32(state.revision)
                s.group = context
                var states: [String: Any] = [:]
                for m in members { states[try MessageStore.privateConversation(db, serviceId: m)] = ["status": "Pending", "updatedAt": MessageStore.now()] }
                guard let id = try StoryStore.insert(db, .init(conversationId: group.conversationId, source: ourAci, sourceDevice: deviceId, sentAt: sentAt,
                                                               story: s, outgoing: true, sendState: states)) else { continue }
                try addAttachment(id, conversationId: group.conversationId)
                plan.groupStories.append((id, group, members))
            }
            return plan
        }

        // One upload serves every copy.
        let firstId = plan.listStories.first?.id ?? plan.groupStories.first?.id
        if attachment != nil, let firstId {
            guard let pointer = try await uploadAttachments(messageId: firstId).first else { throw JobError.permanent("story upload failed") }
            story.fileAttachment = pointer
        }

        // Distribution lists: each recipient once.
        if !plan.listStories.isEmpty {
            var lists: [String: [String]] = [:]
            var canReply: [String: Bool] = [:]
            for entry in plan.listStories {
                for r in entry.recipients {
                    lists[r, default: []].append(entry.list.id)
                    canReply[r] = (canReply[r] ?? false) || entry.list.allowsReplies
                }
            }
            var delivered: Set<String> = []
            for r in lists.keys.sorted() {
                var s = story
                s.allowsReplies = canReply[r] ?? false
                var c = Signalservice_Content()
                c.storyMessage = s
                do {
                    _ = try await sender.send(OutgoingPayload(content: c, timestamp: sentAt, contentHint: .implicit, urgent: false, story: true), to: r,
                                              messageIds: plan.listStories.map(\.id))
                    delivered.insert(r)
                } catch {
                    continue
                }
            }
            try await markStorySent(plan.listStories.map { ($0.id, $0.recipients) }, delivered: delivered)
            var sent = Signalservice_SyncMessage.Sent()
            sent.timestamp = sentAt
            story.allowsReplies = plan.listStories.contains { $0.list.allowsReplies }
            sent.storyMessage = story
            sent.storyMessageRecipients = try lists.keys.sorted().map { r in
                var rec = Signalservice_SyncMessage.Sent.StoryMessageRecipient()
                rec.destinationServiceIDBinary = try ServiceId.parseFrom(serviceIdString: r).serviceIdBinary
                rec.distributionListIds = lists[r] ?? []
                rec.isAllowedToReply = canReply[r] ?? false
                return rec
            }
            var sync = Self.syncMessage()
            sync.sent = sent
            try await sendToSelf(sync, timestamp: sentAt, urgent: false, messageIds: plan.listStories.map(\.id))
        }

        // Group stories.
        for entry in plan.groupStories {
            guard let state = entry.group.state else { continue }
            var s = story
            s.allowsReplies = true
            var context = Signalservice_GroupContextV2()
            context.masterKey = entry.group.keys.masterKey
            context.revision = UInt32(state.revision)
            s.group = context
            var c = Signalservice_Content()
            c.storyMessage = s
            let result = try await groupSender.send(OutgoingPayload(content: c, timestamp: sentAt, contentHint: .implicit, urgent: false, story: true),
                                                    keys: entry.group.keys, recipients: entry.members, messageIds: [entry.id])
            let delivered = Set(result.senderKeyRecipients + result.normalRecipients).subtracting(result.unregistered)
            try await markStorySent([(entry.id, entry.members)], delivered: delivered)
            var sent = Signalservice_SyncMessage.Sent()
            sent.timestamp = sentAt
            sent.storyMessage = s
            sent.storyMessageRecipients = try delivered.sorted().map { r in
                var rec = Signalservice_SyncMessage.Sent.StoryMessageRecipient()
                rec.destinationServiceIDBinary = try ServiceId.parseFrom(serviceIdString: r).serviceIdBinary
                rec.isAllowedToReply = true
                return rec
            }
            var sync = Self.syncMessage()
            sync.sent = sent
            try await sendToSelf(sync, timestamp: sentAt, urgent: false, messageIds: [entry.id])
        }
        return plan.listStories.map(\.id) + plan.groupStories.map(\.id)
    }

    func markStorySent(_ stories: [(id: String, recipients: [String])], delivered: Set<String>) async throws {
        try await database.pool.write { db in
            for (id, recipients) in stories {
                try MessageStore.updateJSON(db, messageId: id) { json in
                    for r in recipients {
                        guard let cid = try? MessageStore.privateConversation(db, serviceId: r) else { continue }
                        MessageStore.setSendStatus(&json, conversationId: cid, delivered.contains(r) ? .sent : .failed, force: !delivered.contains(r))
                    }
                }
            }
        }
    }

    /// Replies to (or, with `emoji`, reacts to) a story. Returns the reply's message id.
    @discardableResult
    public func sendStoryReply(storyId: String, body: String = "", emoji: String? = nil, timestamp: UInt64? = nil) async throws -> String {
        let sentAt = timestamp ?? UInt64(MessageStore.now())
        let ourAci = account.aci
        struct Target { var author: String; var storySentAt: UInt64; var conversationId: String; var group: GroupStore.Stored?; var direct: String? }
        let (target, replyId) = try await database.pool.write { db -> (Target, String) in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT m.sourceServiceId, m.sent_at, m.conversationId, c.groupId, c.serviceId, c.json ->> '$.masterKey' AS masterKey
                FROM messages m JOIN conversations c ON c.id = m.conversationId WHERE m.id = ? AND m.type = 'story'
                """, arguments: [storyId]), let author: String = row["sourceServiceId"] else { throw JobError.permanent("story \(storyId) gone") }
            var group: GroupStore.Stored? = nil
            if let mk: String = row["masterKey"], let data = Data(base64Encoded: mk) {
                group = try GroupStore.conversation(db, keys: try GroupKeys(masterKey: data))
            }
            // A 1:1 reply goes to the author's chat; a group reply stays in the group.
            let conversationId = try group?.conversationId ?? MessageStore.privateConversation(db, serviceId: author)
            var extra: [String: Any] = ["storyId": storyId]
            if let emoji {
                extra["storyReaction"] = ["emoji": emoji, "targetAuthorAci": author, "targetTimestamp": UInt64(row["sent_at"] as Int64)]
            }
            if group != nil { extra.merge(try MessageReceiver.storyReplyExtra(db, storyId: storyId)) { _, new in new } }
            var states: [String: Any] = [:]
            if let state = group?.state {
                for m in state.membersV2 where m.aci != ourAci {
                    states[try MessageStore.privateConversation(db, serviceId: m.aci)] = ["status": "Pending", "updatedAt": MessageStore.now()]
                }
            } else {
                states[conversationId] = ["status": "Pending", "updatedAt": MessageStore.now()]
            }
            extra["sendStateByConversationId"] = states
            let id = try MessageStore.insert(db, .init(conversationId: conversationId, type: "outgoing", body: emoji == nil ? body : "", sentAt: sentAt,
                                                       source: ourAci, sourceDevice: self.account.deviceId, serverGuid: nil, serverTimestamp: nil,
                                                       unidentified: false, extra: extra))
            try db.execute(sql: "UPDATE messages SET storyId = ? WHERE id = ?", arguments: [storyId, id])
            return (Target(author: author, storySentAt: UInt64(row["sent_at"] as Int64), conversationId: conversationId, group: group,
                           direct: group == nil ? author : nil), id)
        }
        var data = Signalservice_DataMessage()
        data.timestamp = sentAt
        if let pk = account.profileKey { data.profileKey = pk }
        var ctx = Signalservice_DataMessage.StoryContext()
        ctx.authorAciBinary = try ServiceId.parseFrom(serviceIdString: target.author).serviceIdBinary
        ctx.sentTimestamp = target.storySentAt
        data.storyContext = ctx
        if let emoji {
            var reaction = Signalservice_DataMessage.Reaction()
            reaction.emoji = emoji
            reaction.targetAuthorAciBinary = ctx.authorAciBinary
            reaction.targetSentTimestamp = target.storySentAt
            data.reaction = reaction
        } else {
            data.body = body
        }
        if let group = target.group, let state = group.state {
            var context = Signalservice_GroupContextV2()
            context.masterKey = group.keys.masterKey
            context.revision = UInt32(state.revision)
            data.groupV2 = context
            var c = Signalservice_Content()
            c.dataMessage = data
            let members = state.membersV2.map(\.aci).filter { $0 != ourAci }
            let result = try await groupSender.send(OutgoingPayload(content: c, timestamp: sentAt, story: true), keys: group.keys, recipients: members,
                                                    messageIds: [replyId])
            let delivered = Set(result.senderKeyRecipients + result.normalRecipients).subtracting(result.unregistered)
            try await markStorySent([(replyId, members)], delivered: delivered)
            try await sendGroupTranscript(data, recipients: Array(delivered), sealed: delivered, timestamp: sentAt, messageId: replyId)
        } else if let direct = target.direct {
            var c = Signalservice_Content()
            c.dataMessage = data
            let result = try await sender.send(OutgoingPayload(content: c, timestamp: sentAt), to: direct, messageIds: [replyId])
            try await markStorySent([(replyId, [direct])], delivered: [direct])
            try await sendTranscript(data, destination: direct, timestamp: sentAt, sealed: result.sealed, messageId: replyId)
        }
        return replyId
    }

    /// We viewed someone's story: viewed state, a viewed sync, and a viewed receipt when story
    /// view receipts are on (`storyViewReceiptsEnabled`, else the read-receipt setting).
    public func markStoryViewed(storyId: String) async throws {
        try await database.pool.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT conversationId, sourceServiceId, sent_at, readStatus FROM messages WHERE id = ? AND type = 'story'",
                                             arguments: [storyId]), let author: String = row["sourceServiceId"], author != self.account.aci,
                  (row["readStatus"] as Int?) != ReadStatus.viewed.rawValue else { return }
            try StoryStore.markViewed(db, storyId: storyId)
            let target = ReceiptTarget(messageId: storyId, conversationId: row["conversationId"], senderAci: author, timestamp: UInt64(row["sent_at"] as Int64))
            try JobQueue.insert(db, queueType: ConversationJob.queueType, payload: ConversationJob.viewedSync([target]))
            let enabled = try Items.get(db, "storyViewReceiptsEnabled", as: Bool.self) ?? Items.get(db, "read-receipt-setting", as: Bool.self) ?? false
            if enabled { try JobQueue.insert(db, queueType: ConversationJob.queueType, payload: ConversationJob.receipts(.viewed, [target])) }
        }
        jobs.poke()
    }
}
