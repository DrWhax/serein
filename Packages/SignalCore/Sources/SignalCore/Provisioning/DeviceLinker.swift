// Linking as a secondary device (port of Desktop Provisioner.preload.ts +
// AccountManager.preload.ts createAccount/linkDevice, minus history import):
//
//   1. provisioning socket → address → QR URL (sgnl://linkdevice?uuid&pub_key&capabilities)
//   2. primary scans → ProvisionEnvelope → ProvisionMessage (identity keys, ACI/PNI, code)
//   3. PUT /v1/devices/link (Basic aci:password) with signed + PQ last-resort pre-keys
//   4. persist account + keys; authenticated socket; PUT /v2/keys one-time pre-keys

import Foundation
import GRDB
import LibSignalClient
import SignalProtos

public enum LinkError: Error, Equatable {
    case provisioningClosed(String)
    case invalidProvisionMessage(String)
    case unexpectedResponse(String)
}

public struct LinkOptions: Sendable {
    public var deviceName: String
    public var oneTimePreKeyCount: Int
    public init(deviceName: String, oneTimePreKeyCount: Int = 100) {
        self.deviceName = deviceName
        self.oneTimePreKeyCount = oneTimePreKeyCount
    }
}

public final class DeviceLinker: Sendable {
    let net: Net
    let socket: SocketManager
    let database: SignalDatabase

    public init(net: Net, socket: SocketManager, database: SignalDatabase) {
        self.net = net
        self.socket = socket
        self.database = database
    }

    /// Runs the whole link flow. `onURL` receives the QR-code URL as soon as the
    /// server assigns a provisioning address.
    public func link(_ options: LinkOptions, onURL: @Sendable (String) async -> Void) async throws -> Account {
        let cipher = ProvisioningCipher()
        let events = ProvisioningEvents()
        let connection = try await net.connectProvisioning()
        connection.start(listener: events)
        defer { Task { try? await connection.disconnect() } }

        var message: Signalservice_ProvisionMessage?
        for try await event in events.stream {
            switch event {
            case .address(let address):
                await onURL(cipher.linkURL(address: address))
            case .envelope(let data):
                message = try cipher.decrypt(envelope: data)
            }
            if message != nil { break }
        }
        guard let message else { throw LinkError.provisioningClosed("no envelope") }
        return try await finishLink(message, options: options)
    }

    func finishLink(_ m: Signalservice_ProvisionMessage, options: LinkOptions) async throws -> Account {
        guard m.hasAciIdentityKeyPrivate, m.hasProvisioningCode, m.hasNumber else {
            throw LinkError.invalidProvisionMessage("missing identity, number or provisioning code")
        }
        let aci = try Self.aci(from: m)
        let aciIdentity = try Self.identity(privateKey: m.aciIdentityKeyPrivate)
        let pniIdentity = m.hasPniIdentityKeyPrivate && !m.pniIdentityKeyPrivate.isEmpty ? try Self.identity(privateKey: m.pniIdentityKeyPrivate) : nil
        let pni = Self.pni(from: m)

        let password = Self.newPassword()
        let aciReg = Self.registrationId()
        let pniReg = Self.registrationId()
        let aciKeys = KeyBundle.generate(identity: aciIdentity, oneTimeCount: options.oneTimePreKeyCount)
        let pniKeys = pniIdentity.map { KeyBundle.generate(identity: $0, oneTimeCount: options.oneTimePreKeyCount) }

        var attributes: [String: Any] = [
            "fetchesMessages": true,
            "registrationId": aciReg,
            "name": try DeviceNameCipher.encrypt(options.deviceName, identityPublicKey: aciIdentity.publicKey).base64EncodedString(),
            "capabilities": Self.capabilities(optionalPhoneNumber: !m.hasNumber || m.number.isEmpty),
        ]
        if pniIdentity != nil { attributes["pniRegistrationId"] = pniReg }
        var body: [String: Any] = [
            "verificationCode": m.provisioningCode,
            "accountAttributes": attributes,
            "aciSignedPreKey": aciKeys.signedJSON,
            "aciPqLastResortPreKey": aciKeys.lastResortJSON,
        ]
        if let pniKeys {
            body["pniSignedPreKey"] = pniKeys.signedJSON
            body["pniPqLastResortPreKey"] = pniKeys.lastResortJSON
        }
        let response = try await socket.unauthenticatedRequest("PUT", "/v1/devices/link", json: try JSONSerialization.data(withJSONObject: body),
                                                               basicAuth: (aci, password))
        struct LinkResponse: Decodable { var deviceId: UInt32; var uuid: String?; var pni: String? }
        let linked = try JSONDecoder().decode(LinkResponse.self, from: response)
        if let uuid = linked.uuid, uuid.lowercased() != aci { throw LinkError.unexpectedResponse("aci \(uuid)") }

        let account = Account(
            aci: aci, pni: pni ?? linked.pni?.lowercased(), number: m.number, deviceId: linked.deviceId, password: password,
            deviceName: options.deviceName, aciIdentity: aciIdentity, pniIdentity: pniIdentity,
            aciRegistrationId: aciReg, pniRegistrationId: pniIdentity == nil ? nil : pniReg,
            profileKey: m.hasProfileKey ? m.profileKey : nil, masterKey: m.hasMasterKey ? m.masterKey : nil,
            accountEntropyPool: m.hasAccountEntropyPool ? m.accountEntropyPool : nil,
            readReceipts: m.hasReadReceipts && m.readReceipts)

        // Persist account and every private key before using the new credentials.
        try await database.pool.write { db in
            try account.save(db)
            try aciKeys.store(into: account.aciStore(), db)
            if let pniKeys, let store = account.pniStore() { try pniKeys.store(into: store, db) }
        }

        await socket.setCredentials(account.credentials)
        return account
    }

