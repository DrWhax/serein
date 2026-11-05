// Storage service, read side (port of the fetch/merge half of Desktop
// ts/services/storage.preload.ts + storageRecordOps.preload.ts for ContactRecord,
// AccountRecord and GroupV2Record; writing back is Phase 4).
//
//   storageKey   = HMAC-SHA256(masterKey, "Storage Service Encryption")
//   manifestKey  = HMAC-SHA256(storageKey, "Manifest_<version>")
//   itemKey      = HKDF(recordIkm, info "20240801_SIGNAL_STORAGE_SERVICE_ITEM_" ‖ raw)   (manifest has recordIkm)
//                | HMAC-SHA256(storageKey, "Item_" + base64(raw))                       (legacy)
//   all values   = AES-256-GCM, nonce(12) ‖ ciphertext ‖ tag
//
// GET v1/storage/auth (chat socket) → Basic credentials for the storage host;
// GET /v1/storage/manifest[/version/<local>] → StorageManifest; PUT /v1/storage/read → StorageItems.

import Foundation
import GRDB
import LibSignalClient
import SignalProtos
import SwiftProtobuf

public enum StorageServiceError: Error, Equatable {
    case noMasterKey
    case recordTypeMismatch(String)
    case manifestVersionMismatch
}

public struct StorageSyncResult: Sendable, Equatable {
    public var version: UInt64
    public var contacts: Int
    public var groups: Int
    public var account: Bool
    public var unknown: Int
}

public final class StorageServiceReader: Sendable {
    public static let queueType = "storage service"
    public struct Job: Codable, Sendable { public init() {} }
    /// Upstream MAX_READ_KEYS.
    static let maxReadKeys = 2500

    let account: Account
    let database: SignalDatabase
    let socket: SocketManager
    let http: HTTPClient
    let endpoints: ServiceEndpoints

    public init(account: Account, database: SignalDatabase, socket: SocketManager, http: HTTPClient, endpoints: ServiceEndpoints) {
        self.account = account
        self.database = database
        self.socket = socket
        self.http = http
        self.endpoints = endpoints
    }

    public func register(on jobs: JobQueue) async {
        await jobs.register(Self.queueType) { [self] _ in _ = try await self.sync() }
    }

    // MARK: keys

    static func storageKey(_ db: Database) throws -> Data {
        if let aep: String = try Items.get(db, "accountEntropyPool"), AccountEntropyPool.isValid(aep) {
            return deriveStorageKey(masterKey: try AccountEntropyPool.deriveSvrKey(aep))
        }
        guard let b64: String = try Items.get(db, "masterKey"), let master = Data(base64Encoded: b64), master.count == 32 else {
            throw StorageServiceError.noMasterKey
        }
        return deriveStorageKey(masterKey: master)
    }

    public static func deriveStorageKey(masterKey: Data) -> Data {
        SignalCrypto.hmacSHA256(key: masterKey, Data("Storage Service Encryption".utf8))
    }

    public static func manifestKey(storageKey: Data, version: UInt64) -> Data {
        SignalCrypto.hmacSHA256(key: storageKey, Data("Manifest_\(version)".utf8))
    }

    public static func itemKey(storageKey: Data, recordIkm: Data?, raw: Data) throws -> Data {
        if let recordIkm, !recordIkm.isEmpty {
            return try SignalCrypto.hkdf(32, ikm: recordIkm, info: Data("20240801_SIGNAL_STORAGE_SERVICE_ITEM_".utf8) + raw)
        }
        return SignalCrypto.hmacSHA256(key: storageKey, Data("Item_\(raw.base64EncodedString())".utf8))
    }

    // MARK: sync

