// LibSignalClient protocol stores over the upstream tables (identityKeys, sessions,
// preKeys, signedPreKeys, kyberPreKeys, kyberPreKey_triples, senderKeys).
//
// Atomicity: every store method uses the GRDB `Database` carried in the
// `StoreContext`. Callers run a whole decrypt (and the persistence of its result)
// inside one write transaction, so session/prekey updates commit together with the
// decrypted message or not at all — the equivalent of Desktop's
// SignalProtocolStore.withZone.

import Foundation
import GRDB
import LibSignalClient

/// A `StoreContext` that carries the open write transaction.
public struct DatabaseStoreContext: StoreContext {
    public let db: Database
    public init(_ db: Database) { self.db = db }
}

public enum ProtocolStoreError: Error, Equatable {
    case wrongContext
    case missing(String)
    case kyberLastResortReused(UInt32)
}

/// Protocol state for one of our identities (ACI or PNI).
public final class ProtocolStore: IdentityKeyStore, PreKeyStore, SignedPreKeyStore, KyberPreKeyStore, SessionStore, SenderKeyStore,
    @unchecked Sendable
{
    public let ourServiceId: String
    let identity: IdentityKeyPair
    let registrationId: UInt32
    /// The identity keys of every service id that is ours (ACI and PNI): what upstream asks
    /// `isOurServiceId` for. Nobody else can change them.
    let ownIdentities: [String: IdentityKey]

    public init(ourServiceId: String, identity: IdentityKeyPair, registrationId: UInt32, ownIdentities: [String: IdentityKey] = [:]) {
        self.ourServiceId = ourServiceId
        self.identity = identity
        self.registrationId = registrationId
        self.ownIdentities = ownIdentities.merging([ourServiceId: identity.identityKey]) { _, ours in ours }
    }

    func db(_ context: StoreContext) throws -> Database {
        guard let c = context as? DatabaseStoreContext else { throw ProtocolStoreError.wrongContext }
        return c.db
    }

    // MARK: IdentityKeyStore

    public func identityKeyPair(context: StoreContext) throws -> IdentityKeyPair { identity }
    public func localRegistrationId(context: StoreContext) throws -> UInt32 { registrationId }

    /// One row of `identityKeys` (upstream IdentityKeyType).
    struct IdentityRow: Codable {
        var id: String
        var publicKey: String
        var firstUse: Bool
        var timestamp: Int64
        var verified: Int
        var nonblockingApproval: Bool

        var key: Data? { Data(base64Encoded: publicKey) }
        var verifiedStatus: VerifiedStatus { VerifiedStatus(rawValue: verified) ?? .default }

        /// `isNonBlockingApprovalRequired` / `isUntrusted`: a key that replaced another one
        /// less than `threshold` ago and that the user has not approved yet.
        func needsApproval(now: Int64, threshold: Int64 = ProtocolStore.approvalWindow) -> Bool {
            !firstUse && timestamp > now - threshold && !nonblockingApproval
        }
    }

    /// Upstream TIMESTAMP_THRESHOLD: how long a replaced identity key blocks sending unless approved.
    public static let approvalWindow: Int64 = 5 * 1000

    static func identityRow(_ db: Database, serviceId: String) throws -> IdentityRow? {
        guard let json = try String.fetchOne(db, sql: "SELECT json FROM identityKeys WHERE id = ?", arguments: [serviceId]) else { return nil }
        return try JSONDecoder().decode(IdentityRow.self, from: Data(json.utf8))
    }

    static func save(_ db: Database, _ row: IdentityRow) throws {
        try db.execute(sql: "INSERT INTO identityKeys (id, json) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET json = excluded.json",
                       arguments: [row.id, String(decoding: try JSONEncoder().encode(row), as: UTF8.self)])
    }

    public func identity(for address: ProtocolAddress, context: StoreContext) throws -> IdentityKey? {
        guard let row = try Self.identityRow(try db(context), serviceId: address.name) else { return nil }
        guard let bytes = row.key else { throw ProtocolStoreError.missing("identity key bytes") }
        return try IdentityKey(bytes: bytes)
    }

    public func saveIdentity(_ identity: IdentityKey, for address: ProtocolAddress, context: StoreContext) throws -> IdentityChange {
        try saveIdentity(try db(context), identity, for: address)
    }

    /// Upstream `saveIdentity`.
    ///  - first key for this id: stored as first use, default verification;
    ///  - a different key: stored as *not* first use with a fresh timestamp (so sending is
    ///    blocked until approved or `approvalWindow` passes), a verified or unverified
    ///    contact becomes unverified (blocked until the user approves), the conversation
    ///    gets its "safety number changed" notice and the sessions of the id's other devices
    ///    are archived;
    ///  - the same key: unchanged.
    /// A key for one of our own ids that is not our key is never stored.
    @discardableResult
    func saveIdentity(_ db: Database, _ identity: IdentityKey, for address: ProtocolAddress, nonblockingApproval: Bool = false,
                      noOverwrite: Bool = false) throws -> IdentityChange {
        let id = address.name
        if let ours = ownIdentities[id], ours != identity { return .newOrUnchanged }
        let key = identity.serialize()
        let now = MessageStore.now()
        guard var row = try Self.identityRow(db, serviceId: id), let existing = row.key else {
            try Self.save(db, IdentityRow(id: id, publicKey: key.base64EncodedString(), firstUse: true, timestamp: now,
                                          verified: VerifiedStatus.default.rawValue, nonblockingApproval: nonblockingApproval))
            return .newOrUnchanged
        }
        if noOverwrite { return .newOrUnchanged }
        if !SignalCrypto.constantTimeEqual(existing, key) {
            let wasMarked = row.verifiedStatus == .verified || row.verifiedStatus == .unverified
            try Self.save(db, IdentityRow(id: id, publicKey: key.base64EncodedString(), firstUse: false, timestamp: now,
                                          verified: (wasMarked ? VerifiedStatus.unverified : .default).rawValue, nonblockingApproval: nonblockingApproval))
            try MessageStore.insertKeyChange(db, serviceId: id)
            try Self.archiveSessions(db, serviceId: id, exceptDevice: address.deviceId)
            return .replacedExisting
        }
        if row.needsApproval(now: now) {
            row.nonblockingApproval = nonblockingApproval
            try Self.save(db, row)
        }
        return .newOrUnchanged
    }

    /// Upstream `isTrustedIdentity`. Our own ids only ever have our own keys. Incoming
    /// messages are otherwise always accepted (the key is saved, which is what raises the
    /// notice and the block); outgoing ones go through `isTrustedForSending`.
    public func isTrustedIdentity(_ identity: IdentityKey, for address: ProtocolAddress, direction: Direction, context: StoreContext) throws -> Bool {
        if let ours = ownIdentities[address.name] { return ours == identity }
        switch direction {
        case .receiving: return true
        case .sending: return try Self.isTrustedForSending(try db(context), serviceId: address.name, key: identity.serialize())
        }
    }

    /// Upstream `isTrustedForSending`: the key we have on record, not marked unverified, and
    /// not a replacement the user still has to see.
    static func isTrustedForSending(_ db: Database, serviceId: String, key: Data) throws -> Bool {
        guard let row = try identityRow(db, serviceId: serviceId), let existing = row.key else { return true }
        guard SignalCrypto.constantTimeEqual(existing, key) else { return false }
        if row.verifiedStatus == .unverified { return false }
        return !row.needsApproval(now: MessageStore.now())
    }

    /// Upstream `updateIdentityKey`: an identity key the server reported for `serviceId`
    /// (profile, pre-key bundle). A change goes through `saveIdentity` and also closes the
    /// primary device's session, which `saveIdentity` leaves alone.
    @discardableResult
    func updateIdentityKey(_ db: Database, _ identity: IdentityKey, serviceId: String, noOverwrite: Bool = false) throws -> Bool {
        let change = try saveIdentity(db, identity, for: try ProtocolAddress(name: serviceId, deviceId: 1), noOverwrite: noOverwrite)
        guard change == .replacedExisting else { return false }
        try Self.archiveSessions(db, serviceId: serviceId)
        return true
    }

    /// `archiveSiblingSessions` (and, with no exception, `archiveAllSessions`).
    static func archiveSessions(_ db: Database, serviceId: String, exceptDevice: UInt32? = nil) throws {
        let rows = try Row.fetchAll(db, sql: "SELECT id, deviceId, record FROM sessions WHERE serviceId = ?", arguments: [serviceId])
        for row in rows where exceptDevice == nil || UInt32(row["deviceId"] as Int) != exceptDevice {
            let session = try SessionRecord(bytes: row["record"] as Data)
            guard session.hasCurrentState else { continue }
            session.archiveCurrentState()
            try db.execute(sql: "UPDATE sessions SET record = ? WHERE id = ?", arguments: [session.serialize(), row["id"] as String])
        }
    }

    // MARK: SessionStore

    func sessionId(_ a: ProtocolAddress) -> String { "\(ourServiceId):\(a.name).\(a.deviceId)" }

    public func loadSession(for address: ProtocolAddress, context: StoreContext) throws -> SessionRecord? {
        guard let blob = try Data.fetchOne(try db(context), sql: "SELECT record FROM sessions WHERE id = ?", arguments: [sessionId(address)]) else {
            return nil
        }
        return try SessionRecord(bytes: blob)
    }

    public func loadExistingSessions(for addresses: [ProtocolAddress], context: StoreContext) throws -> [SessionRecord] {
        try addresses.map { a in
            guard let s = try loadSession(for: a, context: context) else { throw ProtocolStoreError.missing("session \(sessionId(a))") }
            return s
        }
    }

    public func storeSession(_ record: SessionRecord, for address: ProtocolAddress, context: StoreContext) throws {
        try db(context).execute(
            sql: """
                INSERT INTO sessions (id, ourServiceId, serviceId, conversationId, deviceId, record) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET record = excluded.record
                """,
            arguments: [sessionId(address), ourServiceId, address.name, address.name, Int(address.deviceId), record.serialize()])
    }

    // MARK: pre-keys (json = {id, keyId, ourServiceId, record})

    struct KeyRow: Codable {
        var id: String
        var keyId: UInt32
        var ourServiceId: String
        var record: String
        var isLastResort: Bool?
        var isConfirmed: Bool?
        var createdAt: Int64?
    }

    func keyId(_ id: UInt32) -> String { "\(ourServiceId):\(id)" }

    func loadRow(_ table: String, _ id: UInt32, _ context: StoreContext) throws -> KeyRow {
        guard let json = try String.fetchOne(try db(context), sql: "SELECT json FROM \(table) WHERE id = ?", arguments: [keyId(id)]) else {
            throw ProtocolStoreError.missing("\(table) \(keyId(id))")
        }
        return try JSONDecoder().decode(KeyRow.self, from: Data(json.utf8))
    }

    /// `confirmed`: the server has the key (false between generating a signed or last-resort
    /// key and its upload).
    func storeRow(_ table: String, _ id: UInt32, _ record: Data, lastResort: Bool? = nil, confirmed: Bool = true, createdAt: Int64? = nil,
                  _ context: StoreContext) throws {
        let row = KeyRow(id: keyId(id), keyId: id, ourServiceId: ourServiceId, record: record.base64EncodedString(),
                         isLastResort: lastResort, isConfirmed: confirmed, createdAt: createdAt ?? Int64(Date().timeIntervalSince1970 * 1000))
        try db(context).execute(sql: "INSERT INTO \(table) (id, json) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET json = excluded.json",
                                arguments: [keyId(id), String(decoding: try JSONEncoder().encode(row), as: UTF8.self)])
    }

    public func loadPreKey(id: UInt32, context: StoreContext) throws -> PreKeyRecord {
        try PreKeyRecord(bytes: Data(base64Encoded: try loadRow("preKeys", id, context).record)!)
    }
    public func storePreKey(_ record: PreKeyRecord, id: UInt32, context: StoreContext) throws {
        try storeRow("preKeys", id, record.serialize(), context)
    }
    public func removePreKey(id: UInt32, context: StoreContext) throws {
        try db(context).execute(sql: "DELETE FROM preKeys WHERE id = ?", arguments: [keyId(id)])
    }

    public func loadSignedPreKey(id: UInt32, context: StoreContext) throws -> SignedPreKeyRecord {
        try SignedPreKeyRecord(bytes: Data(base64Encoded: try loadRow("signedPreKeys", id, context).record)!)
    }
    public func storeSignedPreKey(_ record: SignedPreKeyRecord, id: UInt32, context: StoreContext) throws {
        try storeRow("signedPreKeys", id, record.serialize(), context)
    }

    public func loadKyberPreKey(id: UInt32, context: StoreContext) throws -> KyberPreKeyRecord {
        try KyberPreKeyRecord(bytes: Data(base64Encoded: try loadRow("kyberPreKeys", id, context).record)!)
    }
    public func storeKyberPreKey(_ record: KyberPreKeyRecord, id: UInt32, context: StoreContext) throws {
        try storeRow("kyberPreKeys", id, record.serialize(), lastResort: false, context)
    }
    public func storeLastResortKyberPreKey(_ record: KyberPreKeyRecord, id: UInt32, context: StoreContext) throws {
        try storeRow("kyberPreKeys", id, record.serialize(), lastResort: true, context)
    }

    /// One-time Kyber keys are deleted on use; a last-resort key may be reused, but
    /// never with the same (signed pre-key, base key) pair (replay protection).
    public func markKyberPreKeyUsed(id: UInt32, signedPreKeyId: UInt32, baseKey: PublicKey, context: StoreContext) throws {
        let row = try loadRow("kyberPreKeys", id, context)
        let db = try db(context)
        if row.isLastResort == true {
            let seen = try Bool.fetchOne(db, sql: "SELECT 1 FROM kyberPreKey_triples WHERE id = ? AND signedPreKeyId = ? AND baseKey = ?",
                                         arguments: [keyId(id), Int(signedPreKeyId), baseKey.serialize()]) ?? false
            guard !seen else { throw ProtocolStoreError.kyberLastResortReused(id) }
            try db.execute(sql: "INSERT INTO kyberPreKey_triples (id, signedPreKeyId, baseKey) VALUES (?, ?, ?)",
                           arguments: [keyId(id), Int(signedPreKeyId), baseKey.serialize()])
        } else {
            try db.execute(sql: "DELETE FROM kyberPreKeys WHERE id = ?", arguments: [keyId(id)])
        }
    }

    // MARK: SenderKeyStore

    func senderKeyId(_ sender: ProtocolAddress, _ distributionId: UUID) -> String {
        "\(ourServiceId):\(sender.name).\(sender.deviceId)--\(distributionId.uuidString.lowercased())"
    }

    public func storeSenderKey(from sender: ProtocolAddress, distributionId: UUID, record: SenderKeyRecord, context: StoreContext) throws {
        try db(context).execute(
            sql: """
                INSERT INTO senderKeys (id, senderId, distributionId, data, lastUpdatedDate) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET data = excluded.data, lastUpdatedDate = excluded.lastUpdatedDate
                """,
            arguments: [senderKeyId(sender, distributionId), "\(sender.name).\(sender.deviceId)", distributionId.uuidString.lowercased(),
                        record.serialize(), Int64(Date().timeIntervalSince1970 * 1000)])
    }

    /// `removeSenderKey`
    func removeSenderKey(_ db: Database, from sender: ProtocolAddress, distributionId: UUID) throws {
        try db.execute(sql: "DELETE FROM senderKeys WHERE id = ?", arguments: [senderKeyId(sender, distributionId)])
    }

    public func loadSenderKey(from sender: ProtocolAddress, distributionId: UUID, context: StoreContext) throws -> SenderKeyRecord? {
        guard let blob = try Data.fetchOne(try db(context), sql: "SELECT data FROM senderKeys WHERE id = ?",
                                           arguments: [senderKeyId(sender, distributionId)]) else { return nil }
        return try SenderKeyRecord(bytes: blob)
    }
}
