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

    public init(account: Account, database: SignalDatabase, socket: SocketManager) {
        self.account = account
        self.database = database
        self.socket = socket
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

        guard let identityBytes = Data(base64Encoded: r.identityKey), let identity = try? IdentityKey(bytes: identityBytes) else {
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
        return result
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
            json["profileAvatar"] = p.avatarPath.map { ["path": $0] }
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