    /// Uploads the one-time EC and Kyber pre-keys (`PUT /v2/keys?identity=aci|pni`).
    /// Needs the authenticated socket (SocketManager.connect) to be up.
    /// ts/util/getCapabilities.std.ts (no PIN on a linked device, so no `storage`). The server
    /// refuses (422) a new device that lacks capabilities the account's devices already have.
    static func capabilities(optionalPhoneNumber: Bool) -> [String: Bool] {
        ["attachmentBackfill": false, "spqr": true, "usernameChangeSyncMessage": true, "optionalPhoneNumber": optionalPhoneNumber]
    }

    public func uploadOneTimePreKeys(for account: Account) async throws {
        for (identity, store) in [("aci", account.aciStore()), ("pni", account.pniStore())] {
            guard let store else { continue }
            let body = try await database.pool.read { db in try KeyBundle.uploadJSON(store: store, db) }
            _ = try await socket.authenticatedRequest("PUT", "/v2/keys?identity=\(identity)", json: body)
        }
    }

    /// ACI/PNI arrive as raw 16-byte UUIDs (aciBinary/pniBinary) or, from older primaries, as strings.
    static func aci(from m: Signalservice_ProvisionMessage) throws -> String {
        if m.hasAciBinary, let u = rawUUID(m.aciBinary) { return u.uuidString.lowercased() }
        if m.hasAci, let u = UUID(uuidString: m.aci) { return u.uuidString.lowercased() }
        throw LinkError.invalidProvisionMessage("missing aci")
    }

    static func pni(from m: Signalservice_ProvisionMessage) -> String? {
        if m.hasPniBinary, let u = rawUUID(m.pniBinary) { return u.uuidString.lowercased() }
        if m.hasPni, let u = UUID(uuidString: m.pni.hasPrefix("PNI:") ? String(m.pni.dropFirst(4)) : m.pni) { return u.uuidString.lowercased() }
        return nil
    }

    static func rawUUID(_ d: Data) -> UUID? {
        guard d.count == 16 else { return nil }
        let b = Array(d)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// Desktop generateRegistrationId: `randomInt(1, 16383)`, both ends included.
    static func registrationId() -> UInt32 { UInt32.random(in: 1...16383) }

    /// Upstream `createKeyPair`: an identity is its private key; the public half is derived
    /// from it, never taken from the provisioning message's separate field.
    static func identity(privateKey bytes: Data) throws -> IdentityKeyPair {
        let privateKey = try PrivateKey(bytes)
        return IdentityKeyPair(publicKey: privateKey.publicKey, privateKey: privateKey)
    }

    /// Upstream: 16 random bytes in base64 without the two padding characters.
    static func newPassword() -> String { String(SignalCrypto.randomBytes(16).base64EncodedString().dropLast(2)) }
}

/// Freshly generated pre-keys for one identity.
struct KeyBundle: @unchecked Sendable {  // immutable libsignal record handles
    var signed: SignedPreKeyRecord
    var lastResort: KyberPreKeyRecord
    var oneTime: [PreKeyRecord]
    var oneTimeKyber: [KyberPreKeyRecord]

    static func randomId() -> UInt32 { UInt32.random(in: 1..<0xFF_FFFF) }

