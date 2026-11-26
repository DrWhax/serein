import CLinuxServiceSocket
import Foundation

/// The session supervisor starts one memory-confined child for each lease. Only
/// stdin and stdout reach the child. Closing the independent lease stops it even
/// if it is busy parsing and has stopped reading its input.
public final class LinuxParserChannel: Sendable {
    public let stream: FileHandle
    private let lease: FileHandle

    public init() throws {
        let fd = serein_open_channel(168, 0, 0, 0)
        guard fd >= 0 else { throw ServicePipeError.io("parser supervisor unavailable") }
        let lease = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard serein_bound_channel_receive(fd, 5) == 0 else {
            throw ServicePipeError.io("cannot bound parser startup")
        }
        let data = serein_accept_channel(fd, 1, 0, 0)
        guard data >= 0 else { throw ServicePipeError.io("parser child unavailable") }
        self.lease = lease
        stream = FileHandle(fileDescriptor: data, closeOnDealloc: true)
    }

    public var isRunning: Bool {
        serein_channel_idle(lease.fileDescriptor) != 0
    }

    public func stop() {
        serein_interrupt_channel(lease.fileDescriptor)
        serein_interrupt_channel(stream.fileDescriptor)
    }
}
