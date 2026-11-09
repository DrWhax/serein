// Conversation-level state (Phase 4 step 6b): disappearing messages (DataMessage.expireTimer +
// expireTimerVersion, timer notifications, timers that start when an incoming message is
// read, deletion when they run out, the universal timer), message requests
// (`isConversationAccepted`, MessageRequestResponse), blocking (with the Blocked sync),
// archive / mute / pin / mark unread, nicknames and notes. Local changes go to storage
// (`StorageWriteBack`) as upstream's `captureChange` does.

import Foundation
import GRDB
import LibSignalClient
import SignalProtos

public enum MessageRequestResponse: Int, Sendable {
    case accept = 1, delete = 2, block = 3, blockAndDelete = 4, spam = 5, blockAndSpam = 6
}

enum ConversationState {
    // MARK: message requests (util/isConversationAccepted.preload.ts)

    static func isTrusted(_ db: Database, privateConversation json: [String: Any], serviceId: String?, ourAci: String) -> Bool {
        serviceId == ourAci || json["systemGivenName"] != nil || json["systemFamilyName"] != nil || (json["profileSharing"] as? Bool ?? false)
    }

    static func isAccepted(_ db: Database, conversationId: String, ourAci: String, ignoreEmptyConvo: Bool = false) throws -> Bool {
        guard let row = try Row.fetchOne(db, sql: "SELECT type, serviceId, json FROM conversations WHERE id = ?", arguments: [conversationId]) else { return false }
        let json = try MessageStore.jsonObject(row["json"])
        let serviceId: String? = row["serviceId"]
        if serviceId == ourAci { return true }
        if json["removalStage"] != nil { return false }
        if json["messageRequestResponseType"] as? Int == MessageRequestResponse.accept.rawValue { return true }
        let isGroup = (row["type"] as String?) == "group"
        if isGroup, let g = try GroupStore.load(db, conversationId: conversationId), g.state?.isPendingApproval(ourAci) == true { return true }
        let sent = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages WHERE conversationId = ? AND type = 'outgoing'", arguments: [conversationId]) ?? 0
        let total = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages WHERE conversationId = ? AND type IN ('incoming', 'outgoing')",
                                     arguments: [conversationId]) ?? 0
        let before = json["messageCountBeforeMessageRequests"] as? Int ?? 0
        var trusted: Bool
        if isGroup {
            trusted = false
            if let addedBy = json["addedBy"] as? String,
               let a = try Row.fetchOne(db, sql: "SELECT serviceId, json FROM conversations WHERE id = ?", arguments: [addedBy]) {
                trusted = isTrusted(db, privateConversation: try MessageStore.jsonObject(a["json"]), serviceId: a["serviceId"], ourAci: ourAci)
            }
        } else {
            trusted = isTrusted(db, privateConversation: json, serviceId: serviceId, ourAci: ourAci)
        }
        let emptyPrivate = total == 0 && !isGroup && !ignoreEmptyConvo
        let emptyWhitelistedGroup = total == 0 && isGroup && (json["profileSharing"] as? Bool ?? false)
        return trusted || sent > 0 || before > 0 || emptyPrivate || emptyWhitelistedGroup
    }

    /// `applyMessageRequestResponse`
    static func applyResponse(_ db: Database, conversationId: String, _ type: MessageRequestResponse, ourAci: String) throws {
        let row = try Row.fetchOne(db, sql: "SELECT serviceId, groupId FROM conversations WHERE id = ?", arguments: [conversationId])
        let serviceId: String? = row?["serviceId"], groupId: String? = row?["groupId"]
        switch type {
        case .accept:
            try MessageStore.updateConversationJSON(db, conversationId: conversationId) { json in
                json["messageRequestResponseType"] = type.rawValue
                json["profileSharing"] = true
                json["removalStage"] = nil
            }
            try setBlocked(db, serviceId: serviceId, groupId: groupId, false)
        case .delete, .spam:
            try deleteMessages(db, conversationId: conversationId)
            try MessageStore.updateConversationJSON(db, conversationId: conversationId) { json in
                json["messageRequestResponseType"] = type.rawValue
                json["profileSharing"] = false
                if type == .spam { json["isReportingSpam"] = true }
            }
        case .block, .blockAndDelete, .blockAndSpam:
            try setBlocked(db, serviceId: serviceId, groupId: groupId, true)
            try MessageStore.updateConversationJSON(db, conversationId: conversationId) { json in
                json["messageRequestResponseType"] = type.rawValue
                json["profileSharing"] = false
            }
            if type != .block { try deleteMessages(db, conversationId: conversationId) }
        }
    }

    /// Attachments of a conversation that were stored but not queued (it was not accepted).
    static func queueHeldDownloads(_ db: Database, conversationId: String) throws {
        for id in try String.fetchAll(db, sql: "SELECT id FROM messages WHERE conversationId = ? AND type = 'incoming'", arguments: [conversationId]) {
            for (loc, a) in try MessageAttachments.fetch(db, messageId: id) where !a.isDownloaded && a.pending != true && a.cdnKey != nil {
                try MessageStore.queueDownload(db, loc)
            }
        }
    }

    static func deleteMessages(_ db: Database, conversationId: String) throws {
        for id in try String.fetchAll(db, sql: "SELECT id FROM messages WHERE conversationId = ?", arguments: [conversationId]) {
            try DeleteForMe.deleteMessage(db, id)
        }
        try db.execute(sql: "UPDATE conversations SET active_at = NULL WHERE id = ?", arguments: [conversationId])
    }

    static func setBlocked(_ db: Database, serviceId: String?, groupId: String?, _ blocked: Bool) throws {
        let at = blocked ? MessageStore.now() : nil
        if let groupId { try BlockedList.groups.set(db, groupId, blocked: blocked, at: at) }
        if let serviceId { try BlockedList.serviceIds.set(db, serviceId, blocked: blocked, at: at) }
    }

    // MARK: disappearing messages (expirationTimer, MessageReceiver timer updates)

    static let expirationTimerUpdateFlag: UInt32 = 2
    static let profileKeyUpdateFlag: UInt32 = 4

    struct Timer { var seconds: UInt32?; var version: UInt32 }

    static func timer(_ db: Database, conversationId: String) throws -> Timer {
        let json = try MessageStore.jsonObject(try String.fetchOne(db, sql: "SELECT json FROM conversations WHERE id = ?", arguments: [conversationId]) ?? "{}")
        let seconds = (json["expireTimer"] as? NSNumber)?.uint32Value
        return Timer(seconds: seconds == 0 ? nil : seconds, version: (json["expireTimerVersion"] as? NSNumber)?.uint32Value ?? 1)
    }

    /// An incoming or synced 1:1 timer (flag or carried by a message): applied when its version
    /// is newer (version 1 = a legacy client, applied when the timer differs). Returns whether
    /// it changed.
    @discardableResult
    static func applyIncomingTimer(_ db: Database, conversationId: String, seconds: UInt32, version: UInt32, from: String, sentAt: UInt64,
                                   isGroup: Bool, isUpdate: Bool) throws -> Bool {
        guard !isGroup else { return false }   // group timers come with group changes
        let current = try timer(db, conversationId: conversationId)
        let newSeconds: UInt32? = seconds == 0 ? nil : seconds
        if version > 1 { guard version > current.version else { return false } }
        guard newSeconds != current.seconds || version > current.version else { return false }
        let changed = newSeconds != current.seconds
        try MessageStore.updateConversationJSON(db, conversationId: conversationId) { json in
            json["expireTimer"] = newSeconds
            json["expireTimerVersion"] = max(version, current.version)
        }
        if changed { try insertTimerNotification(db, conversationId: conversationId, seconds: newSeconds ?? 0, from: from, sentAt: sentAt) }
        return changed
    }

    static func insertTimerNotification(_ db: Database, conversationId: String, seconds: UInt32, from: String?, sentAt: UInt64) throws {
        var update: [String: Any] = ["expireTimer": seconds]
        if let from { update["sourceServiceId"] = from }
        try MessageStore.insert(db, .init(conversationId: conversationId, type: "timer-notification", body: "", sentAt: sentAt, source: from, sourceDevice: nil,
                                          serverGuid: nil, serverTimestamp: nil, unidentified: false,
                                          extra: ["expirationTimerUpdate": update, "flags": Int(expirationTimerUpdateFlag),
                                                  "readStatus": ReadStatus.read.rawValue, "seenStatus": SeenStatus.unseen.rawValue]))
    }

    /// The message's own timer: outgoing ones start now, incoming ones when read.
    static func setMessageTimer(_ db: Database, messageId: String, seconds: UInt32, startedAt: Int64?) throws {
        guard seconds > 0 else { return }
        try MessageStore.updateJSON(db, messageId: messageId) { json in
            json["expireTimer"] = seconds
            if let startedAt { json["expirationStartTimestamp"] = startedAt }
        }
        try db.execute(sql: "UPDATE messages SET expireTimer = ?, expirationStartTimestamp = ? WHERE id = ?", arguments: [Int(seconds), startedAt, messageId])
    }

    /// Reading an incoming message starts its timer (`setToExpire` after markRead).
    static func startTimers(_ db: Database, messageIds: [String], at: Int64) throws {
        for id in messageIds {
            try db.execute(sql: "UPDATE messages SET expirationStartTimestamp = ? WHERE id = ? AND expireTimer > 0 AND expirationStartTimestamp IS NULL",
                           arguments: [at, id])
            if db.changesCount > 0 { try MessageStore.updateJSON(db, messageId: id) { $0["expirationStartTimestamp"] = at } }
        }
    }

    /// `deleteExpiredMessages`: returns the ids removed.
    @discardableResult
    static func deleteExpired(_ db: Database, now: Int64) throws -> [String] {
        let ids = try String.fetchAll(db, sql: "SELECT id FROM messages WHERE expiresAt IS NOT NULL AND expiresAt <= ?", arguments: [now])
        for id in ids { try DeleteForMe.deleteMessage(db, id) }
        return ids
    }

    /// The DataMessage fields carrying the conversation's timer.
    static func stamp(_ db: Database, conversationId: String, into data: inout Signalservice_DataMessage) throws {
        if let g = try GroupStore.load(db, conversationId: conversationId) {
            if let t = g.state?.expireTimer, t > 0 { data.expireTimer = UInt32(t) }
            return
        }
        let t = try timer(db, conversationId: conversationId)
        if let s = t.seconds { data.expireTimer = s }
        data.expireTimerVersion = t.version
    }
}

