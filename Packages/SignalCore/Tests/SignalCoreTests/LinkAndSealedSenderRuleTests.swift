// Small rules taken from Signal-Desktop that are easy to get subtly wrong: what a linking
// device derives from the provisioning message (AccountManager), and which unidentified-access
// key a send tries (util/getSendOptions).

import Foundation
import GRDB
import LibSignalClient
import Testing
@testable import SignalCore

@Suite struct LinkingRuleTests {
    /// Upstream `createKeyPair`: the identity is the private key; a public key that came
    /// alongside it is never trusted to match.
    @Test func identityIsDerivedFromThePrivateKey() throws {
        let real = PrivateKey.generate()
        let pair = try DeviceLinker.identity(privateKey: real.serialize())
        #expect(pair.publicKey == real.publicKey)
        // And it signs: a signature by it verifies under the derived public key.
        let message = Data("signed pre-key".utf8)
        #expect(try pair.publicKey.verifySignature(message: message, signature: pair.privateKey.generateSignature(message: message)))
        #expect(throws: (any Error).self) { try DeviceLinker.identity(privateKey: Data([1, 2, 3])) }
    }

    @Test func registrationIdsAndPasswords() {
        var smallest = UInt32.max, largest = UInt32.min
        for _ in 0..<200_000 {
            let id = DeviceLinker.registrationId()
            smallest = min(smallest, id)
            largest = max(largest, id)
        }
        // generateRegistrationId: randomInt(1, 16383), ends included (never 0, 14 bits).
        #expect(smallest == 1 && largest == 16383)

        let passwords = (0..<50).map { _ in DeviceLinker.newPassword() }
        #expect(Set(passwords).count == 50)
        // 16 random bytes, base64, without its "==".
        #expect(passwords.allSatisfy { $0.count == 22 && !$0.contains("=") && Data(base64Encoded: $0 + "==")?.count == 16 })
    }
}

@Suite struct SealedSenderAccessKeyTests {
    private func accessKey(mode: SealedSenderMode?, profileKey: Data?) throws -> Data? {
        let (db, _) = try LinkedClient.temporaryDatabase()
        let contact = UUID().uuidString.lowercased()
        return try db.pool.write { db in
            let id = try MessageStore.privateConversation(db, serviceId: contact)
            try MessageStore.updateConversationJSON(db, conversationId: id) { json in
                if let mode { json["sealedSender"] = mode.rawValue }
                if let profileKey { json["profileKey"] = profileKey.base64EncodedString() }
            }
            return try MessageSender.accessKey(db, serviceId: contact)
        }
    }

    @Test func accessKeyFollowsTheRecipientsMode() throws {
        let profileKey = SignalCrypto.randomBytes(32)
        let derived = try ProfileKey(contents: profileKey).deriveAccessKey()
        let zero = Data(count: 16)
        #expect(derived.count == 16 && derived != zero)

        // Disabled: never sealed, whatever we know.
        #expect(try accessKey(mode: .disabled, profileKey: profileKey) == nil)
        // Unrestricted: upstream's ZERO_ACCESS_KEY (the server takes any key for them).
        #expect(try accessKey(mode: .unrestricted, profileKey: profileKey) == zero)
        #expect(try accessKey(mode: .unrestricted, profileKey: nil) == zero)
        // Enabled or not yet known: the key only someone with their profile key can derive…
        #expect(try accessKey(mode: .enabled, profileKey: profileKey) == derived)
        #expect(try accessKey(mode: .unknown, profileKey: profileKey) == derived)
        #expect(try accessKey(mode: nil, profileKey: profileKey) == derived)
        // …and without it the zero key, which only an unrestricted recipient accepts.
        #expect(try accessKey(mode: .unknown, profileKey: nil) == zero)
        #expect(try accessKey(mode: nil, profileKey: nil) == zero)
        // The key-transparency lookup must only ever use the real, derived key.
        let (kt, _) = try LinkedClient.temporaryDatabase()
        let contact = UUID().uuidString.lowercased()
        try kt.pool.write { db in
            let id = try MessageStore.privateConversation(db, serviceId: contact)
            #expect(try MessageSender.derivedAccessKey(db, serviceId: contact) == nil)
            try MessageStore.updateConversationJSON(db, conversationId: id) { $0["profileKey"] = profileKey.base64EncodedString() }
            #expect(try MessageSender.derivedAccessKey(db, serviceId: contact) == derived)
        }
        // Someone we have no conversation with: nothing to go on, send authenticated.
        let (db, _) = try LinkedClient.temporaryDatabase()
        #expect(try db.pool.read { db in try MessageSender.accessKey(db, serviceId: UUID().uuidString.lowercased()) } == nil)
    }
}
