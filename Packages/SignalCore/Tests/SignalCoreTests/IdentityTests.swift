// Phase 4 step 6c: safety numbers (checked against alice's side computed by the mock's own
// libsignal), verification and its sync, usernames over the mock's Accounts gRPC services,
// key transparency's store and self-health bookkeeping.

import Foundation
import GRDB
import LibSignalClient
import SignalProtos
import Testing
@testable import SignalCore

@Suite(.serialized) struct IdentityTests {
    @Test func safetyNumbersAndVerification() async throws {
        try await LinkedClient.with { c in
            _ = try await c.receiveFromAlice("hi")   // her identity key is now stored
            let ours = try await c.messenger.safetyNumber(with: c.aliceAci)
            let wellFormed = ours.numberBlocks.count == 12 && ours.numberBlocks.allSatisfy { $0.count == 5 && $0.allSatisfy(\.isNumber) }
            #expect(wellFormed)
            let theirs = try await c.server.json("safetyNumber", ["otherAci": c.account.aci,
                                                                  "otherIdentityKey": c.account.aciIdentity.publicKey.serialize().base64EncodedString()])
            #expect(ours.numberBlocks.joined() == theirs["digits"] as? String)
            let scanned = try #require((theirs["scannable"] as? String).flatMap { Data(base64Encoded: $0) })
            let matches = try await c.messenger.matchesScannedSafetyNumber(scanned, with: c.aliceAci)
            let ownMatches = try await c.messenger.matchesScannedSafetyNumber(ours.qrData, with: c.aliceAci)
            #expect(matches && !ownMatches)   // our own code is not theirs

            try await c.messenger.setVerified(try await c.messenger.safetyNumber(with: c.aliceAci).identity, true)
            #expect(try await c.database.pool.read { try ProtocolStore.verifiedStatus($0, serviceId: c.aliceAci) } == .verified)
            let sync = try await c.server.json("waitForSyncMessage", ["kind": "verified"])
            #expect(sync["kind"] as? String == "verified")
            #expect(try await c.database.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM messages WHERE type = 'verified-change'") } == 1)

            // A Verified sync message is dropped, as upstream does: verification comes from the
            // storage service. Neither its state nor a key in it is taken.
            let alice = try await c.accountInfo("alice")
            let other = IdentityKeyPair.generate().identityKey.serialize().base64EncodedString()
            for (key, state) in [(alice.identityKey, "DEFAULT"), (other, "VERIFIED")] {
                try await c.server.callJSON("phoneSync", ["timestamp": TestClock.next(), "verified": ["destination": "alice", "identityKey": key, "state": state]])
                _ = try await c.log.waitFor("verified sync") { if case .sync("verified", _) = $0 { true } else { false } }
            }
            let row = try #require(try await c.database.pool.read { db in try ProtocolStore.identityRow(db, serviceId: c.aliceAci) })
            #expect(row.verifiedStatus == .verified && row.publicKey == alice.identityKey)
            #expect(try await c.database.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM messages WHERE type = 'keychange'") } == 0)
        }
    }

    @Test func usernames() async throws {
        try await LinkedClient.with { c in
            let usernames = UsernameService(account: c.account, database: c.database, socket: c.socket)
            await #expect(throws: UsernameError.self) { try await usernames.reserve(nickname: "x") }       // too short
            let r = try await usernames.reserve(nickname: "teapot")
            #expect(r.username.hasPrefix("teapot.") && r.hash.count == 32)
            let link = try await usernames.confirm(r)
            #expect(link.absoluteString.hasPrefix("https://signal.me/#eu/") && UsernameService.parseLink(link) != nil)
            #expect(try await c.database.pool.read { try Items.get($0, "username", as: String.self) } == r.username)
            #expect(try await usernames.lookUp(r.username) == c.account.aci)
            #expect(try await usernames.lookUp(link: link) == r.username)
            let next = try await usernames.resetLink()
            let viaNext = try await usernames.lookUp(link: next)
            #expect(next != link && viaNext == r.username)
            try await usernames.delete()
            #expect(try await usernames.lookUp(r.username) == nil)
            #expect(try await c.database.pool.read { try Items.get($0, "username", as: String.self) } == nil)
        }
    }

    @Test func keyTransparencyBookkeeping() async throws {
        try await LinkedClient.with { c in
            let kt = KeyTransparencyService(account: c.account, database: c.database, socket: c.socket)
            #expect(try await kt.isAvailable() == false)   // not enabled by remote config
            // Version-gated, as upstream: on from the prod value's version; the account setting turns it off.
            try await c.database.pool.write { db in
                try Items.set(db, "remoteConfig", ["desktop.keyTransparency.prod": RemoteConfig.Value(name: "desktop.keyTransparency.prod", enabled: true, value: "8.0.0")])
            }
            #expect(try await kt.isAvailable())
            #expect(try await kt.isAvailable(version: "7.99.0") == false)
            try await c.database.pool.write { db in try Items.set(db, "hasKeyTransparencyDisabled", true) }
            #expect(try await kt.isAvailable() == false)
            try await c.database.pool.write { db in try Items.set(db, "hasKeyTransparencyDisabled", false) }
            #expect(try await kt.isCheckable(contact: "00000000-0000-4000-8000-000000000000") == false)   // no number for them
            // The store round-trips (the client keeps opaque data there).
            let aci = try Aci.parseFrom(serviceIdString: c.aliceAci)
            await kt.store.setAccountData(Data([1, 2, 3]), for: aci)
            #expect(await kt.store.getAccountData(for: aci) == Data([1, 2, 3]))
            await kt.store.setLastDistinguishedTreeHead(to: Data([9]))
            #expect(await kt.store.getLastDistinguishedTreeHead() == Data([9]))
            // The mock server has no key transparency service: a self check records its
            // outcome without crashing and leaves no "ok".
            let health = try await kt.selfCheck()
            #expect(health != .ok)
            #expect(try await c.database.pool.read { try Items.get($0, "lastKeyTransparencySelfCheck", as: Int64.self) } != nil)
        }
    }
}
