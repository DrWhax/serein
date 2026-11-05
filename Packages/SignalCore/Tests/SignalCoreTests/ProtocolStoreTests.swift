import Foundation
import GRDB
import LibSignalClient
import Testing
@testable import SignalCore

/// Our GRDB-backed stores (as "bob") against libsignal's in-memory store ("alice").
@Suite struct ProtocolStoreTests {
    struct Fixture {
        let db: SignalDatabase
        let bob: ProtocolStore
        let bobKeys: KeyBundle
        let bobAddress: ProtocolAddress
        let alice = InMemorySignalProtocolStore(identity: .generate(), registrationId: 7)
        let aliceAddress: ProtocolAddress

        init() throws {
            (db, _) = try LinkedClient.temporaryDatabase()
            let identity = IdentityKeyPair.generate()
            bob = ProtocolStore(ourServiceId: UUID().uuidString.lowercased(), identity: identity, registrationId: 99)
            bobKeys = KeyBundle.generate(identity: identity, oneTimeCount: 2)
            bobAddress = try ProtocolAddress(name: bob.ourServiceId, deviceId: 2)
            aliceAddress = try ProtocolAddress(name: UUID().uuidString.lowercased(), deviceId: 1)
            try db.pool.write { [bob, bobKeys] db in try bobKeys.store(into: bob, db) }
        }

        func bundle(oneTime: Bool, lastResort: Bool = false) throws -> PreKeyBundle {
            let kyber = lastResort ? bobKeys.lastResort : bobKeys.oneTimeKyber[0]
            if oneTime {
                return try PreKeyBundle(registrationId: 99, deviceId: 2, prekeyId: bobKeys.oneTime[0].id, prekey: try bobKeys.oneTime[0].publicKey(),
                                        signedPrekeyId: bobKeys.signed.id, signedPrekey: try bobKeys.signed.publicKey(),
                                        signedPrekeySignature: bobKeys.signed.signature, identity: try bob.identityKeyPair(context: NullContext()).identityKey,
                                        kyberPrekeyId: kyber.id, kyberPrekey: try kyber.publicKey(), kyberPrekeySignature: kyber.signature)
            }
            return try PreKeyBundle(registrationId: 99, deviceId: 2, signedPrekeyId: bobKeys.signed.id, signedPrekey: try bobKeys.signed.publicKey(),
                                    signedPrekeySignature: bobKeys.signed.signature, identity: try bob.identityKeyPair(context: NullContext()).identityKey,
                                    kyberPrekeyId: kyber.id, kyberPrekey: try kyber.publicKey(), kyberPrekeySignature: kyber.signature)
        }

        func aliceEncrypt(_ text: String) throws -> CiphertextMessage {
            try signalEncrypt(message: Data(text.utf8), for: bobAddress, localAddress: aliceAddress, sessionStore: alice, identityStore: alice,
                              context: NullContext())
        }

        func bobDecrypt(_ c: CiphertextMessage, _ db: Database) throws -> Data {
            let ctx = DatabaseStoreContext(db)
            if c.messageType == .preKey {
                return try signalDecryptPreKey(message: PreKeySignalMessage(bytes: c.serialize()), from: aliceAddress, localAddress: bobAddress,
                                               sessionStore: bob, identityStore: bob, preKeyStore: bob, signedPreKeyStore: bob,
                                               kyberPreKeyStore: bob, context: ctx)
            }
            return try signalDecrypt(message: SignalMessage(bytes: c.serialize()), from: aliceAddress, to: bobAddress, sessionStore: bob,
                                     identityStore: bob, context: ctx)
        }
    }

