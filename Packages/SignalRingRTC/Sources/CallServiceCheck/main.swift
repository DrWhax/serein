// Tools/check-sandbox-profile.sh's host for SignalCalling.xpc (not shipped): run from a bundle
// signed as the app that holds a copy of the built service, it drives the real service under
// its profile exactly as the app does (RingRTC over RemoteCallEndpoint, one session):
//   * the Swift endpoint's system audio devices;
//   * a video call between two endpoints in the service: ICE over this machine's own network
//     addresses (UDP sockets bound and sent from), the call accepted on both sides, and a frame
//     sent by one arriving at the other (the frame path both ways across XPC);
//   * the hang-up reaching both sides.
// Prints "ok: …" or "FAILED: …" per check; exits non-zero when any check fails. With --refused
// it only checks that the service turns it away (a copy signed otherwise); with --devices only
// the audio devices (the service as built: its profile forbids a call between two endpoints on
// one machine, as packets to this machine's own addresses are refused). With --staged-video,
// both endpoints use the shipping default over authenticated XPC, use local TURN, mute audio and
// verify different generated pictures at the two receivers.

import CallXPC
import Foundation
import MediaXPCInterface
import SignalRingRTC

if CommandLine.arguments.dropFirst().first == "--refused" {
    let channel = XPCChannel(.service(RemoteCallEndpoint.serviceName), peer: nil, timeout: .seconds(10))
    let refused: Bool
    do {
        _ = try channel.sendSync(Data(), timeout: .seconds(10), maxReply: 1 << 10)
        refused = false
    } catch XPCServiceError.lost { refused = true } catch XPCServiceError.timedOut { refused = true } catch { refused = false }
    print("\(refused ? "refused" : "SERVED"): calling")
    exit(refused ? 0 : 1)
}

@MainActor final class Side {
    let rtc: RingRTC
    let name: String
    var states: [CallState] = []
    var incoming: Call?
    init(_ name: String, _ factory: @escaping RingRTCEndpointFactory) throws {
        self.name = name
        rtc = try RingRTC(endpoint: factory)
    }
}

@MainActor func wait(_ seconds: Double, until done: () -> Bool) async {
    let end = Date().addingTimeInterval(seconds)
    while !done() && Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
}

var failed = false
@MainActor func report(_ ok: Bool, _ what: String, _ detail: String) {
    print("\(ok ? "ok" : "FAILED"): \(what): \(detail)")
    if !ok { failed = true }
}

let staged = CommandLine.arguments.dropFirst() == ["--staged-video"]
if CommandLine.arguments.dropFirst() == ["--test-peer-devices"] {
    do {
        guard let factory = RemoteCallEndpoint.testPeerFactory() else { throw RingRTCError.noEndpoint }
        let peer = try RingRTC(endpoint: factory)
        guard peer.getAudioInputs()?.devices.map(\.name) == ["Serein file microphone"],
              peer.getAudioOutputs()?.devices.map(\.name) == ["Serein file speaker"] else {
            throw RingRTCError.native("Unexpected native audio devices")
        }
        print("ok: signed test peer reports synthetic input and output")
        exit(0)
    } catch {
        print("FAILED: signed test peer: \(error)")
        exit(1)
    }
}
let factory = staged ? RemoteCallEndpoint.factory()
                     : RemoteCallEndpoint.factory(.service(RemoteCallEndpoint.serviceName), peer: nil)