    /// Fetches the manifest if newer than ours and applies every record we do not have.
    /// Returns nil when already up to date (or no manifest exists yet).
    @discardableResult
    public func sync() async throws -> StorageSyncResult? {
        let (storageKey, localVersion) = try await database.pool.read { db in
            (try Self.storageKey(db), try Items.get(db, "manifestVersion", as: UInt64.self))
        }
        struct Auth: Decodable { var username: String; var password: String }
        let auth = try JSONDecoder().decode(Auth.self, from: try await socket.authenticatedRequest("GET", "/v1/storage/auth"))
        let headers = ["authorization": HTTPClient.basicAuth(auth.username, auth.password), "content-type": "application/x-protobuf"]

        let manifestPath = localVersion.map { "v1/storage/manifest/version/\($0)" } ?? "v1/storage/manifest"
        let (status, body) = try await http.send("GET", endpoints.storageURL.appendingPathComponent(manifestPath), headers: headers, accept: [204, 404])
        guard status == 200 else { return nil }
        let manifest = try Signalservice_StorageManifest(serializedBytes: body)
        let record = try Signalservice_ManifestRecord(
            serializedBytes: try SignalCrypto.aes256GCMDecrypt(key: Self.manifestKey(storageKey: storageKey, version: manifest.version), manifest.value))
        guard record.version == manifest.version else { throw StorageServiceError.manifestVersionMismatch }

        // Records we already hold are identified by their storageID (upstream: conversations' storageID,
        // the account record's `storageID` item, and `storage-service-unknown-records`).
        let known = try await database.pool.read { db in try Self.knownStorageIDs(db) }
        let wanted = record.identifiers.filter { !known.contains($0.raw.base64EncodedString()) }
        var items: [Signalservice_StorageItem] = []
        for start in stride(from: 0, to: wanted.count, by: Self.maxReadKeys) {
            var read = Signalservice_ReadOperation()
            read.readKey = wanted[start..<min(start + Self.maxReadKeys, wanted.count)].map(\.raw)
            let (_, data) = try await http.send("PUT", endpoints.storageURL.appendingPathComponent("v1/storage/read"),
                                                body: try read.serializedBytes() as Data, headers: headers)
            items += try Signalservice_StorageItems(serializedBytes: data).items
        }
        let typeByKey = Dictionary(record.identifiers.map { ($0.raw, $0.type) }, uniquingKeysWith: { a, _ in a })
        let ikm = record.recordIkm.isEmpty ? nil : record.recordIkm
        let decrypted: [(Data, Signalservice_ManifestRecord.Identifier.TypeEnum, Signalservice_StorageRecord)] = try items.map { item in
            let key = try Self.itemKey(storageKey: storageKey, recordIkm: ikm, raw: item.key)
            let value = try Signalservice_StorageRecord(serializedBytes: try SignalCrypto.aes256GCMDecrypt(key: key, item.value))
            return (item.key, typeByKey[item.key] ?? .unknown, value)
        }
        let version = manifest.version
        let liveIDs = Set(record.identifiers.map { $0.raw.base64EncodedString() })
        return try await database.pool.write { db in
            var result = StorageSyncResult(version: version, contacts: 0, groups: 0, account: false, unknown: 0)
            var unknown = try Items.get(db, "storage-service-unknown-records", as: [UnknownRecord].self) ?? []
            unknown.removeAll { !liveIDs.contains($0.storageID) }
            for (raw, type, value) in decrypted {
                let storageID = raw.base64EncodedString()
                switch (type, value.record) {
                case (.contact, .contact(let c)):
                    if try StorageRecordApplier.applyContact(db, c, storageID: storageID, version: version, account: self.account) { result.contacts += 1 }
                case (.groupv2, .groupV2(let g)):
                    try StorageRecordApplier.applyGroup(db, g, storageID: storageID, version: version)
                    result.groups += 1
                case (.account, .account(let a)):
                    try StorageRecordApplier.applyAccount(db, a, storageID: storageID, version: version, account: self.account)
                    result.account = true
                case (_, .none), (.unknown, _):
                    unknown.append(UnknownRecord(storageID: storageID, itemType: type.rawValue))
                    result.unknown += 1
                case (.contact, _), (.groupv2, _), (.account, _):
                    throw StorageServiceError.recordTypeMismatch("\(type) carries \(String(describing: value.record))")
                default:
                    // Other record types (story lists, sticker packs, call links, chat folders, …) are
                    // kept as unknown until their Phase 4 handlers exist, so a later merge preserves them.
                    unknown.append(UnknownRecord(storageID: storageID, itemType: type.rawValue))
                    result.unknown += 1
                }
            }
            try Items.set(db, "storage-service-unknown-records", unknown)
            try Items.set(db, "manifestVersion", version)
            return result
        }
    }

