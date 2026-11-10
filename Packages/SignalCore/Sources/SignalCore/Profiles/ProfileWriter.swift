// Writing our own profile (ts/services/writeProfile.preload.ts with `keepAvatar`, and
// ts/util/encryptProfileData.preload.ts) and the phone number privacy settings that depend on
// it (ts/state/smart/Preferences.preload.tsx `onWhoCanSeeMeChange` / `onWhoCanFindMeChange`).
//
// PUT /v1/profile replaces every field, so a write starts from a fresh fetch of our profile
// and sends back what it found: the name, about and emoji (decrypted, re-encrypted with new
// nonces), the payment address as the server holds it, the visible badges, and the avatar
// kept as it is (`avatar` + `sameAvatar`; this never uploads one). The number-sharing flag
// comes from `phoneNumberSharingMode`. Stricter than upstream: no write without a name we
// could decrypt (upstream asserts a name too), and a changed sharing mode is saved only after
// the profile carrying it was accepted, so the setting never claims "Nobody" while the
// profile still shares the number.

import Foundation
import GRDB
import LibSignalClient
import SignalProtos

public enum ProfileWriteError: Error, Equatable {
    /// Our profile has no name we could read: nothing is written.
    case noName
    case noProfileKey
    case tooLong
}

/// The parts of our profile the user edits (Profile editor).
public struct OwnProfileFields: Sendable, Equatable {
    public var givenName: String
    public var familyName: String?
    public var about: String?
    public var aboutEmoji: String?

    public init(givenName: String, familyName: String? = nil, about: String? = nil, aboutEmoji: String? = nil) {
        self.givenName = givenName
        self.familyName = familyName
        self.about = about
        self.aboutEmoji = aboutEmoji
    }
}

/// `ProfileRequestDataType`: the PUT /v1/profile body.
struct ProfileWriteRequest: Codable, Equatable {
    var version: String
    var name: String
    var about: String?
    var aboutEmoji: String?
    var badgeIds: [String]
    var paymentAddress: String?
    var avatar: Bool
    var sameAvatar: Bool
    var commitment: String
    var phoneNumberSharing: String

    enum CodingKeys: String, CodingKey {
        case version, name, about, aboutEmoji, badgeIds, paymentAddress, avatar, sameAvatar, commitment, phoneNumberSharing
    }

    /// Nulls are sent as nulls (upstream's JSON), not left out.
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(name, forKey: .name)
        try c.encode(about, forKey: .about)
        try c.encode(aboutEmoji, forKey: .aboutEmoji)
        try c.encode(badgeIds, forKey: .badgeIds)
        try c.encode(paymentAddress, forKey: .paymentAddress)
        try c.encode(avatar, forKey: .avatar)
        try c.encode(sameAvatar, forKey: .sameAvatar)
        try c.encode(commitment, forKey: .commitment)
        try c.encode(phoneNumberSharing, forKey: .phoneNumberSharing)
    }
}

public final class ProfileWriter: Sendable {
    let account: Account
    let database: SignalDatabase
    let profiles: ProfileService
    /// An authenticated request (the chat socket; tests record them).
    let send: @Sendable (_ method: String, _ path: String, _ json: Data) async throws -> Data

    public convenience init(account: Account, database: SignalDatabase, socket: SocketManager, profiles: ProfileService) {
        self.init(account: account, database: database, profiles: profiles) { method, path, json in
            try await socket.authenticatedRequest(method, path, json: json)
        }
    }

    init(account: Account, database: SignalDatabase, profiles: ProfileService,
         send: @escaping @Sendable (_ method: String, _ path: String, _ json: Data) async throws -> Data) {
        self.account = account
        self.database = database
        self.profiles = profiles
        self.send = send
    }

    var profileKey: Data {
        get async throws {
            let stored = try await database.pool.read { try Items.get($0, "profileKey", as: String.self) }.flatMap { Data(base64Encoded: $0) }
            guard let key = account.profileKey ?? stored, key.count == 32 else { throw ProfileWriteError.noProfileKey }
            return key
        }
    }

