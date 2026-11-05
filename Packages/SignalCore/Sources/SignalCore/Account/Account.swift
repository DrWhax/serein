// The linked account, persisted in `items` under the upstream keys
// (ts/types/StorageKeys.std.ts): uuid_id, pni, number_id, password, device_name,
// identityKeyMap, registrationIdMap, profileKey, masterKey, accountEntropyPool, read-receipt-setting.

import Foundation
import GRDB
import LibSignalClient

public struct Account: Sendable {
    public var aci: String              // untagged UUID string (lowercase)
    public var pni: String?             // untagged UUID string (lowercase)
    public var number: String
    public var deviceId: UInt32
    public var password: String
    public var deviceName: String
    public var aciIdentity: IdentityKeyPair
    public var pniIdentity: IdentityKeyPair?
    public var aciRegistrationId: UInt32
    public var pniRegistrationId: UInt32?
    public var profileKey: Data?
    public var masterKey: Data?
    public var accountEntropyPool: String?
    public var readReceipts: Bool

    /// The PNI as a tagged service-id string ("PNI:<uuid>"), as upstream stores it.
    public var pniServiceId: String? { pni.map { "PNI:\($0)" } }
    public var credentials: ChatCredentials { ChatCredentials(username: "\(aci).\(deviceId)", password: password) }

    public func aciStore() -> ProtocolStore {
        ProtocolStore(ourServiceId: aci, identity: aciIdentity, registrationId: aciRegistrationId)
    }
    public func pniStore() -> ProtocolStore? {
        guard let p = pniServiceId, let id = pniIdentity, let reg = pniRegistrationId else { return nil }
        return ProtocolStore(ourServiceId: p, identity: id, registrationId: reg)
    }

    struct KeyPairJSON: Codable { var pubKey: String; var privKey: String }

    public func save(_ db: Database) throws {
        try Items.set(db, "uuid_id", "\(aci).\(deviceId)")
        if let pniServiceId { try Items.set(db, "pni", pniServiceId) }
        try Items.set(db, "number_id", "\(number).\(deviceId)")
        try Items.set(db, "password", password)
        try Items.set(db, "device_name", deviceName)
        var identities = [aci: KeyPairJSON(aciIdentity)]
        var registrations = [aci: aciRegistrationId]
        if let pniServiceId, let pniIdentity, let pniRegistrationId {
            identities[pniServiceId] = KeyPairJSON(pniIdentity)
            registrations[pniServiceId] = pniRegistrationId
        }
        try Items.set(db, "identityKeyMap", identities)
        try Items.set(db, "registrationIdMap", registrations)
        if let profileKey { try Items.set(db, "profileKey", profileKey.base64EncodedString()) }
        if let masterKey { try Items.set(db, "masterKey", masterKey.base64EncodedString()) }
        if let accountEntropyPool { try Items.set(db, "accountEntropyPool", accountEntropyPool) }
        try Items.set(db, "read-receipt-setting", readReceipts)
    }

    public static func load(_ db: Database) throws -> Account? {
        guard let uuidId: String = try Items.get(db, "uuid_id"),
              let dot = uuidId.lastIndex(of: "."), let deviceId = UInt32(uuidId[uuidId.index(after: dot)...]),
              let password: String = try Items.get(db, "password"),
              let identities: [String: KeyPairJSON] = try Items.get(db, "identityKeyMap"),
              let registrations: [String: UInt32] = try Items.get(db, "registrationIdMap")
        else { return nil }
        let aci = String(uuidId[..<dot])
        guard let aciKeys = identities[aci], let aciReg = registrations[aci] else { return nil }
        let pniServiceId: String? = try Items.get(db, "pni")
        let numberId: String = try Items.get(db, "number_id") ?? ""
        return Account(
            aci: aci,
            pni: pniServiceId.map { $0.hasPrefix("PNI:") ? String($0.dropFirst(4)) : $0 },
            number: numberId.split(separator: ".").first.map(String.init) ?? "",
            deviceId: deviceId,
            password: password,
            deviceName: try Items.get(db, "device_name") ?? "",
            aciIdentity: try aciKeys.keyPair(),
            pniIdentity: try pniServiceId.flatMap { identities[$0] }?.keyPair(),
            aciRegistrationId: aciReg,
            pniRegistrationId: pniServiceId.flatMap { registrations[$0] },
            profileKey: (try Items.get(db, "profileKey", as: String.self)).flatMap { Data(base64Encoded: $0) },
            masterKey: (try Items.get(db, "masterKey", as: String.self)).flatMap { Data(base64Encoded: $0) },
            accountEntropyPool: try Items.get(db, "accountEntropyPool"),
            readReceipts: try Items.get(db, "read-receipt-setting") ?? false)
    }
}

extension Account.KeyPairJSON {
    init(_ pair: IdentityKeyPair) {
        pubKey = pair.publicKey.serialize().base64EncodedString()
        privKey = pair.privateKey.serialize().base64EncodedString()
    }
    func keyPair() throws -> IdentityKeyPair {
        guard let pub = Data(base64Encoded: pubKey), let priv = Data(base64Encoded: privKey) else {
            throw ProtocolStoreError.missing("identity key encoding")
        }
        return IdentityKeyPair(publicKey: try PublicKey(pub), privateKey: try PrivateKey(priv))
    }
}
