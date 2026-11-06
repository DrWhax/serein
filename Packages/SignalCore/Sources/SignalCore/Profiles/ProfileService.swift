// Profile fetch and decryption (port of Desktop ts/services/profiles.preload.ts
// doGetProfile + ts/Crypto.node.ts decryptProfile/decryptProfileName):
//
//   GET v1/profile/<aci>/<profileKeyVersion>   (versioned, when we know the profile key)
//   GET v1/profile/<serviceId>                 (otherwise: identity key and capabilities only)
//
// Sent unauthenticated with the Unidentified-Access-Key when we have one (falls back to
// the authenticated socket on 401). Encrypted fields are AES-256-GCM under the profile key;
// names are `given ‖ 0x00 ‖ family` zero-padded. The access-key verifier tells whether
// sealed sender works for this contact.

import Foundation
import GRDB
import LibSignalClient

public struct Profile: Sendable, Equatable {
    public var serviceId: String
    public var givenName: String?
    public var familyName: String?
    public var about: String?
    public var aboutEmoji: String?
    public var avatarPath: String?
    public var identityKey: IdentityKey
    public var sealedSender: SealedSenderMode
    public var capabilities: [String: Bool]
}

public enum ProfileError: Error, Equatable {
    case notFound(String)
    case invalidResponse(String)
}

public final class ProfileService: Sendable {
    let account: Account
    let database: SignalDatabase
    let socket: SocketManager
    /// Where profile avatars come from (CDN0) and go (the local store, encrypted at rest).
    struct Avatars: Sendable {
        var http: HTTPClient
        var cdn0: URL
        var store: AttachmentStore
    }
    let avatars: Avatars?
    /// Avatars larger than this are not downloaded (upstream caps uploads at 5 MiB).
    static let maxAvatarBytes = 10 << 20

    public init(account: Account, database: SignalDatabase, socket: SocketManager, http: HTTPClient? = nil, cdn0: URL? = nil,
                store: AttachmentStore? = nil) {
        self.account = account
        self.database = database
        self.socket = socket
        if let http, let cdn0, let store { avatars = Avatars(http: http, cdn0: cdn0, store: store) } else { avatars = nil }
    }

    struct Response: Decodable {
        var identityKey: String
        var name: String?
        var about: String?
        var aboutEmoji: String?
        var avatar: String?
        var unidentifiedAccess: String?
        var unrestrictedUnidentifiedAccess: Bool?
    }

