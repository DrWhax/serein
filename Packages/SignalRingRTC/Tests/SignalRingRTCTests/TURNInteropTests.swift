import CryptoKit
import Foundation
import SignalRingRTC
import Synchronization
import Testing
@testable import SwiftCalling

/// An unmodified native caller and a strict Swift callee each allocate their own relay.
/// Both exchange only relay candidates. Receiving the encrypted acceptance requires a
/// nominated pair, bidirectional TURN permissions and matching per-direction media keys.
@MainActor struct TURNInteropTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEREIN_TEST_TURN_PORT"] != nil))
    func relayOnlyNativeCall() async throws {
        let relay = try await TURNTestRelay.open()
        defer { relay.close() }
        let native = try LoopbackCallTests.Side("reference", .inProcess)
        defer { withExtendedLifetime(native) {} }
        let rtc = native.rtc
        var nativeConfirmedRelayPair = false
        rtc.handleLogMessage = { _, _, _, message in
            guard message.contains("ice_network_route_change") else { return }
            let route = message.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            nativeConfirmedRelayPair = route.contains { $0.hasPrefix("local:") && $0.contains(" typ relay") }
                && route.contains { $0.hasPrefix("remote:") && $0.contains(" typ relay") }
        }
        let caller = Data([5]) + Data(repeating: 0x11, count: 32), callee = Data([5]) + Data(repeating: 0x22, count: 32)
        let options = RingRTC.CallingMessageOptions(remoteUserId: "swift", remoteUuid: nil, remoteDeviceId: 2,
            localDeviceId: 1, ageSec: 0, receivedAtCounter: 0, receivedAtDate: 0, senderIdentityKey: callee, receiverIdentityKey: caller)
        let key = Curve25519.KeyAgreement.PrivateKey()
        var local = DirectCallParameters()
        let localUfrag = "serein", localPassword = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        local.publicKey = key.publicKey.rawRepresentation
        local.iceUfrag = localUfrag
        local.icePassword = localPassword
        local.encoders = [8]; local.decoders = [8]
        let ice = IceServer(username: "serein", password: "serein-test-relay", urls: [TURNTestRelay.peerURI])
        var remote: DirectCallParameters?, candidate: ICERelayCandidate?
        rtc.handleStartCall = { [weak rtc] call in
            rtc?.proceed(callId: call.callId, settings: .init(iceServers: [ice], hideIp: true, dataMode: .normal))
            return true
        }
        rtc.handleOutgoingSignaling = { [weak rtc] _, message in
            do {
                if let offer = message.offer {
                    remote = try DirectCallParameters(envelope: offer.opaque)
                    rtc?.handleCallingMessage(.init(answer: .init(callId: offer.callId, opaque: local.envelope())), options)
                    let only = IceCandidateUpdate(addedSDP: relay.localCandidate.sdp).envelope()
                    rtc?.handleCallingMessage(.init(iceCandidates: [.init(callId: offer.callId, opaque: only)]), options)
                }
                for change in message.iceCandidates ?? [] {
                    let update = try IceCandidateUpdate(envelope: change.opaque)
                    if update.removed == nil, let sdp = update.addedSDP {
                        let relayed = try #require(ICERelayCandidate(sdp), "Native hideIp must only advertise UDP relay candidates: \(sdp)")
                        let tokens = sdp.split(separator: " ")
                        if let index = tokens.firstIndex(of: "raddr") {
                            #expect(["0.0.0.0", "::"].contains(tokens.dropFirst(index + 1).first))
                        }
                        if candidate == nil { candidate = relayed }
                    }
                }
                return true
            } catch { Issue.record("Relay signaling failed: \(error)"); return false }
        }
        let call = try rtc.startOutgoingCall(remoteUserId: "swift", isVideoCall: false, localDeviceId: 1)
        defer { if call.state != .ended { call.hangup() } }
        await LoopbackCallTests.wait(8) { candidate != nil && remote != nil }
        let peer = try #require(candidate), params = try #require(remote)
        let path = try await relay.connect(to: peer)
        let ufrag = try #require(params.iceUfrag), password = try #require(params.icePassword)
        let pair = Mutex(try ICEHostPair(relay: path, localUfrag: localUfrag, localPassword: localPassword,
                                        remoteUfrag: ufrag, remotePassword: password, role: .controlled(127)))
        path.receive { datagram in
            if let response = try? pair.withLock({ try $0.receive(datagram, at: .now) }) { try? path.send(response) }
        }
        for _ in 0..<100 {
            if let check = try pair.withLock({ try $0.check(at: .now) }) { try path.send(check) }
            if pair.withLock({ $0.canSendMedia(at: .now) }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(pair.withLock { $0.canSendMedia(at: .now) })
        let master = try DirectCallKeys(local: key, remote: try #require(params.publicKey), callerIdentity: caller, calleeIdentity: callee)
        let outgoing = try SRTPKeyDerivation(key: master.answer.key, salt: master.answer.salt).sessionKeys(rtcp: false)
        let incoming = try SRTPKeyDerivation(key: master.offer.key, salt: master.offer.salt).sessionKeys(rtcp: false)
        var control = DirectControlStream(callID: call.callId, role: .callee, outgoing: outgoing, incoming: incoming)
        try control.accept()
        for _ in 0..<25 {
            if let packet = try control.packet() { try path.send(packet) }
            if call.state == .accepted { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(call.state == .accepted)
        #expect(nativeConfirmedRelayPair)
    }
}
