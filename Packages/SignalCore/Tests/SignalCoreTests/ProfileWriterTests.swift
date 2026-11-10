// Writing our own profile (PUT /v1/profile) and the phone number privacy settings: every field
// of the request decrypts to what the profile held, what must survive a re-write (payment
// address, visible badges, the avatar) does, nothing is written without a name, and a sharing
// change is saved only after the profile carrying it was accepted.

import Foundation
import GRDB
import LibSignalClient
import Synchronization
import Testing
@testable import SignalCore

struct Refused: Error {}

@Suite struct ProfileWriterTests {
    static let aci = "9d0652a3-dcc3-4d11-975f-74d61598733f"

    static func profile(given: String? = "Ada", avatar: String? = "profiles/abc") throws -> Profile {
        var p = Profile(serviceId: aci, givenName: given, familyName: "Lovelace", about: "Counting", aboutEmoji: "🧮", avatarPath: avatar,
                        identityKey: IdentityKeyPair.generate().identityKey, sealedSender: .disabled, capabilities: [:])
        p.paymentAddress = "c2VydmVyLWhlbGQ="
        p.visibleBadgeIds = ["BOOST"]
        return p
    }

    @Test func requestCarriesTheProfileOver() throws {
        let key = SignalCrypto.randomBytes(32)
        let r = try ProfileWriter.request(current: try Self.profile(), fields: nil, sharesNumber: false, profileKey: key, aci: Self.aci)
        func field(_ b64: String?) throws -> Data { try ProfileService.decryptPadded(try #require(b64.flatMap { Data(base64Encoded: $0) }), profileKey: key) }
        #expect(try ProfileService.decryptName(Data(base64Encoded: r.name)!, profileKey: key) == ("Ada", "Lovelace"))
        #expect(try ProfileService.decryptString(Data(base64Encoded: r.about!)!, profileKey: key) == "Counting")
        let (aboutField, emojiField) = (try field(r.about), try field(r.aboutEmoji))
        #expect(aboutField.count == 128 && emojiField.count == 32)
        #expect(try field(r.phoneNumberSharing) == Data([0]))
        #expect(r.paymentAddress == "c2VydmVyLWhlbGQ=" && r.badgeIds == ["BOOST"])
        #expect(r.avatar && r.sameAvatar)   // the avatar stays
        let userId = try Aci.parseFrom(serviceIdString: Self.aci)
        let pk = try ProfileKey(contents: key)
        #expect(r.version == String(decoding: try pk.getProfileKeyVersion(userId: userId).serialize(), as: UTF8.self))
        #expect(r.commitment == (try pk.getCommitment(userId: userId).serialize().base64EncodedString()))

        // Sharing, edits, no avatar; nulls go out as nulls.
        let edited = try ProfileWriter.request(current: try Self.profile(avatar: nil), fields: OwnProfileFields(givenName: "Grace"), sharesNumber: true,
                                               profileKey: key, aci: Self.aci)
        #expect(try ProfileService.decryptName(Data(base64Encoded: edited.name)!, profileKey: key) == ("Grace", nil))
        #expect(edited.about == nil && edited.aboutEmoji == nil && !edited.avatar && edited.sameAvatar)
        #expect(try field(edited.phoneNumberSharing) == Data([1]))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(edited)) as! [String: Any]
        #expect(json["about"] is NSNull && json.keys.count == 10)
    }

    @Test func noNameNoWrite() throws {
        #expect(throws: ProfileWriteError.noName) {
            try ProfileWriter.request(current: try Self.profile(given: nil), fields: nil, sharesNumber: false, profileKey: SignalCrypto.randomBytes(32), aci: Self.aci)
        }
        #expect(throws: ProfileWriteError.noName) {
            try ProfileWriter.request(current: try Self.profile(), fields: OwnProfileFields(givenName: "  "), sharesNumber: false,
                                      profileKey: SignalCrypto.randomBytes(32), aci: Self.aci)
        }
    }

    /// Against the mock server: the profile write is accepted; "who can see me: everybody"
    /// makes us discoverable first, writes the profile, then saves the setting; a refused
    /// write leaves the setting as it was.
    @Test func phoneNumberSettings() async throws {
        try await LinkedClient.with { c in
            let sent = Mutex<[String]>([])
            let fail = Atomic<Bool>(false)
            let socket = c.socket
            let writer = ProfileWriter(account: c.account, database: c.database, profiles: c.profiles) { method, path, json in
                sent.withLock { $0.append("\(method) \(path)") }
                if fail.load(ordering: .relaxed) { throw Refused() }
                // The mock server has no discoverability endpoint.
                if path.hasSuffix("phone_number_discoverability") { return Data() }
                return try await socket.authenticatedRequest(method, path, json: json)
            }
            try await writer.setSharesNumber(true)
            #expect(sent.withLock { $0 } == ["PUT /v2/accounts/phone_number_discoverability", "PUT /v1/profile"])
            let items = try await c.database.pool.read { db in
                (try Items.get(db, "phoneNumberSharingMode", as: String.self), try Items.get(db, "phoneNumberDiscoverability", as: String.self))
            }
            #expect(items.0 == "Everybody" && items.1 == "Discoverable")
            // Our name came through the round trip.
            #expect(try await c.profiles.fetch(c.account.aci).givenName != nil)

            fail.store(true, ordering: .relaxed)
            await #expect(throws: Refused.self) { try await writer.setSharesNumber(false) }
            #expect(try await c.database.pool.read { try Items.get($0, "phoneNumberSharingMode", as: String.self) } == "Everybody")
        }
    }
}