extension Messenger {
    // MARK: message requests

    /// `syncMessageRequestResponse` + the local change; accepting a 1:1 also sends our profile
    /// key to them (`sendProfileKeyUpdate`).
    ///
    /// For a group (`groups` given), blocking or deleting leaves it and accepting accepts a
    /// pending invite (`leaveGroupV2`, `acceptInvite`). Accepting downloads the media that
    /// waited for it (`handleReadAndDownloadAttachments`).
    public func respondToMessageRequest(conversationId: String, _ type: MessageRequestResponse, groups: GroupsService? = nil) async throws {
        let ourAci = account.aci
        let (serviceId, groupId, group) = try await database.pool.write { db -> (String?, String?, GroupStore.Stored?) in
            try ConversationState.applyResponse(db, conversationId: conversationId, type, ourAci: ourAci)
            try StorageWriteBack.conversationChanged(db, conversationId: conversationId)
            if type == .accept { try ConversationState.queueHeldDownloads(db, conversationId: conversationId) }
            let row = try Row.fetchOne(db, sql: "SELECT serviceId, groupId FROM conversations WHERE id = ?", arguments: [conversationId])
            return (row?["serviceId"], row?["groupId"], try GroupStore.load(db, conversationId: conversationId))
        }
        if let groups, let group, let state = group.state {
            if type == .accept, state.isPending(ourAci) {
                try await groups.acceptInvite(group.keys)
            } else if type != .accept, state.isMember(ourAci) || state.isPending(ourAci) {
                try await groups.leave(group.keys)
            }
        }
        var r = Signalservice_SyncMessage.MessageRequestResponse()
        r.type = .init(rawValue: type.rawValue) ?? .unknown
        if let groupId, let g = Data(base64Encoded: groupId) { r.groupID = g } else if let serviceId, let b = StorageLocal.uuidBytes(serviceId) { r.threadAciBinary = b }
        var sync = Self.syncMessage()
        sync.messageRequestResponse = r
        try await sendToSelf(sync, timestamp: UInt64(MessageStore.now()), urgent: false, messageIds: [])
        if type == .accept, groupId == nil, let serviceId, let pk = account.profileKey {
            var data = Signalservice_DataMessage()
            data.timestamp = UInt64(MessageStore.now())
            data.flags = ConversationState.profileKeyUpdateFlag
            data.profileKey = pk
            var content = Signalservice_Content()
            content.dataMessage = data
            _ = try await sender.send(OutgoingPayload(content: content, timestamp: data.timestamp, contentHint: .implicit, urgent: false), to: serviceId, messageIds: [])
        }
        jobs.poke()
    }

