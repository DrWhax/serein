import CallService
import CallXPC
import Foundation
import MediaXPCInterface
import RingRTCNative
import Testing
import XPC
@testable import SignalRingRTC

/// Where a side's endpoint runs: in this process, or behind XPC as in the app (a listener in
/// this process running the calling service's handler, so every command, event and frame
/// crosses the wire format and the transport).
enum EndpointPlace: String, CaseIterable, Sendable {
    case inProcess, overXPC
}

/// Two endpoints call each other: signaling is handed across directly.
@MainActor
@Suite(.serialized) struct LoopbackCallTests {
    @MainActor final class Side {
        let rtc: RingRTC
        let name: String
        let listener: XPCListener?
        let handler: CallXPCHandler?
        var states: [CallState] = []
        var incoming: Call?
        init(_ name: String, _ place: EndpointPlace = .inProcess) throws {
            self.name = name
            switch place {
            case .inProcess:
                listener = nil
                handler = nil
                rtc = try RingRTC(endpoint: NativeEndpoint.factory)
            case .overXPC:
                let h = CallXPCHandler()
                let l = XPCServer.anonymous(requirement: nil, h)
                listener = l
                handler = h
                rtc = try RingRTC(endpoint: RemoteCallEndpoint.factory(.endpoint(l.endpoint), peer: nil))
            }
        }
        isolated deinit { listener?.cancel() }
    }

    static func wait(_ seconds: Double = 20, until done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
    }

    @Test(arguments: EndpointPlace.allCases) func oneToOneCall(_ place: EndpointPlace) async throws {
        let a = try Side("alice", place), b = try Side("bob", place)
        let key = Data(repeating: 5, count: 33)
        for (me, other, myId) in [(a, b, DeviceId(1)), (b, a, DeviceId(2))] {
            me.rtc.handleOutgoingSignaling = { [weak other] _, message in
                guard let other else { return false }
                other.rtc.handleCallingMessage(message, .init(remoteUserId: me.name, remoteUuid: nil, remoteDeviceId: myId, localDeviceId: myId == 1 ? 2 : 1,
                                                              ageSec: 0, receivedAtCounter: 0, receivedAtDate: 0, senderIdentityKey: key, receiverIdentityKey: key))
                return true
            }
            me.rtc.handleIncomingCall = { call in me.incoming = call; return true }
            me.rtc.handleStartCall = { call in
                call.handleStateChanged = { me.states.append(call.state) }
                me.rtc.proceed(callId: call.callId, settings: CallSettings(iceServers: [], hideIp: false, dataMode: .normal))
                return true
            }
        }
        let call = try a.rtc.startOutgoingCall(remoteUserId: "bob", isVideoCall: false, localDeviceId: 1)
        await Self.wait { b.incoming != nil && b.states.contains(.ringing) }
        let incoming = try #require(b.incoming)
        #expect(incoming.remoteUserId == "alice" && incoming.isIncoming && !incoming.isVideoCall)
        incoming.accept()
        await Self.wait { a.states.contains(.accepted) && b.states.contains(.accepted) }
        #expect(a.states.contains(.accepted) && b.states.contains(.accepted), "alice \(a.states) bob \(b.states)")
        call.hangup()
        await Self.wait { a.states.last == .ended && b.states.last == .ended }
        #expect(a.states.last == .ended && b.states.last == .ended)
        #expect(call.endedReason == .localHangup && incoming.endedReason == .remoteHangup, "\(String(describing: call.endedReason)) \(String(describing: incoming.endedReason))")
    }

