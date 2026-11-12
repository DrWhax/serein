// What the app shows about one contact (upstream's ConversationType fields for AboutContactModal,
// ContactModal and the conversation hero): the names (nickname, system contact, profile), the
// note, about, the number, whether we share our profile with them, the message request, blocked,
// verified, and the groups we share.

import Foundation
import GRDB

public struct ContactAboutInfo: Sendable, Equatable {
    /// Their 1:1 conversation, if there is one.
    public var conversationId: String?
    public var serviceId: String
    public var title: String
    /// The title without the nickname (`titleNoNickname`): shown when a nickname is set.
    public var titleNoNickname: String?
    public var profileName: String?
    public var profileFamilyName: String?
    public var nicknameGivenName: String?
    public var nicknameFamilyName: String?
    public var note: String?
    public var about: String?
    public var aboutEmoji: String?
    public var e164: String?
    public var systemGivenName: String?
    /// A name from the primary's system contacts (`isInSystemContacts`).
    public var isInSystemContacts: Bool
    public var profileSharing: Bool
    public var acceptedMessageRequest: Bool
    public var hasMessages: Bool
    public var isBlocked: Bool
    public var isVerified: Bool
    /// The groups we are both in (not left), by name (`getSharedGroupNames`).
    public var sharedGroupNames: [String]

    /// `isSignalConnection`: someone we share our profile with or have in contacts, not blocked.
    public var isSignalConnection: Bool { (profileSharing || isInSystemContacts) && !isBlocked }
    /// `isFromOrAddedByTrustedContact` for a direct chat: a contact name or a shared profile.
    public var isTrusted: Bool { isInSystemContacts || profileSharing }
    public var hasNickname: Bool { nicknameGivenName != nil || nicknameFamilyName != nil }
    public var hasProfileName: Bool { profileName != nil }
}

extension ConversationQueries {
    public static func contactAbout(_ db: Database, serviceId: String, ourAci: String?) throws -> ContactAboutInfo {
        let row = try Row.fetchOne(db, sql: "SELECT id, type, json, serviceId, e164, name FROM conversations WHERE serviceId = ? AND type = 'private'",
                                   arguments: [serviceId])
        let json = row.flatMap { try? MessageStore.jsonObject($0["json"] ?? "{}") } ?? [:]
        func text(_ key: String) -> String? { (json[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let conversationId: String? = row?["id"]
        var title = "Unknown contact"
        var withoutNickname: String?
        if let row {
            title = Self.title(row, json: json, kind: .private)
            var plain = json
            plain["nicknameGivenName"] = nil
            plain["nicknameFamilyName"] = nil
            withoutNickname = Self.titleNoDefault(row, json: plain, kind: .private)
        }
        let blocked = try BlockedList.serviceIds.entries(db).contains { $0.id == serviceId }
        let verified = try ProtocolStore.verifiedStatus(db, serviceId: serviceId) == .verified
        var messages = false
        var accepted = true
        if let conversationId {
            messages = try Int.fetchOne(db, sql: "SELECT 1 FROM messages WHERE conversationId = ? AND type IN ('incoming', 'outgoing') LIMIT 1",
                                        arguments: [conversationId]) != nil
            if let ourAci { accepted = try ConversationState.isAccepted(db, conversationId: conversationId, ourAci: ourAci) }
        }
        var shared: [String] = []
        for g in try Row.fetchAll(db, sql: "SELECT json FROM conversations WHERE type = 'group'") {
            let gj = (try? MessageStore.jsonObject(g["json"] ?? "{}")) ?? [:]
            guard gj["left"] as? Bool != true, gj["terminated"] as? Bool != true, let name = gj["name"] as? String, !name.isEmpty else { continue }
            let members = Set((gj["membersV2"] as? [[String: Any]] ?? []).compactMap { $0["aci"] as? String })
            if members.contains(serviceId), ourAci.map(members.contains) ?? true { shared.append(name) }
        }
        let named = ["systemGivenName", "systemFamilyName", "systemNickname"].contains { text($0) != nil } || ((row?["name"] as String?) ?? "").isEmpty == false
        return ContactAboutInfo(
            conversationId: conversationId, serviceId: serviceId, title: title,
            titleNoNickname: text("nicknameGivenName") != nil || text("nicknameFamilyName") != nil ? withoutNickname : nil,
            profileName: text("profileName"), profileFamilyName: text("profileFamilyName"),
            nicknameGivenName: text("nicknameGivenName"), nicknameFamilyName: text("nicknameFamilyName"), note: text("note"),
            about: text("about"), aboutEmoji: text("aboutEmoji"), e164: text("e164") ?? (row?["e164"] as String?),
            systemGivenName: text("systemGivenName"), isInSystemContacts: named, profileSharing: json["profileSharing"] as? Bool ?? false,
            acceptedMessageRequest: accepted, hasMessages: messages, isBlocked: blocked, isVerified: verified,
            sharedGroupNames: shared.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }
}

extension SignalDatabase {
    /// A contact's details, live (they change with their profile, nickname, blocks and groups).
    public func contactAboutUpdates(serviceId: String, ourAci: String?) -> AsyncThrowingStream<ContactAboutInfo, Error> {
        observe { try ConversationQueries.contactAbout($0, serviceId: serviceId, ourAci: ourAci) }
    }
}
