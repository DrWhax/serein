// Local state shared by the storage-service record ops: the storage fields on conversations
// (storageID / storageVersion / storageUnknownFields / needsStorageServiceSync in the JSON)
// and on the record tables, upstream's blocked lists (textsecure/storage/Blocked.std.ts),
// MuteExpiration and OptionalBool mappings, and Recipient <-> conversation id.

import Foundation
import GRDB
import LibSignalClient
import SignalProtos
import SwiftProtobuf

/// `ExtendedStorageID` / `UnknownRecord` (storage-service-unknown-records, -error-records,
/// -pending-deletes items).
struct StorageIDRecord: Codable, Equatable, Sendable {
    var storageID: String
    var storageVersion: UInt64?
    var itemType: Int?
}

enum StorageLocal {
    /// `SIGNAL_ACI` (release notes).
    static let signalAci = "11111111-1111-4111-8111-111111111111"
    /// `MY_STORY_ID`
    static let myStoryId = "00000000-0000-0000-0000-000000000000"
    /// `CHAT_FOLDER_DELETED_POSITION`
    static let chatFolderDeletedPosition: UInt32 = 4_294_967_295

    /// `getMessageQueueTime`: max(remote `global.messageQueueTimeInSeconds`, 30 days), in ms.
    static func messageQueueTime(_ db: Database) throws -> Int64 {
        let month: Int64 = 30 * 24 * 3600
        let seconds = max(Int64(try RemoteConfig.int(db, "global.messageQueueTimeInSeconds") ?? Int(month)), month)
        return seconds * 1000
    }

    static func isOlderThan(_ timestamp: Int64, _ age: Int64, now: Int64 = MessageStore.now()) -> Bool {
        timestamp <= now - age
    }

    /// `isProtoBinaryEncodingEnabled`: binary service ids (aciBinary, serviceIdBinary, …) unless
    /// the remote config explicitly turns them off. Upstream is on in test and staging and
    /// behind `desktop.binaryServiceId.prod` in production; current clients and the storage
    /// protos of the mock server read only the binary fields.
    static func binaryServiceIds(_ db: Database) throws -> Bool {
        guard try RemoteConfig.isKnown(db, "desktop.binaryServiceId.prod") else { return true }
        return try RemoteConfig.isEnabled(db, "desktop.binaryServiceId.prod") || RemoteConfig.isEnabled(db, "desktop.binaryServiceId.beta")
    }

    // MARK: unknown fields

    /// The record's unknown fields, or nil when it has none (`toStorageUnknownFields`).
    static func unknownFields(_ m: some SwiftProtobuf.Message) -> Data? {
        m.unknownFields.data.isEmpty ? nil : m.unknownFields.data
    }

    /// Re-attaches stored unknown fields to a record we generate.
    static func attach<M: SwiftProtobuf.Message>(_ unknown: Data?, to record: inout M) throws {
        guard let unknown, !unknown.isEmpty else { return }
        try record.merge(serializedBytes: unknown)
    }

    // MARK: MuteExpiration (packages/types MuteExpiration.std.ts)

    static let muteAlways: Int64 = 9_007_199_254_740_991     // Number.MAX_SAFE_INTEGER
    static let maxSafeDate: UInt64 = 8_640_000_000_000_000

    static func muteFromProto(_ v: UInt64) -> Int64? {
        if v == 0 { return nil }
        if v >= maxSafeDate { return muteAlways }
        return Int64(v)
    }

    static func muteToProto(_ v: Int64?) -> UInt64 {
        guard let v, v > 0 else { return 0 }
        if v >= Int64(maxSafeDate) { return UInt64(Int64.max) }
        return UInt64(v)
    }

    // MARK: OptionalBool

    static func fromOptionalBool(_ v: Signalservice_OptionalBool) -> Bool? {
        switch v {
        case .enabled: return true
        case .disabled: return false
        default: return nil
        }
    }

    static func toOptionalBool(_ v: Bool?) -> Signalservice_OptionalBool {
        switch v {
        case true?: return .enabled
        case false?: return .disabled
        case nil: return .unset
        }
    }

