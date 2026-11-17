// Same-name warnings in the conversation header (upstream state/selectors/timeline
// getContactSpoofingWarningSelector, selectors/conversations getSafeConversationWithSameTitle,
// util/groupMemberNameCollisions, isConversationNameKnown, isInSystemContacts): someone asking to
// message us under the name of a contact we already talk to, and group members sharing a name.
// Titles are compared as they are shown (getTitle), so a look-alike under the same name is caught.

import Foundation
import GRDB

public enum ContactSpoofingCheck: Sendable, Equatable {
    /// A message request (not blocked) whose title is that of a 1:1 chat we accepted.
    case directConversationWithSameTitle(safeConversationId: String)
    /// Members (not us, with a known name) sharing a title, unless all of them are system
    /// contacts: their private conversations by title, and the collisions acknowledged so far.
    case multipleGroupMembersWithSameTitle(collisions: [String: [String]], acknowledged: [String: [String]])

    /// `getRenderableContactSpoofingWarning` for a group: a collision has a member not
    /// acknowledged yet (`hasUnacknowledgedCollisions`). A direct warning shows until dismissed.
    public var isRenderable: Bool {
        switch self {
        case .directConversationWithSameTitle: true
        case .multipleGroupMembersWithSameTitle(let collisions, let acknowledged):
            collisions.contains { title, ids in
                let seen = Set(acknowledged[title] ?? [])
                return ids.contains { !seen.contains($0) }
            }
        }
    }
}

/// One person in the same-name review.
public struct ContactSpoofingCandidate: Sendable, Equatable {
    public var conversationId: String
    public var serviceId: String?
    public var title: String
    public var profileName: String?
    public var e164: String?
    public var color: String
    public var avatar: LocalFile?
    public var isSignalConnection: Bool
    public var isBlocked: Bool
    public var sharedGroupNames: [String]
}

