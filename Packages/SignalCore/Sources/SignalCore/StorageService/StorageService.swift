// Storage service (ts/services/storage.preload.ts): sync = fetch the manifest, fetch and
// merge the records we do not have, forget local storageIDs the manifest no longer lists;
// upload = regenerate every local record, give new or changed ones (needs-sync, or no
// storageID yet) a fresh random storageID, and write manifest + inserts + deletes atomically
// (409 = someone else wrote first: sync and retry).
//
//   storageKey   = HMAC-SHA256(masterKey, "Storage Service Encryption")
//   manifestKey  = HMAC-SHA256(storageKey, "Manifest_<version>")
//   itemKey      = HKDF(recordIkm, info "20240801_SIGNAL_STORAGE_SERVICE_ITEM_" ‖ raw)   (manifest has recordIkm)
//                | HMAC-SHA256(storageKey, "Item_" + base64(raw))                       (legacy)
//   all values   = AES-256-GCM, nonce(12) ‖ ciphertext ‖ tag
//
// GET v1/storage/auth (chat socket) → Basic credentials for the storage host;
// GET /v1/storage/manifest[/version/<local>] → StorageManifest (204 same, 404 none);
// PUT /v1/storage/read → StorageItems; PUT /v1/storage (WriteOperation) → 200 or 409 + manifest.
//
// Records with an item type this client does not merge (HIDDEN_STICKER_PACK, GROUPV1, a type
// whose payload does not match) are kept by storageID and passed through every upload.

import Foundation
import GRDB
import LibSignalClient
import SignalProtos
import SwiftProtobuf
import Synchronization

public enum StorageServiceError: Error, Equatable {
    case noMasterKey
    case recordTypeMismatch(String)
    case manifestVersionMismatch
    case cannotDecrypt(String)
    case invalidWrite(String)
    case tooManyWrites
    case conflict
}

public struct StorageSyncResult: Sendable, Equatable {
    public var version: UInt64
    public var contacts: Int
    public var groups: Int
    public var account: Bool
    public var unknown: Int
    /// Story lists, sticker packs, favourite stickers, call links, chat folders, notification profiles.
    public var other: Int = 0
    public var errors: Int = 0

    public init(version: UInt64, contacts: Int, groups: Int, account: Bool, unknown: Int, other: Int = 0, errors: Int = 0) {
        self.version = version
        self.contacts = contacts
        self.groups = groups
        self.account = account
        self.unknown = unknown
        self.other = other
        self.errors = errors
    }
}

public struct StorageUploadResult: Sendable, Equatable {
    public var version: UInt64
    public var inserted: Int
    public var deleted: Int
    /// 409s answered with a sync and a regenerated write.
    public var conflicts: Int = 0
}

public final class StorageService: Sendable {
    public static let queueType = "storage service"
    public static let uploadQueueType = "storage service upload"
    public struct Job: Codable, Sendable {
        public var fromSync: Bool?
        public init(fromSync: Bool? = nil) { self.fromSync = fromSync }
    }
    /// Upstream MAX_READ_KEYS.
    static let maxReadKeys = 2500
    /// `RECORD_IKM_LENGTH`
    static let recordIkmLength = 32
    /// Conflict retries before giving up (upstream conflictBackOff has 3 steps).
    static let maxConflictRetries = 3

    /// ITEM_TYPE values this client merges (`validRecordTypes` minus GROUPV1, which has no
    /// local representation and is passed through).
    static let mergedTypes: Set<Signalservice_ManifestRecord.Identifier.TypeEnum> = [
        .contact, .groupv2, .account, .storyDistributionList, .stickerPack, .callLink, .chatFolder, .notificationProfile, .favoriteStickerPack,
    ]

    let account: Account
    let database: SignalDatabase
    let socket: SocketManager
    let http: HTTPClient
    let endpoints: ServiceEndpoints

    struct Hooks: Sendable {
        var jobs: JobQueue?
        var profileFetch: (@Sendable ([String]) async -> Void)?
        var groupUpdate: (@Sendable ([Data]) async -> Void)?
        var uploadBucket: [Int64] = []
    }
    let hooks = Mutex(Hooks())
    /// `storageJobQueue`: syncs and uploads run one at a time.
    let queue = StorageQueue()