    @discardableResult
    public func fetch(_ serviceId: String) async throws -> Profile {
        let profileKey: Data? = try await database.pool.read { db in
            if serviceId == self.account.aci {
                if let key = self.account.profileKey { return key }
                return (try Items.get(db, "profileKey", as: String.self)).flatMap { Data(base64Encoded: $0) }
            }
            guard let json = try String.fetchOne(db, sql: "SELECT json FROM conversations WHERE serviceId = ? AND type = 'private'", arguments: [serviceId])
            else { return nil }
            return (try MessageStore.jsonObject(json)["profileKey"] as? String).flatMap { Data(base64Encoded: $0) }
        }
        var path = "/v1/profile/\(serviceId)"
        var accessKey: Data? = nil
        if let profileKey, profileKey.count == 32, let aci = try? Aci.parseFrom(serviceIdString: serviceId) {
            let key = try ProfileKey(contents: profileKey)
            // The 64-byte version is already lowercase hex text.
            path += "/" + String(decoding: try key.getProfileKeyVersion(userId: aci).serialize(), as: UTF8.self)
            accessKey = key.deriveAccessKey()
        }

        let body: Data
        do {
            if let accessKey, serviceId != account.aci {
                do {
                    body = try await socket.unauthenticatedRequest("GET", path, headers: ["unidentified-access-key": accessKey.base64EncodedString()])
                } catch let e as ChatRequestError where e.status == 401 {
                    body = try await socket.authenticatedRequest("GET", path)
                }
            } else {
                body = try await socket.authenticatedRequest("GET", path)
            }
        } catch let e as ChatRequestError where e.status == 404 {
            throw ProfileError.notFound(serviceId)
        }
        let r = try JSONDecoder().decode(Response.self, from: body)
        let capabilities = ((try JSONSerialization.jsonObject(with: body) as? [String: Any])?["capabilities"] as? [String: Any] ?? [:])
            .compactMapValues { $0 as? Bool }

        guard let identityBytes = Data(lenientBase64: r.identityKey), let identity = try? IdentityKey(bytes: identityBytes) else {
            throw ProfileError.invalidResponse("identityKey")
        }
        var profile = Profile(serviceId: serviceId, identityKey: identity, sealedSender: .disabled, capabilities: capabilities)
        profile.avatarPath = r.avatar
        if let profileKey {
            if let n = r.name.flatMap({ Data(base64Encoded: $0) }) { (profile.givenName, profile.familyName) = try Self.decryptName(n, profileKey: profileKey) }
            if let a = r.about.flatMap({ Data(base64Encoded: $0) }) { profile.about = try Self.decryptString(a, profileKey: profileKey) }
            if let e = r.aboutEmoji.flatMap({ Data(base64Encoded: $0) }) { profile.aboutEmoji = try Self.decryptString(e, profileKey: profileKey) }
        }
        if r.unrestrictedUnidentifiedAccess == true {
            profile.sealedSender = .unrestricted
        } else if let accessKey, let verifier = r.unidentifiedAccess.flatMap({ Data(base64Encoded: $0) }),
                  SignalCrypto.constantTimeEqual(Self.accessKeyVerifier(accessKey), verifier) {
            profile.sealedSender = .enabled
        }

        let result = profile
        try await database.pool.write { db in try self.store(db, result) }
        if let url = result.avatarPath, let profileKey { try? await fetchAvatar(serviceId: serviceId, url: url, profileKey: profileKey) }
        return result
    }

    /// `setAndMaybeFetchProfileAvatar`: download only for accepted chats and people in a group
    /// with us; keep the stored file while the URL is unchanged; decrypt with the profile key
    /// (AES-256-GCM) and store encrypted at rest as `profileAvatar` {url, path, localKey, …}.
    func fetchAvatar(serviceId: String, url: String, profileKey: Data) async throws {
        guard let avatars else { return }
        let ourAci = account.aci
        let decision = try await database.pool.read { db -> (conversationId: String, download: Bool)? in
            guard let row = try Row.fetchOne(db, sql: "SELECT id, json FROM conversations WHERE serviceId = ? AND type = 'private'", arguments: [serviceId])
            else { return nil }
            let id: String = row["id"]
            let json = try MessageStore.jsonObject(row["json"])
            if let existing = json["profileAvatar"] as? [String: Any], existing["url"] as? String == url, existing["localKey"] != nil {
                return (id, false)
            }
            let accepted = try ConversationState.isAccepted(db, conversationId: id, ourAci: ourAci, ignoreEmptyConvo: true)
            if serviceId == ourAci || accepted {
                return (id, true)
            }
            let inGroup = try String.fetchOne(db, sql: """
                SELECT 1 FROM conversations, json_each(conversations.json, '$.membersV2') AS m
                WHERE conversations.type = 'group' AND coalesce(json_extract(conversations.json, '$.left'), 0) = 0
                  AND json_extract(m.value, '$.aci') = ? LIMIT 1
                """, arguments: [serviceId]) != nil
            return (id, inGroup)
        }
        guard let decision, decision.download else { return }
        let (_, blob) = try await avatars.http.send("GET", avatars.cdn0.appendingPathComponent(url))
        guard blob.count <= Self.maxAvatarBytes else { throw ProfileError.invalidResponse("avatar too large") }
        let image = try SignalCrypto.aes256GCMDecrypt(key: profileKey, blob)
        let saved = try avatars.store.storeLocally(image)
        let old = try await database.pool.write { db -> String? in
            var previous: String?
            try MessageStore.updateConversationJSON(db, conversationId: decision.conversationId) { json in
                previous = (json["profileAvatar"] as? [String: Any])?["path"] as? String
                json["profileAvatar"] = ["url": url, "path": saved.path, "localKey": saved.localKey.base64EncodedString(), "hash": saved.plaintextHash,
                                         "size": image.count]
            }
            return previous
        }
        if let old, old != saved.path { try? avatars.store.delete(old) }
    }

