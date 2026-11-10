// Keeps a capture device (the call's camera) in the state its owner wants, one change at a
// time. The owner says what it wants through `wanted` and calls `update()` whenever that may
// have changed. Each pass reads `wanted` again after every suspension (the permission prompt,
// the device starting or stopping), so a start that had to wait never runs once it is no
// longer wanted: hanging up while the permission prompt is open, or while the camera is
// starting, leaves the camera off.

@MainActor
public final class CaptureReconciler {
    /// The device: asking for access, starting (or switching to the chosen device) and stopping.
    public struct Device {
        public var requestAccess: @MainActor () async -> Bool
        public var start: @MainActor () async throws -> Void
        public var stop: @MainActor () async -> Void

        public init(requestAccess: @escaping @MainActor () async -> Bool, start: @escaping @MainActor () async throws -> Void,
                    stop: @escaping @MainActor () async -> Void) {
            self.requestAccess = requestAccess
            self.start = start
            self.stop = stop
        }
    }

    let device: Device
    let wanted: @MainActor () -> Bool
    let report: @MainActor (String) -> Void
    public private(set) var isRunning = false
    var pass: Task<Void, Never>?
    var again = false
    var restartRequested = false

    public init(device: Device, wanted: @escaping @MainActor () -> Bool, report: @escaping @MainActor (String) -> Void = { _ in }) {
        self.device = device
        self.wanted = wanted
        self.report = report
    }

    /// What `wanted` reads may have changed.
    public func update() {
        guard pass == nil else {
            again = true
            return
        }
        pass = Task {
            repeat {
                again = false
                await reconcile()
            } while again
            pass = nil
        }
    }

    /// The chosen device changed: if running, stop and start again.
    public func restart() {
        restartRequested = true
        update()
    }

    /// Waits until the device is in the wanted state (tests).
    public func settle() async {
        while let pass { await pass.value }
    }

    func reconcile() async {
        if restartRequested {
            restartRequested = false
            if isRunning { await stopDevice() }
        }
        guard wanted() else {
            if isRunning { await stopDevice() }
            return
        }
        guard !isRunning else { return }
        guard await device.requestAccess() else { return report("camera: no permission") }
        guard wanted() else { return }   // hung up while the prompt was open
        do { try await device.start() } catch { return report("camera failed: \(error)") }
        isRunning = true
        if !wanted() { await stopDevice() }   // hung up while it was starting
    }

    func stopDevice() async {
        isRunning = false
        await device.stop()
    }
}