    // MARK: avatar colour (fromAvatarColor)

    static let avatarColors = ["A100", "A110", "A120", "A130", "A140", "A150", "A160", "A170", "A180", "A190", "A200", "A210"]

    /// `applyAvatarColor`
    static func applyAvatarColor(_ json: inout [String: Any], has: Bool, _ raw: Int) {
        guard has else {
            json["colorFromPrimary"] = nil
            return
        }
        json["colorFromPrimary"] = raw
        json["color"] = raw >= 0 && raw < avatarColors.count ? avatarColors[raw] : "A100"
    }

    // MARK: service ids

    static func uuidBytes(_ s: String) -> Data? {
        guard let u = UUID(uuidString: s) else { return nil }
        let t = u.uuid
        return Data([t.0, t.1, t.2, t.3, t.4, t.5, t.6, t.7, t.8, t.9, t.10, t.11, t.12, t.13, t.14, t.15])
    }

    static func uuidString(_ d: Data) -> String? {
        guard d.count == 16 else { return nil }
        return UUID(uuid: StorageLocal.rawUUID(d)).uuidString.lowercased()
    }

    /// An ACI from `aciBinary` (16 bytes) or the `aci` string.
    static func aci(binary: Data, string: String) -> String? {
        if let s = uuidString(binary) { return s }
        if !binary.isEmpty { return nil }
        guard !string.isEmpty, let id = try? ServiceId.parseFrom(serviceIdString: string), id.kind == .aci else { return nil }
        return id.serviceIdString
    }

    /// A service id (ACI untagged, PNI "PNI:"-tagged) from binary or string.
    static func serviceId(binary: Data, string: String) -> String? {
        if !binary.isEmpty, let id = try? ServiceId.parseFrom(serviceIdBinary: binary) { return id.serviceIdString }
        if !string.isEmpty, let id = try? ServiceId.parseFrom(serviceIdString: string) { return id.serviceIdString }
        return nil
    }

    static func pniString(binary: Data, string: String) -> String? {
        if binary.count == 16 { return Pni(fromUUID: UUID(uuid: rawUUID(binary))).serviceIdString }
        if !binary.isEmpty, let id = try? ServiceId.parseFrom(serviceIdBinary: binary), id.kind == .pni { return id.serviceIdString }
        if !string.isEmpty, let id = try? ServiceId.parseFrom(serviceIdString: string.hasPrefix("PNI:") ? string : "PNI:" + string), id.kind == .pni {
            return id.serviceIdString
        }
        return nil
    }