    /// `isConversationAccepted`
    public func isAccepted(_ conversationId: String) async throws -> Bool {
        let ourAci = account.aci
        return try await database.pool.read { try ConversationState.isAccepted($0, conversationId: conversationId, ourAci: ourAci) }
    }

    // MARK: blocking

    /// `block` / `unblock`: the list, our devices (SyncMessage.Blocked with the whole list), and
    /// storage. Blocking also stops profile sharing.
    public func setBlocked(_ conversationId: String, _ blocked: Bool) async throws {
        let sync = try await database.pool.write { db -> Signalservice_SyncMessage.Blocked in
            let row = try Row.fetchOne(db, sql: "SELECT serviceId, groupId, e164 FROM conversations WHERE id = ?", arguments: [conversationId])
            try ConversationState.setBlocked(db, serviceId: row?["serviceId"], groupId: row?["groupId"], blocked)
            if blocked { try MessageStore.updateConversationJSON(db, conversationId: conversationId) { $0["profileSharing"] = false } }
            try StorageWriteBack.conversationChanged(db, conversationId: conversationId)
            var b = Signalservice_SyncMessage.Blocked()
            b.numbers = try BlockedList.numbers.entries(db).map(\.id)
            b.acisBinary = try BlockedList.serviceIds.entries(db).compactMap { StorageLocal.uuidBytes($0.id) }
            b.groupIds = try BlockedList.groups.entries(db).compactMap { Data(base64Encoded: $0.id) }
            return b
        }
        var s = Self.syncMessage()
        s.blocked = sync
        try await sendToSelf(s, timestamp: UInt64(MessageStore.now()), urgent: false, messageIds: [])
        jobs.poke()
    }

