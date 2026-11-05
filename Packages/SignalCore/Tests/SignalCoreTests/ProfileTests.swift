// Profiles: fetch + decrypt against the mock server, and the profile crypto itself.

import Foundation
import GRDB
import LibSignalClient
import Testing
@testable import SignalCore

@Suite(.serialized) struct ProfileTests {
    @Test func contactProfileWithProfileKey() async throws {
        try await LinkedClient.with { c in
            try await c.receiveFromAlice("my profile key", withProfileKey: true)
            let alice = try await c.accountInfo("alice")
            let profile = try await c.profiles.fetch(c.aliceAci)
            #expect(profile.givenName == "Alice" && profile.familyName == nil)
            #expect(profile.identityKey.serialize().base64EncodedString() == alice.identityKey)
            // The mock publishes HMAC(accessKey, 0³²) for alice: sealed sender works.
            #expect(profile.sealedSender == .enabled)

            let json = try await c.conversationJSON(serviceId: c.aliceAci)
            #expect(json["profileName"] as? String == "Alice")
            #expect(json["sealedSender"] as? Int == SealedSenderMode.enabled.rawValue)
            #expect(json["profileLastFetchedAt"] as? Int64 != nil)
            try await c.database.pool.read { db throws in
                let row = try #require(try Row.fetchOne(db, sql: "SELECT profileName, profileFullName, profileLastFetchedAt FROM conversations WHERE serviceId = ?",
                                                        arguments: [c.aliceAci]))
                #expect(row["profileName"] as String? == "Alice" && row["profileFullName"] as String? == "Alice")
                #expect(row["profileLastFetchedAt"] as Int64? != nil)
            }
        }
    }

    @Test func ownProfile() async throws {
        try await LinkedClient.with { c in
            let me = try await c.profiles.fetch(c.account.aci)
            #expect(me.givenName == "Phone")
            #expect(me.identityKey == c.account.aciIdentity.identityKey)
        }
    }

    @Test func unknownProfileKeyGivesIdentityOnly() async throws {
        try await LinkedClient.with { c in
            let alice = try await c.accountInfo("alice")
            let profile = try await c.profiles.fetch(c.aliceAci)
            #expect(profile.givenName == nil && profile.sealedSender == .disabled)
            #expect(profile.identityKey.serialize().base64EncodedString() == alice.identityKey)
            // The identity key was recorded for alice, ready for a first send.
            let stored = try await c.database.pool.read { db in
                try String.fetchOne(db, sql: "SELECT json ->> '$.publicKey' FROM identityKeys WHERE id = ?", arguments: [c.aliceAci])
            }
            #expect(stored == alice.identityKey)
        }
    }

    @Test func unknownAccountIsNotFound() async throws {
        try await LinkedClient.with { c in
            await #expect(throws: ProfileError.notFound("00000000-0000-4000-8000-000000000001")) {
                try await c.profiles.fetch("00000000-0000-4000-8000-000000000001")
            }
        }
    }

    @Test func nameCryptoRoundTripAndPadding() throws {
        let key = SignalCrypto.randomBytes(32)
        let short = try ProfileService.encryptName(given: "Ada", family: "Lovelace", profileKey: key)
        #expect(short.count == 12 + 53 + 16)
        let (given, family) = try ProfileService.decryptName(short, profileKey: key)
        #expect(given == "Ada" && family == "Lovelace")
        let long = try ProfileService.encryptName(given: String(repeating: "x", count: 60), family: nil, profileKey: key)
        #expect(long.count == 12 + 257 + 16)
        #expect(try ProfileService.decryptName(long, profileKey: key) == (String(repeating: "x", count: 60), nil))
        var tampered = short
        tampered[20] ^= 1
        #expect(throws: SignalCryptoError.badMAC) { try ProfileService.decryptName(tampered, profileKey: key) }
        #expect(throws: SignalCryptoError.badMAC) { try ProfileService.decryptName(short, profileKey: SignalCrypto.randomBytes(32)) }
    }

    @Test func accessKeyVerifierMatchesServerDefinition() throws {
        let profileKey = try ProfileKey(contents: Data(repeating: 7, count: 32))
        let accessKey = profileKey.deriveAccessKey()
        #expect(accessKey.count == 16)
        #expect(ProfileService.accessKeyVerifier(accessKey) == SignalCrypto.hmacSHA256(key: accessKey, Data(count: 32)))
    }
}
