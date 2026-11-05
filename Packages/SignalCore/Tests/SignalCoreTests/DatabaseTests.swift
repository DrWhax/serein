import Foundation
import GRDB
import LibSignalClient
import Testing
@testable import SignalCore

@Suite struct DatabaseTests {
    @Test func upstreamSchema() throws {
        let (db, _) = try LinkedClient.temporaryDatabase()
        let tables = try db.tableNames
        for t in ["messages", "conversations", "items", "sessions", "preKeys", "signedPreKeys", "kyberPreKeys", "kyberPreKey_triples",
                  "senderKeys", "identityKeys", "unprocessed", "edited_messages", "reactions", "messages_fts"] {
            #expect(tables.contains(t), "missing \(t)")
        }
        let indexes = try db.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL")! }
        let triggers = try db.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sqlite_master WHERE type = 'trigger'")! }
        #expect(indexes >= 90 && triggers >= 9)
    }

    @Test func encryptedAtRestAndWrongKeyFails() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("signalsafe-\(UUID()).sqlite")
        let key = SignalCrypto.randomBytes(32)
        do {
            let db = try SignalDatabase(url: url, key: key)
            try db.pool.write { try Items.set($0, "canary", "plaintext-canary-value") }
        }
        let raw = try Data(contentsOf: url)
        #expect(raw.range(of: Data("SQLite format 3".utf8)) == nil)
        #expect(raw.range(of: Data("plaintext-canary-value".utf8)) == nil)
        #expect(throws: (any Error).self) { _ = try SignalDatabase(url: url, key: SignalCrypto.randomBytes(32)) }
        let again = try SignalDatabase(url: url, key: key)
        #expect(try again.pool.read { try Items.get($0, "canary", as: String.self) } == "plaintext-canary-value")
    }

    @Test func keychainKeyStore() throws {
        let store = KeychainDatabaseKeyStore(service: "org.signalsafe.tests.\(UUID())", account: "k")
        defer { try? store.deleteKey() }
        let a = try store.loadOrCreateKey()
        #expect(a.count == 32)
        #expect(try store.loadOrCreateKey() == a)
        try store.deleteKey()
        #expect(try store.loadOrCreateKey() != a)
    }

    @Test func accountRoundTrip() throws {
        let (db, _) = try LinkedClient.temporaryDatabase()
        let account = Account(aci: UUID().uuidString.lowercased(), pni: UUID().uuidString.lowercased(), number: "+14155550123", deviceId: 3,
                              password: "pw", deviceName: "Mac", aciIdentity: .generate(), pniIdentity: .generate(),
                              aciRegistrationId: 42, pniRegistrationId: 43, profileKey: SignalCrypto.randomBytes(32), masterKey: nil,
                              accountEntropyPool: "aep", readReceipts: true)
        try db.pool.write { try account.save($0) }
        let loaded = try #require(try db.pool.read { try Account.load($0) })
        #expect(loaded.aci == account.aci && loaded.pni == account.pni && loaded.deviceId == 3 && loaded.number == "+14155550123")
        #expect(loaded.aciIdentity.publicKey == account.aciIdentity.publicKey)
        #expect(loaded.pniIdentity?.privateKey.serialize() == account.pniIdentity?.privateKey.serialize())
        #expect(loaded.pniRegistrationId == 43 && loaded.profileKey == account.profileKey && loaded.readReceipts)
        #expect(try db.pool.read { try Items.get($0, "uuid_id", as: String.self) } == "\(account.aci).3")
        #expect(try db.pool.read { try Items.get($0, "pni", as: String.self) } == "PNI:\(account.pni!)")
    }
}
