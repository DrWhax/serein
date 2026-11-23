import CryptoKit
import Foundation
import Network
import SignalRingRTC
import Synchronization
import Testing
@testable import SwiftCalling

/// One RingRTC endpoint and one independent Swift peer exchange signaling and UDP packets.
@MainActor @Suite(.serialized) struct NativeICEInteropTests {
    @Test(arguments: DirectCallRole.allCases, EndpointPlace.allCases)
    func directCallControlAndAudioDelivery(_ role: DirectCallRole, _ place: EndpointPlace) async throws {
        try await exercise(role, place, speech: nil)
    }

    @Test func nativeRecoversMissingSwiftVideoFragmentWithULPFEC() async throws {
        try await exercise(.caller, .overXPC, speech: nil, fec: true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEREIN_SPEECH_DIR"] != nil))
    func decodedSpeech() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["SEREIN_SPEECH_DIR"])
        let role = try #require(ProcessInfo.processInfo.environment["SEREIN_SPEECH_ROLE"])
        try #require(role == "caller" || role == "callee")
        try await exercise(role == "caller" ? .caller : .callee, .overXPC,
                           speech: SpeechFixture(directory: URL(fileURLWithPath: path, isDirectory: true)))
    }

    private func exercise(_ role: DirectCallRole, _ place: EndpointPlace, speech: SpeechFixture?, fec: Bool = false) async throws {
        let native = try LoopbackCallTests.Side("reference", place)
        defer { withExtendedLifetime(native) {} }
        let rtc = native.rtc
        if speech != nil {
            try #require(rtc.getAudioInputs()?.devices.map(\.name) == ["Serein file microphone"])
            try #require(rtc.getAudioOutputs()?.devices.map(\.name) == ["Serein file speaker"])
        }
        let localKey = Curve25519.KeyAgreement.PrivateKey()
        let callerIdentity = Data([5]) + Data(repeating: 0x11, count: 32)
        let calleeIdentity = Data([5]) + Data(repeating: 0x22, count: 32)
        let options = RingRTC.CallingMessageOptions(remoteUserId: "swift", remoteUuid: nil,
            remoteDeviceId: role == .caller ? 1 : 2, localDeviceId: role == .caller ? 2 : 1,
            ageSec: 0, receivedAtCounter: 0, receivedAtDate: 0,
            senderIdentityKey: role == .caller ? callerIdentity : calleeIdentity,
            receiverIdentityKey: role == .caller ? calleeIdentity : callerIdentity)
        let localUfrag = "serein"
        let localPassword = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var local = DirectCallParameters()
        local.publicKey = localKey.publicKey.rawRepresentation
        local.iceUfrag = localUfrag
        local.icePassword = localPassword
        // The pinned peer requires a video codec in V4 even for an audio-only call.
        // This control fixture advertises VP8. It never requests or enables video.
        local.encoders = [8]
        local.decoders = [8]

        let relayOnly = speech != nil && ProcessInfo.processInfo.environment["SEREIN_SPEECH_ROUTE"] == "relay"
        var relayRoutes = 0
        var unexpectedRoutes: [String] = []
        if relayOnly {
            rtc.handleLogMessage = { _, _, _, message in
                guard message.contains("ice_network_route_change") else { return }
                let lines = message.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                // Rust also logs delivery of the route-change event. Only WebRTC's
                // detailed record contains the two selected candidate descriptions.
                let candidates = lines.filter { $0.hasPrefix("local:") || $0.hasPrefix("remote:") }
                guard !candidates.isEmpty else { return }
                if ["local:", "remote:"].allSatisfy({ prefix in
                    candidates.contains { $0.hasPrefix(prefix) && $0.contains(" typ relay") }
                }) { relayRoutes += 1 }
                else { unexpectedRoutes.append(candidates.joined(separator: " / ")) }
            }
        }
        let allocation: TURNAllocation?
        let servers: [IceServer]
        if relayOnly {
            allocation = try await TURNTestRelay.open()
            servers = [IceServer(username: "serein", password: "serein-test-relay", urls: [TURNTestRelay.peerURI])]
        } else {
            allocation = nil
            servers = []
        }
        defer { allocation?.close() }
        var peerParameters: DirectCallParameters?
        var destination: String?
        var nativeCall: Call?
        rtc.handleIncomingCall = { call in nativeCall = call; return true }
        rtc.handleStartCall = { [weak rtc] call in
            rtc?.proceed(callId: call.callId, settings: CallSettings(iceServers: servers, hideIp: relayOnly, dataMode: .normal))
            return true
        }
        rtc.handleOutgoingSignaling = { [weak rtc] _, message in
            do {
                if let offer = message.offer, role == .callee {
                    peerParameters = try DirectCallParameters(envelope: offer.opaque)
                    rtc?.handleCallingMessage(.init(answer: .init(callId: offer.callId, opaque: local.envelope())), options)
                }
                if let answer = message.answer, role == .caller {
                    peerParameters = try DirectCallParameters(envelope: answer.opaque)
                }
                for candidate in message.iceCandidates ?? [] {
                    let update = try IceCandidateUpdate(envelope: candidate.opaque)
                    if update.removed == nil, let sdp = update.addedSDP {
                        if relayOnly {
                            try #require(ICERelayCandidate(sdp) != nil, "RingRTC advertised a direct candidate in relay-only mode")
                            let fields = sdp.split(whereSeparator: \.isWhitespace)
                            if let i = fields.firstIndex(of: "raddr") {
                                try #require(["0.0.0.0", "::"].contains(fields.dropFirst(i + 1).first))
                            }
                            if let i = fields.firstIndex(of: "rport") { try #require(fields.dropFirst(i + 1).first == "0") }
                            if destination == nil { destination = sdp }
                        } else if destination == nil && ICEHostCandidate(sdp) != nil { destination = sdp }
                    }
                }
                return true
            } catch { Issue.record("Swift signaling failed: \(error)"); return false }
        }
        if role == .caller {
            let offer = OfferMessage(callId: 0x1234, type: .audioCall, opaque: local.envelope())
            rtc.handleCallingMessage(.init(offer: offer), options)
        } else {
            nativeCall = try rtc.startOutgoingCall(remoteUserId: "swift", isVideoCall: false, localDeviceId: 1)
        }
        defer { if nativeCall?.state != .ended { nativeCall?.hangup() } }
        await LoopbackCallTests.wait(5) { peerParameters != nil && destination != nil && nativeCall != nil }
        let call = try #require(nativeCall)
        let sdp = try #require(destination)
        let route: DirectICETransport.Route
        if let allocation {
            let peer = try #require(ICERelayCandidate(sdp))
            let advertised = IceCandidateUpdate(addedSDP: allocation.localCandidate.sdp)
            rtc.handleCallingMessage(.init(iceCandidates: [.init(callId: call.callId, opaque: advertised.envelope())]), options)
            route = try await .relay(allocation.connect(to: peer))
        } else {
            route = try .host(#require(ICEHostCandidate(sdp)))
        }
        let remoteKey = try #require(peerParameters?.publicKey)
        let master = try DirectCallKeys(local: localKey, remote: remoteKey, callerIdentity: callerIdentity, calleeIdentity: calleeIdentity)
        let outgoing = role == .caller ? master.offer : master.answer
        let incoming = role == .caller ? master.answer : master.offer
        let outgoingKeys = try SRTPKeyDerivation(key: outgoing.key, salt: outgoing.salt).sessionKeys(rtcp: false)
        let incomingKeys = try SRTPKeyDerivation(key: incoming.key, salt: incoming.salt).sessionKeys(rtcp: false)
        let controlStream = Mutex(DirectControlStream(callID: call.callId, role: role, outgoing: outgoingKeys, incoming: incomingKeys))
        let localAudioSSRC = role.audioSSRC
        let remoteRole: DirectCallRole = role == .caller ? .callee : .caller
        let speechReceiver = Mutex(DirectSpeechReceiver(keys: incomingKeys, remoteRole: remoteRole))
        let localControl = try SRTPKeyDerivation(key:outgoing.key,salt:outgoing.salt).sessionKeys(rtcp:true)
        let probe = fec ? NativeVideoFECProbe(role:role,incoming:incomingKeys,outgoingControl:localControl) : nil
        let audioSender = DirectOpusSender(keys: outgoingKeys, role: role, sequence: 700, transportNumbers: probe?.numbers)
        var speechSender = DirectSpeechSender(transport: audioSender)
        let reportKeys = try SRTPKeyDerivation(key: incoming.key, salt: incoming.salt).sessionKeys(rtcp: true)
        // Bundled RTCP reports for audio can originate on RingRTC's video SSRC.
        let remoteBase: UInt32 = role == .caller ? 2000 : 1000
        let reportStreams = [2, 3].map { SRTCPReceiver(keys: reportKeys, ssrc: remoteBase + UInt32($0)) }
        let audioDelivered = Mutex(false)
        let remoteUfrag = try #require(peerParameters?.iceUfrag)
        let password = try #require(peerParameters?.icePassword)
        let receivedControl = Mutex(false)
        let callID = call.callId
        let tie = UInt64.random(in: .min ... .max)
        let transport = try await DirectICETransport.connect(route: route, relayOnly: relayOnly,
            local: .init(ufrag: localUfrag, password: localPassword), remote: .init(ufrag: remoteUfrag, password: password),
            role: role == .caller ? .controlling(tie) : .controlled(tie)) { data in
                probe?.observe(data)
                if data.dropFirst().first.map({ (192...223).contains($0) }) == true {
                    for stream in reportStreams {
                        guard let plain = try? stream.open(data) else { continue }
                        probe?.observeControl(plain)
                        guard let blocks = try? RTCPReport.parse(plain) else { break }
                        if blocks.contains(where: { $0.stream == localAudioSSRC && (700..<820).contains($0.extendedHighestSequence) }) {
                            audioDelivered.withLock { $0 = true }
                        }
                        break
                    }
                } else if let speech,
                          data.dropFirst().first.map({ $0 & 0x7f }) == DirectOpusSender.payloadType {
                    do {
                        try speechReceiver.withLock { try $0.insert(data) }
                    } catch { speech.fail(error) }
                } else if let control = try? controlStream.withLock({ try $0.receive(data) }) {
                    let recognized = role == .caller ? control.acceptedID == callID :
                        control.sender?.id == callID || control.receiver?.id == callID
                    if recognized { receivedControl.withLock { $0 = true } }
                }
        }
        let playout = Task {
            guard let speech else { return }
            var deadline = ContinuousClock.now, stamp: UInt32 = 0
            while !Task.isCancelled {
                if let block = speechReceiver.withLock({ $0.render() }) {
                    speech.append(timestamp: stamp, samples: block.pcm)
                }
                stamp &+= 960
                deadline += .milliseconds(20)
                if deadline < .now { deadline = .now }
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            }
        }
        defer { playout.cancel() }
        defer { transport.close() }
        if role == .caller {
            await LoopbackCallTests.wait(4) { call.state == .ringing }
            try #require(call.state == .ringing)
            call.accept()
        }
        try controlStream.withLock {
            if role == .callee { try $0.accept() }
            try $0.setAudio(enabled: true)
            if fec { try $0.setVideo(enabled:true,screen:false) }
        }
        for _ in 0..<40 {
            let packet = try controlStream.withLock { try $0.packet() }
            let encrypted = try #require(packet)
            try transport.send(encrypted)
            try await Task.sleep(for: .milliseconds(100))
            if call.state == .accepted && call.remoteAudioEnabled && receivedControl.withLock({ $0 }) { break }
        }
        try #require(call.state == .accepted && call.remoteAudioEnabled, "RingRTC must apply Swift's encrypted control state")
        if let probe {
            try await sendDamagedVideo(to:call, transport:transport, role:role, keys:outgoingKeys)
            try await checkNativeParity(from:call,probe:probe,transport:transport)
        }
        if speech != nil { call.setOutgoingAudioMuted(false) }
        #expect(receivedControl.withLock { $0 }, "Swift must authenticate RingRTC's control state")
        // 60 ms of mono silence encoded by this WebRTC archive's libopus. The native
        // reception report identifies the specific stream and sequence numbers it received.
        let silence = Data(callingTestBytes("""
        7b8336360be4c136f8455dea51258bd59e5d2bca005a63ec0000234924f4000042800000000000000000000000000000
        02af467c136def72400007c979c8c957c0a21223dc7964012504002d7a1c00000e4924e4000049000000000000000000
        00000000000002e99e1b021bfa98300007c979c8c957c0a21223faef67f3415f28000bca1bc600005a5bea000000e400
        00000000000000000000000000000075ae54853c4aa67000
        """))
        let samples = try OpusPacket(silence).sampleCount
        try #require(samples == 2880)
        let start = ContinuousClock.now
        for index in UInt32(0)..<120 {
            let audio: Data?
            if let speech {
                audio = try speechSender.seal(speech.block(Int(index)), talkspurt: index == 0)
            } else {
                audio = try audioSender.seal(silence, talkspurt: index == 0)
            }
            if let audio { try transport.send(audio) }
            try await Task.sleep(until: start.advanced(by: .milliseconds(Int(index + 1) * 60)), clock: .continuous)
            if speech == nil && audioDelivered.withLock({ $0 }) && probe?.acknowledged != false { break }
        }
        if let probe { #expect(probe.acknowledged, "Native transport feedback must acknowledge Swift’s numbered RTP fragments") }
        if speech == nil {
            #expect(audioDelivered.withLock { $0 }, "RingRTC must confirm receipt of the Swift audio stream over SRTCP")
        }
        try controlStream.withLock { try $0.hangup() }
        for _ in 0..<20 {
            let packet = try controlStream.withLock { try $0.packet() }
            let encrypted = try #require(packet)
            try transport.send(encrypted)
            try await Task.sleep(for: .milliseconds(100))
            if call.state == .ended { break }
        }
        #expect(call.state == .ended && call.endedReason == .remoteHangup)
        if relayOnly {
            #expect(relayRoutes > 0, "RingRTC must independently confirm the selected relay pair")
            #expect(unexpectedRoutes.isEmpty)
        }
        try speech?.verify(route: "\(relayOnly ? "TURN" : "direct") Swift \(role)")
    }
    private func checkNativeParity(from call: Call, probe: NativeVideoFECProbe, transport: DirectICETransport) async throws {
        call.setOutgoingVideoMuted(false)
        defer { call.setOutgoingVideoMuted(true) }
        let width = 640, height = 360
        var pixels = [UInt8](repeating:128,count:width*height*3/2)
        let started = ContinuousClock.now
        var index = 0
        while started.duration(to:.now) < .seconds(10), !probe.matched {
            for y in 0..<height {
                for x in 0..<width { pixels[y*width+x] = UInt8(24+((x/6+y/7+index*3)%200)) }
            }
            _ = call.sendVideoFrame(width:width,height:height,format:.i420,buffer:pixels)
            if index.isMultiple(of:3) { try probe.feedback(to:transport) }
            index += 1
            try await Task.sleep(for:.milliseconds(35))
        }
        print("Reverse ULPFEC:", probe.observed)
        #expect(probe.matched, "Swift must reproduce a withheld native fragment byte for byte from native-generated parity; \(probe.observed)")
    }

    /// One isolated native decoder gets only three quarters of each keyframe.
    /// No RTX is supplied. Only the Swift-generated ULPFEC packet can supply
    /// the absent bytes. Validate the independent vpxenc picture's two halves.
    private func sendDamagedVideo(to call: Call, transport: DirectICETransport, role: DirectCallRole, keys: SRTPKeys) async throws {
        let picture = callingTestBytes("7003009d012a60004000004708858588858488020200068e4fbf71cf341d6640a079cd2d00feff555b3fb41d00")
        let sender = SRTPSender(keys:keys,ssrc:role.videoSSRC,startingAt:500)
        var parity = VideoFEC.Generator(), seq: UInt16 = 500
        var pixels = [UInt8](repeating:0,count:96*64*4)
        for index in 0..<20 {
            let timestamp = UInt32(9000+4500*index)
            for i in 0..<4 {
                let start = picture.count*i/4, end = picture.count*(i+1)/4
                var data = Data([i == 0 ? 0x10 : 0])
                data.append(contentsOf:picture[start..<end])
                let packet = RTPPayload(type:108,timestamp:timestamp,sequence:seq,marker:i == 3,rotation:0,transportNumber:nil,
                                        bytes:data,protectedHeader:.init(flags:0,tail:[]))
                let piece = try #require(VideoFEC.Piece(packet))
                let red = try sender.seal(Data([108])+data,type:120,timestamp:timestamp,marker:i == 3)
                seq &+= 1
                if i != 1 { try transport.send(red) }
                if let repair = parity.add(piece,count:4) {
                    try transport.send(sender.seal(Data([122])+repair,type:120,timestamp:timestamp))
                    seq &+= 1
                }
            }
            try await Task.sleep(for:.milliseconds(60))
            if let size = call.receiveVideoFrame(into:&pixels,maxWidth:96,maxHeight:64), size.width == 96, size.height == 64,
               Int(pixels[(32*96+72)*4]) - Int(pixels[(32*96+24)*4]) > 100 { return }
        }
        Issue.record("Native RingRTC failed to recover the withheld fragment using Swift ULPFEC")
    }

}
