import Foundation
import SignalRingRTC
import SwiftCallingServiceAdapter
import Testing

/// Signal's development SFU uses Basic auth in place of the production ZK frontend.
/// The server controls the admin role, the pending list and every admission decision.
@MainActor @Suite struct GroupAdmissionTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEREIN_TEST_SFU_APPROVAL"] == "1"))
    func approveRemoveDenyAndBlockInTheSFU() async throws {
        let server = try #require(ProcessInfo.processInfo.environment["SEREIN_TEST_SFU_URL"].flatMap(URL.init(string:)))
        try #require(server.host == "127.0.0.1")
        let key = try CallLinkSFUFixture.rootKey()
        let room = try key.deriveRoomId().map { String($0 >> 4, radix: 16) + String($0 & 15, radix: 16) }.joined()
        var observers: [BoundaryObserver] = []
        var clients: [LoopbackCallTests.Side] = []
        var calls: [GroupCall] = []
        let users: [Data] = (1...4).map { Data(repeating: UInt8($0), count: 16) }
        let ids = CallLinkSFUFixture.ids, ciphers = CallLinkSFUFixture.ciphers
        struct Issuance: Encodable { let response: Data; let members: [Data] }
        var issued: [Issuance] = []
        var sendsWhilePending: [Data] = []
        for i in ids.indices {
            let side = try LoopbackCallTests.Side(ids[i], .overXPC, backend: SwiftVoiceEndpoint.factory)
            clients.append(side)
            try side.rtc.setSelfUuid(users[i])
            side.rtc.handleSendHttpRequest = { [weak side] id, url, method, headers, body in
                guard let side, url == server.absoluteString + "/v2/conference/participants",
                      headers["X-Room-Id"] == room, headers["X-Epoch"] == "87", headers["Authorization"] == "Bearer auth.AQ==" else {
                    Issue.record("invalid call-link request")
                    side?.rtc.httpRequestFailed(requestId: id, debugInfo: nil)
                    return
                }
                var req = URLRequest(url: server.appending(path: "v2/conference/participants"))
                req.httpMethod = method == .get ? "GET" : "PUT"
                req.setValue("Basic " + Data(("test:2:" + ids[i] + ":" + room + ":1:2:3").utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = body
                Task {
                    do {
                        let (data, response) = try await URLSession.shared.data(for: req)
                        side.rtc.receivedHttpResponse(requestId: id, status: (response as? HTTPURLResponse)?.statusCode ?? 500, body: data)
                    } catch { side.rtc.httpRequestFailed(requestId: id, debugInfo: nil) }
                }
            }
            side.rtc.handleSendCallMessage = { recipient, data, _ in
                guard let target = users.firstIndex(of: recipient), target < clients.count else { return }
                if calls[i].localDeviceState.joinState == .pending { sendsWhilePending.append(data) }
                clients[target].rtc.handleCallingMessage(.init(opaque: .init(data: data)),
                    .init(remoteUserId: ids[i], remoteUuid: users[i], remoteDeviceId: 1, localDeviceId: 1, ageSec: 0,
                          receivedAtCounter: 0, receivedAtDate: 0, senderIdentityKey: Data(repeating: 2, count: 32), receiverIdentityKey: Data(repeating: 3, count: 32)))
            }
            let observer = BoundaryObserver { _ in }
            observers.append(observer)
            let call = try #require(side.rtc.getCallLinkCall(sfuUrl: server.absoluteString, endorsementPublicKey: Data(),
                authCredentialPresentation: Data([1]), rootKey: key, adminPasskey: i == 0 ? Data([9]) : nil, hkdfExtraInfo: Data(),
                audioLevelsIntervalMillis: 200, dredDuration: nil, svcConfig: nil, observer: observer, scopedLinkSignaling: true, resolveMember: { bytes in
                    ciphers.firstIndex(of: bytes).map { users[$0] }
                }))
            if i == 0 {
                call.receiveLinkEndorsements = { response, members in
                    if let response { issued.append(.init(response: response, members: members)) }
                }
            }
            calls.append(call)
        }
        defer {
            for peer in clients { peer.rtc.handleSendHttpRequest = nil; peer.rtc.handleSendCallMessage = nil }
            for call in calls { call.disconnect() }
            withExtendedLifetime(observers) {}
        }
        let admin = calls[0], guest = calls[1], denied = calls[2], removed = calls[3]
        admin.connect()
        admin.join()
        await LoopbackCallTests.wait(8) { admin.localDeviceState.connectionState == .connected && admin.localDeviceState.joinState == .joined }
        try #require(admin.localDeviceState.joinState == .joined)
        for client in [guest, denied, removed] { client.connect(); client.join() }
        await LoopbackCallTests.wait(12) { Set(admin.peekInfo?.pendingUsers ?? []) == Set(users.dropFirst()) }
        try #require(guest.localDeviceState.joinState == .pending && denied.localDeviceState.joinState == .pending)
        try #require(Set(admin.peekInfo?.pendingUsers ?? []) == Set(users.dropFirst()))
        #expect(!guest.sendVideoFrame(width: 2, height: 2, format: .rgba, buffer: [UInt8](repeating: 1, count: 16)))
        admin.approveUser(users[1])
        admin.approveUser(users[3])
        admin.denyUser(users[2])
        await LoopbackCallTests.wait(14) { guest.localDeviceState.joinState == .joined && denied.localDeviceState.joinState == .notJoined }
        try #require(guest.localDeviceState.joinState == .joined && denied.localDeviceState.joinState == .notJoined)
        await LoopbackCallTests.wait(8) { admin.remoteDeviceStates?.contains { $0.userId == users[1] && $0.mediaKeysReceived } == true }
        let joined = try #require(admin.remoteDeviceStates?.first { $0.userId == users[1] && $0.mediaKeysReceived })
        await LoopbackCallTests.wait(8) { removed.localDeviceState.joinState == .joined && admin.remoteDeviceStates?.contains { $0.userId == users[3] } == true }
        let departing = try #require(admin.remoteDeviceStates?.first { $0.userId == users[3] })
        if let path = ProcessInfo.processInfo.environment["SEREIN_TEST_SFU_ENDORSEMENTS"] {
            let guests = Set([ciphers[1], ciphers[3]])
            await LoopbackCallTests.wait(8) { guests.isSubset(of: Set(issued.flatMap(\.members))) }
            try #require(guests.isSubset(of: Set(issued.flatMap(\.members))))
            #expect(!issued.flatMap(\.members).contains(ciphers[2]))
            try JSONEncoder().encode(issued).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        admin.removeClient(departing.demuxId)
        await LoopbackCallTests.wait(8) { removed.localDeviceState.joinState == .notJoined }
        #expect(removed.localDeviceState.joinState == .notJoined)
        admin.blockClient(joined.demuxId)
        await LoopbackCallTests.wait(10) { guest.localDeviceState.joinState == .notJoined }
        #expect(guest.localDeviceState.joinState == .notJoined)
        #expect(sendsWhilePending.isEmpty)
    }
}
