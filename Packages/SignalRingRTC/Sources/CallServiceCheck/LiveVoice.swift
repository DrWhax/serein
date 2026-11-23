// QA and debug builds only (Package.swift `testPeer`; SEREIN_QA_CALL_PEER=1 Tools/build-app.sh).
#if SEREIN_CALL_TEST_PEER
import CallXPC
import Foundation
import SignalRingRTC

/// The signed, loopback-only fixture bundles a RingRTC audio device that plays a known
/// phrase and discards its received PCM. Only the Swift endpoint uses the system hardware.
@MainActor func checkLiveVoice() async throws {
    guard let referenceFactory = RemoteCallEndpoint.testPeerFactory() else { throw RingRTCError.noEndpoint }
    let swift = try Side("swift", RemoteCallEndpoint.factory())
    let reference = try Side("reference", referenceFactory)
    let args = CommandLine.arguments.dropFirst()
    let relayPort: UInt16?
    if args.count == 3, args.dropFirst().first == "--relay-port", let port = args.last.flatMap(UInt16.init), port > 0 {
        relayPort = port
    } else if args == ["--live-voice"] { relayPort = nil }
    else { throw RingRTCError.native("Expected --live-voice [--relay-port PORT]") }
    let servers = relayPort.map { [IceServer(username: "serein", password: "serein-test-relay", urls: ["turn:127.0.0.1:\($0)?transport=udp"])] } ?? []
    guard reference.rtc.getAudioInputs()?.devices.map(\.name) == ["Serein file microphone"],
          let inputs = swift.rtc.getAudioInputs(), let microphone = inputs.defaultDevice, inputs.devices.contains(microphone)
    else { throw RingRTCError.native("Expected separate Swift hardware and reference fixture devices") }
    var receivedPackets = false, renderedSpeech = false
    var receiverReports = 0
    var maximumPacketRate = 0.0
    var relayNominated = false
    var sawDirectRoute = false
    var diagnostics: [String] = []
    var verified = false
    defer { if !verified { for line in diagnostics.suffix(16) { print(line) } } }
    swift.rtc.handleLogMessage = { level, _, _, message in
        if level.rawValue <= CallLogLevel.warn.rawValue { diagnostics.append("Swift: " + message) }
    }
    reference.rtc.handleLogMessage = { level, _, _, message in
        if level.rawValue <= CallLogLevel.warn.rawValue { diagnostics.append("RingRTC: " + message) }
        if relayPort != nil, message.contains("ice_network_route_change") {
            let lines = message.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            let pair = lines.filter { $0.hasPrefix("local:") || $0.hasPrefix("remote:") }
            if !pair.isEmpty {
                if ["local:", "remote:"].allSatisfy({ side in pair.contains { $0.hasPrefix(side) && $0.contains(" typ relay") } }) {
                    relayNominated = true
                } else { sawDirectRoute = true }
            }
        }
        guard let marker = message.range(of: "ringrtc_stats!,audio,recv,") else { return }
        let values = message[marker.upperBound...].split(separator: ",")
        if values.count >= 2, values[0] == "1002", let pps = Double(values[1]) {
            receiverReports += 1
            maximumPacketRate = max(maximumPacketRate, pps)
            if pps > 0 { receivedPackets = true }
        }
    }
    for (me, other, id) in [(swift, reference, DeviceId(1)), (reference, swift, DeviceId(2))] {
        let remoteId: DeviceId = id == 1 ? 2 : 1
        me.rtc.handleOutgoingSignaling = { _, message in
            other.rtc.handleCallingMessage(message, .init(remoteUserId: me.name, remoteUuid: nil, remoteDeviceId: id,
                localDeviceId: remoteId, ageSec: 0, receivedAtCounter: 0, receivedAtDate: 0,
                senderIdentityKey: Data(repeating: UInt8(id), count: 32), receiverIdentityKey: Data(repeating: UInt8(remoteId), count: 32)))
            return true
        }
        me.rtc.handleIncomingCall = { call in me.incoming = call; return true }
        me.rtc.handleStartCall = { call in
            call.handleStateChanged = { me.states.append(call.state) }
            if me === swift { call.handleAudioLevels = { if call.remoteAudioLevel > 0 { renderedSpeech = true } } }
            me.rtc.proceed(callId: call.callId, settings: .init(iceServers: servers, hideIp: relayPort != nil, dataMode: .normal,
                                                               audioLevelsIntervalMillis: 100, statsIntervalSecs: 1))
            return true
        }
    }
    let outgoing = try swift.rtc.startOutgoingCall(remoteUserId: reference.name, isVideoCall: false, localDeviceId: 1)
    defer { outgoing.hangup() }
    outgoing.setOutgoingAudioMuted(false)
    await wait(45) { reference.states.contains(.ringing) || outgoing.state == .ended }
    guard let incoming = reference.incoming, incoming.state == .ringing else {
        throw RingRTCError.native("Reference peer did not ring. Swift ended with \(String(describing: outgoing.endedReason))")
    }
    incoming.setOutgoingAudioMuted(false)
    incoming.accept()
    await wait(10) { outgoing.state == .accepted && incoming.state == .accepted || outgoing.state == .ended }
    report(outgoing.state == .accepted && incoming.state == .accepted, "Swift hardware call connected",
           "Swift \(swift.states) \(String(describing: outgoing.endedReason)), RingRTC \(reference.states) \(String(describing: incoming.endedReason))")
    guard outgoing.state == .accepted && incoming.state == .accepted else { return }
    await wait(25) { receivedPackets && renderedSpeech || outgoing.state == .ended }
    report(receivedPackets && incoming.remoteAudioEnabled, "microphone to RingRTC",
           "\(receiverReports) receive reports, peak \(maximumPacketRate) packets/s, microphone enabled: \(incoming.remoteAudioEnabled)")
    report(renderedSpeech, "RingRTC to speaker", "received a nonzero level from speaker playout: \(renderedSpeech)")
    if relayPort != nil {
        report(relayNominated && !sawDirectRoute, "forced TURN pair", "relay pair observed: \(relayNominated), direct route observed: \(sawDirectRoute)")
    }
    outgoing.setOutgoingAudioMuted(true)
    await wait(3) { !incoming.remoteAudioEnabled }
    report(!incoming.remoteAudioEnabled, "Swift microphone mute", "observed by RingRTC")
    outgoing.hangup()
    await wait(5) { incoming.state == .ended }
    report(incoming.endedReason == .remoteHangup, "Swift hardware call ended", String(describing: incoming.endedReason))
    verified = !failed
}
#endif