    static func generate(identity: IdentityKeyPair, oneTimeCount: Int) -> KeyBundle {
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        func signedRecord() -> SignedPreKeyRecord {
            let key = PrivateKey.generate()
            return try! SignedPreKeyRecord(id: randomId(), timestamp: now, privateKey: key,
                                           signature: identity.privateKey.generateSignature(message: key.publicKey.serialize()))
        }
        func kyberRecord(_ id: UInt32) -> KyberPreKeyRecord {
            let pair = KEMKeyPair.generate()
            return try! KyberPreKeyRecord(id: id, timestamp: now, keyPair: pair,
                                          signature: identity.privateKey.generateSignature(message: pair.publicKey.serialize()))
        }
        let ecStart = randomId(), kyberStart = randomId()
        return KeyBundle(
            signed: signedRecord(),
            lastResort: kyberRecord(randomId()),
            oneTime: (0..<oneTimeCount).map { i in try! PreKeyRecord(id: (ecStart &+ UInt32(i)) % 0xFF_FFFF + 1, privateKey: .generate()) },
            oneTimeKyber: (0..<oneTimeCount).map { i in kyberRecord((kyberStart &+ UInt32(i)) % 0xFF_FFFF + 1) })
    }

    var signedJSON: [String: Any] {
        ["keyId": signed.id, "publicKey": try! signed.publicKey().serialize().base64EncodedString(),
         "signature": signed.signature.base64EncodedString()]
    }
    var lastResortJSON: [String: Any] { Self.kyberJSON(lastResort) }

    static func kyberJSON(_ r: KyberPreKeyRecord) -> [String: Any] {
        ["keyId": r.id, "publicKey": try! r.publicKey().serialize().base64EncodedString(), "signature": r.signature.base64EncodedString()]
    }

    func store(into store: ProtocolStore, _ db: Database) throws {
        let ctx = DatabaseStoreContext(db)
        try store.storeSignedPreKey(signed, id: signed.id, context: ctx)
        try store.storeLastResortKyberPreKey(lastResort, id: lastResort.id, context: ctx)
        for k in oneTime { try store.storePreKey(k, id: k.id, context: ctx) }
        for k in oneTimeKyber { try store.storeKyberPreKey(k, id: k.id, context: ctx) }
    }

    /// Body for PUT /v2/keys built from the stored (not yet uploaded) one-time keys.
    static func uploadJSON(store: ProtocolStore, _ db: Database) throws -> Data {
        let ctx = DatabaseStoreContext(db)
        let ec = try store.allPreKeyIds(table: "preKeys", lastResort: nil, db).map { try store.loadPreKey(id: $0, context: ctx) }
        let kyber = try store.allPreKeyIds(table: "kyberPreKeys", lastResort: false, db).map { try store.loadKyberPreKey(id: $0, context: ctx) }
        let body: [String: Any] = [
            "preKeys": try ec.map { ["keyId": $0.id, "publicKey": try $0.publicKey().serialize().base64EncodedString()] },
            "pqPreKeys": kyber.map(kyberJSON),
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }
}

extension ProtocolStore {
    /// Key ids of this identity's rows in `table` (optionally filtered by isLastResort).
    func allPreKeyIds(table: String, lastResort: Bool?, _ db: Database) throws -> [UInt32] {
        let rows = try String.fetchAll(db, sql: "SELECT json FROM \(table) WHERE json ->> '$.ourServiceId' = ?", arguments: [ourServiceId])
        return try rows.compactMap { json in
            let row = try JSONDecoder().decode(KeyRow.self, from: Data(json.utf8))
            if let lastResort, (row.isLastResort ?? false) != lastResort { return nil }
            return row.keyId
        }.sorted()
    }
}

/// Bridges libsignal's provisioning callbacks to an async stream.
final class ProvisioningEvents: ProvisioningConnectionListener, Sendable {
    enum Event { case address(String), envelope(Data) }
    let stream: AsyncThrowingStream<Event, Error>
    let continuation: AsyncThrowingStream<Event, Error>.Continuation

    init() { (stream, continuation) = AsyncThrowingStream.makeStream() }

    func provisioningConnection(_ connection: ProvisioningConnection, didReceiveAddress address: String, sendAck: @escaping () throws -> Void) {
        try? sendAck()
        continuation.yield(.address(address))
    }

    func provisioningConnection(_ connection: ProvisioningConnection, didReceiveEnvelope envelope: Data, sendAck: @escaping () throws -> Void) {
        continuation.yield(.envelope(envelope))
        try? sendAck()
    }

    func connectionWasInterrupted(_ service: ProvisioningConnection, error: Error?) {
        if let error { continuation.finish(throwing: LinkError.provisioningClosed("\(error)")) } else { continuation.finish() }
    }
}