public enum ContactSpoofing {
    public static func check(_ db: Database, conversationId: String, ourAci: String) throws -> ContactSpoofingCheck? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM conversations WHERE id = ?", arguments: [conversationId]) else { return nil }
        let json = try MessageStore.jsonObject(row["json"])
        if (row["type"] as String?) == "private" {
            let serviceId: String? = row["serviceId"]
            guard serviceId != ourAci, try !ConversationState.isAccepted(db, conversationId: conversationId, ourAci: ourAci),
                  try !MessageModifiers.isBlocked(db, conversationId: conversationId, sender: serviceId ?? "") else { return nil }
            let title = ConversationQueries.title(row, json: json, kind: .private)
            for other in try Row.fetchAll(db, sql: "SELECT * FROM conversations WHERE type = 'private' AND id != ?", arguments: [conversationId]) {
                guard ConversationQueries.title(other, json: try MessageStore.jsonObject(other["json"]), kind: .private) == title else { continue }
                let id: String = other["id"]
                if try ConversationState.isAccepted(db, conversationId: id, ourAci: ourAci) { return .directConversationWithSameTitle(safeConversationId: id) }
            }
            return nil
        }
        guard json["left"] as? Bool != true, let state = try GroupStore.load(db, conversationId: conversationId)?.state else { return nil }
        var byTitle: [String: [(id: String, inSystemContacts: Bool)]] = [:]
        for member in state.membersV2 where member.aci != ourAci {
            guard let m = try Row.fetchOne(db, sql: "SELECT * FROM conversations WHERE type = 'private' AND serviceId = ?", arguments: [member.aci])
            else { continue }
            let mj = try MessageStore.jsonObject(m["json"])
            guard isNameKnown(m, mj) else { continue }
            byTitle[ConversationQueries.title(m, json: mj, kind: .private), default: []].append((m["id"], isInSystemContacts(mj)))
        }
        let collisions = byTitle.filter { $0.value.count >= 2 && !$0.value.allSatisfy(\.inSystemContacts) }.mapValues { $0.map(\.id) }
        guard !collisions.isEmpty else { return nil }
        let acknowledged = json["acknowledgedGroupNameCollisions"] as? [String: [String]] ?? [:]
        return .multipleGroupMembersWithSameTitle(collisions: collisions, acknowledged: acknowledged)
    }

    /// `acknowledgeGroupMemberNameCollisions`: the warning stays away until someone else joins
    /// a collision.
    public static func acknowledge(_ db: Database, conversationId: String, collisions: [String: [String]]) throws {
        try MessageStore.updateConversationJSON(db, conversationId: conversationId) { $0["acknowledgedGroupNameCollisions"] = collisions }
    }

    /// The people the review dialog shows (ContactSpoofingReviewDialog's conversations, with
    /// `isSignalConnection` and `sharedGroupNames`), in the order asked.
    public static func candidates(_ db: Database, conversationIds: [String]) throws -> [ContactSpoofingCandidate] {
        let groups = try Row.fetchAll(db, sql: "SELECT json FROM conversations WHERE type = 'group'").compactMap { g -> (name: String, members: Set<String>)? in
            let gj = try MessageStore.jsonObject(g["json"])
            guard gj["left"] as? Bool != true, gj["terminated"] as? Bool != true, let name = gj["name"] as? String, !name.isEmpty else { return nil }
            return (name, Set((gj["membersV2"] as? [[String: Any]] ?? []).compactMap { $0["aci"] as? String }))
        }
        return try conversationIds.compactMap { id in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM conversations WHERE id = ? AND type = 'private'", arguments: [id]) else { return nil }
            let json = try MessageStore.jsonObject(row["json"])
            let serviceId: String? = row["serviceId"], e164: String? = row["e164"]
            let blocked = try MessageModifiers.isBlocked(db, conversationId: id, sender: serviceId ?? "")
            func text(_ k: String) -> String? { (json[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
            let profileName = [text("profileName"), text("profileFamilyName")].compactMap { $0 }.joined(separator: " ")
            return ContactSpoofingCandidate(
                conversationId: id, serviceId: serviceId, title: ConversationQueries.title(row, json: json, kind: .private),
                profileName: profileName.isEmpty ? nil : profileName, e164: e164 ?? text("e164"),
                color: json["color"] as? String ?? ConversationQueries.avatarColor(serviceId: serviceId, e164: e164, groupId: nil),
                avatar: LocalFile.from(json["profileAvatar"]),
                isSignalConnection: (json["profileSharing"] as? Bool == true || isInSystemContacts(json)) && !blocked, isBlocked: blocked,
                sharedGroupNames: serviceId.map { s in groups.filter { $0.members.contains(s) }.map(\.name).sorted() } ?? [])
        }
    }

    /// `isConversationNameKnown` for a direct conversation: a system or contact-sync name, a
    /// profile name or a number.
    static func isNameKnown(_ row: Row, _ json: [String: Any]) -> Bool {
        ["name", "systemGivenName", "systemFamilyName", "profileName", "e164"].contains { key in
            let v = (json[key] as? String) ?? (row.hasColumn(key) ? row[key] as String? : nil)
            return v?.isEmpty == false
        }
    }

    /// `isInSystemContacts`
    static func isInSystemContacts(_ json: [String: Any]) -> Bool {
        json["name"] is String || (json["systemGivenName"] as? String)?.isEmpty == false || (json["systemFamilyName"] as? String)?.isEmpty == false
    }
}

extension SignalDatabase {
    public func spoofingCandidates(conversationIds: [String]) async throws -> [ContactSpoofingCandidate] {
        try await pool.read { try ContactSpoofing.candidates($0, conversationIds: conversationIds) }
    }

    public func acknowledgeNameCollisions(conversationId: String, collisions: [String: [String]]) async throws {
        try await pool.write { try ContactSpoofing.acknowledge($0, conversationId: conversationId, collisions: collisions) }
    }
}
