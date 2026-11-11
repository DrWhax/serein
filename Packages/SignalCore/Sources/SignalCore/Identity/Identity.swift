// Phase 4 step 6c: safety numbers (ts/util/safetyNumber.preload.ts + setVerified and the
// Verified sync), usernames (ts/services/username.preload.ts over libsignal's typed
// Accounts/Usernames services), and key transparency (ts/services/keyTransparency.preload.ts
// over `UnauthenticatedChatConnection.keyTransparencyClient`).

import Foundation
import GRDB
import LibSignalClient
import SignalProtos

// MARK: socket entry points

extension SocketManager {
    func authenticatedChat() throws -> AuthenticatedChatConnection {
        guard let chat = authenticated else { throw ChatRequestError.notConnected }
        return chat
    }

    public func reserveUsernameHashes(_ hashes: [Data]) async throws -> Data { try await authenticatedChat().reserveUsernameHashes(hashes) }
    public func confirmUsername(_ username: Username, usernameCiphertext: Data) async throws -> UUID {
        try await authenticatedChat().confirmUsername(username, usernameCiphertext: usernameCiphertext)
    }
    public func deleteUsernameHash() async throws { try await authenticatedChat().deleteUsernameHash() }
    public func setUsernameLink(_ ciphertext: Data, keepLinkHandle: Bool) async throws -> UUID {
        try await authenticatedChat().setUsernameLink(usernameCiphertext: ciphertext, keepLinkHandle: keepLinkHandle)
    }
    public func lookUpUsernameHash(_ hash: Data) async throws -> Aci? { try await unauthenticatedConnection().lookUpUsernameHash(hash) }
    public func lookUpUsernameLink(_ handle: UUID, entropy: Data) async throws -> Username? {
        try await unauthenticatedConnection().lookUpUsernameLink(handle, entropy: entropy)
    }
    /// `isSelf` nil = a contact check; otherwise a self check (with discoverability).
    func keyTransparencyCheck(isSelf discoverable: Bool?, aci: String, identityKey: Data, e164: String?, accessKey: Data?, usernameHash: Data?,
                              store: KeyTransparencyStore) async throws {
        let mode: KeyTransparency.CheckMode = discoverable.map { .self(isE164Discoverable: $0) } ?? .contact
        let info = KeyTransparency.AciInfo(aci: try Aci.parseFrom(serviceIdString: aci), identityKey: try IdentityKey(bytes: identityKey))
        let e164Info = e164.flatMap { n in accessKey.map { KeyTransparency.E164Info(e164: n, unidentifiedAccessKey: $0) } }
        try await unauthenticatedConnection().keyTransparencyClient.check(for: mode, account: info, e164: e164Info, usernameHash: usernameHash, store: store)
    }
}

// MARK: safety numbers

public struct SafetyNumber: Sendable, Equatable {
    /// The exact identity used to generate the displayed fingerprint.
    public let identity: ReviewedIdentity
    /// 12 blocks of 5 digits.
    public var numberBlocks: [String]
    /// The QR payload (scannable fingerprint).
    public var qrData: Data
}

public enum SafetyNumbers {
    static let iterations = 5200
    static let serviceIdVersion = 2
    static let blockSize = 5

    static func fingerprint(ourAci: String, ourKey: PublicKey, theirAci: String, theirKey: PublicKey) throws -> Fingerprint {
        guard let us = StorageLocal.uuidBytes(ourAci), let them = StorageLocal.uuidBytes(theirAci) else { throw ModifierError.notFound }
        return try NumericFingerprintGenerator(iterations: iterations).create(version: serviceIdVersion, localIdentifier: us, localKey: ourKey,
                                                                             remoteIdentifier: them, remoteKey: theirKey)
    }