    @Test func sessionLifecycleAndReply() throws {
        let f = try Fixture()
        try processPreKeyBundle(try f.bundle(oneTime: true), for: f.bobAddress, ourAddress: f.aliceAddress, sessionStore: f.alice,
                                identityStore: f.alice, context: NullContext())
        let first = try f.aliceEncrypt("hello bob")
        #expect(first.messageType == .preKey)
        let plain = try f.db.pool.write { try f.bobDecrypt(first, $0) }
        #expect(String(decoding: plain, as: UTF8.self) == "hello bob")

        // One-time keys are consumed; the session and alice's identity are persisted.
        try f.db.pool.read { db throws in
            let ctx = DatabaseStoreContext(db)
            #expect(throws: (any Error).self) { try f.bob.loadPreKey(id: f.bobKeys.oneTime[0].id, context: ctx) }
            #expect(throws: (any Error).self) { try f.bob.loadKyberPreKey(id: f.bobKeys.oneTimeKyber[0].id, context: ctx) }
            #expect(try f.bob.loadSession(for: f.aliceAddress, context: ctx) != nil)
            #expect(try f.bob.identity(for: f.aliceAddress, context: ctx) != nil)
        }

        // Bob replies from the stored session; alice decrypts; alice's next message is a whisper.
        let reply = try f.db.pool.write { db in
            try signalEncrypt(message: Data("hi alice".utf8), for: f.aliceAddress, localAddress: f.bobAddress, sessionStore: f.bob,
                              identityStore: f.bob, context: DatabaseStoreContext(db))
        }
        let got = try signalDecrypt(message: SignalMessage(bytes: reply.serialize()), from: f.bobAddress, to: f.aliceAddress,
                                    sessionStore: f.alice, identityStore: f.alice, context: NullContext())
        #expect(String(decoding: got, as: UTF8.self) == "hi alice")
        let second = try f.aliceEncrypt("again")
        #expect(second.messageType == .whisper)
        #expect(String(decoding: try f.db.pool.write { try f.bobDecrypt(second, $0) }, as: UTF8.self) == "again")
    }

    /// A failed transaction leaves no trace: the same ciphertext decrypts afterwards
    /// (session state was not advanced, the one-time pre-key was not consumed).
    @Test func decryptIsAtomicWithCommit() throws {
        let f = try Fixture()
        try processPreKeyBundle(try f.bundle(oneTime: true), for: f.bobAddress, ourAddress: f.aliceAddress, sessionStore: f.alice,
                                identityStore: f.alice, context: NullContext())
        let msg = try f.aliceEncrypt("atomic")
        struct PersistFailed: Error {}
        #expect(throws: PersistFailed.self) {
            try f.db.pool.write { db in
                _ = try f.bobDecrypt(msg, db)
                throw PersistFailed()  // e.g. storing the message failed
            }
        }
        try f.db.pool.read { db throws in
            #expect(try f.bob.loadSession(for: f.aliceAddress, context: DatabaseStoreContext(db)) == nil)
            #expect(try f.bob.loadPreKey(id: f.bobKeys.oneTime[0].id, context: DatabaseStoreContext(db)).id == f.bobKeys.oneTime[0].id)
        }
        #expect(String(decoding: try f.db.pool.write { try f.bobDecrypt(msg, $0) }, as: UTF8.self) == "atomic")
    }

    @Test func lastResortKyberReplayIsRejected() throws {
        let f = try Fixture()
        try processPreKeyBundle(try f.bundle(oneTime: false, lastResort: true), for: f.bobAddress, ourAddress: f.aliceAddress,
                                sessionStore: f.alice, identityStore: f.alice, context: NullContext())
        let msg = try f.aliceEncrypt("once")
        _ = try f.db.pool.write { try f.bobDecrypt(msg, $0) }
        // Drop the session so the replayed PreKey message must use the pre-keys again.
        try f.db.pool.write { try $0.execute(sql: "DELETE FROM sessions") }
        #expect(throws: (any Error).self) { _ = try f.db.pool.write { try f.bobDecrypt(msg, $0) } }
        try f.db.pool.read { db throws in
            #expect(try f.bob.loadKyberPreKey(id: f.bobKeys.lastResort.id, context: DatabaseStoreContext(db)).id == f.bobKeys.lastResort.id)
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM kyberPreKey_triples") == 1)
        }
    }

    @Test func senderKeys() throws {
        let f = try Fixture()
        let distributionId = UUID()
        let skdm = try SenderKeyDistributionMessage(from: f.aliceAddress, distributionId: distributionId, store: f.alice, context: NullContext())
        try f.db.pool.write { db in
            try processSenderKeyDistributionMessage(try SenderKeyDistributionMessage(bytes: skdm.serialize()), from: f.aliceAddress,
                                                    store: f.bob, context: DatabaseStoreContext(db))
        }
        let c = try groupEncrypt(Data("group hi".utf8), from: f.aliceAddress, distributionId: distributionId, store: f.alice, context: NullContext())
        let p = try f.db.pool.write { try groupDecrypt(c.serialize(), from: f.aliceAddress, store: f.bob, context: DatabaseStoreContext($0)) }
        #expect(String(decoding: p, as: UTF8.self) == "group hi")
        #expect(try f.db.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM senderKeys") } == 1)
    }
}
