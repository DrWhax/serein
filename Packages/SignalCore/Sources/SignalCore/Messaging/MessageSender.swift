// 1:1 send pipeline (port of Desktop OutgoingMessage.preload.ts + getKeysForServiceId):
//
//   Content ─► pad ─► for each device with a session { signalEncrypt ─► sealedSenderEncrypt? }
//           ─► PUT v1/messages/<serviceId>   (sealed: unauthenticated socket + Unidentified-Access-Key)
//   409 mismatched devices: archive sessions of extra devices, fetch pre-key bundles of missing ones, retry
//   410 stale devices:      archive their sessions, fetch fresh bundles, retry
//   401 on a sealed send:   retry unsealed (authenticated)
//   no sessions at all:     fetch v2/keys/<serviceId>/* and process every bundle
//
// Encryption of all devices runs in one write transaction (session state advances
// atomically). Successful sends are recorded in the send log.

import Foundation
import GRDB
import LibSignalClient
import SignalProtos
import SwiftProtobuf

public enum SendError: Error, Equatable {
    case unregistered(String)
    case untrustedIdentity(String)
    case deviceMismatchUnresolved(String)
    case invalidKeysResponse(String)
}

public typealias ContentHint = UnidentifiedSenderMessageContent.ContentHint

public struct OutgoingPayload: Sendable {
    public var content: Signalservice_Content
    public var timestamp: UInt64
    public var contentHint: ContentHint
    public var urgent: Bool
    public var online: Bool

    public init(content: Signalservice_Content, timestamp: UInt64, contentHint: ContentHint = .resendable, urgent: Bool = true, online: Bool = false) {
        self.content = content
        self.timestamp = timestamp
        self.contentHint = contentHint
        self.urgent = urgent
        self.online = online
    }
}

public struct SendResult: Sendable, Equatable {
    public var serviceId: String
    public var devices: [UInt32]
    public var sealed: Bool
}

public final class MessageSender: Sendable {
    let account: Account
    let database: SignalDatabase
    let socket: SocketManager
    public let certificates: SenderCertificates
    let maxAttempts = 4

    public init(account: Account, database: SignalDatabase, socket: SocketManager, trustRoots: [PublicKey]) {
        self.account = account
        self.database = database
        self.socket = socket
        certificates = SenderCertificates(account: account, database: database, socket: socket, trustRoots: trustRoots)
    }

    var store: ProtocolStore { account.aciStore() }

    // MARK: send

