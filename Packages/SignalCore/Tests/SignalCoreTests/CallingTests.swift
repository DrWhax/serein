// Calling (Phase 6): CallMessage ↔ ringrtc CallingMessage, call-history syncs through the
// receive pipeline, and call links, ICE relays and group membership proofs against the
// mock server (which also plays the SFU's call-link API).

import Foundation
import GRDB
import LibSignalClient
import SignalProtos
import SignalRingRTC
import Testing
import CryptoKit
@testable import SignalCore

@Suite(.serialized) struct CallingTests {
    @MainActor @Test func callingMessageProtoRoundTrip() {
        let m = CallingMessage(offer: OfferMessage(callId: 0xFFFF_0000_1234, type: .videoCall, opaque: Data([1, 2, 3])),
                               iceCandidates: [IceCandidateMessage(callId: 7, opaque: Data([9])), IceCandidateMessage(callId: 7, opaque: Data([8]))],
                               hangup: HangupMessage(callId: 7, type: .needPermission, deviceId: 3), opaque: OpaqueMessage(data: Data([4])),
                               destinationDeviceId: 2)
        let p = CallingService.proto(m, urgency: .handleImmediately)
        #expect(p.offer.id == 0xFFFF_0000_1234 && p.offer.type == .offerVideoCall && p.offer.opaque == Data([1, 2, 3]))
        #expect(p.iceUpdate.count == 2 && p.hangup.type == .hangupNeedPermission && p.hangup.deviceID == 3)
        #expect(p.opaque.urgency == .handleImmediately && p.opaque.data == Data([4]) && p.destinationDeviceID == 2)
        #expect(CallingService.callingMessage(p) == m)

        // Fields without a call id or opaque bytes are dropped, as upstream does.
        var bad = Signalservice_CallMessage()
        bad.offer.id = 5
        bad.iceUpdate = [Signalservice_CallMessage.IceUpdate()]
        bad.busy.id = 0
        let parsed = CallingService.callingMessage(bad)
        #expect(parsed.offer == nil && parsed.iceCandidates == nil && parsed.busy == nil)
    }

