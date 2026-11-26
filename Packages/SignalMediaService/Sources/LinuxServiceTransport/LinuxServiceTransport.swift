import Foundation
import CLinuxServiceSocket

public enum ServicePipeError: Error, Equatable {
    case tooLarge(Int)
    case truncated
    case badReply
    case io(String)
}

/// The private stdin/stdout channels inherited by Serein's parser helper.
/// A single reader and a single writer own each direction of the stream.
public enum LinuxServiceTransport {
    public static func write(_ frame: Data, to handle: FileHandle) throws(ServicePipeError) {
        guard let length = UInt32(exactly: frame.count) else { throw .tooLarge(frame.count) }
        let header = Data((0..<4).map { UInt8(truncatingIfNeeded: length >> (8 * $0)) })
        let mask = serein_block_pipe_signal()
        guard mask >= 0 else { throw .io("cannot block SIGPIPE") }
        var failed: Int32 = 0
        defer { serein_restore_pipe_signal(mask, failed) }
        do {
            try handle.write(contentsOf: header)
            try handle.write(contentsOf: frame)
        } catch {
            failed = 1
            throw .io(String(describing: error))
        }
    }

    /// A clean end of stream is valid only between frames. Check the declared
    /// size before reading the body, with bounded individual reads.
    public static func read(_ handle: FileHandle, maxBytes: Int) throws(ServicePipeError) -> Data? {
        guard let header = try readExactly(4, from: handle) else { return nil }
        let length = header.enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        guard length <= maxBytes else { throw .tooLarge(length) }
        guard let body = try readExactly(length, from: handle) else { throw .truncated }
        return body
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws(ServicePipeError) -> Data? {
        var result = Data()
        while result.count < count {
            let chunk: Data?
            do { chunk = try handle.read(upToCount: min(count - result.count, 64 * 1024)) }
            catch { throw .io(String(describing: error)) }
            guard let chunk, !chunk.isEmpty else {
                if result.isEmpty { return nil }
                throw .truncated
            }
            result.append(chunk)
        }
        return result
    }
}