    public init(account: Account, database: SignalDatabase, socket: SocketManager, http: HTTPClient, endpoints: ServiceEndpoints) {
        self.account = account
        self.database = database
        self.socket = socket
        self.http = http
        self.endpoints = endpoints
    }

    public func register(on jobs: JobQueue) async {
        hooks.withLock { $0.jobs = jobs }
        await jobs.register(Self.queueType) { [self] _ in try await self.recoveringFromBadKey { _ = try await self.sync() } }
        await jobs.register(Self.uploadQueueType) { [self] job in
            let payload = try? JSONDecoder().decode(Job.self, from: job.data)
            // Uploads queued before this one starts are covered by the manifest it generates
            // (upstream debounces runStorageServiceUploadJob the same way).
            // A coalesced local change makes the whole run a local one (sync first, no rate limit).
            let localChangeQueued = try await self.database.pool.write { db -> Bool in
                let others = try String.fetchAll(db, sql: "SELECT data FROM jobs WHERE queueType = ? AND id != ?", arguments: [Self.uploadQueueType, job.id])
                try db.execute(sql: "DELETE FROM jobs WHERE queueType = ? AND id != ?", arguments: [Self.uploadQueueType, job.id])
                return others.contains { (try? JSONDecoder().decode(Job.self, from: Data($0.utf8)))?.fromSync != true }
            }
            try await self.recoveringFromBadKey { _ = try await self.upload(fromSync: (payload?.fromSync ?? false) && !localChangeQueued) }
        }
    }

    /// `stopStorageServiceSync` on a linked device: data we cannot decrypt means our storage
    /// key is stale, so ask the primary for keys (the Keys sync then triggers a new sync)
    /// instead of retrying the job.
    func recoveringFromBadKey(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch StorageServiceError.cannotDecrypt {
            _ = try await database.pool.write { db in
                try JobQueue.insert(db, queueType: ConversationJob.queueType,
                                    payload: ConversationJob.syncRequest([Signalservice_SyncMessage.Request.TypeEnum.keys.rawValue]))
            }
            hooks.withLock { $0.jobs }?.poke()
        }
    }

    /// Profile fetches (`needsProfileFetch`) and group refreshes (`waitThenMaybeUpdateGroup`)
    /// a sync asks for.
    public func setHooks(profileFetch: (@Sendable ([String]) async -> Void)?, groupUpdate: (@Sendable ([Data]) async -> Void)?) {
        hooks.withLock {
            $0.profileFetch = profileFetch
            $0.groupUpdate = groupUpdate
        }
    }