    @Test func iceServerListFromRelays() throws {
        let json = #"{"relays":[{"urls":["turn:a.example"],"urlsWithIps":["turn:1.2.3.4"],"hostname":"a.example","username":"u","password":"p","ttl":86400}]}"#
        let r = try JSONDecoder().decode(CallingService.RelaysResponse.self, from: Data(json.utf8))
        let servers = CallingService.iceServers(r)
        #expect(servers == [IceServer(username: "u", password: "p", hostname: "a.example", urls: ["turn:1.2.3.4"]),
                            IceServer(username: "u", password: "p", hostname: "", urls: ["turn:a.example"])])
    }

    /// Optional resources: verified by size and SHA-512, cached on disk, refetched when the
    /// cached copy no longer matches, rejected when the download does not match.
    @Test func optionalResourceVerification() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("signalsafe-optional-\(UUID())")
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("signalsafe-remote-\(UUID()).bin")
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: src) }
        let payload = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try payload.write(to: src)
        let digest = Data(SHA512Digest(payload)).base64EncodedString()
        let good = OptionalResource(name: "x.bin", url: src, size: payload.count, digest: digest)
        let store = OptionalResources(directory: dir)
        #expect(try await store.data(for: good) == payload)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("x.bin").path))
        // A corrupted cache is ignored and replaced by a fresh, verified copy.
        try Data([1, 2, 3]).write(to: dir.appendingPathComponent("x.bin"))
        #expect(try await OptionalResources(directory: dir).data(for: good) == payload)
        let bad = OptionalResource(name: "y.bin", url: src, size: payload.count, digest: Data(repeating: 0, count: 64).base64EncodedString())
        await #expect(throws: OptionalResourceError.invalidRemoteResource("y.bin")) { try await store.data(for: bad) }
        #expect(!OptionalResource(name: "z", url: src, size: payload.count + 1, digest: digest).matches(payload))
        #expect(OptionalResource.callingDredWeights.size == 1_998_208)
    }

    /// CallEvent and CallLogEvent syncs from the phone update call history; a CallLinkUpdate
    /// records the link and queues its refresh.
    @Test func callSyncsFromPhone() async throws {
        try await LinkedClient.with { c in
            let callId: UInt64 = 0x1234_5678_9ABC
            let alice = c.aliceAci
            let now = UInt64(Date().timeIntervalSince1970 * 1000)
            _ = try await c.server.call("phoneSync", ["timestamp": now, "callEvent": [
                "conversationId": UUID(uuidString: alice)!.data.base64EncodedString(), "callId": String(callId), "timestamp": now - 5000,
                "type": "AUDIO_CALL", "direction": "INCOMING", "event": "ACCEPTED"] as [String: any Sendable]])
            try await c.eventually("call history row") { db in
                try String.fetchOne(db, sql: "SELECT status FROM callsHistory WHERE callId = ?", arguments: [String(callId)]) == "Accepted"
            }
            try await c.eventually("call-history message") { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM messages WHERE type = 'call-history' AND callId = ?", arguments: [String(callId)]) == 1
            }

            _ = try await c.server.call("phoneSync", ["timestamp": now + 1, "callLogEvent": ["type": "CLEAR", "timestamp": now] as [String: any Sendable]])
            try await c.eventually("history cleared") { db in
                try String.fetchOne(db, sql: "SELECT status FROM callsHistory WHERE callId = ?", arguments: [String(callId)]) == "Deleted"
                    && (try Int.fetchOne(db, sql: "SELECT count(*) FROM messages WHERE type = 'call-history'") ?? -1) == 0
            }

            let rootKey = Data((0..<16).map { UInt8($0) })
            let admin = Data(repeating: 7, count: 32)
            _ = try await c.server.call("phoneSync", ["timestamp": now + 2, "callLinkUpdate": [
                "rootKey": rootKey.base64EncodedString(), "adminPasskey": admin.base64EncodedString()] as [String: any Sendable]])
            let roomId = try CallLinkStore.roomId(rootKey: rootKey)
            try await c.eventually("call link recorded") { db in
                try CallLinkStore.get(db, roomId: roomId)?.adminKey == admin
                    && (try Int.fetchOne(db, sql: "SELECT count(*) FROM callsHistory WHERE peerId = ? AND mode = 'Adhoc'", arguments: [roomId]) ?? 0) == 1
            }
        }
    }

    /// Creating, reading, renaming and deleting a call link through ringrtc → our HTTP →
    /// the mock SFU, with the zkgroup credentials from the chat server.
    @Test func callLinksAgainstMockServer() async throws {
        try await LinkedClient.with { c in
            let http = HTTPClient(rootCertificatesDER: c.endpoints.rootCertificatesDER)
            let groupsAPI = GroupsAPI(http: http, endpoints: c.endpoints, credentials: c.groupCredentials)
            let sfu = URL(string: "https://localhost:\(c.server.ready.port)/callingService")!
            let calling = try await MainActor.run {
                try CallingService(account: c.account, database: c.database, socket: c.socket, http: http, messenger: c.messenger, groups: groupsAPI,
                                   credentials: c.groupCredentials, config: CallingConfig(sfuURL: sfu))
            }

            let link = try await calling.createCallLink()
            #expect(link.adminKey?.isEmpty == false && !link.revoked && link.roomId.count == 64)
            let stored = try await c.database.pool.read { db in try CallLinkStore.get(db, roomId: link.roomId) }
            #expect(stored?.adminKey == link.adminKey)
            let sync = try await c.server.json("waitForSyncMessage", ["kind": "callLinkUpdate"])
            #expect((sync["callLinkUpdate"] as? [String: Any])?["rootKey"] as? String == link.rootKey.base64EncodedString())

            let rootKey = try CallLinkRootKey.fromBytes(link.rootKey)
            let read = try await calling.readCallLink(rootKey: rootKey)
            #expect(read != nil && read?.revoked == false)

            let renamed = try await calling.updateCallLinkName(link, name: "Book club")
            #expect(renamed.name == "Book club")
            let name = try await c.database.pool.read { db in try CallLinkStore.get(db, roomId: link.roomId)?.name }
            #expect(name == "Book club")

            // The refresh job (a link learned from a sync or storage) re-reads the SFU state.
            try await c.database.pool.write { db in try db.execute(sql: "DELETE FROM callLinks WHERE roomId = ?", arguments: [link.roomId]) }
            try await calling.refreshCallLink(CallLinkRefreshJob(rootKey: link.rootKey.base64EncodedString(), adminKey: link.adminKey?.base64EncodedString(),
                                                                 source: "test"))
            let refreshed = try await c.database.pool.read { db in try CallLinkStore.get(db, roomId: link.roomId) }
            #expect(refreshed?.name == "Book club" && refreshed?.adminKey == link.adminKey)

            try await calling.deleteCallLink(link)
            let deleted = try await c.database.pool.read { db in try CallLinkStore.get(db, roomId: link.roomId) }
            #expect(deleted?.deleted == true && deleted?.deletedAt != nil)
            #expect(try await calling.readCallLink(rootKey: rootKey) == nil)
        }
    }

    @Test func relaysAndMembershipProof() async throws {
        try await LinkedClient.with { c in
            let http = HTTPClient(rootCertificatesDER: c.endpoints.rootCertificatesDER)
            let groupsAPI = GroupsAPI(http: http, endpoints: c.endpoints, credentials: c.groupCredentials)
            let calling = try await MainActor.run {
                try CallingService(account: c.account, database: c.database, socket: c.socket, http: http, messenger: c.messenger, groups: groupsAPI,
                                   credentials: c.groupCredentials, config: CallingConfig(sfuURL: URL(string: "https://localhost:\(c.server.ready.port)/callingService")!))
            }
            let servers = await calling.iceServers()
            #expect(servers.count >= 2 && servers.allSatisfy { !$0.urls.isEmpty || $0.hostname == "" })

            let g = try await c.server.json("createGroup", ["title": "Calls"])
            let keys = try GroupKeys(masterKey: Data(base64Encoded: g["masterKey"] as! String)!)
            let proof = try await groupsAPI.membershipProof(keys)
            #expect(!proof.isEmpty && String(data: proof, encoding: .utf8) != nil)
        }
    }
}