    /// `generateSafetyNumber`: ours and theirs, by ACI (version 2).
    public static func generate(ourAci: String, ourKey: PublicKey, theirAci: String, theirKey: PublicKey) throws -> SafetyNumber {
        let f = try fingerprint(ourAci: ourAci, ourKey: ourKey, theirAci: theirAci, theirKey: theirKey)
        let digits = Array(f.displayable.formatted)
        let blocks = stride(from: 0, to: digits.count, by: blockSize).map { String(digits[$0..<min($0 + blockSize, digits.count)]) }
        return SafetyNumber(identity: ReviewedIdentity(ourServiceId: ourAci, ourKey: ourKey.serialize(), serviceId: theirAci, key: theirKey.serialize()),
                            numberBlocks: blocks, qrData: f.scannable.encoding)
    }
}

extension Messenger {
    func theirIdentityKey(_ aci: String) async throws -> PublicKey {
        let key = try await database.pool.read { db -> Data? in
            guard let s = try String.fetchOne(db, sql: "SELECT json FROM identityKeys WHERE id = ?", arguments: [aci]) else { return nil }
            return (try MessageStore.jsonObject(s)["publicKey"] as? String).flatMap { Data(base64Encoded: $0) }
        }
        guard let key else { throw ModifierError.notFound }
        return try PublicKey(key)
    }

    /// The safety number with a contact (their stored identity key).
    public func safetyNumber(with aci: String) async throws -> SafetyNumber {
        try SafetyNumbers.generate(ourAci: account.aci, ourKey: account.aciIdentity.publicKey, theirAci: aci, theirKey: try await theirIdentityKey(aci))
    }

    /// Scanning their QR code (`compareSafetyNumber`).
    public func matchesScannedSafetyNumber(_ scanned: Data, with aci: String) async throws -> Bool {
        let f = try SafetyNumbers.fingerprint(ourAci: account.aci, ourKey: account.aciIdentity.publicKey, theirAci: aci, theirKey: try await theirIdentityKey(aci))
        return try f.scannable.compare(againstEncoding: scanned)
    }

    /// `setVerified` / `setUnverified`: the reviewed identity's state, a verified-change notice,
    /// the Verified sync to our devices (queued, carrying the reviewed key), storage. One
    /// transaction: the review is checked against the key on record and our own account, and
    /// nothing changes unless both are still the ones the user saw.
    public func setVerified(_ identity: ReviewedIdentity, _ verified: Bool) async throws {
        let account = self.account
        try await database.pool.write { db in
            try identity.validate(db, account: account)
            try Self.applyVerified(db, identity, verified)
        }
        jobs.poke()
    }

    static func applyVerified(_ db: Database, _ identity: ReviewedIdentity, _ verified: Bool) throws {
        let aci = identity.serviceId
        let state: VerifiedStatus = verified ? .verified : .default
        guard try ProtocolStore.verifiedStatus(db, serviceId: aci) != state else { return }
        try ProtocolStore.setVerified(db, serviceId: aci, state)
        let conversationId = try MessageStore.privateConversation(db, serviceId: aci)
        try Identity.insertVerifiedChange(db, conversationId: conversationId, verified: verified, local: true)
        try StorageWriteBack.conversationChanged(db, conversationId: conversationId)
        try queueVerifiedSync(db, identity, verified: verified)
    }

    /// The Verified sync for `identity`, as a job in the caller's transaction.
    static func queueVerifiedSync(_ db: Database, _ identity: ReviewedIdentity, verified: Bool) throws {
        try JobQueue.insert(db, queueType: ConversationJob.queueType,
                            payload: ConversationJob.verifiedSync(serviceId: identity.serviceId, key: identity.key, verified: verified))
    }

    /// The SyncMessage a VerifiedSync job sends: exactly the job's key and state (with a
    /// NullMessage-sized padding, as upstream). The key is not looked up again: the contact may
    /// have a newer one by now, which the user has not reviewed.
    func verifiedSyncMessage(_ job: ConversationJob) async throws -> Signalservice_SyncMessage {
        guard let aci = job.requester, let key = job.identityKey.flatMap({ Data(base64Encoded: $0) }), let verified = job.verified
        else { throw JobError.permanent("malformed job") }
        var v = Signalservice_Verified()
        v.destinationAciBinary = StorageLocal.uuidBytes(aci) ?? Data()
        v.identityKey = key
        v.state = verified ? .verified : .default
        v.nullMessage = SignalCrypto.randomBytes(140)
        var sync = Self.syncMessage()
        sync.verified = v
        return sync
    }
}

