// Group state on the conversation row (upstream's group attributes in conversations.json,
// plus the `name` and `members` columns), member profile keys onto their contacts, and the
// `group-v2-change` / `timer-notification` timeline messages a change produces.

import Foundation
import GRDB

public enum GroupStore {
    public struct Stored: Sendable {
        public var conversationId: String
        public var keys: GroupKeys
        /// nil until the first fetch.
        public var state: GroupV2State?
        public var left: Bool
    }

    static let stateKeys = ["revision", "name", "description", "expireTimer", "accessControl", "membersV2", "pendingMembersV2",
                            "pendingAdminApprovalV2", "bannedMembersV2", "groupInviteLinkPassword", "announcementsOnly", "terminated"]

    /// The group conversation for a master key (created if new).
    public static func conversation(_ db: Database, keys: GroupKeys) throws -> Stored {
        let (id, _) = try MessageStore.groupConversation(db, masterKey: keys.masterKey)
        try MessageStore.updateConversationJSON(db, conversationId: id) { json in
            if json["publicParams"] == nil { json["publicParams"] = keys.publicParams.base64EncodedString() }
        }
        return try load(db, conversationId: id)!
    }

    public static func load(_ db: Database, conversationId: String) throws -> Stored? {
        guard let s = try String.fetchOne(db, sql: "SELECT json FROM conversations WHERE id = ? AND type = 'group'", arguments: [conversationId]),
              let json = try? MessageStore.jsonObject(s), let mk = (json["masterKey"] as? String).flatMap({ Data(base64Encoded: $0) })
        else { return nil }
        let keys = try GroupKeys(masterKey: mk)
        var state: GroupV2State? = nil
        if json["revision"] != nil {
            var subset: [String: Any] = [:]
            for k in stateKeys { if let v = json[k] { subset[k] = v } }
            if let avatar = json["avatar"] as? [String: Any], let url = avatar["url"] { subset["avatarUrl"] = url }
            state = try JSONDecoder().decode(GroupV2State.self, from: JSONSerialization.data(withJSONObject: subset))
        }
        return Stored(conversationId: conversationId, keys: keys, state: state, left: json["left"] as? Bool ?? false)
    }

    public static func find(_ db: Database, groupId: Data) throws -> Stored? {
        guard let id = try String.fetchOne(db, sql: "SELECT id FROM conversations WHERE groupId = ?", arguments: [groupId.base64EncodedString()])
        else { return nil }
        return try load(db, conversationId: id)
    }

    /// Writes the state (transient member flags dropped) and `left`; avatar path/hash stay
    /// unless the URL changed.
    public static func save(_ db: Database, conversationId: String, state: GroupV2State, ourAci: String) throws {
        var clean = state
        clean.membersV2 = clean.membersV2.map { var m = $0; m.joinedFromLink = nil; m.approvedByAdmin = nil; return m }
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(clean)) as? [String: Any] ?? [:]
        try MessageStore.updateConversationJSON(db, conversationId: conversationId) { json in
            for k in stateKeys { json[k] = encoded[k] ?? NSNull() }
            for k in stateKeys where json[k] is NSNull { json[k] = nil }
            let oldURL = (json["avatar"] as? [String: Any])?["url"] as? String
            if let url = state.avatarUrl {
                if oldURL != url { json["avatar"] = ["url": url] }
            } else {
                json["avatar"] = nil
            }
            json["left"] = !state.isMember(ourAci)
            json["groupVersion"] = 2
        }
        try db.execute(sql: "UPDATE conversations SET name = ?, members = ? WHERE id = ?",
                       arguments: [state.name, state.membersV2.map(\.aci).joined(separator: " "), conversationId])
        if state.isMember(ourAci) { try StorageWriteBack.conversationCreated(db, conversationId: conversationId) }
    }

    /// Applies learnt profile keys to the members' contacts (not our own).
    static func saveProfileKeys(_ db: Database, _ keys: [String: Data], ourAci: String) throws {
        for (aci, key) in keys where aci != ourAci { _ = try MessageStore.setProfileKey(db, serviceId: aci, key) }
    }

    /// Inserts the timeline messages for a change (`appendChangeMessages`).
    @discardableResult
    static func appendChangeMessages(_ db: Database, conversationId: String, _ messages: [GroupChangeMessage], timestamp: UInt64) throws -> [String] {
        var ids: [String] = []
        for m in messages {
            let detailsJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(m.details))
            var extra: [String: Any] = [:]
            let type: String
            if let timer = m.timer {
                type = "timer-notification"
                var update: [String: Any] = ["expireTimer": timer]
                if let from = m.from { update["sourceServiceId"] = from }
                extra["expirationTimerUpdate"] = update
                extra["flags"] = 2   // DataMessage.Flags.EXPIRATION_TIMER_UPDATE
            } else {
                type = "group-v2-change"
                var change: [String: Any] = ["details": detailsJSON]
                if let from = m.from { change["from"] = from }
                extra["groupV2Change"] = change
            }
            extra["readStatus"] = (m.read ? ReadStatus.read : .unread).rawValue
            extra["seenStatus"] = SeenStatus.unseen.rawValue
            let id = try MessageStore.insert(db, .init(conversationId: conversationId, type: type, body: "", sentAt: timestamp, source: m.from,
                                                       sourceDevice: nil, serverGuid: nil, serverTimestamp: nil, unidentified: false, extra: extra))
            ids.append(id)
        }
        return ids
    }
}
