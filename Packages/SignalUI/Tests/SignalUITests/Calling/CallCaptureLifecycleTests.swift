// Capture after hang-up: the camera's reconciler and the screen share's start each wait (for
// permission, or for the device or stream to start); a hang-up during that wait must win.
// Each test suspends a start, ends the call, resumes it, and checks nothing is left running.

import Testing
@testable import SignalUI

/// A camera whose permission prompt and start each wait until the test lets them finish.
@MainActor final class FakeCamera {
    var running = false
    var starts = 0
    var stops = 0
    var holdAccess = false
    var holdStart = false
    var accessWaiter: CheckedContinuation<Bool, Never>?
    var startWaiter: CheckedContinuation<Void, Never>?

    var device: CaptureReconciler.Device {
        CaptureReconciler.Device(
            requestAccess: { [self] in
                guard holdAccess else { return true }
                return await withCheckedContinuation { accessWaiter = $0 }
            },
            start: { [self] in
                starts += 1
                if holdStart { await withCheckedContinuation { startWaiter = $0 } }
                running = true
            },
            stop: { [self] in
                stops += 1
                running = false
            })
    }

    /// Yields until `condition` holds (the reconciler's task has reached the wait).
    func until(_ condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() { await Task.yield() }
        #expect(condition())
    }
}

@MainActor @Suite struct CameraReconcilerTests {
    @Test func followsWhatIsWanted() async {
        let camera = FakeCamera()
        var wanted = true
        let r = CaptureReconciler(device: camera.device, wanted: { wanted })
        r.update()
        await r.settle()
        #expect(camera.running && r.isRunning)
        wanted = false
        r.update()
        await r.settle()
        #expect(!camera.running && !r.isRunning && camera.stops == 1)
    }

    /// Hanging up while the permission prompt is open: granting it afterwards starts nothing.
    @Test func hangupDuringThePermissionPrompt() async {
        let camera = FakeCamera()
        camera.holdAccess = true
        var wanted = true
        let r = CaptureReconciler(device: camera.device, wanted: { wanted })
        r.update()
        await camera.until { camera.accessWaiter != nil }
        wanted = false
        r.update()
        camera.accessWaiter?.resume(returning: true)
        await r.settle()
        #expect(camera.starts == 0 && !camera.running && !r.isRunning)
    }

    /// Hanging up while the camera is starting: it is stopped as soon as the start finishes.
    @Test func hangupWhileStarting() async {
        let camera = FakeCamera()
        camera.holdStart = true
        var wanted = true
        let r = CaptureReconciler(device: camera.device, wanted: { wanted })
        r.update()
        await camera.until { camera.startWaiter != nil }
        wanted = false
        r.update()
        camera.startWaiter?.resume()
        await r.settle()
        #expect(camera.starts == 1 && camera.stops == 1 && !camera.running && !r.isRunning)
    }

    @Test func restartSwitchesDevice() async {
        let camera = FakeCamera()
        let r = CaptureReconciler(device: camera.device, wanted: { true })
        r.update()
        await r.settle()
        r.restart()
        await r.settle()
        #expect(camera.starts == 2 && camera.stops == 1 && camera.running)
    }
}

/// A stream whose start waits until the test lets it finish.
@MainActor final class SlowStream: ScreenStream {
    var startWaiter: CheckedContinuation<Void, Never>?
    var started = false
    var stopped = false
    func startCapture() async throws {
        await withCheckedContinuation { startWaiter = $0 }
        started = true
    }
    func stopCapture() async throws { stopped = true }
}

@MainActor @Suite struct ScreenShareLifecycleTests {
    /// A stop while the stream is starting: the stream is stopped again and never kept, so no
    /// frames are delivered and the repeat timer never runs.
    @Test func stopWhileStartingWins() async throws {
        let capture = ScreenShareCapture(onFrame: { _ in }, onStop: { _ in })
        let stream = SlowStream()
        let output = ScreenStreamOutput(onFrame: { _ in }, onStop: { _ in })
        let generation = capture.begin()
        let starting = Task { try await capture.install(stream, output: output, generation) }
        for _ in 0..<1000 where stream.startWaiter == nil { await Task.yield() }
        await capture.stop()
        stream.startWaiter?.resume()
        await #expect(throws: CancellationError.self) { try await starting.value }
        #expect(stream.started && stream.stopped)
        #expect(!capture.isCapturing && capture.repeater == nil)
        #expect(!output.state.withLock { $0.running })
    }

    @Test func startWithoutAStopIsKept() async throws {
        let capture = ScreenShareCapture(onFrame: { _ in }, onStop: { _ in })
        let stream = SlowStream()
        let generation = capture.begin()
        let starting = Task { try await capture.install(stream, output: ScreenStreamOutput(onFrame: { _ in }, onStop: { _ in }), generation) }
        for _ in 0..<1000 where stream.startWaiter == nil { await Task.yield() }
        stream.startWaiter?.resume()
        try await starting.value
        #expect(capture.isCapturing && !stream.stopped)
        await capture.stop()
        #expect(!capture.isCapturing && stream.stopped)
    }
}
