import CallService
import Foundation
import MediaXPCInterface
import RingRTCNative
import SignalRingRTC

// This executable is staged exclusively in the optional test service. Refuse to serve
// without the bundled speech and the pinned RingRTC build's pair of virtual audio devices.
let name = "SignalCallTestPeer"
ServiceSandbox.requireConfinement(name, systemFiles: true)
guard let identifier = Bundle.main.bundleIdentifier,
      Bundle.main.url(forResource: "native-input", withExtension: "pcm", subdirectory: "ReferenceSpeech") != nil else {
    exit(78)
}
let synthetic: LocalCallEndpointFactory = { trials in
    let endpoint = try NativeEndpoint.factory(trials)
    for (command, expected) in [("getAudioInputs", "Serein file microphone"), ("getAudioOutputs", "Serein file speaker")] {
        let result = try endpoint.command(command, [:], generation: nil)
        guard result["devices"].array.map({ $0["name"].string }) == [expected] else { throw RingRTCError.noEndpoint }
    }
    return endpoint
}
// A stopped peer may still drain a decoded frame while its replacement joins. Give each
// connection its own endpoints so closing the old session only releases the old peer.
XPCServer.serve(identifier, requirement: XPCPeer.required(.app, by: name), sessions: {
    CallXPCHandler(makeEndpoint: synthetic)
})
