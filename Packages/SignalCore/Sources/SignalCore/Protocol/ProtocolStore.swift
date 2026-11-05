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

    public init(ourServiceId: String, identity: IdentityKeyPair, registrationId: UInt32) {
        self.ourServiceId = ourServiceId
        self.identity = identity
        self.registrationId = registrationId
    }

    func db(_ context: StoreContext) throws -> Database {
        guard let c = context as? DatabaseStoreContext else { throw ProtocolStoreError.wrongContext }
        return c.db
    }

    // MARK: IdentityKeyStore

    public func identityKeyPair(context: StoreContext) throws -> IdentityKeyPair { identity }
    public func localRegistrationId(context: StoreContext) throws -> UInt32 { registrationId }

    struct IdentityRow: Codable {
        var id: String
        var publicKey: String
        var firstUse: Bool
        var timestamp: Int64
        var verified: Int
        var nonblockingApproval: Bool
    }

    public func identity(for address: ProtocolAddress, context: StoreContext) throws -> IdentityKey? {
        guard let json = try String.fetchOne(try db(context), sql: "SELECT json FROM identityKeys WHERE id = ?", arguments: [address.name]) else {
            return nil
        }
        let row = try JSONDecoder().decode(IdentityRow.self, from: Data(json.utf8))
        guard let bytes = Data(base64Encoded: row.publicKey) else { throw ProtocolStoreError.missing("identity key bytes") }
        return try IdentityKey(bytes: bytes)
    }

    public func saveIdentity(_ identity: IdentityKey, for address: ProtocolAddress, context: StoreContext) throws -> IdentityChange {
        let existing = try self.identity(for: address, context: context)
        if existing == identity { return .newOrUnchanged }
        let row = IdentityRow(id: address.name, publicKey: identity.serialize().base64EncodedString(), firstUse: existing == nil,
                              timestamp: Int64(Date().timeIntervalSince1970 * 1000), verified: 0, nonblockingApproval: false)
        try db(context).execute(sql: "INSERT INTO identityKeys (id, json) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET json = excluded.json",
                                arguments: [address.name, String(decoding: try JSONEncoder().encode(row), as: UTF8.self)])
        return existing == nil ? .newOrUnchanged : .replacedExisting
    }

    /// Trust on first use. Incoming messages are always accepted (Desktop behaviour);
    /// outgoing messages to a changed identity need the change to be saved first.
    public func isTrustedIdentity(_ identity: IdentityKey, for address: ProtocolAddress, direction: Direction, context: StoreContext) throws -> Bool {
        if direction == .receiving { return true }
        guard let existing = try self.identity(for: address, context: context) else { return true }
        return existing == identity
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

    func storeRow(_ table: String, _ id: UInt32, _ record: Data, lastResort: Bool? = nil, _ context: StoreContext) throws {
        let row = KeyRow(id: keyId(id), keyId: id, ourServiceId: ourServiceId, record: record.base64EncodedString(),
                         isLastResort: lastResort, isConfirmed: true, createdAt: Int64(Date().timeIntervalSince1970 * 1000))
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

    public func loadSenderKey(from sender: ProtocolAddress, distributionId: UUID, context: StoreContext) throws -> SenderKeyRecord? {
        guard let blob = try Data.fetchOne(try db(context), sql: "SELECT data FROM senderKeys WHERE id = ?",
                                           arguments: [senderKeyId(sender, distributionId)]) else { return nil }
        return try SenderKeyRecord(bytes: blob)
    }
}
