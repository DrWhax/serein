import Foundation
import SignalRingRTC
import SwiftCalling
import SwiftCallingServiceAdapter
import Testing

actor VideoTestMic: VoiceCallMicrophone {
    func start() -> AsyncStream<[Int16]> { AsyncStream { _ in } }
    func stop() {}
}
actor VideoTestSpeaker: VoiceCallSpeaker {
    func start() {}
    func enqueue(_ samples: [Int16], timestamp: UInt32) {}
    func stop() {}
}

@MainActor @Suite(.serialized) struct DirectVideoInteropTests {
    @Test(arguments: [true, false], [true, false]) func twoWayVideo(swiftCalls: Bool, vp9: Bool) async throws {
        let strict = try LoopbackCallTests.Side("swift", .overXPC, backend: SwiftVoiceEndpoint.factory(devices: {
            .init(microphone: VideoTestMic(), speaker: VideoTestSpeaker())
        }))
        let native = try LoopbackCallTests.Side("native", .overXPC)
        let uri = ProcessInfo.processInfo.environment["SEREIN_TEST_TURN_URI"]
        let servers = uri.map { [IceServer(username: "serein", password: "serein-test-relay", urls: [$0])] } ?? []
        let asymmetric = ProcessInfo.processInfo.environment["SEREIN_TEST_ASYMMETRIC_TURN"] == "1"
        if asymmetric { try #require(uri != nil) }
        let impair = ProcessInfo.processInfo.environment["SEREIN_TEST_VIDEO_LOSS"] == "1"
        let proxy = try impair ? VideoLossProxy() : nil
        if let proxy {
            try #require(uri == nil)
            await LoopbackCallTests.wait(3) { proxy.port != nil }
            try #require(proxy.port != nil)
        }
        defer { proxy?.close() }
        var verifiedRelay = false
        native.rtc.handleLogMessage = { _, _, _, message in
            guard uri != nil, message.contains("ice_network_route_change") else { return }
            if ProcessInfo.processInfo.environment["SEREIN_TEST_NATIVE_LOG"] == "1" { print(message) }
            // The selected pair may label the locally relayed address peer-reflexive
            // after a triggered check; RingRTC reports the underlying port separately.
            if message.contains("local_relayed: true"),
               message.contains(asymmetric ? "remote_relayed: false" : "remote_relayed: true") { verifiedRelay = true }
        }
        let caller = swiftCalls ? strict : native, callee = swiftCalls ? native : strict
        for (me, other, id) in [(caller, callee, DeviceId(1)), (callee, caller, DeviceId(2))] {
            let otherID: DeviceId = id == 1 ? 2 : 1
            me.rtc.handleOutgoingSignaling = { [weak other] _, original in
                guard let other else { return false }
                var message = original
                if let bytes = message.offer?.opaque ?? message.answer?.opaque {
                    guard var parameters = try? DirectCallParameters(envelope: bytes) else { return false }
                    let codec: UInt64 = vp9 ? 9 : 8
                    guard parameters.encoders.contains(codec), parameters.decoders.contains(codec) else {
                        Issue.record("Endpoint did not advertise the required video codec")
                        return false
                    }
                    // Require an exclusive codec match so a passing picture cannot come from fallback.
                    parameters.encoders = [codec]
                    parameters.decoders = [codec]
                    if message.offer != nil { message.offer?.opaque = parameters.envelope() }
                    else { message.answer?.opaque = parameters.envelope() }
                }
                if asymmetric, let candidates = message.iceCandidates {
                    // Coturn models a one-to-one NAT entirely on loopback. Stock RingRTC
                    // sees the public mapping; the directly connected Swift peer sees localhost.
                    message.iceCandidates = candidates.compactMap { entry in
                        guard let update = try? IceCandidateUpdate(envelope: entry.opaque), let sdp = update.addedSDP,
                              update.removed == nil else { return nil }
                        var fields = sdp.split(separator: " ").map(String.init)
                        guard fields.count >= 8, fields[2].lowercased() == "udp" else { return nil }
                        if me === native {
                            guard fields[7] == "relay", fields[4] == "192.0.2.1" else {
                                Issue.record("Forced-relay native endpoint advertised a direct address")
                                return nil
                            }
                            fields[4] = "127.0.0.1"
                        } else {
                            guard fields[7] == "host", !fields[4].contains(":") else { return nil }
                            fields[4] = "192.0.2.1"
                            fields[7] = "srflx"
                        }
                        return IceCandidateMessage(callId: entry.callId, opaque: IceCandidateUpdate(addedSDP: fields.joined(separator: " ")).envelope())
                    }
                    if message.iceCandidates?.isEmpty == true { return true }
                }
                if let proxy, let candidates = message.iceCandidates {
                    message.iceCandidates = me === native ? candidates.compactMap(proxy.substitute) : []
                    if message.iceCandidates?.isEmpty == true { return true }
                }
                other.rtc.handleCallingMessage(message, .init(remoteUserId: me.name, remoteUuid: nil, remoteDeviceId: id,
                    localDeviceId: otherID, ageSec: 0, receivedAtCounter: 0, receivedAtDate: 0,
                    senderIdentityKey: Data(repeating: UInt8(id), count: 32), receiverIdentityKey: Data(repeating: UInt8(otherID), count: 32)))
                return true
            }
            me.rtc.handleIncomingCall = { call in me.incoming = call; return true }
            me.rtc.handleStartCall = { call in
                call.handleStateChanged = { me.states.append(call.state) }
                let relay = uri != nil && (!asymmetric || me === native)
                me.rtc.proceed(callId: call.callId, settings: .init(iceServers: relay ? servers : [], hideIp: relay, dataMode: .normal,
                                                                    enableVp9Encode: vp9, enableVp9Decode: vp9))
                return true
            }
        }
        defer {
            strict.handler?.sessionEnded()
            for side in [strict, native] {
                side.rtc.handleOutgoingSignaling = nil
                side.rtc.handleIncomingCall = nil
                side.rtc.handleStartCall = nil
                side.rtc.call?.handleStateChanged = nil
            }
        }
        // Also exercise enabling video during a call that began as audio.
        let outgoing = try caller.rtc.startOutgoingCall(remoteUserId: callee.name, isVideoCall: swiftCalls, localDeviceId: 1)
        await LoopbackCallTests.wait { callee.states.contains(.ringing) }
        let incoming = try #require(callee.incoming)
        outgoing.setOutgoingAudioMuted(true)
        incoming.setOutgoingAudioMuted(true)
        incoming.accept()
        await LoopbackCallTests.wait { outgoing.state == .accepted && incoming.state == .accepted }
        try #require(outgoing.state == .accepted && incoming.state == .accepted)
        let a = swiftCalls ? outgoing : incoming, b = swiftCalls ? incoming : outgoing
        a.setOutgoingVideoMuted(false)
        b.setOutgoingVideoMuted(false)
        let w = 192, h = 128
        for second in [false, true] {
            a.setOutgoingVideoIsScreenShare(second)
            b.setOutgoingVideoIsScreenShare(second)
            // Compare both halves and invert them mid-call. A decoder replaying the
            // first keyframe or a sender substituting a flat picture fails here.
            let aY = Self.luma(w, h, inverted: second), bY = Self.luma(w, h, inverted: !second)
            let aFrame = aY + Array(repeating: UInt8(128), count: w*h/2)
            let bFrame = bY + Array(repeating: UInt8(128), count: w*h/2)
            var atA = false, atB = false
            var buffer = [UInt8](repeating: 0, count: w*h*4)
            let end = ContinuousClock.now + .seconds(12)
            while ContinuousClock.now < end, !(atA && atB && a.remoteSharingScreen == second && b.remoteSharingScreen == second && (!second || proxy?.repairedBothDirections != false)) {
                _ = a.sendVideoFrame(width: w, height: h, format: .i420, buffer: aFrame)
                _ = b.sendVideoFrame(width: w, height: h, format: .nv12, buffer: bFrame)
                try await Task.sleep(for: .milliseconds(50))
                if let size = a.receiveVideoFrame(into: &buffer, maxWidth: w, maxHeight: h) {
                    atA = atA || Self.matches(buffer, size, inverted: !second)
                }
                if let size = b.receiveVideoFrame(into: &buffer, maxWidth: w, maxHeight: h) {
                    atB = atB || Self.matches(buffer, size, inverted: second)
                }
            }
            try #require(atA && atB, "screen=\(second) native → Swift=\(atA) Swift → native=\(atB)")
            #expect(a.remoteVideoEnabled && b.remoteVideoEnabled)
            #expect(a.remoteSharingScreen == second && b.remoteSharingScreen == second)
        }
        if swiftCalls, vp9, uri == nil, !impair {
            // Native must trust the transport feedback Swift returns for the video it receives. With
            // feedback it ignored (media source SSRC 0), its bandwidth estimate fell 20% a second to
            // its 63.6 kbps floor: busy 640x480 came at 0.5 fps here (a stock client sent Serein a few
            // tens of kbps); trusted, it comes at ~17 fps, as native to native. Frames received in
            // the last five of ten seconds of busy pictures.
            let width = 640, height = 480
            var frame = [UInt8](repeating: 128, count: width*height*3/2), seed: UInt32 = 1, tick = 0
            var buffer = [UInt8](repeating: 0, count: width*height*4)
            let start = ContinuousClock.now
            var received = 0
            while ContinuousClock.now < start + .seconds(10) {
                for i in 0..<(width*height) {
                    seed = seed &* 1664525 &+ 1013904223
                    frame[i] = UInt8(truncatingIfNeeded: (i % width + tick*3) ^ (i / width) &+ Int(seed >> 28))
                }
                _ = b.sendVideoFrame(width: width, height: height, format: .i420, buffer: frame)
                if a.receiveVideoFrame(into: &buffer, maxWidth: width, maxHeight: height) != nil,
                   ContinuousClock.now >= start + .seconds(5) { received += 1 }
                tick += 1
                try await Task.sleep(for: .milliseconds(33))
            }
            #expect(received >= 40, "Swift received \(received) pictures of native's busy video in 5 s")
        }
        if !vp9, swiftCalls, ProcessInfo.processInfo.environment["SEREIN_TEST_SCREEN_RESOLUTION"] == "1" {
            let width = 2880, height = 1800
            var frame = [UInt8](repeating:128, count:width*height*3/2)
            for row in 0..<height {
                for col in 0..<width { frame[row*width+col] = col < width/2 ? 40 : 200 }
            }
            var buffer = [UInt8](repeating:0,count:width*height*4)
            var decoded = false
            let deadline = ContinuousClock.now + .seconds(20)
            while !decoded, ContinuousClock.now < deadline {
                _ = a.sendVideoFrame(width:width,height:height,format:.i420,buffer:frame)
                try await Task.sleep(for:.milliseconds(200))
                if let size = b.receiveVideoFrame(into:&buffer,maxWidth:width,maxHeight:height) {
                    decoded = size.width == width && size.height == height && Self.matches(buffer,size,inverted:false)
                }
            }
            #expect(decoded, "Native RingRTC must display Serein’s full-resolution screen share")
        }
        if swiftCalls, vp9, uri == nil, !impair {
            // The raw 2880×1800 source exceeds the VP9 assembly bound at normal
            // quality. A real peer must display both the adapted share and a change.
            let width = 2880, height = 1800
            var buffer = [UInt8](repeating: 0, count: width*height*4)
            for inverted in [true, false] {
                let frame = detailedTestScreen(width: width, height: height, inverted: inverted)
                var decoded = false
                let deadline = SuspendingClock.now + .seconds(20)
                while !decoded, SuspendingClock.now < deadline {
                    _ = a.sendVideoFrame(width: width, height: height, format: .i420, buffer: frame)
                    try await Task.sleep(for: .milliseconds(200))
                    if let size = b.receiveVideoFrame(into: &buffer, maxWidth: width, maxHeight: height),
                       size.width > w, size.height > h {
                        decoded = Self.matches(buffer, size, inverted: inverted)
                        if decoded { print("Native decoded detailed VP9 share", size, "inverted", inverted) }
                    }
                }
                try #require(decoded, "Native RingRTC must display both versions of the detailed VP9 screen share")
            }
        }
        if uri != nil { #expect(verifiedRelay) }
        if let proxy {
            await LoopbackCallTests.wait(2) { proxy.reportedTransportFeedback }
            #expect(proxy.reportedTransportFeedback, "Swift must return transport-CC feedback for native RTP")
            print("Video repair directions", proxy.evidence)
            #expect(proxy.repairedBothDirections, "Expected bidirectional RTX across the induced loss: \(proxy.evidence)")
        }
        a.setOutgoingVideoMuted(true)
        await LoopbackCallTests.wait { !b.remoteVideoEnabled }
        #expect(!b.remoteVideoEnabled)
        outgoing.hangup()
        await LoopbackCallTests.wait { outgoing.state == .ended && incoming.state == .ended }
        #expect(outgoing.state == .ended && incoming.state == .ended)
    }

    private static func luma(_ w: Int, _ h: Int, inverted: Bool) -> [UInt8] {
        (0..<w*h).map { index -> UInt8 in
            let x = index % w, y = index / w
            let bright = (x >= w/2) != inverted
            return UInt8((bright ? 175 : 36) + ((x/3 ^ y/3) & 31))
        }
    }

    private static func matches(_ rgba: [UInt8], _ size: (width: Int, height: Int), inverted: Bool) -> Bool {
        let mid = size.height / 2 * size.width
        let left = (mid + size.width / 4) * 4, right = (mid + size.width*3 / 4) * 4
        guard rgba[left+3] == 255 && rgba[right+3] == 255 else { return false }
        let difference = Int(rgba[right]) - Int(rgba[left])
        return inverted ? difference < -70 : difference > 70
    }
}