    struct UnknownRecord: Codable { var storageID: String; var itemType: Int }

    static func knownStorageIDs(_ db: Database) throws -> Set<String> {
        var ids = Set(try String.fetchAll(db, sql: "SELECT json ->> '$.storageID' FROM conversations WHERE json ->> '$.storageID' IS NOT NULL"))
        if let s: String = try Items.get(db, "storageID") { ids.insert(s) }
        for u in try Items.get(db, "storage-service-unknown-records", as: [UnknownRecord].self) ?? [] { ids.insert(u.storageID) }
        return ids
    }
}

/// Merge of remote records into local state (upstream mergeContactRecord /
/// mergeGroupV2Record / mergeAccountRecord, remote-wins for the read-only phase).
enum StorageRecordApplier {
    static func applyContact(_ db: Database, _ c: Signalservice_ContactRecord, storageID: String, version: UInt64, account: Account) throws -> Bool {
        let aci = MessageReceiver.serviceIdString(binary: c.aciBinary.isEmpty ? nil : c.aciBinary, string: c.aci.isEmpty ? nil : c.aci)
        let pni = pniString(binary: c.pniBinary, string: c.pni)
        guard let serviceId = aci ?? pni else { return false }   // e164-only records need CDSI first
        if serviceId == account.aci { return false }
        let conversationId = try MessageStore.privateConversation(db, serviceId: serviceId)
        try MessageStore.updateConversationJSON(db, conversationId: conversationId) { json in
            json["storageID"] = storageID
            json["storageVersion"] = version
            if !c.e164.isEmpty { json["e164"] = c.e164 }
            if let pni { json["pni"] = pni }
            if !c.givenName.isEmpty || !c.familyName.isEmpty {
                json["profileName"] = c.givenName
                json["profileFamilyName"] = c.familyName.isEmpty ? nil : c.familyName
            }
            set(&json, "systemGivenName", c.systemGivenName)
            set(&json, "systemFamilyName", c.systemFamilyName)
            set(&json, "systemNickname", c.systemNickname)
            if c.hasNickname {
                set(&json, "nicknameGivenName", c.nickname.given)
                set(&json, "nicknameFamilyName", c.nickname.family)
            }
            set(&json, "note", c.note)
            set(&json, "username", c.username)
            json["profileSharing"] = c.whitelisted
            json["isArchived"] = c.archived
            json["markedUnread"] = c.markedUnread
            json["muteExpiresAt"] = c.mutedUntilTimestamp > 0 ? c.mutedUntilTimestamp : nil
            json["hideStory"] = c.hideStory
            json["removalStage"] = c.hidden ? "justNotification" : nil
            if c.unregisteredAtTimestamp > 0 { json["firstUnregisteredAt"] = c.unregisteredAtTimestamp }
        }
        let given = c.givenName.isEmpty ? nil : c.givenName
        let family = c.familyName.isEmpty ? nil : c.familyName
        try db.execute(sql: """
            UPDATE conversations SET e164 = coalesce(?, e164), profileName = coalesce(?, profileName), profileFamilyName = coalesce(?, profileFamilyName),
              profileFullName = coalesce(?, profileFullName) WHERE id = ?
            """, arguments: [c.e164.isEmpty ? nil : c.e164, given, family,
                             given.map { [$0, family].compactMap { $0 }.joined(separator: " ") }, conversationId])
        if !c.profileKey.isEmpty { try MessageStore.setProfileKey(db, serviceId: serviceId, c.profileKey) }
        if !c.identityKey.isEmpty, (try? IdentityKey(bytes: c.identityKey)) != nil {
            let status: VerifiedStatus = c.identityState == .verified ? .verified : c.identityState == .unverified ? .unverified : .default
            try ProtocolStore.setIdentity(db, serviceId: serviceId, key: c.identityKey, verified: status)
        }
        try setBlocked(db, list: "blocked-uuids", value: serviceId, blocked: c.blocked)
        return true
    }