enum Identity {
    static func insertVerifiedChange(_ db: Database, conversationId: String, verified: Bool, local: Bool) throws {
        try MessageStore.insert(db, .init(conversationId: conversationId, type: "verified-change", body: "", sentAt: UInt64(MessageStore.now()), source: nil,
                                          sourceDevice: nil, serverGuid: nil, serverTimestamp: nil, unidentified: false,
                                          extra: ["verified": verified, "verifiedChanged": conversationId, "local": local,
                                                  "readStatus": ReadStatus.read.rawValue, "seenStatus": local ? SeenStatus.seen.rawValue : SeenStatus.unseen.rawValue]))
    }
}

// MARK: usernames

public enum UsernameError: Error, Equatable {
    case invalid(String)
    case unavailable
    case notSet
}

public struct UsernameReservation: Sendable, Equatable {
    public var username: String
    public var hash: Data
}

public struct UsernameService: Sendable {
    let account: Account
    let database: SignalDatabase
    let socket: SocketManager

    public init(account: Account, database: SignalDatabase, socket: SocketManager) {
        self.account = account
        self.database = database
        self.socket = socket
    }

    /// `getMinNickname` / `getMaxNickname`
    func nicknameLengths() async throws -> ClosedRange<UInt32> {
        try await database.pool.read { db in
            let min = UInt32(try RemoteConfig.int(db, "global.nicknames.min") ?? 3), max = UInt32(try RemoteConfig.int(db, "global.nicknames.max") ?? 32)
            return min...Swift.max(min, max)
        }
    }

    /// `reserveUsername`: a chosen discriminator, or the generated candidates (`generateCandidates`).
    public func reserve(nickname: String, discriminator: String? = nil) async throws -> UsernameReservation {
        let lengths = try await nicknameLengths()
        let candidates: [Username]
        do {
            if let discriminator {
                candidates = [try Username(nickname: nickname, discriminator: discriminator, withValidLengthWithin: lengths)]
            } else {
                candidates = try Username.candidates(from: nickname, withValidLengthWithin: lengths)
            }
        } catch {
            throw UsernameError.invalid(nickname)
        }
        let hash: Data
        do {
            hash = try await socket.reserveUsernameHashes(candidates.map(\.hash))
        } catch {
            throw UsernameError.unavailable
        }
        guard let chosen = candidates.first(where: { $0.hash == hash }) else { throw UsernameError.unavailable }
        return UsernameReservation(username: chosen.value, hash: hash)
    }

    /// `confirmUsername`: claims the reservation with a fresh link; stored and synced to storage.
    public func confirm(_ reservation: UsernameReservation) async throws -> URL {
        let username = try Username(reservation.username)
        let (entropy, ciphertext) = try username.createLink()
        let handle = try await socket.confirmUsername(username, usernameCiphertext: ciphertext)
        try await save(username: username.value, entropy: entropy, handle: handle)
        return Self.linkURL(entropy: entropy, handle: handle)
    }

    /// `deleteUsername`
    public func delete() async throws {
        try await socket.deleteUsernameHash()
        try await save(username: nil, entropy: nil, handle: nil)
    }

    /// `resetLink`: a new link for the current username (the old one stops working).
    public func resetLink() async throws -> URL {
        let current = try await database.pool.read { try Items.get($0, "username", as: String.self) }
        guard let current else { throw UsernameError.notSet }
        let (entropy, ciphertext) = try Username(current).createLink()
        let handle = try await socket.setUsernameLink(ciphertext, keepLinkHandle: false)
        try await save(username: current, entropy: entropy, handle: handle)
        return Self.linkURL(entropy: entropy, handle: handle)
    }

