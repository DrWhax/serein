// Chat events recorded as they happen, as upstream's ConversationModel does
// (ts/models/conversations.preload.ts): profile name changes (`addProfileChange`), number
// changes (`addChangeNumberNotification`), message request responses
// (`addMessageRequestResponseEventMessage`, by `applyMessageRequestResponse`'s rules), ended
// polls (`addPollTerminateNotification`) and phone number discovery
// (`addPhoneNumberDiscoveryIfNeeded`). The history import writes the same rows.

import Foundation
import GRDB

enum ChatEventNotices {
    /// A notice row. Unlike a message it does not make its chat active (upstream's notices do
    /// not set `active_at`).
    @discardableResult
    static func insert(_ db: Database, conversationId: String, type: String, sentAt: Int64, source: String? = nil,
                       readStatus: ReadStatus = .read, seenStatus: SeenStatus, extra: [String: Any] = [:]) throws -> String {
        let active = try Int64.fetchOne(db, sql: "SELECT active_at FROM conversations WHERE id = ?", arguments: [conversationId])
        var fields = extra
        fields["readStatus"] = readStatus.rawValue
        fields["seenStatus"] = seenStatus.rawValue
        let id = try MessageStore.insert(db, .init(conversationId: conversationId, type: type, body: "", sentAt: UInt64(max(0, sentAt)), source: source,
                                                   sourceDevice: nil, serverGuid: nil, serverTimestamp: nil, unidentified: false, extra: fields))
        try db.execute(sql: "UPDATE conversations SET active_at = ? WHERE id = ?", arguments: [active, conversationId])
        return id
    }

