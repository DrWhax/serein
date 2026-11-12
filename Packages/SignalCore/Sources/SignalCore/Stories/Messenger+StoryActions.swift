// What can be done to a story once it exists (upstream deleteStoryForEveryone,
// sendDeleteStoryForEveryone, toggleHideStories, the story retry, StoriesSettingsModal):
// - delete for everyone: a DataMessage.delete (sent as a story) to whoever still only has this
//   copy, and our other devices get the remaining recipients (a recipient update);
// - hide / unhide a sender's or group's stories (conversation hideStory, a storage field);
// - retry a story to the recipients it failed for;
// - its viewers (send state Viewed), and story lists and settings with storage write-back.

import Foundation
import GRDB
import LibSignalClient
import SignalProtos

public enum StoryActionError: Error, Equatable {
    case notFound
    case notOurs
    case tooOld
}

extension Messenger {
    /// `deleteStoryForEveryone`.
    public func deleteStoryForEveryone(storyId: String, timestamp: UInt64? = nil) async throws {
        let ourAci = account.aci
        struct Plan {
            var sentAt: UInt64
            var group: GroupStore.Stored?
            var groupMembers: [String] = []
            /// Who gets the delete (no other copy of the story reaches them).
            var targets: [String] = []
            /// Everyone the story went to, with the lists that still reach them.
            var remaining: [(serviceId: String, lists: [String], allowedToReply: Bool)] = []
        }
        let plan = try await database.pool.read { db -> Plan in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT conversationId, sent_at, sourceServiceId, json FROM messages WHERE id = ? AND type = 'story'
                """, arguments: [storyId]) else { throw StoryActionError.notFound }
            guard (row["sourceServiceId"] as String?) == ourAci else { throw StoryActionError.notOurs }
            let sentAt = UInt64(row["sent_at"] as Int64)
            guard Int64(sentAt) + StoryStore.day > MessageStore.now() else { throw StoryActionError.tooOld }
            var plan = Plan(sentAt: sentAt)
            let conversationId: String = row["conversationId"]
            // Group stories are deleted like group messages.
            if let group = try GroupStore.load(db, conversationId: conversationId) {
                plan.group = group
                plan.groupMembers = group.state?.membersV2.map(\.aci).filter { $0 != ourAci } ?? []
                return plan
            }
            func states(_ json: String?) throws -> [String: [String: Any]] {
                (try MessageStore.jsonObject(json ?? "{}"))["sendStateByConversationId"] as? [String: [String: Any]] ?? [:]
            }
            func serviceId(_ conversationId: String) throws -> String? {
                try String.fetchOne(db, sql: "SELECT serviceId FROM conversations WHERE id = ?", arguments: [conversationId])
            }
            var targets: [String] = []
            var remaining: [String: (lists: Set<String>, reply: Bool)] = [:]
            for (cid, state) in try states(row["json"]) {
                guard let s = try serviceId(cid), s != ourAci else { continue }
                targets.append(s)
                remaining[s] = ([], state["isAllowedToReplyToStory"] as? Bool != false)
            }
            // Copies of this story sent to other lists still reach their recipients.
            for other in try Row.fetchAll(db, sql: """
                SELECT id, storyDistributionListId, json FROM messages
                WHERE type = 'story' AND sourceServiceId = ? AND sent_at = ? AND id != ?
                """, arguments: [ourAci, Int64(sentAt), storyId]) {
                guard (try MessageStore.jsonObject(other["json"] ?? "{}"))["deletedForEveryone"] as? Bool != true else { continue }
                for (cid, state) in try states(other["json"]) {
                    guard let s = try serviceId(cid), s != ourAci else { continue }
                    targets.removeAll { $0 == s }
                    var r = remaining[s] ?? ([], state["isAllowedToReplyToStory"] as? Bool != false)
                    if let list: String = other["storyDistributionListId"] { r.lists.insert(list) }
                    remaining[s] = r
                }
            }
            plan.targets = targets.sorted()
            plan.remaining = remaining.keys.sorted().map { ($0, remaining[$0]?.lists.sorted() ?? [], remaining[$0]?.reply ?? true) }
            return plan
        }

        // Gone here at once (upstream emulates the recipient update right away); the deletes to
        // everyone it reached follow, one per recipient, which can take a while for My Story.
        try await database.pool.write { try DeleteForMe.deleteMessage($0, storyId) }

        let now = timestamp ?? UInt64(MessageStore.now())
        var data = Signalservice_DataMessage()
        data.timestamp = now
        if let pk = account.profileKey { data.profileKey = pk }
        var delete = Signalservice_DataMessage.Delete()
        delete.targetSentTimestamp = plan.sentAt
        data.delete = delete

        if let group = plan.group, let state = group.state {
            var ctx = Signalservice_GroupContextV2()
            ctx.masterKey = group.keys.masterKey
            ctx.revision = UInt32(state.revision)
            data.groupV2 = ctx
            var c = Signalservice_Content()
            c.dataMessage = data
            _ = try await groupSender.send(OutgoingPayload(content: c, timestamp: now, contentHint: .resendable, urgent: true, story: true),
                                           keys: group.keys, recipients: plan.groupMembers, messageIds: [storyId])
            var sent = Signalservice_SyncMessage.Sent()
            sent.timestamp = now
            sent.message = data
            var sync = Self.syncMessage()
            sync.sent = sent
            try await sendToSelf(sync, timestamp: now, urgent: false, messageIds: [storyId])
        } else {
            var c = Signalservice_Content()
            c.dataMessage = data
            for r in plan.targets {
                _ = try? await sender.send(OutgoingPayload(content: c, timestamp: now, contentHint: .resendable, urgent: true, story: true), to: r,
                                           messageIds: [storyId])
            }
            // Our other devices: who still has the story, through which lists.
            var sent = Signalservice_SyncMessage.Sent()
            sent.timestamp = plan.sentAt
            sent.isRecipientUpdate = true
            sent.storyMessageRecipients = try plan.remaining.map { r in
                var rec = Signalservice_SyncMessage.Sent.StoryMessageRecipient()
                rec.destinationServiceIDBinary = try ServiceId.parseFrom(serviceIdString: r.serviceId).serviceIdBinary
                rec.distributionListIds = r.lists
                rec.isAllowedToReply = r.allowedToReply
                return rec
            }
            var sync = Self.syncMessage()
            sync.sent = sent
            try await sendToSelf(sync, timestamp: now, urgent: false, messageIds: [storyId])
        }
    }

    /// `toggleHideStories`: a contact's or group's stories go to "Hidden stories".
    public func setHideStories(_ conversationId: String, _ hidden: Bool) async throws {
        try await changeConversation(conversationId) { $0["hideStory"] = hidden }
    }

    /// Sends one of our stories again to the recipients it failed for.
    public func retryStory(storyId: String) async throws {
        let ourAci = account.aci
        let (item, failed) = try await database.pool.read { db -> (StoryFeedItem?, [String]) in
            let item = try StoryFeed.items(db, now: 0).first { $0.id == storyId }
            guard let json = try String.fetchOne(db, sql: "SELECT json FROM messages WHERE id = ?", arguments: [storyId]) else { return (nil, []) }
            let states = (try MessageStore.jsonObject(json))["sendStateByConversationId"] as? [String: [String: Any]] ?? [:]
            let failed = try states.filter { ($0.value["status"] as? String) == SendStatus.failed.rawValue }.keys.compactMap { cid in
                try String.fetchOne(db, sql: "SELECT serviceId FROM conversations WHERE id = ?", arguments: [cid])
            }
            return (item, failed.filter { $0 != ourAci })
        }
        guard let item, item.isOutgoing else { throw StoryActionError.notFound }
        guard !failed.isEmpty else { return }
        var story = Signalservice_StoryMessage()
        if let pk = account.profileKey { story.profileKey = pk }
        story.allowsReplies = item.canReply
        if let t = item.text, case .text(let attachment) = OutgoingStoryContent.text(t) {
            story.textAttachment = attachment
        } else if let pointer = try await uploadAttachments(messageId: storyId).first {
            story.fileAttachment = pointer
        }
        if let groupId = item.groupConversationId {
            let group = try await database.pool.read { try GroupStore.load($0, conversationId: groupId) }
            guard let group, let state = group.state else { throw StoryActionError.notFound }
            var ctx = Signalservice_GroupContextV2()
            ctx.masterKey = group.keys.masterKey
            ctx.revision = UInt32(state.revision)
            story.group = ctx
            var c = Signalservice_Content()
            c.storyMessage = story
            let result = try await groupSender.send(OutgoingPayload(content: c, timestamp: UInt64(item.sentAt), contentHint: .implicit, urgent: false, story: true),
                                                    keys: group.keys, recipients: failed, messageIds: [storyId])
            let delivered = Set(result.senderKeyRecipients + result.normalRecipients).subtracting(result.unregistered)
            try await markStorySent([(storyId, failed)], delivered: delivered, unregistered: Set(result.unregistered))
            return
        }
        var c = Signalservice_Content()
        c.storyMessage = story
        var delivered: Set<String> = []
        var unregistered: Set<String> = []
        for r in failed {
            do {
                _ = try await sender.send(OutgoingPayload(content: c, timestamp: UInt64(item.sentAt), contentHint: .implicit, urgent: false, story: true),
                                          to: r, messageIds: [storyId])
                delivered.insert(r)
            } catch SendError.unregistered {
                unregistered.insert(r)
            } catch {
                continue
            }
        }
        try await markStorySent([(storyId, failed)], delivered: delivered, unregistered: unregistered)
    }

    // MARK: lists and settings

    @discardableResult
    public func createStoryList(id: String? = nil, name: String, members: [String], allowsReplies: Bool = true) async throws -> String {
        let id = try await database.pool.write { try StoryDistributionLists.create($0, id: id, name: name, members: members, allowsReplies: allowsReplies) }
        jobs.poke()
        return id
    }

    public func updateStoryList(_ listId: String, name: String? = nil, allowsReplies: Bool? = nil, isBlockList: Bool? = nil, members: [String]? = nil) async throws {
        try await database.pool.write {
            try StoryDistributionLists.update($0, listId: listId, name: name, allowsReplies: allowsReplies, isBlockList: isBlockList, members: members)
        }
        jobs.poke()
    }

    public func deleteStoryList(_ listId: String) async throws {
        try await database.pool.write { try StoryDistributionLists.delete($0, listId: listId) }
        jobs.poke()
    }

    /// A group's stories in the send list (upstream storySendMode Always) or out of it (Never).
    public func setGroupStorySendMode(_ conversationId: String, always: Bool) async throws {
        try await changeConversation(conversationId) { $0["storySendMode"] = always ? "Always" : "Never" }
    }

    /// Settings → Stories: view receipts (AccountRecord storyViewReceiptsEnabled) and turning
    /// stories off (hasStoriesDisabled); both synced.
    public func setStorySettings(viewReceipts: Bool? = nil, storiesDisabled: Bool? = nil) async throws {
        let account = self.account
        try await database.pool.write { db in
            if let viewReceipts { try Items.set(db, "storyViewReceiptsEnabled", viewReceipts) }
            if let storiesDisabled { try Items.set(db, "hasStoriesDisabled", storiesDisabled) }
            try StorageWriteBack.accountChanged(db, account: account)
        }
        jobs.poke()
    }
}

/// One of our story's recipients and their send state (StoryDetailsModal, the views list).
public struct StoryRecipientState: Sendable, Equatable {
    public var conversationId: String
    public var serviceId: String?
    public var status: String
    public var updatedAt: Int64?
}

extension StoryFeed {
    /// A story's recipients (ours) with their send state, viewers first by when they viewed.
    public static func recipients(_ db: Database, storyId: String) throws -> [StoryRecipientState] {
        guard let json = try String.fetchOne(db, sql: "SELECT json FROM messages WHERE id = ?", arguments: [storyId]) else { return [] }
        let states = (try MessageStore.jsonObject(json))["sendStateByConversationId"] as? [String: [String: Any]] ?? [:]
        return try states.map { cid, state in
            StoryRecipientState(conversationId: cid, serviceId: try String.fetchOne(db, sql: "SELECT serviceId FROM conversations WHERE id = ?", arguments: [cid]),
                                status: state["status"] as? String ?? "Pending", updatedAt: number(state["updatedAt"]))
        }
        .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
    }
}

/// A reply or reaction to a story (the group story replies list).
public struct StoryReplyItem: Sendable, Equatable, Identifiable {
    public var id: String
    public var author: String
    public var body: String
    public var emoji: String?
    public var sentAt: Int64
    public var deletedForEveryone: Bool
}

extension StoryFeed {
    /// Replies and reactions to a story, oldest first.
    public static func replies(_ db: Database, storyId: String, ourAci: String) throws -> [StoryReplyItem] {
        try Row.fetchAll(db, sql: "SELECT id, sourceServiceId, body, sent_at, json FROM messages WHERE storyId = ? ORDER BY received_at",
                         arguments: [storyId]).map { row in
            let json = (try? MessageStore.jsonObject(row["json"] ?? "{}")) ?? [:]
            return StoryReplyItem(id: row["id"], author: row["sourceServiceId"] ?? ourAci, body: row["body"] ?? "",
                                  emoji: (json["storyReaction"] as? [String: Any])?["emoji"] as? String, sentAt: row["sent_at"] ?? 0,
                                  deletedForEveryone: json["deletedForEveryone"] as? Bool ?? false)
        }
    }
}

extension SignalDatabase {
    public func storyReplies(storyId: String, ourAci: String) async throws -> [StoryReplyItem] {
        try await pool.read { try StoryFeed.replies($0, storyId: storyId, ourAci: ourAci) }
    }

    public func storyRecipients(storyId: String) async throws -> [StoryRecipientState] {
        try await pool.read { try StoryFeed.recipients($0, storyId: storyId) }
    }
}