    static func rawUUID(_ d: Data) -> uuid_t {
        let b = [UInt8](d)
        return (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
    }

    static func serviceIdBinary(_ serviceId: String) -> Data? {
        (try? ServiceId.parseFrom(serviceIdString: serviceId)).map { Data($0.serviceIdBinary) }
    }

    // MARK: conversations

    struct ConversationRow {
        var id: String
        var type: String
        var serviceId: String?
        var e164: String?
        var groupId: String?
        var json: [String: Any]

        var storageID: String? { json["storageID"] as? String }
        var storageVersion: UInt64? { (json["storageVersion"] as? NSNumber)?.uint64Value }
        var needsSync: Bool { json["needsStorageServiceSync"] as? Bool ?? false }
        var unknownFields: Data? { (json["storageUnknownFields"] as? String).flatMap { Data(base64Encoded: $0) } }
    }

    static func conversations(_ db: Database, where clause: String = "1", arguments: StatementArguments = []) throws -> [ConversationRow] {
        try Row.fetchAll(db, sql: "SELECT id, type, serviceId, e164, groupId, json FROM conversations WHERE \(clause) ORDER BY id", arguments: arguments)
            .map { r in
                ConversationRow(id: r["id"], type: r["type"], serviceId: r["serviceId"], e164: r["e164"], groupId: r["groupId"],
                                json: try MessageStore.jsonObject(r["json"] as String? ?? "{}"))
            }
    }

    static func conversation(_ db: Database, id: String) throws -> ConversationRow? {
        try conversations(db, where: "id = ?", arguments: [id]).first
    }

    /// Writes storageID/storageVersion/needs-sync onto a conversation.
    static func setStorageFields(_ db: Database, conversationId: String, storageID: String?, version: UInt64?, needsSync: Bool) throws {
        try MessageStore.updateConversationJSON(db, conversationId: conversationId) { json in
            json["storageID"] = storageID
            json["storageVersion"] = version
            json["needsStorageServiceSync"] = needsSync
        }
    }

    /// `addUnknownFieldsToConversation`
    static func setUnknownFields(_ json: inout [String: Any], _ unknown: Data?) {
        json["storageUnknownFields"] = unknown?.base64EncodedString()
    }

    /// Our own conversation (Note to Self), created if missing.
    static func ourConversation(_ db: Database, account: Account) throws -> String {
        try MessageStore.privateConversation(db, serviceId: account.aci)
    }

    /// `maybeMergeContacts` for a storage record (aci, pni, e164): the conversation that holds
    /// the ACI, else the PNI one (upgraded to the ACI), else the e164-only one, else a new one.
    static func contactConversation(_ db: Database, aci: String?, pni: String?, e164: String?) throws -> String {
        if let aci, let id = try String.fetchOne(db, sql: "SELECT id FROM conversations WHERE type = 'private' AND serviceId = ?", arguments: [aci]) {
            if let pni { try attachPni(db, conversationId: id, pni: pni) }
            return id
        }
        if let pni {
            let byPni = try String.fetchOne(db, sql: """
                SELECT id FROM conversations WHERE type = 'private' AND (serviceId = ? OR json ->> '$.pni' = ?) ORDER BY serviceId = ? DESC
                """, arguments: [pni, pni, pni])
            if let id = byPni {
                if let aci {
                    try db.execute(sql: "UPDATE conversations SET serviceId = ? WHERE id = ?", arguments: [aci, id])
                    try MessageStore.updateConversationJSON(db, conversationId: id) { $0["serviceId"] = aci; $0["pni"] = pni }
                }
                return id
            }
        }
        if let e164, let id = try String.fetchOne(db, sql: "SELECT id FROM conversations WHERE type = 'private' AND serviceId IS NULL AND e164 = ?",
                                                    arguments: [e164]) {
            let serviceId = aci ?? pni
            try db.execute(sql: "UPDATE conversations SET serviceId = ? WHERE id = ?", arguments: [serviceId, id])
            try MessageStore.updateConversationJSON(db, conversationId: id) { $0["serviceId"] = serviceId; if aci != nil { $0["pni"] = pni } }
            return id
        }
        let id = try MessageStore.privateConversation(db, serviceId: aci ?? pni!)
        if aci != nil, let pni { try attachPni(db, conversationId: id, pni: pni) }
        return id
    }

    static func attachPni(_ db: Database, conversationId: String, pni: String) throws {
        // A PNI moves to the ACI conversation; a separate PNI-only conversation loses it.
        try db.execute(sql: "UPDATE conversations SET json = json_remove(json, '$.pni') WHERE id != ? AND json ->> '$.pni' = ?",
                       arguments: [conversationId, pni])
        try MessageStore.updateConversationJSON(db, conversationId: conversationId) { $0["pni"] = pni }
    }

    // MARK: Recipient (toRecipient / recipientToConversationId)

    static func recipient(_ db: Database, conversationId: String) throws -> Signalservice_Recipient? {
        guard let c = try conversation(db, id: conversationId) else { return nil }
        var r = Signalservice_Recipient()
        if c.type == "private" {
            guard let serviceId = c.serviceId else { return nil }
            var contact = Signalservice_Recipient.Contact()
            contact.serviceID = serviceId
            contact.serviceIDBinary = serviceIdBinary(serviceId) ?? Data()
            contact.e164 = c.e164 ?? ""
            r.identifier = .contact(contact)
        } else {
            guard let mk = (c.json["masterKey"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return nil }
            r.identifier = .groupMasterKey(mk)
        }
        return r
    }

    static func recipients(_ db: Database, _ ids: [String]) throws -> [Signalservice_Recipient] {
        try ids.compactMap { try recipient(db, conversationId: $0) }
    }

    static func conversationId(_ db: Database, recipient: Signalservice_Recipient) throws -> String? {
        switch recipient.identifier {
        case .contact(let c):
            if let s = serviceId(binary: c.serviceIDBinary, string: c.serviceID),
               let id = try String.fetchOne(db, sql: "SELECT id FROM conversations WHERE type = 'private' AND serviceId = ?", arguments: [s]) {
                return id
            }
            guard !c.e164.isEmpty else { return nil }
            return try String.fetchOne(db, sql: "SELECT id FROM conversations WHERE type = 'private' AND e164 = ?", arguments: [c.e164])
        case .groupMasterKey(let mk):
            guard let keys = try? GroupKeys(masterKey: mk) else { return nil }
            return try String.fetchOne(db, sql: "SELECT id FROM conversations WHERE groupId = ?", arguments: [keys.groupIdBase64])
        case .legacyGroupID, .none:
            return nil
        }
    }

    static func conversationIds(_ db: Database, _ recipients: [Signalservice_Recipient]) throws -> [String] {
        try recipients.compactMap { try conversationId(db, recipient: $0) }
    }
}

/// Upstream's blocked lists: `blocked` [{e164, blockedAt}], `blocked-uuids` [{serviceId,
/// blockedAt}], `blocked-groups` [{groupId, blockedAt}]. Older plain-string entries are read too.
enum BlockedList: String {
    case numbers = "blocked"
    case serviceIds = "blocked-uuids"
    case groups = "blocked-groups"

    var field: String {
        switch self {
        case .numbers: "e164"
        case .serviceIds: "serviceId"
        case .groups: "groupId"
        }
    }

    func entries(_ db: Database) throws -> [(id: String, blockedAt: Int64?)] {
        guard let s = try String.fetchOne(db, sql: "SELECT json FROM items WHERE id = ?", arguments: [rawValue]),
              let obj = try MessageStore.jsonObject(s)["value"] as? [Any] else { return [] }
        return obj.compactMap { e in
            if let id = e as? String { return (id, nil) }
            guard let d = e as? [String: Any], let id = d[field] as? String else { return nil }
            return (id, (d["blockedAt"] as? NSNumber)?.int64Value)
        }
    }

    func blockedAt(_ db: Database, _ id: String) throws -> (blocked: Bool, at: Int64?) {
        guard let e = try entries(db).first(where: { $0.id == id }) else { return (false, nil) }
        return (true, e.blockedAt)
    }

    func save(_ db: Database, _ entries: [(id: String, blockedAt: Int64?)]) throws {
        let value: [[String: Any]] = entries.map { e in
            var d: [String: Any] = [field: e.id]
            if let at = e.blockedAt { d["blockedAt"] = at }
            return d
        }
        try db.execute(sql: "INSERT INTO items (id, json) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET json = excluded.json",
                       arguments: [rawValue, try MessageStore.jsonString(["id": rawValue, "value": value])])
    }

    /// Adds (with its time) or removes `id`; returns whether anything changed.
    @discardableResult
    func set(_ db: Database, _ id: String, blocked: Bool, at: Int64? = nil) throws -> Bool {
        var list = try entries(db)
        let had = list.contains { $0.id == id }
        if blocked && !had { list.append((id, at)) } else if !blocked && had { list.removeAll { $0.id == id } } else { return false }
        try save(db, list)
        return true
    }

    func replaceAll(_ db: Database, _ ids: [String]) throws {
        let old = Dictionary(try entries(db).map { ($0.id, $0.blockedAt) }, uniquingKeysWith: { a, _ in a })
        try save(db, ids.map { ($0, old[$0] ?? nil) })
    }
}