    /// Sends `payload` to every device of `serviceId` (for our own ACI: every other device).
    /// Sealed sender is used when the recipient's access key is known, unless `sealed` is false.
    @discardableResult
    public func send(_ payload: OutgoingPayload, to serviceId: String, sealed allowSealed: Bool = true, messageIds: [String] = [],
                     logged: Bool = true) async throws -> SendResult {
        let isSelf = serviceId == account.aci
        var accessKey: Data? = nil
        if allowSealed && !isSelf { accessKey = try await database.pool.read { db in try Self.accessKey(db, serviceId: serviceId) } }
        var certificate: SenderCertificate? = accessKey == nil ? nil : try await certificates.current()
        let proto = try payload.content.serializedBytes() as Data
        let padded = Self.pad(proto)

        var fetchedAll = false
        for _ in 0..<maxAttempts {
            var devices = try await database.pool.read { db in try self.activeDevices(db, serviceId: serviceId) }
            if devices.isEmpty && !fetchedAll {
                fetchedAll = true
                try await fetchKeys(serviceId, deviceId: nil)
                devices = try await database.pool.read { db in try self.activeDevices(db, serviceId: serviceId) }
            }
            if devices.isEmpty && isSelf { return SendResult(serviceId: serviceId, devices: [], sealed: false) }

            let cert = certificate
            let targets = devices
            let messages = try await database.pool.write { db in
                try self.encrypt(db, padded, for: serviceId, devices: targets, certificate: cert, contentHint: payload.contentHint)
            }
            let json = try JSONEncoder().encode(MessageList(messages: messages, timestamp: payload.timestamp,
                                                            online: payload.online && !isSelf, urgent: payload.urgent))
            let path = "/v1/messages/\(serviceId)"
            do {
                if let accessKey {
                    _ = try await socket.unauthenticatedRequest("PUT", path, json: json,
                                                                headers: ["unidentified-access-key": accessKey.base64EncodedString()])
                } else {
                    _ = try await socket.authenticatedRequest("PUT", path, json: json)
                }
                let sent = devices
                if logged {
                    _ = try await database.pool.write { db in
                        try SendLog.record(db, timestamp: payload.timestamp, contentHint: payload.contentHint.rawValue, proto: proto, urgent: payload.urgent,
                                           recipient: serviceId, devices: sent, messageIds: messageIds)
                    }
                }
                return SendResult(serviceId: serviceId, devices: devices, sealed: accessKey != nil)
            } catch let error as ChatRequestError {
                switch (error.status, error) {
                case (409, .http(_, _, let b)):
                    struct Mismatch: Decodable { var missingDevices: [UInt32]?; var extraDevices: [UInt32]? }
                    let m = try JSONDecoder().decode(Mismatch.self, from: b)
                    try await database.pool.write { db in try self.archive(db, serviceId: serviceId, devices: m.extraDevices ?? []) }
                    for d in m.missingDevices ?? [] { try await fetchKeys(serviceId, deviceId: d) }
                case (410, .http(_, _, let b)):
                    struct Stale: Decodable { var staleDevices: [UInt32]? }
                    let stale = try JSONDecoder().decode(Stale.self, from: b).staleDevices ?? []
                    try await database.pool.write { db in try self.archive(db, serviceId: serviceId, devices: stale) }
                    for d in stale { try await fetchKeys(serviceId, deviceId: d) }
                case (401, _) where accessKey != nil:
                    // Wrong or outdated access key: fall back to an authenticated (unsealed) send.
                    accessKey = nil
                    certificate = nil
                case (404, _):
                    throw SendError.unregistered(serviceId)
                default:
                    throw error
                }
            }
        }
        throw SendError.deviceMismatchUnresolved(serviceId)
    }

    // MARK: sessions

    /// Devices of `serviceId` with a usable session (never our own device).
    func activeDevices(_ db: Database, serviceId: String) throws -> [UInt32] {
        let rows = try Row.fetchAll(db, sql: "SELECT deviceId, record FROM sessions WHERE ourServiceId = ? AND serviceId = ? ORDER BY deviceId",
                                    arguments: [account.aci, serviceId])
        return try rows.compactMap { row in
            let device = UInt32(row["deviceId"] as Int)
            if serviceId == account.aci && device == account.deviceId { return nil }
            return try SessionRecord(bytes: row["record"] as Data).hasCurrentState ? device : nil
        }
    }

    func archive(_ db: Database, serviceId: String, devices: [UInt32]) throws {
        let ctx = DatabaseStoreContext(db)
        for d in devices {
            let address = try ProtocolAddress(name: serviceId, deviceId: d)
            guard let session = try store.loadSession(for: address, context: ctx) else { continue }
            session.archiveCurrentState()
            try store.storeSession(session, for: address, context: ctx)
        }
    }