    /// The groups we are in with `aci` (`getSharedGroups`).
    static func sharedGroups(_ db: Database, aci: String) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT DISTINCT conversations.id FROM conversations, json_each(conversations.json, '$.membersV2') AS m
            WHERE conversations.type = 'group' AND coalesce(json_extract(conversations.json, '$.left'), 0) = 0
              AND json_extract(m.value, '$.aci') = ?
            """, arguments: [aci])
    }

    // MARK: profile names

    /// `setEncryptedProfileName`: a contact's profile name changed from one they had (not ours):
    /// a notice in their chat and in each group shared with them (`changedId` names them).
    static func profileNameChanged(_ db: Database, conversationId: String, serviceId: String, oldName: String?, newName: String?,
                                   ourAci: String) throws {
        guard serviceId != ourAci, let oldName, !oldName.isEmpty, oldName != newName else { return }
        let change: [String: Any] = ["type": "name", "oldName": oldName, "newName": newName ?? ""]
        for chat in [conversationId] + (try sharedGroups(db, aci: serviceId)) {
            try insert(db, conversationId: chat, type: "profile-change", sentAt: MessageStore.now(), seenStatus: .notApplicable,
                       extra: ["changedId": conversationId, "profileChange": change])
        }
    }

    // MARK: numbers

    /// `updateE164` → `addChangeNumberNotification`, called before the chat's number is set to
    /// `new`: a contact we knew by another number gets the notice in their chat and each shared
    /// group (never ourselves).
    static func numberChanging(_ db: Database, conversationId: String, to new: String?) throws {
        let ourAci = ((try Items.get(db, "uuid_id") as String?) ?? "").split(separator: ".").first.map(String.init)
        let row = try Row.fetchOne(db, sql: "SELECT serviceId, e164 FROM conversations WHERE id = ?", arguments: [conversationId])
        guard let old: String = row?["e164"], !old.isEmpty, let new, !new.isEmpty, old != new,
              let serviceId: String = row?["serviceId"], serviceId != ourAci else { return }
        var chats = [conversationId]
        if !serviceId.hasPrefix("PNI:") { chats += try sharedGroups(db, aci: serviceId) }
        for chat in chats {
            try insert(db, conversationId: chat, type: "change-number-notification", sentAt: MessageStore.now(), source: serviceId, seenStatus: .unseen)
        }
    }

    /// `addPhoneNumberDiscoveryIfNeeded`: a chat known by its PNI learned its ACI (not from a PNI
    /// signature) and we had a session with that PNI: the number is now linked to the account.
    static func phoneNumberDiscovered(_ db: Database, conversationId: String, oldPni: String) throws {
        guard let e164 = try String.fetchOne(db, sql: "SELECT e164 FROM conversations WHERE id = ?", arguments: [conversationId]), !e164.isEmpty,
              try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM sessions WHERE serviceId = ?)", arguments: [oldPni]) == true
        else { return }
        try insert(db, conversationId: conversationId, type: "phone-number-discovery", sentAt: MessageStore.now(), seenStatus: .unseen,
                   extra: ["phoneNumberDiscovery": ["e164": e164]])
    }

    // MARK: message requests

    /// `MessageRequestResponseEvent`
    enum RequestEvent: String { case accept = "ACCEPT", block = "BLOCK", unblock = "UNBLOCK", spam = "SPAM" }

    /// The state `applyMessageRequestResponse` compares: the last response and whether the chat
    /// is blocked.
    struct RequestState {
        var response: Int?
        var blocked: Bool

        static func of(_ db: Database, conversationId: String) throws -> RequestState {
            let row = try Row.fetchOne(db, sql: "SELECT serviceId, groupId, json FROM conversations WHERE id = ?", arguments: [conversationId])
            let json = try MessageStore.jsonObject(row?["json"] ?? "{}")
            var blocked = false
            if let groupId: String = row?["groupId"] { blocked = try BlockedList.groups.blockedAt(db, groupId).blocked }
            if let serviceId: String = row?["serviceId"] { blocked = try blocked || BlockedList.serviceIds.blockedAt(db, serviceId).blocked }
            return RequestState(response: (json["messageRequestResponseType"] as? NSNumber)?.intValue, blocked: blocked)
        }
    }

    /// `applyMessageRequestResponse`'s notices for a response that changed the state: accepting
    /// notes the accept (an unblock if the chat was blocked); a block that changed it, a block;
    /// a spam report that changed it, a report. Each is one millisecond after the last.
    static func requestResponded(_ db: Database, conversationId: String, _ response: MessageRequestResponse, before: RequestState,
                                 at timestamp: Int64) throws {
        guard response.rawValue != before.response else { return }
        let hasBlock = { (r: Int?) in [MessageRequestResponse.block, .blockAndDelete, .blockAndSpam].map(\.rawValue).contains(r ?? -1) }
        let hasSpam = { (r: Int?) in [MessageRequestResponse.spam, .blockAndSpam].map(\.rawValue).contains(r ?? -1) }
        var events: [RequestEvent] = []
        if response == .accept { events.append(before.blocked ? .unblock : .accept) }
        if hasBlock(response.rawValue), !before.blocked { events.append(.block) }
        if hasSpam(response.rawValue), !hasSpam(before.response) { events.append(.spam) }
        for (i, event) in events.enumerated() {
            try requestEvent(db, conversationId: conversationId, event, sentAt: timestamp + Int64(i))
        }
    }

    /// One `message-request-response-event`; a chat with no activity yet becomes active.
    static func requestEvent(_ db: Database, conversationId: String, _ event: RequestEvent, sentAt: Int64) throws {
        try insert(db, conversationId: conversationId, type: "message-request-response-event", sentAt: sentAt, seenStatus: .notApplicable,
                   extra: ["messageRequestResponseEvent": event.rawValue])
        try db.execute(sql: "UPDATE conversations SET active_at = ? WHERE id = ? AND active_at IS NULL", arguments: [MessageStore.now(), conversationId])
    }

    // MARK: pending notices on opening a chat

    /// `maybeSetPendingUniversalTimer`: a 1:1 chat (not Signal's) with nothing said yet, no
    /// timer of its own and a universal timer set shows "disappearing messages are on for new
    /// chats"; once something has been said, the notice goes.
    static func universalTimerOnOpen(_ db: Database, conversationId: String) throws {
        guard let row = try Row.fetchOne(db, sql: "SELECT type, serviceId, json FROM conversations WHERE id = ?", arguments: [conversationId]),
              (row["type"] as String?) == "private", (row["serviceId"] as String?) != StorageLocal.signalAci else { return }
        let json = try MessageStore.jsonObject(row["json"] ?? "{}")
        let said = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages WHERE conversationId = ? AND type IN ('incoming', 'outgoing')",
                                    arguments: [conversationId]) ?? 0
        if said > 0 {
            try removeUniversalTimerNotice(db, conversationId: conversationId)
            return
        }
        let universal = try Items.get(db, "universalExpireTimer", as: Int.self) ?? 0
        guard json["pendingUniversalTimer"] == nil, ((json["expireTimer"] as? NSNumber)?.intValue ?? 0) == 0, universal > 0 else { return }
        let id = try insert(db, conversationId: conversationId, type: "universal-timer-notification", sentAt: MessageStore.now(), seenStatus: .notApplicable)
        try MessageStore.updateConversationJSON(db, conversationId: conversationId) { $0["pendingUniversalTimer"] = id }
    }

    /// `maybeRemoveUniversalTimer`
    @discardableResult
    static func removeUniversalTimerNotice(_ db: Database, conversationId: String) throws -> Bool {
        let json = try MessageStore.jsonObject(try String.fetchOne(db, sql: "SELECT json FROM conversations WHERE id = ?", arguments: [conversationId]) ?? "{}")
        guard let id = json["pendingUniversalTimer"] as? String else { return false }
        try db.execute(sql: "DELETE FROM messages WHERE id = ?", arguments: [id])
        try MessageStore.updateConversationJSON(db, conversationId: conversationId) { $0["pendingUniversalTimer"] = nil }
        return true
    }

    /// `maybeSetContactRemoved` / `maybeClearContactRemoved`: a removed contact's chat says so
    /// until the contact is back.
    static func contactRemovedOnOpen(_ db: Database, conversationId: String) throws {
        guard let row = try Row.fetchOne(db, sql: "SELECT type, json FROM conversations WHERE id = ?", arguments: [conversationId]),
              (row["type"] as String?) == "private" else { return }
        let json = try MessageStore.jsonObject(row["json"] ?? "{}")
        let pending = json["pendingRemovedContactNotification"] as? String
        if json["removalStage"] as? String == "justNotification" {
            guard pending == nil else { return }
            let id = try insert(db, conversationId: conversationId, type: "contact-removed-notification", sentAt: MessageStore.now(), seenStatus: .notApplicable)
            try MessageStore.updateConversationJSON(db, conversationId: conversationId) { $0["pendingRemovedContactNotification"] = id }
        } else if let pending {
            try db.execute(sql: "DELETE FROM messages WHERE id = ?", arguments: [pending])
            try MessageStore.updateConversationJSON(db, conversationId: conversationId) { $0["pendingRemovedContactNotification"] = nil }
        }
    }

    // MARK: polls

    /// `addPollTerminateNotification`: `terminator` ended the poll asking `question`, sent at
    /// `pollTimestamp`; unread and unseen unless we ended it.
    static func pollEnded(_ db: Database, conversationId: String, terminator: String, question: String, pollTimestamp: Int64, at timestamp: Int64,
                          ourAci: String) throws {
        let mine = terminator == ourAci
        try insert(db, conversationId: conversationId, type: "poll-terminate", sentAt: timestamp, source: terminator,
                   readStatus: mine ? .read : .unread, seenStatus: mine ? .seen : .unseen,
                   extra: ["pollTerminateNotification": ["question": question, "pollTimestamp": pollTimestamp]])
    }
}