private func SHA512Digest(_ d: Data) -> [UInt8] { Array(SHA512.hash(data: d))
}

/// The Calls tab groups consecutive calls with the same peer, type, direction and status within
/// four hours; deleted calls are left out.
@Suite struct CallHistoryGroupTests {
    @Sendable static func call(_ id: String, _ peer: String, _ t: Int64, _ status: CallStatus, _ dir: CallDirection = .incoming) -> CallHistoryDetails {
        CallHistoryDetails(details: CallDetails(callId: id, peerId: peer, ringerId: nil, startedById: nil, mode: .direct, type: .audio,
                                                direction: dir, timestamp: t), status: status)
    }

    @Test func callHistoryGroups() async throws {
        try await LinkedClient.with { c in
            let h: Int64 = 3_600_000
            try await c.database.pool.write { db in
                for x in [Self.call("1", "a", 10 * h, .missed), Self.call("2", "a", 9 * h, .missed), Self.call("3", "a", 3 * h, .missed),
                          Self.call("4", "b", 2 * h, .accepted, .outgoing), Self.call("5", "a", 1 * h, .deleted)] {
                    try CallHistoryStore.save(db, x)
                }
            }
            let groups = try await c.database.pool.read { try CallHistoryStore.groups($0) }
            #expect(groups.map { $0.calls.map(\.callId) } == [["1", "2"], ["3"], ["4"]])
            #expect(groups[0].status == .missed && groups[0].timestamp == 10 * h && groups[2].direction == .outgoing)
        }
    }
}
