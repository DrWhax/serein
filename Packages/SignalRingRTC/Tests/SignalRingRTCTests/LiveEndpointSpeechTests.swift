import Foundation
import SignalRingRTC
import SwiftCalling
import SwiftCallingServiceAdapter
import Testing

/// Feed the same 20 ms PCM blocks the hardware tap supplies, on its ordinary clock.
actor PhraseMicrophone: VoiceCallMicrophone {
    let fixture: SpeechFixture
    private var pump: Task<Void, Never>?
    private(set) var starts = 0
    private(set) var stops = 0

    init(_ fixture: SpeechFixture) { self.fixture = fixture }

    func start() -> AsyncStream<[Int16]> {
        starts += 1
        let stream = AsyncStream<[Int16]>.makeStream(bufferingPolicy: .bufferingNewest(4))
        pump = Task { [fixture] in
            var index = 0
            let start = ContinuousClock.now
            defer { stream.continuation.finish() }
            while !Task.isCancelled {
                let block = fixture.block(index)
                for i in 0..<3 {
                    guard !Task.isCancelled else { return }
                    stream.continuation.yield(Array(block[i * 960..<(i + 1) * 960]))
                    do { try await Task.sleep(until: start + .milliseconds((3 * index + i + 1) * 20), clock: .continuous) }
                    catch { return }
                }
                index += 1
            }
        }
        return stream.stream
    }

    func stop() {
        if pump != nil { stops += 1 }
        pump?.cancel()
        pump = nil
    }
}

actor PhraseSpeaker: VoiceCallSpeaker {
    let fixture: SpeechFixture
    private(set) var playing = false
    init(_ fixture: SpeechFixture) { self.fixture = fixture }
    func start() { playing = true }
    func enqueue(_ samples: [Int16], timestamp: UInt32) {
        #expect(playing)
        fixture.append(timestamp: timestamp, samples: samples)
    }
    func stop() { playing = false }
}

