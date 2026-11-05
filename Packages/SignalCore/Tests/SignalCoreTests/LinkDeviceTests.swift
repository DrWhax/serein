// Integration: link SignalCore as a secondary device of the mock server's phone.

import Foundation
import GRDB
import LibSignalClient
import Testing
@testable import SignalCore

@Suite(.serialized) struct LinkDeviceTests {
    @Test func linksUploadsKeysAndAuthenticates() async throws {
        let server = try await MockServerHarness.start()
        let client = try await LinkedClient.link(server, deviceName: "SignalSafe Mac", oneTimeKeys: 20)
        let ready = server.ready
        let account = client.account

        // The server is upstream's in-tree Signal-Desktop/packages/mock-server (built by
        // Tools/build-mock-server.sh), on the same libsignal release as vendor/libsignal.
        #expect(ready.mockServer.path.hasSuffix("/Tests/MockServer/.mock-server"))
        #expect(ready.mockServer.version == "27.0.0" && ready.mockServer.libsignal == "0.106.0")

        // Identity matches the primary's account.
        #expect(account.aci == ready.phone.aci.lowercased())
        #expect(account.pni == ready.phone.pni.map { $0.hasPrefix("PNI:") ? String($0.dropFirst(4)) : $0 }?.lowercased())
        #expect(account.number == ready.phone.number)
        #expect(account.deviceId > 1)
        #expect(account.pniIdentity != nil && account.profileKey?.count == 32 && account.readReceipts)

        // Account and keys persisted in the encrypted database.
        let stored = try #require(try await client.database.pool.read { try Account.load($0) })
        #expect(stored.aci == account.aci && stored.deviceId == account.deviceId && stored.password == account.password)
        let counts = try await client.database.pool.read { db in
            (try Int.fetchOne(db, sql: "SELECT count(*) FROM signedPreKeys")!,
             try Int.fetchOne(db, sql: "SELECT count(*) FROM kyberPreKeys WHERE json ->> '$.isLastResort' = 1")!,
             try Int.fetchOne(db, sql: "SELECT count(*) FROM preKeys")!,
             try Int.fetchOne(db, sql: "SELECT count(*) FROM kyberPreKeys WHERE json ->> '$.isLastResort' = 0")!)
        }
        #expect(counts.0 == 2 && counts.1 == 2 && counts.2 == 40 && counts.3 == 40)

        // The server has our one-time keys for both identities (PUT /v2/keys over the authenticated socket).
        let keys = try await server.json("keyCounts")
        // After provisioning the harness opens sessions from the phone and from alice, which
        // consumes one ACI one-time EC + Kyber key each (as Signal Desktop's test bootstrap does).
        let aci = try #require(keys["aci"] as? [String: Int])
        #expect(aci["preKeys"] == 18 && aci["kyberPreKeys"] == 18)
        if let pni = keys["pni"] as? [String: Int] { #expect(pni["preKeys"] == 20 && pni["kyberPreKeys"] == 20) }

        // The authenticated socket works with the new credentials.
        let response = try await client.socket.authenticatedRequest("GET", "/v2/keys?identity=aci")
        let json = try JSONSerialization.jsonObject(with: response) as? [String: Int]
        #expect(json?["count"] == 18)
        await client.close()
    }

    @Test func wrongPasswordIsRejected() async throws {
        let server = try await MockServerHarness.start()
        let client = try await LinkedClient.link(server, oneTimeKeys: 1)
        let net = Net.localTestServer(userAgent: "SignalSafe-Tests", chatPort: UInt16(server.ready.port),
                                      rootCertificateDer: server.ready.certificateAuthorityDER)
        let socket = SocketManager(net: net, credentials: ChatCredentials(username: client.account.credentials.username, password: "wrong"))
        // The mock accepts the upgrade and then closes the socket for bad credentials (code 3000),
        // so either the connect or the first authenticated request must fail.
        await #expect(throws: (any Error).self) {
            try await socket.connect(listener: client.receiver)
            _ = try await socket.authenticatedRequest("GET", "/v2/keys?identity=aci")
        }
        await socket.disconnect()
        await client.close()
    }
}
