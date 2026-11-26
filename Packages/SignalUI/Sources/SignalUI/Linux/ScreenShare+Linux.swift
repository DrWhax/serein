#if os(Linux)
import CLinuxVideo
import Foundation

/// A single portal selection. The desktop owns the picker and can revoke this grant during capture.
public final class ScreenShareFilter: Sendable {
    fileprivate let handle = serein_share_request()
    fileprivate let id = UUID().uuidString
    fileprivate var status: SereinShareStatus { serein_share_status(handle) }
    fileprivate func cancel() { serein_share_cancel(handle) }
    deinit { serein_share_release(handle) }
}

@MainActor public final class ScreenShareCapture {
    private let onFrame: @Sendable (CapturedFrame) -> Void
    private let onStop: @Sendable ((any Error)?) -> Void
    private let tasks: MainTasks
    private var picker: ScreenShareFilter?
    private var selection: ScreenShareFilter?
    private var starting: ScreenShareFilter?
    private var live: ScreenShareFilter?
    private var stream: LinuxCaptureStream?
    private var reader: Task<Void, Never>?
    private var generation: UInt64 = 0

    public var isCapturing: Bool { stream != nil }

    public init(onFrame: @escaping @Sendable (CapturedFrame) -> Void, onStop: @escaping @Sendable ((any Error)?) -> Void,
                tasks: MainTasks = .system) {
        self.onFrame = onFrame
        self.onStop = onStop
        self.tasks = tasks
    }

    public func pickFilter() async throws -> ScreenShareFilter? {
        cancelStart()
        let request = ScreenShareFilter()
        picker = request
        defer { if picker === request { picker = nil } }
        return try await withTaskCancellationHandler {
            while !Task.isCancelled && picker === request {
                switch request.status {
                case SereinSharePending: try await Task.sleep(for: .milliseconds(20))
                case SereinShareGranted: return request
                case SereinShareCancelled, SereinShareClosed: return nil
                default: throw ScreenShareError.sourceGone
                }
            }
            return nil
        } onCancel: { request.cancel() }
    }

    public func sources() async throws -> [PresentableSource] {
        guard let grant = try await pickFilter() else { return [] }
        selection = grant
        let screen = serein_share_is_screen(grant.handle) != 0
        return [PresentableSource(id: grant.id, name: screen ? "Entire Screen" : "Window", isScreen: screen)]
    }

    public func filter(for id: String) throws -> ScreenShareFilter {
        guard let selection, selection.id == id, selection.status == SereinShareGranted else { throw ScreenShareError.sourceGone }
        return selection
    }

    public func start(_ filter: ScreenShareFilter) async throws {
        if selection === filter { selection = nil }
        await stop()
        let token = generation
        starting = filter
        defer { if starting === filter { starting = nil } }
        let maximum = CallVideoConstants.screenShare
        let handle = await Task.detached {
            serein_share_open(filter.handle, Int32(maximum.width), Int32(maximum.height), Int32(maximum.framerate)).handle
        }.value
        guard !Task.isCancelled, token == generation, filter.status == SereinShareGranted, handle != 0 else {
            if handle != 0 { serein_capture_close(handle) }
            filter.cancel()
            throw ScreenShareError.sourceGone
        }
        stream = LinuxCaptureStream(handle, width: maximum.width, height: maximum.height)
        live = filter
        reader = tasks.spawn("screen.frames") { [weak self] in
            while !Task.isCancelled, self?.deliver(token) == true {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { break }
            }
        }
    }

    private func deliver(_ token: UInt64) -> Bool {
        guard token == generation, let stream else { return false }
        do {
            if live?.status != SereinShareGranted { throw ScreenShareError.sourceGone }
            if let frame = try stream.read() { onFrame(frame) }
            return true
        } catch {
            let revoked = live?.status == SereinShareClosed
            teardown()
            onStop(revoked ? nil : error)
            return false
        }
    }

    public func cancelStart() {
        generation &+= 1
        picker?.cancel()
        picker = nil
        starting?.cancel()
        starting = nil
        selection?.cancel()
        selection = nil
    }

    private func teardown() {
        reader?.cancel()
        reader = nil
        stream = nil
        live?.cancel()
        live = nil
    }

    public func stop() async {
        cancelStart()
        teardown()
    }
}
#endif
