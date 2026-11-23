// Verify that the signed app can reach its bundled Swift calling engine over XPC.

import CallXPC
import Foundation
import SignalRingRTC

@MainActor enum CallingLink {
    static func checkService() -> Bool {
        do {
            let rtc = try RingRTC(endpoint: RemoteCallEndpoint.factory())
            guard let inputs = rtc.getAudioInputs(), let outputs = rtc.getAudioOutputs() else {
                throw RingRTCError.invalidResponse
            }
            FileHandle.standardError.write(Data("Swift calling service ready (\(inputs.devices.count) audio inputs, \(outputs.devices.count) audio outputs)\n".utf8))
            return true
        } catch {
            FileHandle.standardError.write(Data("Calling service check failed: \(error)\n".utf8))
            return false
        }
    }
}
