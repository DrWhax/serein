// Links SignalCore (libsignal) and SignalRingRTC's Swift layer into the app binary; ringrtc
// itself (WebRTC) runs in SignalCalling.xpc. The calling session is created once the app has a
// linked account: `CallingService` over the account's socket, messenger and groups API and the
// service's endpoint, its events feeding CallManager / the Calls tab, with CameraCapture,
// ScreenShareCapture and MuteState.

import CallXPC
import Foundation
import SignalCore
import SignalRingRTC

@MainActor enum CallingLink {
    static var linkedTypes: [Any.Type] { [CallingService.self, RingRTC.self] }

    /// `SIGNALSAFE_RINGRTC_SMOKE=1`: start the calling engine at launch and list the audio
    /// devices — proof that ringrtc (WebRTC, cubeb) runs in the calling service for the app.
    static func smokeTestIfRequested() {
        guard ProcessInfo.processInfo.environment["SIGNALSAFE_RINGRTC_SMOKE"] == "1" else { return }
        do {
            let rtc = try RingRTC(endpoint: RemoteCallEndpoint.factory())
            let inputs = rtc.getAudioInputs()?.devices.count ?? 0
            FileHandle.standardError.write(Data("ringrtc smoke: ok, \(inputs) audio input(s)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("ringrtc smoke: failed: \(error)\n".utf8))
        }
    }
}