if CommandLine.arguments.contains("--live-voice") {
    do { try await checkLiveVoice(); exit(failed ? 1 : 0) }
    catch { print("FAILED: live voice call: \(error)"); exit(1) }
}
/// ringrtc's warnings and errors, shown when a check fails.
var log: [String] = []
do {
    let a = try Side("alice", factory), b = try Side("bob", factory)
    for side in [a, b] {
        side.rtc.handleLogMessage = { level, _, _, message in
            if level.rawValue <= CallLogLevel.warn.rawValue { log.append("\(side.name): \(message)") }
        }
    }
    let inputs = a.rtc.getAudioInputs()?.devices.count, outputs = a.rtc.getAudioOutputs()?.devices.count
    report(inputs != nil && outputs != nil, "calling audio devices", "\(inputs ?? -1) inputs, \(outputs ?? -1) outputs")
    if CommandLine.arguments.dropFirst().first == "--devices" {
        guard let inputs = a.rtc.getAudioInputs(), let mic = inputs.defaultDevice, inputs.devices.contains(mic),
              let outputs = a.rtc.getAudioOutputs(), let speaker = outputs.defaultDevice, outputs.devices.contains(speaker)
        else { throw RingRTCError.native("Missing hardware audio defaults") }
        let selectedInput = try await a.rtc.setAudioInputById(mic.uniqueId)
        let selectedOutput = try await a.rtc.setAudioOutputById(speaker.uniqueId)
        _ = try await a.rtc.setVoiceProcessingEnabled(true)
        report(selectedInput == mic && selectedOutput == speaker, "Swift voice endpoint", "selected hardware input and output")
        exit(failed ? 1 : 0)
    }
    var servers: [IceServer] = []
    if staged {
        guard XPCPeer.requirement(.calling) != nil, let value = ProcessInfo.processInfo.environment["SEREIN_TEST_TURN_PORT"],
              let port = UInt16(value), port > 0 else { throw RingRTCError.native("Missing staged peer identity or loopback TURN port") }
        servers = [IceServer(username: "serein", password: "serein-test-relay", urls: ["turn:127.0.0.1:\(port)?transport=udp"])]
    }
    for (me, other, myId) in [(a, b, DeviceId(1)), (b, a, DeviceId(2))] {
        me.rtc.handleOutgoingSignaling = { [weak other] _, message in
            guard let other else { return false }
            other.rtc.handleCallingMessage(message, .init(remoteUserId: me.name, remoteUuid: nil, remoteDeviceId: myId, localDeviceId: myId == 1 ? 2 : 1,
                                                          ageSec: 0, receivedAtCounter: 0, receivedAtDate: 0, senderIdentityKey: Data(repeating: UInt8(myId), count: 32),
                                                          receiverIdentityKey: Data(repeating: myId == 1 ? 2 : 1, count: 32)))
            return true
        }
        me.rtc.handleIncomingCall = { call in me.incoming = call; return true }
        me.rtc.handleStartCall = { call in
            call.setOutgoingAudioMuted(true)
            call.handleStateChanged = { me.states.append(call.state) }
            me.rtc.proceed(callId: call.callId, settings: CallSettings(iceServers: servers, hideIp: staged, dataMode: .normal))
            return true
        }
    }
    let call = try a.rtc.startOutgoingCall(remoteUserId: "bob", isVideoCall: true, localDeviceId: 1)
    await wait(20) { b.incoming != nil && b.states.contains(.ringing) }
    guard let incoming = b.incoming else { throw RingRTCError.native("no incoming call (alice \(a.states), bob \(b.states))") }
    call.setOutgoingAudioMuted(true)
    incoming.setOutgoingAudioMuted(true)
    incoming.setOutgoingVideoMuted(false)
    incoming.accept()
    await wait(20) { a.states.contains(.accepted) && b.states.contains(.accepted) }
    let accepted = a.states.contains(.accepted) && b.states.contains(.accepted)
    report(accepted, "calling call connects",
           "alice \(a.states) \(String(describing: call.endedReason)), bob \(b.states) \(String(describing: incoming.endedReason))")
    guard accepted else { throw RingRTCError.native("Call did not reach the media check") }
    call.setOutgoingVideoMuted(false)
    let (w, h) = (320, 240)
    let directions: [(Call, Call, UInt8)] = staged ? [(call, incoming, UInt8(56)), (incoming, call, UInt8(192))] : [(call, incoming, UInt8(128))]
    for (sender, receiver, luma) in directions {
        let frame = [UInt8](repeating: luma, count: w * h) + [UInt8](repeating: 128, count: w * h / 2)
        var buffer = [UInt8](repeating: 0, count: 960 * 720 * 4)
        var got: (width: Int, height: Int)?
        let end = Date().addingTimeInterval(20)
        while got == nil && Date() < end {
            sender.sendVideoFrame(width: w, height: h, format: .nv12, buffer: frame)
            try await Task.sleep(for: .milliseconds(33))
            if let picture = receiver.receiveVideoFrame(into: &buffer, maxWidth: 960, maxHeight: 720) {
                let middle = 4 * ((picture.height / 2) * picture.width + picture.width / 2)
                if !staged || (picture.width == w && picture.height == h && abs(Int(buffer[middle]) - Int(luma)) <= 20) {
                    got = picture
                }
            }
        }
        report(got != nil, staged ? "Swift video to " + sender.remoteUserId : "calling video frames",
               got.map { "\($0.width)×\($0.height), luma \(luma)" } ?? "no matching frame")
    }
    call.hangup()
    await wait(10) { a.states.last == .ended && b.states.last == .ended }
    report(a.states.last == .ended && b.states.last == .ended, "calling hang-up", "alice \(a.states), bob \(b.states)")
} catch {
    report(false, "calling", "\(error)")
}
if failed { for line in log.suffix(40) { print("log: \(line)") } }
exit(failed ? 1 : 0)
