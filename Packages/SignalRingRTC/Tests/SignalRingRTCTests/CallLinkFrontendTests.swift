import Foundation
import RingRTCNative
import SignalRingRTC
import SwiftCallingServiceAdapter
import Testing

/// Interop with Signal Calling Service's real HTTP credential verifier and link store.
@MainActor @Suite struct CallLinkFrontendTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEREIN_TEST_LINK_CREDENTIALS"] != nil))
    func swiftCreatesAndRingRTCReadsTheSameLink() async throws {
        let env = ProcessInfo.processInfo.environment
        let server = try #require(env["SEREIN_TEST_LINK_FRONTEND"].flatMap(URL.init(string:)))
        try #require(server.scheme == "http" && server.host == "127.0.0.1")
        let fixture = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: #require(env["SEREIN_TEST_LINK_CREDENTIALS"]))))
        let create = try #require(fixture["createPresentation"].data), auth = try #require(fixture["authPresentation"].data)
        let parameters = try #require(fixture["publicZkparams"].data)
        let owner = try LoopbackCallTests.Side("owner", .overXPC, backend: SwiftVoiceEndpoint.factory(devices: {
            .init(microphone: VideoTestMic(), speaker: VideoTestSpeaker())
        }), swiftVoice: true)
        defer { withExtendedLifetime(owner) {} }
        let swift = owner.rtc
        let native = try RingRTC(endpoint: NativeEndpoint.factory)
        let pass = try CallLinkRootKey.generateAdminPassKey()
        let provisional = try CallLinkRootKey.fromBytes(Data((0..<16).map(UInt8.init)) + Data([0x81, 0, 0, 0, 0]))
        for client in [swift, native] {
            client.handleSendHttpRequest = { [weak client] id, address, method, headers, body in
                guard let client, let url = URL(string: address), url.host == server.host, url.port == server.port,
                      url.scheme == "http", ["/v1/call-link", "/v2/conference/participants"].contains(url.path) else { return }
                var req = URLRequest(url: url)
                req.httpMethod = ["GET", "PUT", "POST", "DELETE"][method.rawValue]
                req.allHTTPHeaderFields = headers
                req.httpBody = body
                Task {
                    do {
                        let (data, response) = try await URLSession.shared.data(for: req)
                        client.receivedHttpResponse(requestId: id, status: (response as? HTTPURLResponse)?.statusCode ?? 500, body: data)
                    } catch { client.httpRequestFailed(requestId: id, debugInfo: nil) }
                }
            }
        }
        defer { swift.handleSendHttpRequest = nil; native.handleSendHttpRequest = nil }
        let url = server.absoluteString
        func createRoom() async -> HttpResult<CallLinkState> {
            await swift.createCallLink(sfuUrl: url, createCredentialPresentation: create, linkRootKey: provisional, adminPasskey: pass,
                                       callLinkPublicParams: parameters, restrictions: .adminApproval)
        }
        guard case .success(let link) = await createRoom() else { Issue.record("SFU rejected creation"); return }
        #expect(link.rootKey.bytes.count == 21 && link.rootKey != provisional && link.restrictions == .adminApproval)
        let key = link.rootKey
        guard case .success = await swift.updateCallLinkName(sfuUrl: url, authCredentialPresentation: auth, linkRootKey: key,
                                                             adminPasskey: pass, newName: "Music rehearsal 🎻") else { Issue.record("title update rejected"); return }
        guard case .success(let read) = await native.readCallLink(sfuUrl: url, authCredentialPresentation: auth, linkRootKey: key) else {
            Issue.record("native client could not read Swift-created link"); return
        }
        #expect(read.name == "Music rehearsal 🎻" && read.restrictions == .adminApproval)
        guard case .success(let updated) = await swift.updateCallLinkRestrictions(sfuUrl: url, authCredentialPresentation: auth,
                                                                                  linkRootKey: key, adminPasskey: pass, restrictions: .none) else {
            Issue.record("SFU rejected access update"); return
        }
        #expect(updated.restrictions == .none)
        guard case .failure = await swift.deleteCallLink(sfuUrl: url, authCredentialPresentation: auth, linkRootKey: key, adminPasskey: Data([0])) else {
            Issue.record("SFU accepted the wrong admin key"); return
        }
        guard case .success = await swift.deleteCallLink(sfuUrl: url, authCredentialPresentation: auth, linkRootKey: key, adminPasskey: pass) else {
            Issue.record("SFU rejected deletion"); return
        }
        guard case .failure = await native.readCallLink(sfuUrl: url, authCredentialPresentation: auth, linkRootKey: key) else {
            Issue.record("native client could still read the deleted call link"); return
        }
        if env["SEREIN_TEST_LINK_MEDIA"] == "1" {
            // The SFU forbids restriction changes and deletion while a room is active.
            // Recreate the fixture's room for the separate solo-call check.
            guard case .success(let solo) = await createRoom() else { Issue.record("SFU rejected solo-room creation"); return }
            try await joinEmptyRoom(swift: swift, native: native, url: url, key: solo.rootKey, auth: auth, pass: pass)
        }
    }

    private func joinEmptyRoom(swift: RingRTC, native: RingRTC, url: String, key: CallLinkRootKey, auth: Data, pass: Data) async throws {
        let observer = BoundaryObserver { _ in }
        try swift.setSelfUuid(Data(repeating: 5, count: 16))
        let call = try #require(swift.getCallLinkCall(sfuUrl: url, endorsementPublicKey: Data(), authCredentialPresentation: auth,
                                                       rootKey: key, adminPasskey: pass, hkdfExtraInfo: Data(), audioLevelsIntervalMillis: 200,
                                                       dredDuration: nil, svcConfig: nil, observer: observer))
        defer {
            call.disconnect()
            withExtendedLifetime(observer) {}
        }
        call.connect()
        call.join()
        await LoopbackCallTests.wait(10) { call.localDeviceState.joinState == .joined && call.localDeviceState.connectionState == .connected }
        try #require(call.localDeviceState.joinState == .joined)
        try #require(call.localDeviceState.connectionState == .connected)
        guard case .success(let roster) = await native.peekCallLinkCall(sfuUrl: url, authCredentialPresentation: auth, rootKey: key) else {
            Issue.record("RingRTC could not read the roster of the joined room")
            return
        }
        #expect(roster.deviceCountExcludingPendingDevices == 1)
        let demux = try #require(call.localDeviceState.demuxId)
        #expect(roster.devices.map(\.demuxId) == [demux])
    }
}