    /// A member's ExpiringProfileKeyCredential (needed to add them to a group with a
    /// presentation): cached on the conversation as `profileKeyCredential` +
    /// `profileKeyCredentialExpiration`, else fetched with a versioned profile request carrying a
    /// credential request (`credentialType=expiringProfileKey`). nil without a profile key.
    public func expiringCredential(_ aci: String, serverPublicParams: Data, now: Date = Date()) async throws -> ExpiringProfileKeyCredential? {
        let (profileKey, cached): (Data?, Data?) = try await database.pool.read { db in
            if aci == self.account.aci {
                let stored = try Items.get(db, "profileKey", as: String.self).flatMap { Data(base64Encoded: $0) }
                let key = self.account.profileKey ?? stored
                let c = (try Items.get(db, "profileKeyCredential", as: String.self)).flatMap { Data(base64Encoded: $0) }
                return (key, c)
            }
            guard let json = try String.fetchOne(db, sql: "SELECT json FROM conversations WHERE serviceId = ? AND type = 'private'", arguments: [aci])
                .map(MessageStore.jsonObject) else { return (nil, nil) }
            return ((json["profileKey"] as? String).flatMap { Data(base64Encoded: $0) }, (json["profileKeyCredential"] as? String).flatMap { Data(base64Encoded: $0) })
        }
        if let cached, let c = try? ExpiringProfileKeyCredential(contents: cached), c.expirationTime > now.addingTimeInterval(3600) { return c }
        guard let profileKey, profileKey.count == 32 else { return nil }
        let userId = try Aci.parseFrom(serviceIdString: aci)
        let key = try ProfileKey(contents: profileKey)
        let ops = ClientZkProfileOperations(serverPublicParams: try ServerPublicParams(contents: serverPublicParams))
        let context = try ops.createProfileKeyCredentialRequestContext(userId: userId, profileKey: key)
        let version = String(decoding: try key.getProfileKeyVersion(userId: userId).serialize(), as: UTF8.self)
        let path = "/v1/profile/\(aci)/\(version)/\(try context.getRequest().serialize().hexString)?credentialType=expiringProfileKey"
        let body = try await socket.authenticatedRequest("GET", path)
        struct R: Decodable { var credential: String? }
        guard let response = try JSONDecoder().decode(R.self, from: body).credential.flatMap({ Data(base64Encoded: $0) }) else { return nil }
        let credential = try ops.receiveExpiringProfileKeyCredential(profileKeyCredentialRequestContext: context,
                                                                     profileKeyCredentialResponse: ExpiringProfileKeyCredentialResponse(contents: response), now: now)
        let b64 = credential.serialize().base64EncodedString(), expiration = Int64(credential.expirationTime.timeIntervalSince1970 * 1000)
        try await database.pool.write { db in
            if aci == self.account.aci {
                try Items.set(db, "profileKeyCredential", b64)
            } else {
                let id = try MessageStore.privateConversation(db, serviceId: aci)
                try MessageStore.updateConversationJSON(db, conversationId: id) { json in
                    json["profileKeyCredential"] = b64
                    json["profileKeyCredentialExpiration"] = expiration
                }
            }
        }
        return credential
    }

