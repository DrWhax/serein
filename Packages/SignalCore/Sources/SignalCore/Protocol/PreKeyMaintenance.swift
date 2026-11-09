// Keeping our pre-keys fresh (upstream AccountManager.maybeUpdateKeys and UpdateKeysListener).
//
// Other people start sessions with us from the keys the server holds: one-time EC and Kyber
// pre-keys (each used once), and a signed pre-key and a last-resort Kyber key that are reused
// when the one-time keys have run out. Without this
//   - the one-time keys run out for good, and every new session falls back to the reusable keys;
//   - those reusable keys never change, so whoever obtains one can read the first messages of
//     every session started with it, past and future.
// So: refill the one-time keys when the server runs low, replace the signed and last-resort
// keys every day and a half, and delete old private keys once no message can still need them.

import Foundation
import GRDB
import LibSignalClient

public struct PreKeyMaintenance: Sendable {
    public enum Identity: String, Sendable, CaseIterable {
        case aci, pni
        /// Upstream's `items` keys (the PNI ones carry a suffix).
        func item(_ name: String) -> String { self == .aci ? name : name + "PNI" }
    }

    static let day: Int64 = 86_400_000
    /// PRE_KEY_GEN_BATCH_SIZE / PRE_KEY_MINIMUM / PRE_KEY_MAX_COUNT
    static let batchSize = 100, minimum = 10, maximum = 200
    /// SIGNED_PRE_KEY_ROTATION_AGE / LAST_RESORT_KEY_ROTATION_AGE
    static let rotationAge = day * 3 / 2
    /// SIGNED_PRE_KEY_MINIMUM / LAST_RESORT_KEY_MINIMUM: how many are always kept.
    static let reusableMinimum = 5
    /// PRE_KEY_ARCHIVE_AGE
    static let archiveAge = 90 * day
    /// `getMessageQueueTime`: how long the server may hold a message for us (its floor).
    static let messageQueueTime = 30 * day
    /// UpdateKeysListener's UPDATE_INTERVAL and storage key.
    static let updateInterval = 2 * day
    static let nextUpdateItem = "nextScheduledUpdateKeyTime"
    static let maxKeyId: UInt32 = 0xFF_FFFF
    /// KEY_TOO_OLD_THRESHOLD: nothing is sent while our reusable keys are older than this.
    static let tooOldThreshold = 14 * day

    public typealias Request = @Sendable (_ method: String, _ path: String, _ json: Data?) async throws -> Data

    let account: Account
    let database: SignalDatabase
    let request: Request

    public init(account: Account, database: SignalDatabase, socket: SocketManager) {
        self.init(account: account, database: database) { method, path, json in
            if let json { return try await socket.authenticatedRequest(method, path, json: json) }
            return try await socket.authenticatedRequest(method, path)
        }
    }

    init(account: Account, database: SignalDatabase, request: @escaping Request) {
        self.account = account
        self.database = database
        self.request = request
    }

    public struct Report: Sendable, Equatable {
        public var preKeys = 0
        public var kyberPreKeys = 0
        public var signedPreKey: UInt32?
        public var lastResortKey: UInt32?
        public var removed = 0
        var uploaded: Bool { preKeys > 0 || kyberPreKeys > 0 || signedPreKey != nil || lastResortKey != nil }
    }

    /// `UpdateKeysListener`: runs `maybeUpdateKeys` for both identities when the next
    /// scheduled time has come (at once on first use), then schedules the next run.
    @discardableResult
    public func runIfDue(now time: Int64? = nil) async throws -> Bool {
        let now = time ?? MessageStore.now()
        let due = try await database.pool.read { db in try Items.get(db, Self.nextUpdateItem, as: Int64.self) } ?? now
        guard due <= now else { return false }
        try await maybeUpdateKeys(.aci, now: now)
        // Upstream: a PNI failure is logged and not retried until the next run.
        _ = try? await maybeUpdateKeys(.pni, now: now)
        try await database.pool.write { db in try Items.set(db, Self.nextUpdateItem, now + Self.updateInterval) }
        return true
    }

    /// `areKeysOutOfDate`: the signed pre-key or the last-resort key was last replaced more
    /// than two weeks ago (or never, as far as we know).
    public func areKeysOutOfDate(_ identity: Identity = .aci, now time: Int64? = nil) async throws -> Bool {
        let now = time ?? MessageStore.now()
        return try await database.pool.read { db in
            let signed = try Items.get(db, identity.item("signedKeyUpdateTime"), as: Int64.self) ?? 0
            let lastResort = try Items.get(db, identity.item("lastResortKeyUpdateTime"), as: Int64.self) ?? 0
            return min(signed, lastResort) < now - Self.tooOldThreshold
        }
    }