    // MARK: archive / mute / pin / unread / nickname / note

    func changeConversation(_ conversationId: String, account changesAccount: Bool = false, _ change: @escaping @Sendable (inout [String: Any]) -> Void) async throws {
        let account = self.account
        try await database.pool.write { db in
            try MessageStore.updateConversationJSON(db, conversationId: conversationId, change)
            if changesAccount { try StorageWriteBack.accountChanged(db, account: account) }
            try StorageWriteBack.conversationChanged(db, conversationId: conversationId)
        }
        jobs.poke()
    }

    /// Archiving unpins (upstream `setArchived`).
    public func setArchived(_ conversationId: String, _ archived: Bool) async throws {
        if archived { try await setPinned(conversationId, false) }
        try await changeConversation(conversationId) { $0["isArchived"] = archived }
    }

    /// nil unmutes; `Int64.max`-like values mean forever (MuteExpiration.ALWAYS).
    public func setMuted(_ conversationId: String, until: Int64?) async throws {
        try await changeConversation(conversationId) { $0["muteExpiresAt"] = until.map { min($0, StorageLocal.muteAlways) } }
    }

    /// Saves (or, for an empty body, clears) the composer's unsent text: `json.draft`,
    /// `draftBodyRanges` and `draftTimestamp`, as upstream. Local only (not a storage record).
    public func saveDraft(_ conversationId: String, body: String, bodyRanges: [MessageBodyRange]) async throws {
        let ranges = MessageBodyRange.valid(bodyRanges, bodyLength: body.utf16.count)
        let now = MessageStore.now()
        try await database.pool.write { db in
            try MessageStore.updateConversationJSON(db, conversationId: conversationId) { json in
                if body.isEmpty {
                    json["draft"] = nil
                    json["draftBodyRanges"] = nil
                    json["draftTimestamp"] = nil
                } else {
                    json["draft"] = body
                    json["draftBodyRanges"] = ranges.map(\.json)
                    json["draftTimestamp"] = now
                }
            }
        }
    }