    static func applyGroup(_ db: Database, _ g: Signalservice_GroupV2Record, storageID: String, version: UInt64) throws {
        let (conversationId, groupId) = try MessageStore.groupConversation(db, masterKey: g.masterKey)
        try MessageStore.updateConversationJSON(db, conversationId: conversationId) { json in
            json["storageID"] = storageID
            json["storageVersion"] = version
            json["profileSharing"] = g.whitelisted
            json["isArchived"] = g.archived
            json["markedUnread"] = g.markedUnread
            json["muteExpiresAt"] = g.mutedUntilTimestamp > 0 ? g.mutedUntilTimestamp : nil
            json["dontNotifyForMentionsIfMuted"] = g.dontNotifyForMentionsIfMuted
            json["hideStory"] = g.hideStory
            json["storySendMode"] = ["Default", "Never", "Always"][min(g.storySendMode.rawValue, 2)]
        }
        try setBlocked(db, list: "blocked-groups", value: groupId.base64EncodedString(), blocked: g.blocked)
    }

    static func applyAccount(_ db: Database, _ a: Signalservice_AccountRecord, storageID: String, version: UInt64, account: Account) throws {
        try Items.set(db, "storageID", storageID)
        if a.profileKey.count == 32 { try Items.set(db, "profileKey", a.profileKey.base64EncodedString()) }
        try Items.set(db, "read-receipt-setting", a.readReceipts)
        try Items.set(db, "sealedSenderIndicators", a.sealedSenderIndicators)
        try Items.set(db, "typingIndicators", a.typingIndicators)
        try Items.set(db, "linkPreviews", a.linkPreviews)
        try Items.set(db, "preferContactAvatars", a.preferContactAvatars)
        try Items.set(db, "universalExpireTimer", a.universalExpireTimer)
        try Items.set(db, "phoneNumberSharingMode", a.phoneNumberSharingMode == .everybody ? "Everybody" : "Nobody")
        try Items.set(db, "phoneNumberDiscoverability", a.unlistedPhoneNumber ? "NotDiscoverable" : "Discoverable")
        try Items.set(db, "displayBadgesOnProfile", a.displayBadgesOnProfile)
        try Items.set(db, "keepMutedChatsArchived", a.keepMutedChatsArchived)
        try Items.set(db, "hasStoriesDisabled", a.storiesDisabled)
        if !a.preferredReactionEmoji.isEmpty { try Items.set(db, "preferredReactionEmoji", a.preferredReactionEmoji) }
        if !a.username.isEmpty { try Items.set(db, "username", a.username) }

        // Note to Self carries our own profile name.
        let me = try MessageStore.privateConversation(db, serviceId: account.aci)
        try MessageStore.updateConversationJSON(db, conversationId: me) { json in
            json["profileName"] = a.givenName
            json["profileFamilyName"] = a.familyName.isEmpty ? nil : a.familyName
            json["isArchived"] = a.noteToSelfArchived
            json["markedUnread"] = a.noteToSelfMarkedUnread
        }
        try db.execute(sql: "UPDATE conversations SET profileName = ?, profileFamilyName = ? WHERE id = ?",
                       arguments: [a.givenName, a.familyName.isEmpty ? nil : a.familyName, me])

        var pinned: [String] = []
        for p in a.pinnedConversations {
            switch p.identifier {
            case .contact(let c):
                if let id = MessageReceiver.serviceIdString(binary: c.serviceIDBinary.isEmpty ? nil : c.serviceIDBinary, string: c.serviceID.isEmpty ? nil : c.serviceID) {
                    pinned.append(try MessageStore.privateConversation(db, serviceId: id))
                }
            case .groupMasterKey(let key):
                pinned.append(try MessageStore.groupConversation(db, masterKey: key).id)
            default:
                continue
            }
        }
        try Items.set(db, "pinnedConversationIds", pinned)
        for id in pinned { try MessageStore.updateConversationJSON(db, conversationId: id) { $0["isPinned"] = true } }
    }

    static func set(_ json: inout [String: Any], _ key: String, _ value: String) {
        json[key] = value.isEmpty ? nil : value
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

    static func setBlocked(_ db: Database, list: String, value: String, blocked: Bool) throws {
        var values = try Items.get(db, list, as: [String].self) ?? []
        let had = values.contains(value)
        if blocked && !had { values.append(value) } else if !blocked && had { values.removeAll { $0 == value } } else { return }
        try Items.set(db, list, values)
    }
}
