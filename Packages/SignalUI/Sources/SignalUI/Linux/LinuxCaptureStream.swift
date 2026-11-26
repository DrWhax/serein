#if os(Linux)
import CLinuxVideo

/// The owning camera or screen share serializes reads and releases the stream after its final read.
final class LinuxCaptureStream {
    enum Failure: Error { case closed }
    let handle: UInt64
    private let width, height: Int
    private var bytes: [UInt8]

    init(_ handle: UInt64, width: Int, height: Int) {
        self.handle = handle
        self.width = width
        self.height = height
        bytes = .init(repeating: 0, count: width * height * 3 / 2)
    }
    deinit { serein_capture_close(handle) }

    private static func read(_ handle: UInt64, into bytes: inout [UInt8]) -> SereinCaptureFrame {
        var output = bytes.mutableSpan
        return serein_capture_read(handle, &output)
    }

    func read() throws -> CapturedFrame? {
        let frame = Self.read(handle, into: &bytes)
        if frame.status == 0 { return nil }
        let w = Int(frame.width), h = Int(frame.height)
        guard frame.status > 0, (2...width).contains(w), (2...height).contains(h),
              let captured = CapturedFrame(width: w, height: h, nv12: Array(bytes.prefix(w * h * 3 / 2))) else {
            throw Failure.closed
        }
        return captured
    }
}
#endif