    public func setMarkedUnread(_ conversationId: String, _ unread: Bool) async throws {
        try await changeConversation(conversationId) { $0["markedUnread"] = unread }
    }

    /// `pinConversation`: at most 4 pinned (`MAX_PINNED_CONVERSATIONS`); the AccountRecord holds pins.
    public static let maxPinnedConversations = 4

    public func setPinned(_ conversationId: String, _ pinned: Bool) async throws {
        let account = self.account
        try await database.pool.write { db in
            var ids = try Items.get(db, "pinnedConversationIds", as: [String].self) ?? []
            if pinned {
                guard !ids.contains(conversationId) else { return }
                guard ids.count < Self.maxPinnedConversations else { throw ModifierError.notAllowed("at most \(Self.maxPinnedConversations) pinned chats") }
                ids.append(conversationId)
            } else {
                guard ids.contains(conversationId) else { return }
                ids.removeAll { $0 == conversationId }
            }
            try Items.set(db, "pinnedConversationIds", ids)
            try MessageStore.updateConversationJSON(db, conversationId: conversationId) { json in
                json["isPinned"] = pinned
                if pinned { json["isArchived"] = false }
            }
            try StorageWriteBack.accountChanged(db, account: account)
        }
        jobs.poke()
    }

    /// Nickname and note (ContactRecord.nickname / note).
    public func setNickname(_ conversationId: String, given: String?, family: String?) async throws {
        try await changeConversation(conversationId) { json in
            json["nicknameGivenName"] = given.flatMap { $0.isEmpty ? nil : $0 }
            json["nicknameFamilyName"] = family.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    public func setNote(_ conversationId: String, _ note: String?) async throws {
        try await changeConversation(conversationId) { $0["note"] = note.flatMap { $0.isEmpty ? nil : $0 } }
    }

    // MARK: disappearing messages

    /// `updateExpirationTimer`: a 1:1 timer goes out as an EXPIRATION_TIMER_UPDATE with the
    /// next version; a group's is a group change.
    public func setDisappearingTimer(_ conversationId: String, seconds: UInt32, groups: GroupsService? = nil) async throws {
        let isGroup = try await database.pool.read { try GroupStore.load($0, conversationId: conversationId) } != nil
        if isGroup {
            guard let groups, let keys = try await database.pool.read({ try GroupStore.load($0, conversationId: conversationId)?.keys }) else {
                throw ModifierError.notAllowed("group timer needs the groups service")
            }
            try await groups.setDisappearingMessagesTimer(keys, seconds: Int(seconds))
            return
        }
        let ourAci = account.aci
        let timestamp = UInt64(MessageStore.now())
        let data = try await database.pool.write { db -> Signalservice_DataMessage in
            let current = try ConversationState.timer(db, conversationId: conversationId)
            let version = current.version + 1
            try MessageStore.updateConversationJSON(db, conversationId: conversationId) { json in
                json["expireTimer"] = seconds == 0 ? nil : seconds
                json["expireTimerVersion"] = version
            }
            try ConversationState.insertTimerNotification(db, conversationId: conversationId, seconds: seconds, from: ourAci, sentAt: timestamp)
            var d = Signalservice_DataMessage()
            d.timestamp = timestamp
            d.flags = ConversationState.expirationTimerUpdateFlag
            d.expireTimer = seconds
            d.expireTimerVersion = version
            var content = Signalservice_Content()
            content.dataMessage = d
            try JobQueue.insert(db, queueType: ConversationJob.queueType,
                                payload: ConversationJob.modifierSend(conversationId: conversationId, content: try content.serializedBytes(), timestamp: timestamp))
            return d
        }
        _ = data
        jobs.poke()
    }

    /// Removes messages whose timer ran out (call periodically; upstream's expiringMessagesDeletionService).
    @discardableResult
    public func deleteExpiredMessages(now: Int64? = nil) async throws -> Int {
        let at = now ?? Int64(Date().timeIntervalSince1970 * 1000)
        return try await database.pool.write { try ConversationState.deleteExpired($0, now: at).count }
    }
}
