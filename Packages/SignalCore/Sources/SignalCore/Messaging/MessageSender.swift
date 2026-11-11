// 1:1 send pipeline (port of Desktop OutgoingMessage.preload.ts + getKeysForServiceId):
//
//   Content ─► pad ─► for each device with a session { signalEncrypt ─► sealedSenderEncrypt? }
//           ─► PUT v1/messages/<serviceId>   (sealed: unauthenticated socket + Unidentified-Access-Key)
//   409 mismatched devices: archive sessions of extra devices, fetch pre-key bundles of missing ones, retry
//   410 stale devices:      archive their sessions, fetch fresh bundles, retry
//   401 on a sealed send:   retry unsealed (authenticated)
//   no sessions at all:     fetch v2/keys/<serviceId>/* and process every bundle
//   untrusted identity:     (key changed and not approved, or marked unverified) nothing is sent;
//                           the key goes on record with its notice, SendError.untrustedIdentities
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
    /// The identity keys of these recipients are not trusted for sending: changed and not yet
    /// approved, or marked unverified (upstream OutgoingIdentityKeyError). Nothing was sent to
    /// them; `Messenger.approveIdentities` followed by a retry sends it.
    case untrustedIdentities([String])
    /// Our own signed pre-key or last-resort key is more than two weeks old and could not be
    /// replaced (upstream "Keys still out of date after update").
    case keysOutOfDate
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
    /// A story or story reply: sent sealed with `story=true`, which needs no access key.
    public var story: Bool
    /// A serialized PlaintextContent to send *instead of* encrypting `content`: only a retry
    /// request (DecryptionErrorMessage) goes out this way, when the session may be the problem.
    public var plaintextContent: Data?
    /// The group the message belongs to (sealed sender's group id), if any.
    public var groupId = Data()

    public init(content: Signalservice_Content, timestamp: UInt64, contentHint: ContentHint = .resendable, urgent: Bool = true, online: Bool = false,
                story: Bool = false) {
        self.story = story
        self.content = content
        self.timestamp = timestamp
        self.contentHint = contentHint
        self.urgent = urgent
        self.online = online
    }

    /// A delete for everyone, its transcript, or our phone's recipient update after one: it
    /// follows the removal of the messages it names and carries none of their content, so it is
    /// still sent once they are gone (deleting a story removes it here first, then sends the
    /// deletes). Nothing else qualifies: a delete that also carries a body, attachments or any
    /// other field does not.
    var onlyRetracts: Bool {
        switch content.content {
        case .dataMessage(let m)?: return Self.onlyDeletes(m)
        case .syncMessage(let sync)?:
            guard case .sent(let sent)? = sync.content, !sent.hasStoryMessage, !sent.hasEditMessage else { return false }
            return sent.hasMessage ? Self.onlyDeletes(sent.message) : sent.isRecipientUpdate
        default: return false
        }
    }

    /// A DataMessage that only deletes: a delete (or an admin delete) and the fields every
    /// message has (timestamp, profile key, group context), and nothing else.
    static func onlyDeletes(_ m: Signalservice_DataMessage) -> Bool {
        guard m.hasDelete || m.hasAdminDelete else { return false }
        var bare = Signalservice_DataMessage()
        if m.hasTimestamp { bare.timestamp = m.timestamp }
        if m.hasProfileKey { bare.profileKey = m.profileKey }
        if m.hasGroupV2 { bare.groupV2 = m.groupV2 }
        if m.hasDelete { bare.delete = m.delete }
        if m.hasAdminDelete { bare.adminDelete = m.adminDelete }
        return bare == m
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

    /// Whether we blocked this contact, by service id or by number.
    static func isBlocked(_ db: Database, serviceId: String) throws -> Bool {
        if try BlockedList.serviceIds.blockedAt(db, serviceId).blocked { return true }
        let number = try String.fetchOne(db, sql: "SELECT e164 FROM conversations WHERE serviceId = ?", arguments: [serviceId])
        return try number.map { try BlockedList.numbers.blockedAt(db, $0).blocked } ?? false
    }

    /// Re-evaluated after connection setup, immediately before transport submission.
    /// Blocking a contact does not block shared group conversations; those have their own block state.
    /// `messageIds` must still exist, unerased, unless the payload only retracts them.
    func authorization(to serviceId: String?, groupId: Data, messageIds: [String], retracting: Bool = false) -> @Sendable () throws -> Void {
        { [database, account] in
            try database.pool.read { db in
                if !groupId.isEmpty {
                    if try BlockedList.groups.blockedAt(db, groupId.base64EncodedString()).blocked {
                        throw JobError.permanent("group blocked")
                    }
                } else if let serviceId, serviceId != account.aci {
                    if try Self.isBlocked(db, serviceId: serviceId) { throw JobError.permanent("recipient blocked") }
                }
                for id in messageIds where !retracting {
                    guard let json = try String.fetchOne(db, sql: "SELECT json FROM messages WHERE id = ?", arguments: [id]),
                          try MessageStore.jsonObject(json)["isErased"] as? Bool != true else {
                        throw JobError.permanent("message removed")
                    }
                }
            }
        }
    }

    // MARK: send

    /// Sends `payload` to every device of `serviceId` (for our own ACI: every other device).
    /// Sealed sender is used when the recipient's access key is known, unless `sealed` is false.
    @discardableResult
    public func send(_ payload: OutgoingPayload, to serviceId: String, sealed allowSealed: Bool = true, messageIds: [String] = [],
                     logged: Bool = true) async throws -> SendResult {
        let authorize = authorization(to: serviceId, groupId: payload.groupId, messageIds: messageIds, retracting: payload.onlyRetracts)
        try authorize()
        try await PreKeyMaintenance(account: account, database: database, socket: socket).ensureKeysCurrent()
        let isSelf = serviceId == account.aci
        var accessKey: Data? = nil
        let storySend = payload.story && !isSelf
        if allowSealed && !isSelf && !storySend { accessKey = try await database.pool.read { db in try Self.accessKey(db, serviceId: serviceId) } }
        var certificate: SenderCertificate? = accessKey == nil && !storySend ? nil : try await certificates.current()
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
            let encrypted: [DeviceMessage]? = try await database.pool.write { db in
                do {
                    return try self.encrypt(db, padded, for: serviceId, devices: targets, certificate: cert, contentHint: payload.contentHint,
                                            plaintextContent: payload.plaintextContent, groupId: payload.groupId)
                } catch SignalError.untrustedIdentity {
                    // Upstream OutgoingMessage: close every session with them, fail the send.
                    try ProtocolStore.archiveSessions(db, serviceId: serviceId)
                    return nil
                }
            }
            guard let messages = encrypted else { throw SendError.untrustedIdentities([serviceId]) }
            let json = try JSONEncoder().encode(MessageList(messages: messages, timestamp: payload.timestamp,
                                                            online: payload.online && !isSelf, urgent: payload.urgent))
            let path = "/v1/messages/\(serviceId)" + (storySend ? "?story=true" : "")
            do {
                if storySend {
                    _ = try await socket.unauthenticatedRequest("PUT", path, json: json, headers: [:], authorize: authorize)
                } else if let accessKey {
                    _ = try await socket.unauthenticatedRequest("PUT", path, json: json,
                                                                headers: ["unidentified-access-key": accessKey.base64EncodedString()], authorize: authorize)
                } else {
                    _ = try await socket.authenticatedRequest("PUT", path, json: json, authorize: authorize)
                }
                let sent = devices
                if logged {
                    _ = try await database.pool.write { db in
                        try SendLog.record(db, timestamp: payload.timestamp, contentHint: payload.contentHint.rawValue, proto: proto, urgent: payload.urgent,
                                           recipient: serviceId, devices: sent, messageIds: messageIds)
                    }
                }
                return SendResult(serviceId: serviceId, devices: devices, sealed: accessKey != nil || storySend)
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
                 contentHint: ContentHint, plaintextContent: Data? = nil, groupId: Data = Data()) throws -> [DeviceMessage] {
        let ctx = DatabaseStoreContext(db)
        let store = self.store
        let local = try ProtocolAddress(name: account.aci, deviceId: account.deviceId)
        return try devices.map { device in
            let address = try ProtocolAddress(name: serviceId, deviceId: device)
            guard let session = try store.loadSession(for: address, context: ctx) else { throw ProtocolStoreError.missing("session \(address)") }
            let registrationId = try session.remoteRegistrationId()
            let message = try plaintextContent.map { try CiphertextMessage(PlaintextContent(bytes: $0)) }
                ?? signalEncrypt(message: padded, for: address, localAddress: local, sessionStore: store, identityStore: store, context: ctx)
            let type: Int
            let content: Data
            if let certificate {
                let usmc = try UnidentifiedSenderMessageContent(message, from: certificate, contentHint: contentHint, groupId: groupId)
                content = try sealedSenderEncrypt(usmc, for: address, identityStore: store, context: ctx)
                type = Signalservice_Envelope.TypeEnum.unidentifiedSender.rawValue
            } else {
                content = message.serialize()
                type = message.messageType == .preKey ? Signalservice_Envelope.TypeEnum.prekeyMessage.rawValue
                    : message.messageType == .plaintext ? Signalservice_Envelope.TypeEnum.plaintextContent.rawValue
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
        let trusted = try await database.pool.write { db in try self.process(db, keys, serviceId: serviceId) }
        if !trusted { throw SendError.untrustedIdentities([serviceId]) }
    }

    /// Starts a session per device from the pre-key bundles. Returns false, with no session
    /// started, when the identity key they come with is not trusted for sending. In that
    /// case the key is put on record the way upstream's follow-up profile fetch does
    /// (`updateIdentityKey`): a changed key raises the notice and waits for approval.
    func process(_ db: Database, _ keys: KeysResponse, serviceId: String) throws -> Bool {
        func bytes(_ s: String) throws -> Data {
            guard let d = Data(lenientBase64: s) else { throw SendError.invalidKeysResponse("base64") }
            return d
        }
        let ctx = DatabaseStoreContext(db)
        let store = self.store
        let identity = try IdentityKey(bytes: try bytes(keys.identityKey))
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
            do {
                try processPreKeyBundle(bundle, for: try ProtocolAddress(name: serviceId, deviceId: d.deviceId), ourAddress: local,
                                        sessionStore: store, identityStore: store, context: ctx)
            } catch SignalError.untrustedIdentity {
                try store.updateIdentityKey(db, identity, serviceId: serviceId)
                return false
            }
        }
        return true
    }

    // MARK: helpers

    /// The unidentified-delivery access key to try for a recipient (upstream getSendOptions):
    /// none when they have sealed sender disabled; the all-zero key when they accept it from
    /// anyone; otherwise the key derived from their profile key, or, while we know neither
    /// their mode nor their profile key, the all-zero key, which the server accepts only for
    /// an unrestricted recipient (a 401 falls back to an authenticated send).
    static func accessKey(_ db: Database, serviceId: String) throws -> Data? {
        guard let json = try String.fetchOne(db, sql: "SELECT json FROM conversations WHERE serviceId = ? AND type = 'private'", arguments: [serviceId]) else {
            return nil
        }
        let c = try MessageStore.jsonObject(json)
        let mode = c["sealedSender"] as? Int ?? SealedSenderMode.unknown.rawValue
        if mode == SealedSenderMode.disabled.rawValue { return nil }
        if mode == SealedSenderMode.unrestricted.rawValue { return zeroAccessKey }
        guard let b64 = c["profileKey"] as? String, let key = Data(base64Encoded: b64), key.count == 32 else { return zeroAccessKey }
        return try ProfileKey(contents: key).deriveAccessKey()
    }

    /// The access key derived from the contact's profile key, when we have it (the only key
    /// that says anything about the contact; used for key-transparency lookups).
    static func derivedAccessKey(_ db: Database, serviceId: String) throws -> Data? {
        guard let json = try String.fetchOne(db, sql: "SELECT json FROM conversations WHERE serviceId = ? AND type = 'private'", arguments: [serviceId]),
              let b64 = try MessageStore.jsonObject(json)["profileKey"] as? String, let key = Data(base64Encoded: b64), key.count == 32 else { return nil }
        return try ProfileKey(contents: key).deriveAccessKey()
    }

    /// Upstream ZERO_ACCESS_KEY.
    static let zeroAccessKey = Data(count: 16)

    /// Desktop padMessage: plaintext ‖ 0x80 ‖ 0x00…, total length (n + 2) rounded up to a
    /// multiple of 80 (upstream PADDING_BLOCK), minus 1.
    static let paddingBlock = 80
    static func pad(_ plaintext: Data) -> Data {
        let withTerminator = plaintext.count + 2
        let paddedLength = ((withTerminator + paddingBlock - 1) / paddingBlock) * paddingBlock - 1
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

extension Data {
    /// Base64 with or without padding: the server's key adapters may omit it (upstream's
    /// Bytes.fromBase64 accepts both).
    init?(lenientBase64 s: String) {
        self.init(base64Encoded: s + String(repeating: "=", count: (4 - s.count % 4) % 4))
    }
}
