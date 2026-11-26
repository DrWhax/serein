#if os(Linux)
import CLinuxVideo
import Foundation

public actor CameraCapture {
    private final class Stream {
        let handle: UInt64
        let width, height: Int
        var bytes: [UInt8]
        init(_ handle: UInt64, width: Int, height: Int) {
            self.handle = handle
            self.width = width
            self.height = height
            self.bytes = .init(repeating: 0, count: width * height * 3 / 2)
        }
        deinit { serein_capture_close(handle) }
    }

    private let onFrame: @Sendable (CapturedFrame) -> Void
    private var task: Task<Void, Never>?
    private var stream: Stream?
    private var generation: UInt64 = 0
    public var isCapturing: Bool { stream != nil }

    public init(onFrame: @escaping @Sendable (CapturedFrame) -> Void) {
        self.onFrame = onFrame
    }

    deinit { task?.cancel() }

    public nonisolated static var isAuthorized: Bool { serein_camera_authorized() != 0 }

    public nonisolated static func requestAccess() async -> Bool {
        await Task.detached { serein_camera_request() != 0 }.value
    }

    public nonisolated static func devices() -> [CameraDevice] {
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        let count = { var buffer = bytes.mutableSpan; return serein_camera_devices(&buffer) }()
        guard (0...bytes.count).contains(count) else { return [] }
        let fields = bytes.prefix(count).split(separator: 0)
        var devices: [CameraDevice] = []
        for i in stride(from: 0, to: fields.count - fields.count % 2, by: 2) {
            if let name = String(bytes: fields[i], encoding: .utf8), let label = String(bytes: fields[i + 1], encoding: .utf8) {
                devices.append(CameraDevice(deviceId: name, label: label))
            }
        }
        return devices
    }

    public func start(deviceId: String?, maxWidth: Int = CallVideoConstants.direct.width, maxHeight: Int = CallVideoConstants.direct.height,
                      framerate: Int = CallVideoConstants.direct.framerate) throws {
        stop()
        guard (2...8192).contains(maxWidth), (2...8192).contains(maxHeight), (1...120).contains(framerate) else {
            throw CameraCaptureError.cannotAddOutput
        }
        let name = Array((deviceId ?? "").utf8)
        let result = serein_camera_open(name.span, Int32(maxWidth), Int32(maxHeight), Int32(framerate))
        guard result.handle != 0 else {
            switch result.error {
            case 1: throw CameraCaptureError.notAuthorized
            case 2: throw CameraCaptureError.noCamera
            default: throw CameraCaptureError.cannotAddOutput
            }
        }
        stream = Stream(result.handle, width: maxWidth, height: maxHeight)
        let token = generation
        task = Task { [weak self] in
            while !Task.isCancelled, await self?.deliver(token) == true {
                do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
            }
        }
    }

    private static func read(_ handle: UInt64, into bytes: inout [UInt8]) -> SereinCaptureFrame {
        var output = bytes.mutableSpan
        return serein_capture_read(handle, &output)
    }

    private func deliver(_ token: UInt64) -> Bool {
        guard token == generation, let stream else { return false }
        let frame = Self.read(stream.handle, into: &stream.bytes)
        if frame.status == 0 { return true }
        let width = Int(frame.width), height = Int(frame.height)
        guard frame.status > 0, (2...stream.width).contains(width), (2...stream.height).contains(height),
              let capture = CapturedFrame(width: width, height: height, nv12: Array(stream.bytes.prefix(width * height * 3 / 2))) else {
            stop()
            return false
        }
        onFrame(capture)
        return true
    }

    public func stop() {
        task?.cancel()
        task = nil
        generation &+= 1
        stream = nil
    }
}
#endif
