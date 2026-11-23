import CryptoKit
import Foundation
import SwiftCallingServiceAdapter
import Testing
@testable import SignalRingRTC

@MainActor @Suite struct GroupLobbyTests {
    @Test func scopedLinkIdentitiesAndLateJoinResponse() async throws {
        let peer = try LoopbackCallTests.Side("strict", .overXPC, backend: SwiftVoiceEndpoint.factory)
        let rtc = peer.rtc
        var ended = false
        let observer = BoundaryObserver { _ in ended = true }
        let key = try CallLinkRootKey.generate().issued(epoch: 12)
        let alice = Data(repeating: 1, count: 16)
        var resolved = 0
        let call = try #require(rtc.getCallLinkCall(sfuUrl: "https://sfu.example", endorsementPublicKey: Data(), authCredentialPresentation: Data([9]),
                                                     rootKey: key, adminPasskey: Data([7]), hkdfExtraInfo: Data([8]), audioLevelsIntervalMillis: 200,
                                                     dredDuration: nil, svcConfig: nil, observer: observer, resolveMember: { bytes in
            resolved += 1
            return bytes == Data([18]) ? alice : nil
        }))
        var joinIds: [UInt32] = []
        rtc.handleSendHttpRequest = { id, url, method, headers, body in
            #expect(url == "https://sfu.example/v2/conference/participants")
            #expect(headers["Authorization"] == "Bearer auth.CQ==" && headers["X-Epoch"] == "12")
            if method == .get {
                let roster = #"{"participants":[{"demuxId":32,"opaqueUserId":"12"},{"demuxId":48,"opaqueUserId":"ff"}],"creator":"12","conferenceId":"abcd","pendingClients":[{"demuxId":80,"opaqueUserId":"12"}]}"#
                rtc.receivedHttpResponse(requestId: id, status: 200, body: Data(roster.utf8))
            } else {
                if let body, let value = try? JSONDecoder().decode(JSONValue.self, from: body) {
                    #expect(value["hkdfExtraInfo"].string == "08" && value["adminPasskey"].data == Data([7]))
                    #expect(value["dhePublicKey"].string?.utf8.count == 64 && value["icePwd"].string != nil)
                } else { Issue.record("missing join body") }
                joinIds.append(id)
            }
        }
        defer { rtc.handleSendHttpRequest = nil; call.disconnect() }
        call.connect()
        call.join()
        await LoopbackCallTests.wait(3) { call.peekInfo?.creator == alice && !joinIds.isEmpty }
        try #require(joinIds.count == 1)
        #expect(call.peekInfo?.devices.first?.userId == alice && call.peekInfo?.devices.last?.userId == nil)
        #expect(call.peekInfo?.pendingUsers == [alice] && resolved == 2)
        call.leave()
        await LoopbackCallTests.wait(3) { call.localDeviceState.joinState == .notJoined }
        let obsolete = joinIds[0]
        rtc.receivedHttpResponse(requestId: obsolete, status: 403, body: Data())
        call.join()
        await LoopbackCallTests.wait(3) { joinIds.count == 2 }
        try #require(joinIds.count == 2 && !ended)
        rtc.receivedHttpResponse(requestId: joinIds[1], status: 413, body: Data())
        await LoopbackCallTests.wait(3) { ended }
        #expect(ended)
    }

    @Test func appDoesNotAcquireMediaForPendingLink() async throws {
        let rtc = try RingRTC(endpoint: SwiftVoiceEndpoint.factory)
        let observer = BoundaryObserver { _ in }
        let key = try CallLinkRootKey.generate().issued(epoch: 1)
        let call = try #require(rtc.getCallLinkCall(sfuUrl: "https://sfu.example", endorsementPublicKey: Data(), authCredentialPresentation: Data(),
                                                     rootKey: key, adminPasskey: nil, hkdfExtraInfo: Data(), audioLevelsIntervalMillis: nil, dredDuration: nil,
                                                     svcConfig: nil, observer: observer))
        var pendingReported = false
        observer.localChanged = { current in
            if current.localDeviceState.joinState == .pending {
                pendingReported = true
                #expect(!current.sendVideoFrame(width: 2, height: 2, format: .rgba, buffer: [UInt8](repeating: 0, count: 16)))
            }
        }
        let publicKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let hex = publicKey.map { String($0 >> 4, radix: 16) + String($0 & 15, radix: 16) }.joined()
        rtc.handleSendHttpRequest = { id, _, method, _, _ in
            let reply = method == .get ? #"{"participants":[]}"# :
                "{\"demuxId\":16,\"udpAddresses\":[\"127.0.0.1:9\"],\"iceUfrag\":\"test\",\"icePwd\":\"secret\",\"dhePublicKey\":\"\(hex)\",\"conferenceId\":\"abcd\",\"clientStatus\":\"PENDING\"}"
            rtc.receivedHttpResponse(requestId: id, status: 200, body: Data(reply.utf8))
        }
        defer { rtc.handleSendHttpRequest = nil; call.disconnect() }
        call.setOutgoingAudioMuted(false)
        call.setOutgoingVideoMuted(false)
        call.connect()
        call.join()
        await LoopbackCallTests.wait(3) { pendingReported }
        #expect(pendingReported)
        #expect(!call.sendVideoFrame(width: 2, height: 2, format: .rgba, buffer: [UInt8](repeating: 0, count: 16)))
        call.leave()
        await LoopbackCallTests.wait(3) { call.localDeviceState.joinState == .notJoined }
        #expect(call.localDeviceState.joinState == .notJoined)
    }
}