    func store(_ db: Database, _ p: Profile) throws {
        if p.serviceId != account.aci {
            // A changed identity key is accepted like on send (keychange notification, sessions archived).
            let sender = MessageSender(account: account, database: database, socket: socket, trustRoots: [])
            do {
                try sender.acceptIdentity(db, p.identityKey, serviceId: p.serviceId)
            } catch SendError.untrustedIdentity {
                // Verified contact changed keys: keep the old key, mark unverified (upstream behaviour).
                try ProtocolStore.setIdentity(db, serviceId: p.serviceId, key: p.identityKey.serialize(), verified: .unverified)
            }
            if try sender.store.identity(for: try ProtocolAddress(name: p.serviceId, deviceId: 1), context: DatabaseStoreContext(db)) == nil {
                _ = try sender.store.saveIdentity(p.identityKey, for: try ProtocolAddress(name: p.serviceId, deviceId: 1), context: DatabaseStoreContext(db))
            }
        }
        let conversationId = try MessageStore.privateConversation(db, serviceId: p.serviceId)
        let now = MessageStore.now()
        try MessageStore.updateConversationJSON(db, conversationId: conversationId) { json in
            if p.givenName != nil {
                json["profileName"] = p.givenName
                json["profileFamilyName"] = p.familyName
            }
            json["about"] = p.about
            json["aboutEmoji"] = p.aboutEmoji
            // The CDN path; the downloaded file is `profileAvatar` (fetchAvatar). No avatar: drop it.
            json["remoteAvatarUrl"] = p.avatarPath
            if p.avatarPath == nil { json["profileAvatar"] = nil }
            json["sealedSender"] = p.sealedSender.rawValue
            json["capabilities"] = p.capabilities
            json["profileLastFetchedAt"] = now
        }
        let full = p.givenName.map { [$0, p.familyName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ") }
        try db.execute(sql: """
            UPDATE conversations SET profileName = coalesce(?, profileName), profileFamilyName = ?, profileFullName = coalesce(?, profileFullName),
              profileLastFetchedAt = ? WHERE id = ?
            """, arguments: [p.givenName, p.familyName, full, now, conversationId])
    }

    // MARK: crypto

    /// HMAC-SHA256(accessKey, 32 zero bytes): what the server stores to check access keys.
    public static func accessKeyVerifier(_ accessKey: Data) -> Data {
        SignalCrypto.hmacSHA256(key: accessKey, Data(count: 32))
    }

    /// Decrypts a profile field and strips the zero padding.
    static func decryptPadded(_ data: Data, profileKey: Data) throws -> Data {
        let plain = try SignalCrypto.aes256GCMDecrypt(key: profileKey, data)
        var end = plain.endIndex
        while end > plain.startIndex, plain[end - 1] == 0 { end -= 1 }
        return plain[plain.startIndex..<end]
    }

    static func decryptString(_ data: Data, profileKey: Data) throws -> String? {
        let s = String(decoding: try decryptPadded(data, profileKey: profileKey), as: UTF8.self)
        return s.isEmpty ? nil : s
    }

    /// `given ‖ 0x00 ‖ family` (family optional), zero padded.
    public static func decryptName(_ data: Data, profileKey: Data) throws -> (String?, String?) {
        let plain = try decryptPadded(data, profileKey: profileKey)
        let parts = plain.split(separator: 0, maxSplits: 1, omittingEmptySubsequences: false)
        let given = parts.first.map { String(decoding: $0, as: UTF8.self) }
        let family = parts.count > 1 ? String(decoding: parts[1], as: UTF8.self) : nil
        return (given?.isEmpty == true ? nil : given, family?.isEmpty == true ? nil : family)
    }

    /// Encrypts a name the way clients upload it (padded to 53 or 257 bytes).
    public static func encryptName(given: String, family: String?, profileKey: Data) throws -> Data {
        var plain = Data(given.utf8)
        if let family { plain.append(0); plain.append(contentsOf: family.utf8) }
        let padded = plain.count <= 53 ? 53 : 257
        guard plain.count <= padded else { throw ProfileError.invalidResponse("name too long") }
        plain.append(contentsOf: repeatElement(0, count: padded - plain.count))
        return try SignalCrypto.aes256GCMEncrypt(key: profileKey, plain)
    }
}