@MainActor @Suite struct LiveEndpointSpeechTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEREIN_SPEECH_DIR"] != nil))
    func liveEndpointSpeech() async throws {
        let env = ProcessInfo.processInfo.environment
        let path = try #require(env["SEREIN_SPEECH_DIR"])
        let fixture = try SpeechFixture(directory: URL(filePath: path, directoryHint: .isDirectory))
        let mic = PhraseMicrophone(fixture), speaker = PhraseSpeaker(fixture)
        let swift = try LoopbackCallTests.Side("swift", .overXPC, backend: SwiftVoiceEndpoint.factory(devices: {
            VoiceCallDevices(microphone: mic, speaker: speaker)
        }))
        let native = try LoopbackCallTests.Side("native", .overXPC)
        try #require(native.rtc.getAudioInputs()?.devices.map(\.name) == ["Serein file microphone"])
        let swiftCalls = env["SEREIN_SPEECH_ROLE"] == "caller"
        let relay = env["SEREIN_SPEECH_ROUTE"] == "relay"
        let model = try env["SEREIN_DRED_WEIGHTS"].map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
        if let model {
            try swift.rtc.addAsset("opus-dred", content: model)
            try native.rtc.addAsset("opus-dred", content: model)
        }
        let proxy = try model != nil && !relay ? VideoLossProxy(dropAudio: true) : nil
        defer { proxy?.close() }
        if let proxy {
            await LoopbackCallTests.wait(3) { proxy.port != nil }
            try #require(proxy.port != nil)
        }
        let caller = swiftCalls ? swift : native, callee = swiftCalls ? native : swift
        let servers: [IceServer]
        if relay {
            let port = try #require(env["SEREIN_TEST_TURN_PORT"].flatMap(UInt16.init))
            servers = [IceServer(username: "serein", password: "serein-test-relay", urls: [env["SEREIN_TEST_TURN_URI"] ?? "turn:127.0.0.1:\(port)?transport=udp"])]
        } else { servers = [] }
        var selectedRelay = false
        var nativeLoadedModel = false
        native.rtc.handleLogMessage = { _, _, _, msg in
            if msg.contains("opus-dred asset version") && msg.contains("found") { nativeLoadedModel = true }
            guard relay, msg.contains("ice_network_route_change") else { return }
            let candidates = msg.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("local:") || $0.hasPrefix("remote:") }
            guard !candidates.isEmpty else { return }
            let relayed = ["local:", "remote:"].allSatisfy { prefix in
                candidates.contains { $0.hasPrefix(prefix) && $0.contains(" typ relay") }
            }
            #expect(relayed, "Both nominated candidates must be relayed")
            selectedRelay = relayed
        }
        for (me, other, id) in [(caller, callee, DeviceId(1)), (callee, caller, DeviceId(2))] {
            let remoteId: DeviceId = id == 1 ? 2 : 1
            me.rtc.handleOutgoingSignaling = { [weak other] _, message in
                guard let other else { return false }
                var message = message
                if let proxy, let candidates = message.iceCandidates {
                    message.iceCandidates = me === native ? candidates.compactMap(proxy.substitute) : []
                    if message.iceCandidates?.isEmpty == true { return true }
                }
                other.rtc.handleCallingMessage(message, .init(remoteUserId: me.name, remoteUuid: nil, remoteDeviceId: id,
                    localDeviceId: remoteId, ageSec: 0, receivedAtCounter: 0, receivedAtDate: 0,
                    senderIdentityKey: Data(repeating: UInt8(id), count: 32), receiverIdentityKey: Data(repeating: UInt8(remoteId), count: 32)))
                return true
            }
            me.rtc.handleIncomingCall = { call in me.incoming = call; return true }
            me.rtc.handleStartCall = { call in
                call.handleStateChanged = { me.states.append(call.state) }
                me.rtc.proceed(callId: call.callId, settings: CallSettings(iceServers: servers, hideIp: relay, dataMode: .normal, dredDuration: model == nil ? 0 : 50, statsIntervalSecs: 1))
                return true
            }
        }
        defer {
            swift.handler?.sessionEnded()
            for side in [swift, native] {
                side.rtc.handleIncomingCall = nil
                side.rtc.handleOutgoingSignaling = nil
                side.rtc.handleStartCall = nil
                side.rtc.call?.handleStateChanged = nil
            }
        }
        let outgoing = try caller.rtc.startOutgoingCall(remoteUserId: callee.name, isVideoCall: false, localDeviceId: 1)
        outgoing.setOutgoingAudioMuted(false)
        await LoopbackCallTests.wait { callee.states.contains(.ringing) }
        let incoming = try #require(callee.incoming, "Caller \(caller.states), callee \(callee.states)")
        #expect(await mic.starts == 0)
        incoming.setOutgoingAudioMuted(false)
        incoming.accept()
        await LoopbackCallTests.wait { caller.states.contains(.accepted) && callee.states.contains(.accepted) }
        try #require(outgoing.state == .accepted && incoming.state == .accepted, "Caller \(caller.states), callee \(callee.states)")
        let duration = Int(env["SEREIN_SPEECH_SECONDS"] ?? "") ?? 7
        try #require((7...600).contains(duration))
        try await Task.sleep(for: .seconds(duration))
        let activeSpeech = try fixture.activeSpeechEnd()
        let swiftCall = swiftCalls ? outgoing : incoming
        swiftCall.setOutgoingAudioMuted(true)
        try await waitForDevice { await mic.stops == 1 }
        try #require(await speaker.playing)
        if let proxy {
            // Drain captured audio. The subsequent receiver report is sent while
            // only RingRTC is transmitting speech.
            try await Task.sleep(for: .milliseconds(120))
            let audio = proxy.swiftAudioPackets, reports = proxy.swiftReceptionReports
            try await waitForDevice { proxy.swiftReceptionReports > reports }
            #expect(proxy.swiftAudioPackets == audio)
        }
        swiftCall.setOutgoingAudioMuted(false)
        try await waitForDevice { await mic.starts == 2 }
        if swiftCalls {
            swiftCall.hangup()
            await LoopbackCallTests.wait { outgoing.state == .ended && incoming.state == .ended }
            #expect(incoming.endedReason == .remoteHangup && outgoing.endedReason == .localHangup)
        } else {
            swift.handler?.sessionEnded()
            outgoing.hangup()
        }
        try await waitForDevice { await mic.stops == 2 }
        try await waitForDevice { await !speaker.playing }
        if relay { #expect(selectedRelay) }
        if model != nil { #expect(nativeLoadedModel) }
        if let proxy {
            print("Bidirectional audio packet drops", proxy.audioLoss, "Swift RTCP receiver report", proxy.swiftReceptionReports)
            #expect(proxy.audioLoss.allSatisfy { $0 >= 2 })
            #expect(proxy.swiftReceptionReports > 0)
        }
        try fixture.verify(route: "\(relay ? "TURN" : "direct") Swift \(swiftCalls ? "caller" : "callee")", through: activeSpeech)
    }

    private func waitForDevice(_ done: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while await !done(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(await done())
    }
}
