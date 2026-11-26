import Foundation
import ProbeDesktop
import SignalUI
import Synchronization

@main enum CameraProbe {
    static func main() async throws {
        if CommandLine.arguments.contains("--confined") {
            precondition(serein_desktop_confine() == 1, "Run as the app user with private /var/lib/serein and /run/serein directories")
        }
        precondition(!CameraCapture.isAuthorized && CameraCapture.devices().isEmpty)
        let denied = await CameraCapture.requestAccess()
        precondition(!denied && !CameraCapture.isAuthorized)
        let granted = await CameraCapture.requestAccess()
        precondition(granted && CameraCapture.isAuthorized)
        let available = CameraCapture.devices()
        precondition(available.contains { $0.deviceId == "serein-test-camera" && $0.label == "SereinTestCamera" })
        let samples = Mutex((count: 0, last: Optional<CapturedFrame>.none))
        let camera = CameraCapture { frame in samples.withLock { $0 = ($0.count + 1, frame) } }
        for _ in 0..<2 {
            let previous = samples.withLock { $0.count }
            try await camera.start(deviceId: "serein-test-camera", maxWidth: 64, maxHeight: 48, framerate: 10)
            let deadline = ContinuousClock.now + .seconds(4)
            while samples.withLock({ $0.count }) < previous + 2 && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            await camera.stop()
            let (count, frame) = samples.withLock { $0 }
            guard let frame, count >= previous + 2 else { fatalError("The camera did not deliver two frames") }
            precondition(frame.width == 64 && frame.height == 48 && frame.nv12.count == 4608)
            // The PipeWire fixture supplies solid red (limited-range NV12).
            precondition((65...95).contains(frame.nv12[0]) && (78...110).contains(frame.nv12[3072]) && frame.nv12[3073] >= 225)
            try await Task.sleep(for: .milliseconds(200))
            precondition(samples.withLock { $0.count } == count)
        }
        print("Camera permission denial, grant, enumeration, NV12 frames, stop and restart passed.")
        try await checkScreenShare()
    }

    @MainActor private static func checkScreenShare() async throws {
        let frames = Mutex(0)
        let stops = Mutex([Bool]())
        let share = ScreenShareCapture(onFrame: { frame in
            precondition(frame.width == 64 && frame.height == 48 && frame.nv12.count == 4608)
            frames.withLock { $0 += 1 }
        }, onStop: { error in stops.withLock { $0.append(error == nil) } })
        let denied = try await share.pickFilter()
        precondition(denied == nil)
        guard let selected = try await share.pickFilter() else { fatalError("Missing portal selection") }
        try await share.start(selected)
        let deadline = ContinuousClock.now + .seconds(5)
        while share.isCapturing && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        precondition(frames.withLock { $0 } > 0 && stops.withLock { $0 } == [true] && !share.isCapturing)
        let choices = try await share.sources()
        guard let choice = choices.first else { fatalError("Missing selected window") }
        precondition(!choice.isScreen)
        try await share.start(share.filter(for: choice.id))
        let before = frames.withLock { $0 }
        let next = ContinuousClock.now + .seconds(3)
        while frames.withLock({ $0 }) == before && ContinuousClock.now < next { try await Task.sleep(for: .milliseconds(25)) }
        precondition(frames.withLock { $0 } > before)
        await share.stop()
        precondition(!share.isCapturing && stops.withLock { $0 } == [true])
        print("Screen picker cancellation, selected PipeWire frames, portal revocation and explicit stop passed.")
    }
}
