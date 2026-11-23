import CallService
import CallXPC
import Foundation
import MediaXPCInterface
import SignalRingRTC
import SwiftCalling
import SwiftCallingServiceAdapter

actor DisabledMicrophone: VoiceCallMicrophone {
    func start() async throws -> AsyncStream<[Int16]> { throw RingRTCError.invalidResponse }
    func stop() {}
}

/// Consume the decoded 20 ms frames without playing them through the Mac's speakers.
actor SilentPlayback: VoiceCallSpeaker {
    func start() throws {}
    func enqueue(_ samples: [Int16], timestamp: UInt32) throws {
        guard samples.count == 960 else { throw RingRTCError.invalidResponse }
    }
    func stop() {}
}

@main struct SilentStrictCalling {
    static func main() {
        ServiceSandbox.requireConfinement("SignalCalling", systemFiles: true)
        guard let peers = Bundle.main.object(forInfoDictionaryKey: XPCPeer.infoKey) as? [String: String],
              peers["app"] == "org.signalsafe.LocalPeerFixture" else { exit(2) }
        let endpoint = SwiftVoiceEndpoint.factory(devices: {
            VoiceCallDevices(microphone: DisabledMicrophone(), speaker: SilentPlayback())
        })
        let handler = CallXPCHandler(makeEndpoint: endpoint, onSessionEnd: { exit(0) })
        XPCServer.serve(RemoteCallEndpoint.serviceName, requirement: XPCPeer.required(.app, by: "SignalCalling"), handler)
    }
}