    func save(username: String?, entropy: Data?, handle: UUID?) async throws {
        let account = self.account
        try await database.pool.write { db in
            let me = try StorageLocal.ourConversation(db, account: account)
            try MessageStore.updateConversationJSON(db, conversationId: me) { $0["username"] = username }
            if let username { try Items.set(db, "username", username) } else { try Items.remove(db, "username") }
            if let entropy, let handle, let server = StorageLocal.uuidBytes(handle.uuidString) {
                try Items.set(db, "usernameLink", StorageRecords.UsernameLink(entropy: entropy.base64EncodedString(), serverId: server.base64EncodedString()))
            } else {
                try Items.remove(db, "usernameLink")
            }
            try Items.remove(db, "usernameCorrupted")
            try Items.remove(db, "usernameLinkCorrupted")
            try StorageWriteBack.accountChanged(db, account: account)
        }
    }

    /// `getUsernameLink`: https://signal.me/#eu/<base64url(entropy ‖ handle)>
    public static func linkURL(entropy: Data, handle: UUID) -> URL {
        let bytes = entropy + (StorageLocal.uuidBytes(handle.uuidString) ?? Data())
        return URL(string: "https://signal.me/#eu/" + GroupsAPI.webSafe(bytes))!
    }

    /// The link's parts (32 bytes of entropy, then the 16-byte handle).
    public static func parseLink(_ url: URL) -> (entropy: Data, handle: UUID)? {
        guard url.scheme == "https", url.host() == "signal.me", let f = url.fragment, f.hasPrefix("eu/") else { return nil }
        var b64 = String(f.dropFirst(3)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let d = Data(base64Encoded: b64), d.count == 48, let s = StorageLocal.uuidString(d.suffix(16)), let u = UUID(uuidString: s) else { return nil }
        return (d.prefix(32), u)
    }

    /// `lookupUsername` (search): the account behind a username, if any.
    public func lookUp(_ username: String) async throws -> String? {
        guard let u = try? Username(username) else { throw UsernameError.invalid(username) }
        return try await socket.lookUpUsernameHash(u.hash)?.serviceIdString
    }

    /// Following a username link: the username it names.
    public func lookUp(link: URL) async throws -> String? {
        guard let (entropy, handle) = Self.parseLink(link) else { return nil }
        return try await socket.lookUpUsernameLink(handle, entropy: entropy)?.value
    }
}

// MARK: key transparency

/// `KeyTransparency.Store` over `key_transparency_account_data` and the
/// `lastDistinguishedTreeHead` item.
final class KeyTransparencyStore: KeyTransparency.Store, Sendable {
    let database: SignalDatabase
    init(database: SignalDatabase) { self.database = database }

    func getLastDistinguishedTreeHead() async -> Data? {
        try? await database.pool.read { try Items.get($0, "lastDistinguishedTreeHead", as: String.self) }.flatMap { Data(base64Encoded: $0) }
    }
    func setLastDistinguishedTreeHead(to data: Data) async {
        try? await database.pool.write { try Items.set($0, "lastDistinguishedTreeHead", data.base64EncodedString()) }
    }
    func getAccountData(for aci: Aci) async -> Data? {
        try? await database.pool.read { try Data.fetchOne($0, sql: "SELECT data FROM key_transparency_account_data WHERE aci = ?", arguments: [aci.serviceIdString]) }
    }
    func setAccountData(_ data: Data, for aci: Aci) async {
        try? await database.pool.write { db in
            try db.execute(sql: "INSERT INTO key_transparency_account_data (aci, data) VALUES (?, ?) ON CONFLICT(aci) DO UPDATE SET data = excluded.data",
                           arguments: [aci.serviceIdString, data])
        }
    }
    func getAccountData(for aci: Aci, context: StoreContext) -> Data? {
        guard let db = (context as? DatabaseStoreContext)?.db else { return nil }
        return try? Data.fetchOne(db, sql: "SELECT data FROM key_transparency_account_data WHERE aci = ?", arguments: [aci.serviceIdString])
    }
    func setAccountData(_ data: Data, for aci: Aci, context: StoreContext) {
        guard let db = (context as? DatabaseStoreContext)?.db else { return }
        try? db.execute(sql: "INSERT INTO key_transparency_account_data (aci, data) VALUES (?, ?) ON CONFLICT(aci) DO UPDATE SET data = excluded.data",
                        arguments: [aci.serviceIdString, data])
    }
}

public enum KeyTransparencyHealth: String, Sendable {
    case ok, intermittent, fail
}

public struct KeyTransparencyService: Sendable {
    let account: Account
    let database: SignalDatabase
    let socket: SocketManager
    let store: KeyTransparencyStore