    /// What upstream does before every send (sendMessageProto, sendToGroup): with keys that
    /// old, update them first, and refuse to send if that did not help.
    public func ensureKeysCurrent(now time: Int64? = nil) async throws {
        guard try await areKeysOutOfDate(now: time) else { return }
        try await maybeUpdateKeys(.aci, now: time)
        if try await areKeysOutOfDate(now: time) { throw SendError.keysOutOfDate }
    }

    /// `maybeUpdateKeys`
    @discardableResult
    public func maybeUpdateKeys(_ identity: Identity, force: Bool = false, now time: Int64? = nil) async throws -> Report {
        let now = time ?? MessageStore.now()
        guard let store = identity == .aci ? account.aciStore() : account.pniStore() else { return Report() }
        struct Counts: Decodable { var count: Int; var pqCount: Int }
        let counts = try JSONDecoder().decode(Counts.self, from: try await request("GET", "/v2/keys?identity=\(identity.rawValue)", nil))
        let needEC = counts.count < Self.minimum || counts.count > Self.maximum || force
        let needKyber = counts.pqCount < Self.minimum || counts.pqCount > Self.maximum || force

        // Generate and store first: a private key must exist before its public half is offered.
        let (report, body) = try await database.pool.write { db -> (Report, Data) in
            let ctx = DatabaseStoreContext(db)
            let sign = { (key: Data) in store.identity.privateKey.generateSignature(message: key) }
            var report = Report()
            var body: [String: Any] = [:]
            if needEC {
                let ids = try Self.nextIds(db, item: identity.item("maxPreKeyId"), table: "preKeys", store: store, count: Self.batchSize)
                body["preKeys"] = try ids.map { id -> [String: Any] in
                    let record = try PreKeyRecord(id: id, privateKey: .generate())
                    try store.storeRow("preKeys", id, record.serialize(), createdAt: now, ctx)
                    return ["keyId": id, "publicKey": try record.publicKey().serialize().base64EncodedString()]
                }
                report.preKeys = ids.count
            }
            func kyber(_ id: UInt32, lastResort: Bool) throws -> [String: Any] {
                let pair = KEMKeyPair.generate()
                let record = try KyberPreKeyRecord(id: id, timestamp: UInt64(now), keyPair: pair, signature: sign(pair.publicKey.serialize()))
                try store.storeRow("kyberPreKeys", id, record.serialize(), lastResort: lastResort, confirmed: !lastResort, createdAt: now, ctx)
                return KeyBundle.kyberJSON(record)
            }
            if needKyber {
                let ids = try Self.nextIds(db, item: identity.item("maxKyberPreKeyId"), table: "kyberPreKeys", store: store, count: Self.batchSize)
                body["pqPreKeys"] = try ids.map { try kyber($0, lastResort: false) }
                report.kyberPreKeys = ids.count
            }
            // A recent key whose time we never recorded (keys from linking): record it now.
            func remember(_ item: String, _ keys: [ProtocolStore.KeyRow]) throws {
                guard try Items.get(db, item, as: Int64.self) == nil,
                      let newest = keys.filter({ $0.isConfirmed ?? true }).compactMap(\.createdAt).max() else { return }
                try Items.set(db, item, newest)
            }
            if try force || Self.needsRotation(store.reusableKeys(db, table: "kyberPreKeys", lastResort: true), now: now) {
                let id = try Self.nextIds(db, item: identity.item("maxKyberPreKeyId"), table: "kyberPreKeys", store: store, count: 1)[0]
                body["pqLastResortPreKey"] = try kyber(id, lastResort: true)
                report.lastResortKey = id
            } else {
                try remember(identity.item("lastResortKeyUpdateTime"), try store.reusableKeys(db, table: "kyberPreKeys", lastResort: true))
            }
            if try force || Self.needsRotation(store.reusableKeys(db, table: "signedPreKeys", lastResort: nil), now: now) {
                let id = try Self.nextIds(db, item: identity.item("signedKeyId"), table: "signedPreKeys", store: store, count: 1)[0]
                let key = PrivateKey.generate()
                let record = try SignedPreKeyRecord(id: id, timestamp: UInt64(now), privateKey: key, signature: sign(key.publicKey.serialize()))
                try store.storeRow("signedPreKeys", id, record.serialize(), confirmed: false, createdAt: now, ctx)
                body["signedPreKey"] = ["keyId": id, "publicKey": key.publicKey.serialize().base64EncodedString(),
                                        "signature": record.signature.base64EncodedString()]
                report.signedPreKey = id
            } else {
                try remember(identity.item("signedKeyUpdateTime"), try store.reusableKeys(db, table: "signedPreKeys", lastResort: nil))
            }
            return (report, try JSONSerialization.data(withJSONObject: body))
        }
        guard report.uploaded else { return report }
        _ = try await request("PUT", "/v2/keys?identity=\(identity.rawValue)", body)

        // `_confirmKeys`, then the four `_clean…` passes.
        return try await database.pool.write { db in
            var report = report
            if let id = report.signedPreKey {
                try store.confirm(db, table: "signedPreKeys", id: id)
                try Items.set(db, identity.item("signedKeyUpdateTime"), now)
            }
            if let id = report.lastResortKey {
                try store.confirm(db, table: "kyberPreKeys", id: id)
                try Items.set(db, identity.item("lastResortKeyUpdateTime"), now)
            }
            report.removed = try Self.clean(db, store: store, now: now)
            return report
        }
    }

