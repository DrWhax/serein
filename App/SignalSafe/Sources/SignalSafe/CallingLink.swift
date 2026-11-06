// Links SignalCore (libsignal) and SignalRingRTC (ringrtc + WebRTC) into the app binary.
// The calling session is created here once the app has a linked account (app integration):
// `CallingService` over the account's socket, messenger and groups API, its events feeding
// CallManager / the Calls tab, with CameraCapture, ScreenShareCapture and MuteState.

import Foundation
import SignalCore
import SignalRingRTC

@MainActor enum CallingLink {
    static var linkedTypes: [Any.Type] { [CallingService.self, RingRTC.self] }

    /// `SIGNALSAFE_RINGRTC_SMOKE=1`: start the calling engine at launch and list the audio
    /// devices — proof that ringrtc (WebRTC, cubeb) and libsignal run side by side in the app.
    static func smokeTestIfRequested() {
        guard ProcessInfo.processInfo.environment["SIGNALSAFE_RINGRTC_SMOKE"] == "1" else { return }
        do {
            let rtc = try RingRTC()
            let inputs = rtc.getAudioInputs()?.devices.count ?? 0
            FileHandle.standardError.write(Data("ringrtc smoke: ok, \(inputs) audio input(s)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("ringrtc smoke: failed: \(error)\n".utf8))
        }
    }
}
