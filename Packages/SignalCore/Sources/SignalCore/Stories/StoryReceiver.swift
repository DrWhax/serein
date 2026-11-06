// Receiving stories (upstream MessageReceiver #handleStoryMessage, the story checks in
// #decryptAndProcess and handleDataMessage, util/onStoryRecipientUpdate):
// - a StoryMessage: kept 24h from its send time; 1:1 stories only from contacts we share
//   our profile with; group stories only for groups we know and haven't blocked;
// - our other device's sent story (SyncMessage.Sent.storyMessage): a group story, or one
//   story per distribution list with its recipients' send state;
// - a recipient update (storyMessageRecipients alone): recipients removed; a list story with
//   nobody left is deleted;
// - a reply or reaction (DataMessage.storyContext): linked to its story; group replies to a
//   story we don't have, and replies to a list story that doesn't allow them, are dropped.

import Foundation
import GRDB
import SignalProtos

extension MessageReceiver {
    func handleStoryMessage(_ story: Signalservice_StoryMessage, _ d: Decrypted, _ e: Signalservice_Envelope, _ db: Database) throws -> [ReceiveEvent] {
        let timestamp = e.clientTimestamp
        // Already expired (timeRemaining <= 0).
        guard Int64(timestamp) + StoryStore.day > MessageStore.now() else { return [] }
        if try StoryStore.find(db, author: d.sender, sentAt: timestamp) != nil { return [] }
        let conversation: String
        if story.hasGroup, story.group.hasMasterKey {
            guard story.group.masterKey.count == 32 else { throw ReceiveError.invalidEnvelope("bad group master key") }
            conversation = try MessageStore.groupConversation(db, masterKey: story.group.masterKey).id
            if try MessageModifiers.isBlocked(db, conversationId: conversation, sender: d.sender) { return [] }
        } else {
            conversation = try MessageStore.privateConversation(db, serviceId: d.sender)
            // "Dropping story message - !profileSharing for sender"
            let sharing = try Bool.fetchOne(db, sql: "SELECT json ->> '$.profileSharing' FROM conversations WHERE id = ?", arguments: [conversation]) ?? false
            guard sharing else { return [] }
            if try MessageModifiers.isBlocked(db, conversationId: conversation, sender: d.sender) { return [] }
        }
        if story.hasProfileKey { try MessageStore.setProfileKey(db, serviceId: d.sender, story.profileKey) }
        guard let id = try StoryStore.insert(db, .init(conversationId: conversation, source: d.sender, sourceDevice: d.senderDevice, sentAt: timestamp,
                                                       serverTimestamp: e.serverTimestamp, serverGuid: e.serverGuid, story: story, outgoing: false,
                                                       unidentified: d.sealed)) else {
            throw ReceiveError.invalidEnvelope("text story without text or preview")
        }
        return [.story(storyId: id, conversationId: conversation, sender: d.sender, timestamp: timestamp)]
    }

    /// Our other device's sent story, or a recipient update.
    func handleSentStory(_ sent: Signalservice_SyncMessage.Sent, _ d: Decrypted, _ db: Database) throws -> [ReceiveEvent] {
        let timestamp = sent.timestamp
        var recipients: [(serviceId: String, lists: [String], allowedToReply: Bool)] = []
        for r in sent.storyMessageRecipients {
            guard let id = Self.serviceIdString(binary: r.hasDestinationServiceIDBinary ? r.destinationServiceIDBinary : nil,
                                                string: r.hasDestinationServiceID ? r.destinationServiceID : nil) else { continue }
            recipients.append((id, r.distributionListIds.map { $0.lowercased() }, r.isAllowedToReply))
        }
        if !sent.hasStoryMessage {
            try applyStoryRecipientUpdate(db, timestamp: timestamp, recipients: recipients)
            return [.sync(kind: "storyRecipientUpdate", senderDevice: d.senderDevice)]
        }
        let story = sent.storyMessage
        if sent.isRecipientUpdate, try StoryStore.find(db, author: account.aci, sentAt: timestamp) != nil {
            try applyStoryRecipientUpdate(db, timestamp: timestamp, recipients: recipients)
            return [.sync(kind: "storyRecipientUpdate", senderDevice: d.senderDevice)]
        }
        func state(_ serviceIds: [String]) throws -> [String: Any] {
            var out: [String: Any] = [:]
            for s in serviceIds {
                let c = try MessageStore.privateConversation(db, serviceId: s)
                out[c] = ["status": "Sent", "updatedAt": MessageStore.now()]
            }
            return out
        }
        var events: [ReceiveEvent] = []
        if story.hasGroup, story.group.hasMasterKey {
            let conversation = try MessageStore.groupConversation(db, masterKey: story.group.masterKey).id
            if try StoryStore.find(db, author: account.aci, sentAt: timestamp) == nil,
               let id = try StoryStore.insert(db, .init(conversationId: conversation, source: account.aci, sourceDevice: d.senderDevice, sentAt: timestamp,
                                                        story: story, outgoing: true, sendState: try state(recipients.map(\.serviceId)))) {
                events.append(.story(storyId: id, conversationId: conversation, sender: account.aci, timestamp: timestamp))
            }
        } else {
            // One story per distribution list (the "sent distribution list story" events).
            let ours = try MessageStore.privateConversation(db, serviceId: account.aci)
            var byList: [String: [String]] = [:]
            for r in recipients { for l in r.lists { byList[l, default: []].append(r.serviceId) } }
            for (list, members) in byList.sorted(by: { $0.key < $1.key }) {
                let exists = try Int.fetchOne(db, sql: """
                    SELECT 1 FROM messages WHERE type = 'story' AND sourceServiceId = ? AND sent_at = ? AND storyDistributionListId = ?
                    """, arguments: [account.aci, Int64(timestamp), list]) != nil
                if exists { continue }
                if let id = try StoryStore.insert(db, .init(conversationId: ours, source: account.aci, sourceDevice: d.senderDevice, sentAt: timestamp,
                                                            story: story, outgoing: true, distributionListId: list, sendState: try state(members))) {
                    events.append(.story(storyId: id, conversationId: ours, sender: account.aci, timestamp: timestamp))
                }
            }
        }
        return events + [.sync(kind: "sentStory", senderDevice: d.senderDevice)]
    }