    /// The newest confirmed key is older than the rotation age (or there is none).
    static func needsRotation(_ keys: [ProtocolStore.KeyRow], now: Int64) -> Bool {
        let newest = keys.filter { $0.isConfirmed ?? true }.map { $0.createdAt ?? 0 }.max() ?? 0
        return newest <= now - rotationAge
    }

    /// `count` consecutive key ids from the stored counter (`getNextKeyId`), wrapping within
    /// 24 bits and never 0. Without a counter (keys from linking have none) the ids continue
    /// after the highest one in use, so no unused key is overwritten.
    static func nextIds(_ db: Database, item: String, table: String, store: ProtocolStore, count: Int) throws -> [UInt32] {
        let start: UInt32
        if let stored = try Items.get(db, item, as: Int64.self), stored >= 1, stored <= Int64(maxKeyId) {
            start = UInt32(stored)
        } else {
            let highest = try store.allPreKeyIds(table: table, lastResort: nil, db).max() ?? UInt32.random(in: 1..<maxKeyId)
            start = highest % maxKeyId + 1
        }
        let ids = (0..<count).map { (start - 1 + UInt32($0)) % maxKeyId + 1 }
        try Items.set(db, item, Int64((start - 1 + UInt32(count)) % maxKeyId + 1))
        return ids
    }

    /// `_cleanSignedPreKeys`, `_cleanLastResortKeys`, `_cleanPreKeys`, `_cleanKyberPreKeys`:
    /// the newest five reusable keys always stay, older ones until no queued message can
    /// still have been encrypted to them; one-time keys beyond the newest 200 go after 90 days.
    static func clean(_ db: Database, store: ProtocolStore, now: Int64) throws -> Int {
        var removed = 0
        func drop(_ table: String, lastResort: Bool?, keep: Int, olderThan age: Int64) throws {
            let rows = try store.reusableKeys(db, table: table, lastResort: lastResort).sorted { ($0.createdAt ?? 0) > ($1.createdAt ?? 0) }
            for row in rows.dropFirst(keep) where (row.createdAt ?? 0) < now - age {
                try db.execute(sql: "DELETE FROM \(table) WHERE id = ?", arguments: [row.id])
                removed += 1
            }
        }
        try drop("signedPreKeys", lastResort: nil, keep: reusableMinimum, olderThan: messageQueueTime)
        try drop("kyberPreKeys", lastResort: true, keep: reusableMinimum, olderThan: messageQueueTime)
        try drop("preKeys", lastResort: nil, keep: maximum, olderThan: archiveAge)
        try drop("kyberPreKeys", lastResort: false, keep: maximum, olderThan: archiveAge)
        return removed
    }
}

extension ProtocolStore {
    /// This identity's rows of a pre-key table (optionally by isLastResort).
    func reusableKeys(_ db: Database, table: String, lastResort: Bool?) throws -> [KeyRow] {
        try String.fetchAll(db, sql: "SELECT json FROM \(table) WHERE json ->> '$.ourServiceId' = ?", arguments: [ourServiceId]).compactMap { json in
            let row = try JSONDecoder().decode(KeyRow.self, from: Data(json.utf8))
            if let lastResort, (row.isLastResort ?? false) != lastResort { return nil }
            return row
        }
    }

    func confirm(_ db: Database, table: String, id: UInt32) throws {
        try db.execute(sql: "UPDATE \(table) SET json = json_set(json, '$.isConfirmed', json('true')) WHERE id = ?", arguments: [keyId(id)])
    }
}