    func encrypt(_ db: Database, _ padded: Data, for serviceId: String, devices: [UInt32], certificate: SenderCertificate?,
                 contentHint: ContentHint) throws -> [DeviceMessage] {
        let ctx = DatabaseStoreContext(db)
        let store = self.store
        let local = try ProtocolAddress(name: account.aci, deviceId: account.deviceId)
        return try devices.map { device in
            let address = try ProtocolAddress(name: serviceId, deviceId: device)
            guard let session = try store.loadSession(for: address, context: ctx) else { throw ProtocolStoreError.missing("session \(address)") }
            let registrationId = try session.remoteRegistrationId()
            let message = try signalEncrypt(message: padded, for: address, localAddress: local, sessionStore: store, identityStore: store, context: ctx)
            let type: Int
            let content: Data
            if let certificate {
                let usmc = try UnidentifiedSenderMessageContent(message, from: certificate, contentHint: contentHint, groupId: Data())
                content = try sealedSenderEncrypt(usmc, for: address, identityStore: store, context: ctx)
                type = Signalservice_Envelope.TypeEnum.unidentifiedSender.rawValue
            } else {
                content = message.serialize()
                type = message.messageType == .preKey ? Signalservice_Envelope.TypeEnum.prekeyMessage.rawValue
                    : Signalservice_Envelope.TypeEnum.doubleRatchet.rawValue
            }
            return DeviceMessage(type: type, destinationDeviceId: device, destinationRegistrationId: registrationId, content: content.base64EncodedString())
        }
    }

    /// PUT v1/messages body (upstream OutgoingMessage.getMessageList / server IncomingMessageList).
    struct DeviceMessage: Encodable, Sendable {
        var type: Int
        var destinationDeviceId: UInt32
        var destinationRegistrationId: UInt32
        var content: String
    }
    struct MessageList: Encodable {
        var messages: [DeviceMessage]
        var timestamp: UInt64
        var online: Bool
        var urgent: Bool
    }

    // MARK: pre-key bundles

    struct KeysResponse: Decodable {
        struct Signed: Decodable { var keyId: UInt32; var publicKey: String; var signature: String }
        struct OneTime: Decodable { var keyId: UInt32; var publicKey: String }
        struct Device: Decodable {
            var deviceId: UInt32
            var registrationId: UInt32
            var signedPreKey: Signed
            var pqPreKey: Signed
            var preKey: OneTime?
        }
        var identityKey: String
        var devices: [Device]
    }

    /// Fetches pre-key bundles (one device, or all with `deviceId == nil`) and starts sessions.
    func fetchKeys(_ serviceId: String, deviceId: UInt32?) async throws {
        let body: Data
        do {
            body = try await socket.authenticatedRequest("GET", "/v2/keys/\(serviceId)/\(deviceId.map(String.init) ?? "*")")
        } catch let e as ChatRequestError where e.status == 404 {
            if deviceId != nil { return }   // device went away: the next attempt reports it as extra
            throw SendError.unregistered(serviceId)
        }
        let keys = try JSONDecoder().decode(KeysResponse.self, from: body)
        try await database.pool.write { db in try self.process(db, keys, serviceId: serviceId) }
    }

    func process(_ db: Database, _ keys: KeysResponse, serviceId: String) throws {
        func bytes(_ s: String) throws -> Data {
            guard let d = Data(base64Encoded: s) else { throw SendError.invalidKeysResponse("base64") }
            return d
        }
        let ctx = DatabaseStoreContext(db)
        let store = self.store
        let identity = try IdentityKey(bytes: try bytes(keys.identityKey))
        try acceptIdentity(db, identity, serviceId: serviceId)
        let local = try ProtocolAddress(name: account.aci, deviceId: account.deviceId)
        for d in keys.devices {
            if serviceId == account.aci && d.deviceId == account.deviceId { continue }
            let bundle: PreKeyBundle
            if let pre = d.preKey {
                bundle = try PreKeyBundle(registrationId: d.registrationId, deviceId: d.deviceId, prekeyId: pre.keyId, prekey: try PublicKey(try bytes(pre.publicKey)),
                                          signedPrekeyId: d.signedPreKey.keyId, signedPrekey: try PublicKey(try bytes(d.signedPreKey.publicKey)),
                                          signedPrekeySignature: try bytes(d.signedPreKey.signature), identity: identity,
                                          kyberPrekeyId: d.pqPreKey.keyId, kyberPrekey: try KEMPublicKey(try bytes(d.pqPreKey.publicKey)),
                                          kyberPrekeySignature: try bytes(d.pqPreKey.signature))
            } else {
                bundle = try PreKeyBundle(registrationId: d.registrationId, deviceId: d.deviceId,
                                          signedPrekeyId: d.signedPreKey.keyId, signedPrekey: try PublicKey(try bytes(d.signedPreKey.publicKey)),
                                          signedPrekeySignature: try bytes(d.signedPreKey.signature), identity: identity,
                                          kyberPrekeyId: d.pqPreKey.keyId, kyberPrekey: try KEMPublicKey(try bytes(d.pqPreKey.publicKey)),
                                          kyberPrekeySignature: try bytes(d.pqPreKey.signature))
            }
            try processPreKeyBundle(bundle, for: try ProtocolAddress(name: serviceId, deviceId: d.deviceId), ourAddress: local,
                                    sessionStore: store, identityStore: store, context: ctx)
        }
    }