    /// `onStoryRecipientUpdate`: each of our stories sent at `timestamp` keeps only the
    /// recipients still listed for its list; a list story left with nobody is deleted.
    func applyStoryRecipientUpdate(_ db: Database, timestamp: UInt64,
                                   recipients: [(serviceId: String, lists: [String], allowedToReply: Bool)]) throws {
        let rows = try Row.fetchAll(db, sql: "SELECT id, json, storyDistributionListId FROM messages WHERE type = 'story' AND sourceServiceId = ? AND sent_at = ?",
                                    arguments: [account.aci, Int64(timestamp)])
        for row in rows {
            let id: String = row["id"]
            let list: String? = row["storyDistributionListId"]
            var json = try MessageStore.jsonObject(row["json"])
            guard let list else { continue }      // group stories keep their state
            let keep = try Set(recipients.filter { $0.lists.contains(list) }.map { try MessageStore.privateConversation(db, serviceId: $0.serviceId) })
            if keep.isEmpty {
                try db.execute(sql: "DELETE FROM messages WHERE id = ?", arguments: [id])
                continue
            }
            var states = json["sendStateByConversationId"] as? [String: [String: Any]] ?? [:]
            states = states.filter { keep.contains($0.key) }
            json["sendStateByConversationId"] = states
            try db.execute(sql: "UPDATE messages SET json = ? WHERE id = ?", arguments: [try MessageStore.jsonString(json), id])
        }
    }

    /// A reply or reaction to a story: the story it belongs to, or nil to drop it.
    enum StoryReplyTarget { case none, story(id: String), drop }

    func storyReplyTarget(_ m: Signalservice_DataMessage, isGroup: Bool, _ db: Database) throws -> StoryReplyTarget {
        guard m.hasStoryContext else { return .none }
        let ctx = m.storyContext
        guard let author = Self.serviceIdString(binary: ctx.hasAuthorAciBinary ? ctx.authorAciBinary : nil, string: ctx.hasAuthorAci ? ctx.authorAci : nil)
        else { return isGroup ? .drop : .none }
        guard let story = try StoryStore.find(db, author: author, sentAt: ctx.sentTimestamp) else {
            // "message in group but no matching story": dropped; 1:1 replies stay plain messages.
            return isGroup ? .drop : .none
        }
        if let list = story.distributionListId {
            guard let l = try StoryDistributionLists.list(db, id: list), l.allowsReplies else { return .drop }
        }
        return .story(id: story.id)
    }

    /// A group story reply follows its story's timer (it disappears with it).
    static func storyReplyExtra(_ db: Database, storyId: String) throws -> [String: Any] {
        var extra: [String: Any] = ["storyId": storyId]
        if let row = try Row.fetchOne(db, sql: "SELECT expireTimer, expirationStartTimestamp FROM messages WHERE id = ?", arguments: [storyId]) {
            extra["expireTimer"] = row["expireTimer"] as Int64?
            extra["expirationStartTimestamp"] = row["expirationStartTimestamp"] as Int64?
        }
        return extra
    }
}