    /// A video call: NV12 frames sent by one side arrive at the other as RGBA.
    @Test(arguments: EndpointPlace.allCases) func videoFramesFlow(_ place: EndpointPlace) async throws {
        let a = try Side("alice", place), b = try Side("bob", place)
        let key = Data(repeating: 5, count: 33)
        for (me, other, myId) in [(a, b, DeviceId(1)), (b, a, DeviceId(2))] {
            me.rtc.handleOutgoingSignaling = { [weak other] _, message in
                guard let other else { return false }
                other.rtc.handleCallingMessage(message, .init(remoteUserId: me.name, remoteUuid: nil, remoteDeviceId: myId, localDeviceId: myId == 1 ? 2 : 1,
                                                              ageSec: 0, receivedAtCounter: 0, receivedAtDate: 0, senderIdentityKey: key, receiverIdentityKey: key))
                return true
            }
            me.rtc.handleIncomingCall = { call in me.incoming = call; return true }
            me.rtc.handleStartCall = { call in
                call.handleStateChanged = { me.states.append(call.state) }
                me.rtc.proceed(callId: call.callId, settings: CallSettings(iceServers: [], hideIp: false, dataMode: .normal))
                return true
            }
        }
        let call = try a.rtc.startOutgoingCall(remoteUserId: "bob", isVideoCall: true, localDeviceId: 1)
        await Self.wait { b.incoming != nil && b.states.contains(.ringing) }
        let incoming = try #require(b.incoming)
        #expect(incoming.isVideoCall)
        incoming.setOutgoingVideoMuted(false)
        incoming.accept()
        await Self.wait { a.states.contains(.accepted) && b.states.contains(.accepted) }
        call.setOutgoingVideoMuted(false)

        let (w, h) = (320, 240)
        // A grey frame: Y 128, neutral chroma.
        let frame = [UInt8](repeating: 128, count: w * h) + [UInt8](repeating: 128, count: w * h / 2)
        #expect(!call.sendVideoFrame(width: w, height: h, format: .nv12, buffer: Array(frame.dropLast())), "short buffer must be refused")
        var buffer = [UInt8](repeating: 0, count: 960 * 720 * 4)
        var got: (width: Int, height: Int)?
        let end = Date().addingTimeInterval(20)
        while got == nil && Date() < end {
            #expect(call.sendVideoFrame(width: w, height: h, format: .nv12, buffer: frame))
            try await Task.sleep(for: .milliseconds(33))
            got = incoming.receiveVideoFrame(into: &buffer, maxWidth: 960, maxHeight: 720)
        }
        let size = try #require(got, "no remote frame arrived")
        #expect(size.width > 0 && size.width <= w && size.height > 0 && size.height <= h)
        // Grey in, grey out (RGBA ≈ 128 after VP8/VP9 and YUV → RGB).
        #expect(abs(Int(buffer[0]) - 128) < 24 && abs(Int(buffer[1]) - 128) < 24 && buffer[3] == 255)
        call.hangup()
        await Self.wait { a.states.last == .ended && b.states.last == .ended }
    }

    /// SFU requests go through the app's HTTP (`handleSendHttpRequest`), and the answer
    /// settles the request.
    @Test func callLinkPeekUsesAppHTTP() async throws {
        let rtc = try RingRTC(endpoint: NativeEndpoint.factory)
        var seen: [(String, HttpMethod, [String: String])] = []
        rtc.handleSendHttpRequest = { id, url, method, headers, _ in
            seen.append((url, method, headers))
            rtc.receivedHttpResponse(requestId: id, status: 404, body: Data())
        }
        // A v0 key (a fresh v1 key is invalid until the server gives it an epoch).
        let key = try CallLinkRootKey.fromBytes(Data((0 ..< 16).map { UInt8($0 * 17 % 251) }))
        let result = await rtc.peekCallLinkCall(sfuUrl: "https://sfu.example", authCredentialPresentation: Data([1, 2, 3]), rootKey: key)
        // A 404 from the SFU means "no call in progress": an empty peek.
        guard case .success(let info) = result else { Issue.record("expected an empty peek, got \(result)"); return }
        #expect(info.devices.isEmpty && info.deviceCount == 0)
        try #require(seen.count == 1)
        #expect(seen[0].0.hasPrefix("https://sfu.example") && seen[0].1 == .get)
        #expect(seen[0].2.keys.contains { $0.lowercased() == "authorization" })
    }
}