    /// Desktop behaviour for a changed identity key: a contact whose safety number was
    /// marked verified blocks sending (the user must re-verify); otherwise the new key is
    /// accepted, sessions with the old identity are archived and a "keychange"
    /// notification is added to the conversation.
    func acceptIdentity(_ db: Database, _ identity: IdentityKey, serviceId: String) throws {
        let ctx = DatabaseStoreContext(db)
        let address = try ProtocolAddress(name: serviceId, deviceId: 1)
        guard let existing = try store.identity(for: address, context: ctx), existing != identity else { return }
        if try ProtocolStore.verifiedStatus(db, serviceId: serviceId) == .verified { throw SendError.untrustedIdentity(serviceId) }
        _ = try store.saveIdentity(identity, for: address, context: ctx)
        let devices = try Int.fetchAll(db, sql: "SELECT deviceId FROM sessions WHERE ourServiceId = ? AND serviceId = ?", arguments: [account.aci, serviceId])
        try archive(db, serviceId: serviceId, devices: devices.map { UInt32($0) })
        if serviceId != account.aci { try MessageStore.insertKeyChange(db, serviceId: serviceId) }
    }

    // MARK: helpers

    /// Unidentified-delivery access key for a recipient (Desktop getAccessKey): derived
    /// from their profile key; random when they allow unrestricted access; none when
    /// sealed sender is disabled for them or their profile key is unknown.
    static func accessKey(_ db: Database, serviceId: String) throws -> Data? {
        guard let json = try String.fetchOne(db, sql: "SELECT json FROM conversations WHERE serviceId = ? AND type = 'private'", arguments: [serviceId]) else {
            return nil
        }
        let c = try MessageStore.jsonObject(json)
        let mode = c["sealedSender"] as? Int ?? SealedSenderMode.unknown.rawValue
        if mode == SealedSenderMode.disabled.rawValue { return nil }
        if mode == SealedSenderMode.unrestricted.rawValue { return SignalCrypto.randomBytes(16) }
        guard let b64 = c["profileKey"] as? String, let key = Data(base64Encoded: b64), key.count == 32 else { return nil }
        return try ProfileKey(contents: key).deriveAccessKey()
    }

    /// Desktop padMessage: plaintext ‖ 0x80 ‖ 0x00…, total length (n + 2) rounded up to 160 minus 1.
    static func pad(_ plaintext: Data) -> Data {
        let withTerminator = plaintext.count + 2
        let paddedLength = ((withTerminator + 159) / 160) * 160 - 1
        var out = plaintext
        out.append(0x80)
        out.append(contentsOf: repeatElement(0, count: paddedLength - out.count))
        return out
    }
}

/// Upstream SEALED_SENDER (ts/types/SealedSender.std.ts).
public enum SealedSenderMode: Int, Sendable {
    case unknown = 0, enabled = 1, disabled = 2, unrestricted = 3
}