    public init(account: Account, database: SignalDatabase, socket: SocketManager) {
        self.account = account
        self.database = database
        self.socket = socket
        store = KeyTransparencyStore(database: database)
    }

    /// `isKeyTransparencyAvailable`: not turned off in the AccountRecord, and enabled remotely.
    public func isAvailable() async throws -> Bool {
        try await database.pool.read { db in
            if try Items.get(db, "hasKeyTransparencyDisabled", as: Bool.self) == true { return false }
            return try RemoteConfig.isEnabled(db, "desktop.keyTransparency.prod") || RemoteConfig.isEnabled(db, "desktop.keyTransparency.beta")
        }
    }

    /// `check(conversationId)`: a contact's ACI, identity key and (when we have their access
    /// key) number against the log.
    public func check(contact aci: String) async throws {
        let info = try await database.pool.read { db -> (Data, String?, Data?)? in
            guard let s = try String.fetchOne(db, sql: "SELECT json FROM identityKeys WHERE id = ?", arguments: [aci]),
                  let key = (try MessageStore.jsonObject(s)["publicKey"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return nil }
            let e164 = try String.fetchOne(db, sql: "SELECT e164 FROM conversations WHERE type = 'private' AND serviceId = ?", arguments: [aci])
            return (key, e164, try MessageSender.derivedAccessKey(db, serviceId: aci))
        }
        guard let (key, e164, accessKey) = info else { throw ModifierError.notFound }
        try await socket.keyTransparencyCheck(isSelf: nil, aci: aci, identityKey: key, e164: e164, accessKey: accessKey, usernameHash: nil, store: store)
    }

    /// `selfCheck`: our own entry; the result goes to `keyTransparencySelfHealth` with
    /// upstream's rules (a verification failure twice in a row is `fail`; network trouble
    /// keeps a failed state until a success).
    @discardableResult
    public func selfCheck() async throws -> KeyTransparencyHealth? {
        let account = self.account
        let (discoverable, username, number, accessKey) = try await database.pool.read { db in
            (try Items.get(db, "phoneNumberDiscoverability", as: String.self) != "NotDiscoverable",
             try Items.get(db, "username", as: String.self),
             account.number,
             try Items.get(db, "profileKey", as: String.self).flatMap { Data(base64Encoded: $0) }.flatMap { try? ProfileKey(contents: $0).deriveAccessKey() })
        }
        let old = try await database.pool.read { try Items.get($0, "keyTransparencySelfHealth", as: String.self) }.flatMap(KeyTransparencyHealth.init)
        let new: KeyTransparencyHealth?
        do {
            let hash = username.flatMap { try? Username($0).hash }
            try await socket.keyTransparencyCheck(isSelf: discoverable, aci: account.aci, identityKey: account.aciIdentity.identityKey.serialize(),
                                                  e164: discoverable ? number : nil, accessKey: accessKey, usernameHash: hash, store: store)
            new = .ok
        } catch SignalError.keyTransparencyVerificationFailed {
            new = old == .intermittent || old == .fail ? .fail : .intermittent
        } catch SignalError.keyTransparencyError, SignalError.chatServiceInactive, SignalError.ioError, SignalError.connectionFailed, SignalError.webSocketError,
                SignalError.rateLimitedError {
            new = old == .intermittent || old == .fail ? old : nil
        } catch {
            new = .fail
        }
        try await database.pool.write { db in
            if let new { try Items.set(db, "keyTransparencySelfHealth", new.rawValue) } else { try Items.remove(db, "keyTransparencySelfHealth") }
            try Items.set(db, "lastKeyTransparencySelfCheck", MessageStore.now())
        }
        return new
    }
}