    /// `runStorageServiceUploadJob`: queues one upload (inside the caller's transaction).
    public static func scheduleUpload(_ db: Database, fromSync: Bool = false) throws {
        try JobQueue.insert(db, queueType: uploadQueueType, payload: Job(fromSync: fromSync))
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

    /// `deriveMasterKeyFromGroupV1`
    static func masterKey(groupV1Id: Data) throws -> Data {
        try SignalCrypto.hkdf(32, ikm: groupV1Id, info: Data("GV2 Migration".utf8), salt: Data(count: 32))
    }

    /// `encryptRecord`
    static func encryptItem(_ record: Signalservice_StorageRecord, raw: Data, storageKey: Data, recordIkm: Data?) throws -> Signalservice_StorageItem {
        var item = Signalservice_StorageItem()
        item.key = raw
        item.value = try SignalCrypto.aes256GCMEncrypt(key: itemKey(storageKey: storageKey, recordIkm: recordIkm, raw: raw), record.serializedBytes())
        return item
    }

    static func decryptItem(_ item: Signalservice_StorageItem, storageKey: Data, recordIkm: Data?) throws -> Signalservice_StorageRecord {
        let plaintext: Data
        do {
            plaintext = try SignalCrypto.aes256GCMDecrypt(key: itemKey(storageKey: storageKey, recordIkm: recordIkm, raw: item.key), item.value)
        } catch {
            throw StorageServiceError.cannotDecrypt("item \(item.key.base64EncodedString())")
        }
        return try Signalservice_StorageRecord(serializedBytes: plaintext)
    }

    // MARK: HTTP

    func headers() async throws -> [String: String] {
        struct Auth: Decodable { var username: String; var password: String }
        let auth = try JSONDecoder().decode(Auth.self, from: try await socket.authenticatedRequest("GET", "/v1/storage/auth"))
        return ["authorization": HTTPClient.basicAuth(auth.username, auth.password), "content-type": "application/x-protobuf"]
    }

    func url(_ path: String) -> URL { endpoints.storageURL.appendingPathComponent(path) }

    enum Fetched {
        case none
        case same
        case manifest(Signalservice_ManifestRecord)
    }

    /// `fetchManifest`
    func fetchManifest(after local: UInt64?, storageKey: Data, headers: [String: String]) async throws -> Fetched {
        let path = local.map { "v1/storage/manifest/version/\($0)" } ?? "v1/storage/manifest"
        let (status, body) = try await http.send("GET", url(path), headers: headers, accept: [204, 404])
        if status == 204 { return .same }
        if status == 404 { return .none }
        return .manifest(try Self.decryptManifest(try Signalservice_StorageManifest(serializedBytes: body), storageKey: storageKey))
    }

    static func decryptManifest(_ manifest: Signalservice_StorageManifest, storageKey: Data) throws -> Signalservice_ManifestRecord {
        let plaintext: Data
        do {
            plaintext = try SignalCrypto.aes256GCMDecrypt(key: manifestKey(storageKey: storageKey, version: manifest.version), manifest.value)
        } catch {
            throw StorageServiceError.cannotDecrypt("manifest \(manifest.version)")
        }
        let record = try Signalservice_ManifestRecord(serializedBytes: plaintext)
        guard record.version == manifest.version else { throw StorageServiceError.manifestVersionMismatch }
        return record
    }

    /// `fetchRemoteRecords`: the items, and the requested keys the server had no item for.
    func fetchItems(_ keys: [Data], headers: [String: String]) async throws -> (items: [Signalservice_StorageItem], missing: Set<Data>) {
        var items: [Signalservice_StorageItem] = []
        for start in stride(from: 0, to: keys.count, by: Self.maxReadKeys) {
            var read = Signalservice_ReadOperation()
            read.readKey = Array(keys[start..<min(start + Self.maxReadKeys, keys.count)])
            let (_, data) = try await http.send("PUT", url("v1/storage/read"), body: try read.serializedBytes() as Data, headers: headers)
            items += try Signalservice_StorageItems(serializedBytes: data).items
        }
        let wanted = Set(keys)
        guard items.allSatisfy({ wanted.contains($0.key) }) else { throw StorageServiceError.invalidWrite("unrequested storage item") }
        return (items, wanted.subtracting(items.map(\.key)))
    }

    // MARK: local records

    func context(_ db: Database, version: UInt64) throws -> StorageMergeContext {
        StorageMergeContext(account: account, version: version, isFirstSync: !(try Items.get(db, "storageFetchComplete", as: Bool.self) ?? false),
                            now: MessageStore.now(), messageQueueTime: try StorageLocal.messageQueueTime(db),
                            binaryServiceIds: try StorageLocal.binaryServiceIds(db),
                            sender: MessageSender(account: account, database: database, socket: socket, trustRoots: []))
    }

    /// Every local record with its storage fields (`generateManifest`'s inputs). Contacts that
    /// are unregistered and stale come back with `drop`.
    static func localEntries(_ db: Database, ctx: StorageMergeContext) throws -> [StorageLocalEntry] {
        var out: [StorageLocalEntry] = []
        let ourId = try StorageLocal.ourConversation(db, account: ctx.account)
        let our = try StorageLocal.conversation(db, id: ourId)!
        var account = Signalservice_StorageRecord()
        account.record = .account(try StorageRecords.toAccountRecord(db, account: ctx.account, binary: ctx.binaryServiceIds))
        out.append(StorageLocalEntry(type: .account, owner: .account(ourId), storageID: our.storageID, storageVersion: our.storageVersion,
                                     needsSync: our.needsSync, record: account))
        for c in try StorageLocal.conversations(db, where: "id != ?", arguments: [ourId]) {
            var r = Signalservice_StorageRecord()
            if c.type == "private" {
                guard let serviceId = c.serviceId, serviceId != StorageLocal.signalAci else { continue }
                // isConversationUnregisteredAndStale
                if let first = StorageRecords.int64(c.json, "firstUnregisteredAt"), StorageLocal.isOlderThan(first, ctx.messageQueueTime, now: ctx.now) {
                    if c.storageID != nil {
                        out.append(StorageLocalEntry(type: .contact, owner: .conversation(c.id), storageID: c.storageID, storageVersion: c.storageVersion,
                                                     needsSync: false, record: r, drop: true))
                    }
                    continue
                }
                r.record = .contact(try StorageRecords.toContactRecord(db, c, binary: ctx.binaryServiceIds))
                out.append(StorageLocalEntry(type: .contact, owner: .conversation(c.id), storageID: c.storageID, storageVersion: c.storageVersion,
                                             needsSync: c.needsSync, record: r))
            } else if c.type == "group" {
                guard c.json["needsGroupUpdate"] as? Bool != true, let g = try StorageRecords.toGroupV2Record(db, c) else { continue }
                r.record = .groupV2(g)
                out.append(StorageLocalEntry(type: .groupv2, owner: .conversation(c.id), storageID: c.storageID, storageVersion: c.storageVersion,
                                             needsSync: c.needsSync, record: r))
            }
        }
        out += try StorageRecords.storyEntries(db, ctx: ctx)
        out += try StorageRecords.notificationProfileEntries(db, ctx: ctx)
        out += try StorageRecords.stickerPackEntries(db, ctx: ctx)
        out += try StorageRecords.favoriteStickerEntries(db, ctx: ctx)
        out += try StorageRecords.callLinkEntries(db, ctx: ctx)
        out += try StorageRecords.chatFolderEntries(db, ctx: ctx)
        return out
    }

    static func ids(_ db: Database, _ key: String) throws -> [StorageIDRecord] { try Items.get(db, key, as: [StorageIDRecord].self) ?? [] }

    // MARK: sync

    /// `sync`: returns nil when already up to date (or no manifest exists yet).
    @discardableResult
    public func sync() async throws -> StorageSyncResult? {
        try await queue.run { try await self.syncManifest().result }
    }

    struct SyncOutcome {
        var result: StorageSyncResult?
        var manifest: Signalservice_ManifestRecord?
        var same: Bool
    }

    func syncManifest() async throws -> SyncOutcome {
        let (storageKey, localVersion) = try await database.pool.write { db in
            let local = try Items.get(db, "manifestVersion", as: UInt64.self)
            if local != nil, try Items.get(db, "storageFetchComplete", as: Bool.self) != true { try Items.set(db, "storageFetchComplete", true) }
            return (try Self.storageKey(db), local)
        }
        let headers = try await headers()
        let manifest: Signalservice_ManifestRecord
        switch try await fetchManifest(after: localVersion, storageKey: storageKey, headers: headers) {
        case .same:
            return SyncOutcome(result: nil, manifest: nil, same: true)
        case .none:
            try await database.pool.write { try Items.set($0, "storageFetchComplete", true) }
            return SyncOutcome(result: nil, manifest: nil, same: false)
        case .manifest(let m):
            manifest = m
        }
        let version = manifest.version
        if let localVersion, version <= localVersion, version != 0 || localVersion != 0 { throw StorageServiceError.manifestVersionMismatch }

        // processManifest: which remote keys are new to us.
        let remoteTypes = Dictionary(manifest.identifiers.map { ($0.raw.base64EncodedString(), $0.type) }, uniquingKeysWith: { a, _ in a })
        let localKeys = try await database.pool.write { db -> Set<String> in
            let ctx = try self.context(db, version: version)
            var keys = Set(try Self.localEntries(db, ctx: ctx).compactMap(\.storageID))
            // Unknown records of a type we now merge are fetched again.
            for u in try Self.ids(db, "storage-service-unknown-records") where !Self.mergedTypes.contains(.init(rawValue: u.itemType ?? 0) ?? .unknown) {
                keys.insert(u.storageID)
            }
            return keys
        }
        let remoteOnly = manifest.identifiers.filter { !localKeys.contains($0.raw.base64EncodedString()) }
        let recordIkm = manifest.recordIkm.isEmpty ? nil : manifest.recordIkm
        var decrypted: [(String, Signalservice_ManifestRecord.Identifier.TypeEnum, Signalservice_StorageRecord)] = []
        var missing = Set<Data>()
        if !remoteOnly.isEmpty {
            let fetched = try await fetchItems(remoteOnly.map(\.raw), headers: headers)
            missing = fetched.missing
            for item in fetched.items {
                let id = item.key.base64EncodedString()
                decrypted.append((id, remoteTypes[id] ?? .unknown, try Self.decryptItem(item, storageKey: storageKey, recordIkm: recordIkm)))
            }
        }
        let missingIDs = Set(missing.map { $0.base64EncodedString() })
        let account = self.account
        let toMerge = decrypted
        let (result, followUp) = try await database.pool.write { db in
            let ctx = try self.context(db, version: version)
            let processed = try Self.processRemoteRecords(db, toMerge, keysWithoutRecords: missingIDs, ctx: ctx)
            try Self.forgetMissing(db, remoteKeys: Set(remoteTypes.keys), ctx: ctx)
            try StorageRecords.ensureMyStory(db)
            try StorageRecords.ensureAllChatsFolder(db)
            try Items.set(db, "manifestVersion", version)
            if let recordIkm { try Items.set(db, "manifestRecordIkm", recordIkm.base64EncodedString()) } else { try Items.remove(db, "manifestRecordIkm") }
            try Items.set(db, "storageFetchComplete", true)
            // Conflicts found while merging (and records created above) go back up.
            let after = try self.context(db, version: version)
            if try Self.localEntries(db, ctx: after).contains(where: { $0.needsSync || ($0.storageID == nil && !$0.drop) }) {
                try Self.scheduleUpload(db, fromSync: true)
            }
            _ = account
            return processed
        }
        hooks.withLock { $0.jobs }?.poke()
        let (profileFetch, groupUpdate) = hooks.withLock { ($0.profileFetch, $0.groupUpdate) }
        if !followUp.profiles.isEmpty { await profileFetch?(followUp.profiles) }
        if !followUp.groups.isEmpty { await groupUpdate?(followUp.groups) }
        return SyncOutcome(result: result, manifest: manifest, same: false)
    }

    struct FollowUp {
        var profiles: [String] = []
        var groups: [Data] = []
    }

    /// `processRemoteRecords`: merge order is the plain records, then contacts whose PNI is on
    /// an ACI conversation, then chat folders and notification profiles (they refer to
    /// conversations), then the account record (pins refer to conversations).
    static func processRemoteRecords(_ db: Database, _ items: [(String, Signalservice_ManifestRecord.Identifier.TypeEnum, Signalservice_StorageRecord)],
                                     keysWithoutRecords: Set<String>, ctx: StorageMergeContext) throws -> (StorageSyncResult, FollowUp) {
        var result = StorageSyncResult(version: ctx.version, contacts: 0, groups: 0, account: false, unknown: 0)
        var followUp = FollowUp()
        var keysToDrop = Set<String>()
        var masterKeys = Set<Data>()
        for (_, type, record) in items {
            if type == .groupv2, case .groupV2(let g)? = record.record, !g.masterKey.isEmpty { masterKeys.insert(g.masterKey) }
        }
        var first: [(String, Signalservice_ManifestRecord.Identifier.TypeEnum, Signalservice_StorageRecord)] = []
        var splitPNI = first, needingContacts = first
        var accountItem: (String, Signalservice_ManifestRecord.Identifier.TypeEnum, Signalservice_StorageRecord)?
        for item in items {
            let (id, type, record) = item
            switch (type, record.record) {
            case (.notificationProfile, _), (.chatFolder, _):
                needingContacts.append(item)
            case (.account, _):
                if let previous = accountItem { keysToDrop.insert(previous.0) }
                accountItem = item
            case (.groupv1, .groupV1(let g)?) where !g.id.isEmpty:
                if masterKeys.contains(try masterKey(groupV1Id: g.id)) { keysToDrop.insert(id) } else { first.append(item) }
            case (.contact, .contact(let c)?):
                if !c.e164.isEmpty, let pni = StorageLocal.pniString(binary: c.pniBinary, string: c.pni),
                   try String.fetchOne(db, sql: "SELECT 1 FROM conversations WHERE type = 'private' AND json ->> '$.pni' = ? AND serviceId != ?",
                                       arguments: [pni, pni]) != nil {
                    splitPNI.append(item)
                } else {
                    first.append(item)
                }
            default:
                first.append(item)
            }
        }

        var unknown = try ids(db, "storage-service-unknown-records")
        var errors: [StorageIDRecord] = []
        var kept = Set<String>()
        for (id, type, record) in first + splitPNI + needingContacts + (accountItem.map { [$0] } ?? []) {
            var merged: StorageMergeResult? = nil
            var failed = false
            do {
                try db.inSavepoint {
                    merged = try mergeRecord(db, type: type, record: record, storageID: id, ctx: ctx)
                    return .commit
                }
            } catch {
                failed = true
            }
            unknown.removeAll { $0.storageID == id }
            if failed {
                errors.append(StorageIDRecord(storageID: id, storageVersion: ctx.version, itemType: type.rawValue))
                result.errors += 1
                continue
            }
            guard let merged else {
                unknown.append(StorageIDRecord(storageID: id, storageVersion: ctx.version, itemType: type.rawValue))
                result.unknown += 1
                continue
            }
            if merged.shouldDrop { keysToDrop.insert(id) } else { kept.insert(id) }
            if let p = merged.needsProfileFetch { followUp.profiles.append(p) }
            if let g = merged.groupToUpdate { followUp.groups.append(g) }
            switch type {
            case .contact: if !merged.shouldDrop { result.contacts += 1 }
            case .groupv2: result.groups += 1
            case .account: result.account = true
            default: result.other += 1
            }
        }
        try Items.set(db, "storage-service-unknown-records", unknown)
        try Items.set(db, "storage-service-error-records", errors)
        var pending = try ids(db, "storage-service-pending-deletes").filter { !kept.contains($0.storageID) }
        for id in keysWithoutRecords.union(keysToDrop) where !pending.contains(where: { $0.storageID == id }) {
            pending.append(StorageIDRecord(storageID: id, storageVersion: ctx.version))
        }
        try Items.set(db, "storage-service-pending-deletes", pending)
        return (result, followUp)
    }

    /// `mergeRecord`: nil when the item type is not merged here (kept as unknown).
    static func mergeRecord(_ db: Database, type: Signalservice_ManifestRecord.Identifier.TypeEnum, record: Signalservice_StorageRecord,
                            storageID: String, ctx: StorageMergeContext) throws -> StorageMergeResult? {
        switch (type, record.record) {
        case (.contact, .contact(let r)?): return try StorageRecords.mergeContact(db, r, storageID: storageID, ctx: ctx)
        case (.groupv2, .groupV2(let r)?): return try StorageRecords.mergeGroupV2(db, r, storageID: storageID, ctx: ctx)
        case (.account, .account(let r)?): return try StorageRecords.mergeAccount(db, r, storageID: storageID, ctx: ctx)
        case (.storyDistributionList, .storyDistributionList(let r)?): return try StorageRecords.mergeStoryList(db, r, storageID: storageID, ctx: ctx)
        case (.stickerPack, .installedStickerPack(let r)?): return try StorageRecords.mergeStickerPack(db, r, storageID: storageID, ctx: ctx)
        case (.favoriteStickerPack, .sticker(let r)?): return try StorageRecords.mergeFavoriteSticker(db, r, storageID: storageID, ctx: ctx)
        case (.callLink, .callLink(let r)?): return try StorageRecords.mergeCallLink(db, r, storageID: storageID, ctx: ctx)
        case (.chatFolder, .chatFolder(let r)?): return try StorageRecords.mergeChatFolder(db, r, storageID: storageID, ctx: ctx)
        case (.notificationProfile, .notificationProfile(let r)?): return try StorageRecords.mergeNotificationProfile(db, r, storageID: storageID, ctx: ctx)
        default: return nil
        }
    }

    /// processManifest's second half: local storageIDs the manifest no longer lists.
    static func forgetMissing(_ db: Database, remoteKeys: Set<String>, ctx: StorageMergeContext) throws {
        let syncDisabled = try Items.get(db, "notificationProfileSyncDisabled", as: Bool.self) ?? false
        for entry in try localEntries(db, ctx: ctx) {
            guard let id = entry.storageID, !remoteKeys.contains(id) else { continue }
            try entry.owner.handleMissingRemotely(db, entry: entry, syncDisabled: syncDisabled)
        }
        var unknown = try ids(db, "storage-service-unknown-records")
        unknown.removeAll { !remoteKeys.contains($0.storageID) }
        try Items.set(db, "storage-service-unknown-records", unknown)
        var errors = try ids(db, "storage-service-error-records")
        errors.removeAll { !remoteKeys.contains($0.storageID) }
        try Items.set(db, "storage-service-error-records", errors)
    }

    // MARK: upload

    struct Generated {
        var identifiers: [Signalservice_ManifestRecord.Identifier] = []
        var inserts: [(raw: Data, record: Signalservice_StorageRecord)] = []
        var deleteKeys = Set<String>()
        var recordIkm: Data?
        var uploaded: [(StorageOwner, String)] = []
    }

    /// `generateManifest`
    static func generateManifest(_ db: Database, ctx: StorageMergeContext, previous: Signalservice_ManifestRecord?) throws -> Generated {
        var g = Generated()
        var insertIDs = Set<String>()
        var recordIDs: [String] = []
        var types: [String: Signalservice_ManifestRecord.Identifier.TypeEnum] = [:]
        var hasAccount = false
        for entry in try localEntries(db, ctx: ctx) {
            if entry.drop {
                if let id = entry.storageID { g.deleteKeys.insert(id) }
                try entry.owner.dropLocal(db)
                continue
            }
            if entry.type == .account {
                if hasAccount { continue }
                hasAccount = true
            }
            let isNew = entry.needsSync || entry.storageID == nil
            let id = isNew ? SignalCrypto.randomBytes(16).base64EncodedString() : entry.storageID!
            guard types[id] == nil else { continue }
            types[id] = entry.type
            recordIDs.append(id)
            if isNew {
                insertIDs.insert(id)
                g.inserts.append((Data(base64Encoded: id)!, entry.record))
                g.uploaded.append((entry.owner, id))
                if let old = entry.storageID { g.deleteKeys.insert(old) }
            }
        }
        // Unknown and failed records pass through unchanged.
        for u in try ids(db, "storage-service-unknown-records") + ids(db, "storage-service-error-records") where types[u.storageID] == nil {
            types[u.storageID] = .init(rawValue: u.itemType ?? 0) ?? .unknown
            recordIDs.append(u.storageID)
        }
        for d in try ids(db, "storage-service-pending-deletes") { g.deleteKeys.insert(d.storageID) }
        recordIDs.removeAll { g.deleteKeys.contains($0) }
        g.inserts.removeAll { g.deleteKeys.contains($0.raw.base64EncodedString()) }
        g.uploaded.removeAll { g.deleteKeys.contains($0.1) }
        insertIDs.subtract(g.deleteKeys)
        g.identifiers = recordIDs.map { id in
            var i = Signalservice_ManifestRecord.Identifier()
            i.raw = Data(base64Encoded: id)!
            i.type = types[id]!
            return i
        }

        if let previous {
            // The write must turn `previous` into exactly our record set.
            let remote = Set(previous.identifiers.map { $0.raw.base64EncodedString() })
            let local = Set(recordIDs)
            let expectedInserts = local.subtracting(remote)
            let expectedDeletes = remote.subtracting(local)
            guard insertIDs == expectedInserts else { throw StorageServiceError.invalidWrite("insert keys do not match") }
            guard expectedDeletes.isSubset(of: g.deleteKeys) else { throw StorageServiceError.invalidWrite("missing delete key") }
            try Items.set(db, "storage-service-pending-deletes", g.deleteKeys.sorted().map { StorageIDRecord(storageID: $0, storageVersion: ctx.version) })
            g.recordIkm = previous.recordIkm.isEmpty ? nil : previous.recordIkm
        } else {
            g.recordIkm = try Items.get(db, "manifestRecordIkm", as: String.self).flatMap { Data(base64Encoded: $0) }
        }
        return g
    }

    /// `upload`. From a local change (`fromSync` false) it syncs first; `fromSync` uploads are
    /// rate limited to 3 per 5 minutes, like upstream's uploadBucket.
    @discardableResult
    public func upload(fromSync: Bool = false) async throws -> StorageUploadResult? {
        try await queue.run { try await self.uploadNow(fromSync: fromSync) }
    }

    func uploadNow(fromSync: Bool) async throws -> StorageUploadResult? {
        // `runStorageServiceUploadJobAfterEnabled`: nothing goes up before the first sync has
        // merged the phone's records; that sync queues the upload itself.
        guard try await database.pool.read({ try Items.get($0, "storageFetchComplete", as: Bool.self) }) == true else { return nil }
        if fromSync {
            let now = MessageStore.now()
            try hooks.withLock { h in
                h.uploadBucket.append(now)
                if h.uploadBucket.count >= 3 {
                    if now - h.uploadBucket[0] < 5 * 60_000 { throw StorageServiceError.tooManyWrites }
                    h.uploadBucket.removeFirst()
                }
            }
        }
        var previous: Signalservice_ManifestRecord? = nil
        if !fromSync { previous = try await syncManifest().manifest }
        for attempt in 0...Self.maxConflictRetries {
            do {
                guard var result = try await write(previous: previous) else { return nil }
                result.conflicts = attempt
                return result
            } catch StorageServiceError.conflict {
                previous = try await syncManifest().manifest
            }
        }
        throw StorageServiceError.conflict
    }

    func write(previous: Signalservice_ManifestRecord?) async throws -> StorageUploadResult? {
        let storageKey = try await database.pool.read { try Self.storageKey($0) }
        let local = try await database.pool.read { try Items.get($0, "manifestVersion", as: UInt64.self) } ?? 0
        let version = local + 1
        let generated = try await database.pool.write { db in
            try Self.generateManifest(db, ctx: try self.context(db, version: version), previous: previous)
        }
        guard !generated.inserts.isEmpty || !generated.deleteKeys.isEmpty else {
            try await database.pool.write { try Items.set($0, "storage-service-pending-deletes", [StorageIDRecord]()) }
            return nil
        }
        var manifest = Signalservice_ManifestRecord()
        manifest.version = version
        manifest.sourceDevice = account.deviceId
        manifest.identifiers = generated.identifiers
        if let ikm = generated.recordIkm { manifest.recordIkm = ikm }
        var write = Signalservice_WriteOperation()
        write.manifest.version = version
        write.manifest.value = try SignalCrypto.aes256GCMEncrypt(key: Self.manifestKey(storageKey: storageKey, version: version), manifest.serializedBytes())
        write.insertItem = try generated.inserts.map { try Self.encryptItem($0.record, raw: $0.raw, storageKey: storageKey, recordIkm: generated.recordIkm) }
        write.deleteKey = generated.deleteKeys.sorted().compactMap { Data(base64Encoded: $0) }

        // WebAPI `storageModify` is "v1/storage/" (the trailing slash is part of the route).
        let modify = URL(string: endpoints.storageURL.absoluteString + "/v1/storage/")!
        let (status, _) = try await http.send("PUT", modify, body: try write.serializedBytes() as Data, headers: try await headers(), accept: [409])
        if status == 409 { throw StorageServiceError.conflict }

        let uploaded = generated.uploaded
        let ikm = generated.recordIkm
        try await database.pool.write { db in
            for (owner, id) in uploaded { try owner.setUploaded(db, storageID: id, version: version) }
            try Items.set(db, "manifestVersion", version)
            if let ikm { try Items.set(db, "manifestRecordIkm", ikm.base64EncodedString()) }
            try Items.set(db, "storage-service-pending-deletes", [StorageIDRecord]())
            // getFetchManifestSyncMessage: our other devices (the phone) refetch.
            try JobQueue.insert(db, queueType: ConversationJob.queueType,
                                payload: ConversationJob.fetchLatest([Signalservice_SyncMessage.FetchLatest.TypeEnum.storageManifest.rawValue]))
        }
        hooks.withLock { $0.jobs }?.poke()
        return StorageUploadResult(version: version, inserted: generated.inserts.count, deleted: generated.deleteKeys.count)
    }
}

/// Runs storage jobs one after another (each waits for the previous one to finish).
actor StorageQueue {
    var tail: Task<Void, Never>?

    func run<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task<T, any Error> {
            await previous?.value
            return try await body()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}