    /// `writeProfile` (keepAvatar): our profile again, with `fields` if given, and the number
    /// shared or not as `sharesNumber` says (nil: as `phoneNumberSharingMode` says).
    public func write(fields: OwnProfileFields? = nil, sharesNumber: Bool? = nil) async throws {
        let key = try await profileKey
        let current = try await profiles.fetch(account.aci)
        let sharing: Bool
        if let sharesNumber {
            sharing = sharesNumber
        } else {
            sharing = try await database.pool.read { try Items.get($0, "phoneNumberSharingMode", as: String.self) } == "Everybody"
        }
        let request = try Self.request(current: current, fields: fields, sharesNumber: sharing, profileKey: key, aci: account.aci)
        _ = try await send("PUT", "/v1/profile", try JSONEncoder().encode(request))

        let aci = account.aci
        let account = self.account
        try await database.pool.write { db in
            if let fields {
                let id = try MessageStore.privateConversation(db, serviceId: aci)
                try MessageStore.updateConversationJSON(db, conversationId: id) { json in
                    json["profileName"] = fields.givenName
                    json["profileFamilyName"] = fields.familyName
                    json["about"] = fields.about
                    json["aboutEmoji"] = fields.aboutEmoji
                }
                let full = [fields.givenName, fields.familyName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
                try db.execute(sql: "UPDATE conversations SET profileName = ?, profileFamilyName = ?, profileFullName = ? WHERE id = ?",
                               arguments: [fields.givenName, fields.familyName, full, id])
            }
            // `captureChange('writeProfile')`, then our other devices refetch it
            // (`getFetchLocalProfileSyncMessage`; a linked device always has the phone).
            try StorageWriteBack.accountChanged(db, account: account)
            try JobQueue.insert(db, queueType: ConversationJob.queueType,
                                payload: ConversationJob.fetchLatest([Signalservice_SyncMessage.FetchLatest.TypeEnum.localProfile.rawValue]))
        }
    }

    /// `encryptProfileData`
    static func request(current: Profile, fields: OwnProfileFields?, sharesNumber: Bool, profileKey: Data, aci: String) throws -> ProfileWriteRequest {
        let given = fields?.givenName ?? current.givenName
        guard let given, !given.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProfileWriteError.noName }
        let family = fields != nil ? fields?.familyName : current.familyName
        let about = fields != nil ? fields?.about : current.about
        let emoji = fields != nil ? fields?.aboutEmoji : current.aboutEmoji
        let userId = try Aci.parseFrom(serviceIdString: aci)
        let pk = try ProfileKey(contents: profileKey)
        func padded(_ s: String?, _ lengths: [Int]) throws -> String? {
            guard let s, !s.isEmpty else { return nil }
            return try ProfileService.encryptPadded(Data(s.utf8), lengths: lengths, profileKey: profileKey).base64EncodedString()
        }
        let hasAvatar = current.avatarPath != nil
        return ProfileWriteRequest(
            version: String(decoding: try pk.getProfileKeyVersion(userId: userId).serialize(), as: UTF8.self),
            name: try ProfileService.encryptName(given: given, family: family, profileKey: profileKey).base64EncodedString(),
            about: try padded(about, ProfileService.PaddedLengths.about),
            aboutEmoji: try padded(emoji, ProfileService.PaddedLengths.aboutEmoji),
            badgeIds: current.visibleBadgeIds,
            paymentAddress: current.paymentAddress,
            // keepAvatar without a re-upload: the avatar stays as it is (or absent).
            avatar: hasAvatar,
            sameAvatar: true,
            commitment: try pk.getCommitment(userId: userId).serialize().base64EncodedString(),
            phoneNumberSharing: try SignalCrypto.aes256GCMEncrypt(key: profileKey, Data([sharesNumber ? 1 : 0])).base64EncodedString())
    }

    // MARK: phone number privacy

    /// `onWhoCanFindMeChange`: the server's discoverability, then the setting (synced).
    public func setDiscoverable(_ discoverable: Bool) async throws {
        struct Body: Encodable { var discoverableByPhoneNumber: Bool }
        _ = try await send("PUT", "/v2/accounts/phone_number_discoverability", try JSONEncoder().encode(Body(discoverableByPhoneNumber: discoverable)))
        let account = self.account
        try await database.pool.write { db in
            try Items.set(db, "phoneNumberDiscoverability", discoverable ? "Discoverable" : "NotDiscoverable")
            try StorageWriteBack.accountChanged(db, account: account)
        }
    }

    /// `onWhoCanSeeMeChange`: sharing with everybody makes us discoverable first; the profile
    /// is written with the new flag, and only then is the setting saved (and synced).
    public func setSharesNumber(_ everybody: Bool) async throws {
        if everybody { try await setDiscoverable(true) }
        try await write(sharesNumber: everybody)
        let account = self.account
        try await database.pool.write { db in
            try Items.set(db, "phoneNumberSharingMode", everybody ? "Everybody" : "Nobody")
            try StorageWriteBack.accountChanged(db, account: account)
        }
    }
}
