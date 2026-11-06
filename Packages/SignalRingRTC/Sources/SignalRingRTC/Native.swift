// The boundary to libsignal_ringrtc (rust/src/lib.rs): commands and events as JSON, frames
// as byte buffers, all passed as Span / MutableSpan (the header's __counted_by/__noescape
// annotations), so nothing here is `unsafe`.

import CSignalRingRTC
import Foundation
import Synchronization

/// A JSON value (commands, results and events).
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int64.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue { if case .object(let o) = self { o[key] ?? .null } else { .null } }
    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var int: Int? {
        switch self {
        case .int(let i): Int(exactly: i)
        case .double(let d): Int(exactly: d.rounded()) ?? nil
        case .string(let s): Int(s)
        default: nil
        }
    }
    public var double: Double? {
        switch self {
        case .int(let i): Double(i)
        case .double(let d): d
        default: nil
        }
    }
    /// 64-bit ids, sent as decimal strings.
    public var uint64: UInt64? {
        switch self {
        case .string(let s): UInt64(s)
        case .int(let i): UInt64(exactly: i)
        default: nil
        }
    }
    public var int64: Int64? {
        switch self {
        case .string(let s): Int64(s)
        case .int(let i): i
        default: nil
        }
    }
    /// Bytes, sent as base64.
    public var data: Data? { string.flatMap { Data(base64Encoded: $0) } }
    public var array: [JSONValue] { if case .array(let a) = self { a } else { [] } }
    public var isNull: Bool { self == .null }

    static func bytes(_ d: Data) -> JSONValue { .string(d.base64EncodedString()) }
    static func bytes(_ d: Data?) -> JSONValue { d.map { .string($0.base64EncodedString()) } ?? .null }
    static func id(_ v: UInt64) -> JSONValue { .string(String(v)) }
}

public enum RingRTCError: Error, Equatable, Sendable {
    case native(String)
    case noEndpoint
    case invalidResponse
}

/// One ringrtc call endpoint (`createCallEndpoint`).
final class NativeEndpoint: Sendable {
    let id: UInt64

    init?(fieldTrials: String) {
        let bytes = Array(fieldTrials.utf8)
        let id = srr_endpoint_create(bytes.span)
        guard id != 0 else { return nil }
        self.id = id
    }

    deinit { srr_endpoint_destroy(id) }

    /// A command (static ones work with `endpoint` 0).
    static func command(_ endpoint: UInt64, _ name: String, _ fields: [String: JSONValue] = [:]) throws -> JSONValue {
        var obj = fields
        obj["cmd"] = .string(name)
        let input = [UInt8](try JSONEncoder().encode(JSONValue.object(obj)))
        var out = [UInt8](repeating: 0, count: 64 << 10)
        let r: SrrResult
        do {
            var span = out.mutableSpan
            r = srr_command(endpoint, input.span, &span)
        }
        let bytes: [UInt8]
        switch r.status {
        case 0: bytes = Array(out.prefix(Int(r.length)))
        case 1: throw RingRTCError.native(String(decoding: out.prefix(Int(r.length)), as: UTF8.self))
        case 2: bytes = try takePending(endpoint, size: Int(r.length))
        default: throw RingRTCError.invalidResponse
        }
        return try JSONDecoder().decode(JSONValue.self, from: Data(bytes))
    }

    func command(_ name: String, _ fields: [String: JSONValue] = [:]) throws -> JSONValue {
        try Self.command(id, name, fields)
    }

    static func takePending(_ endpoint: UInt64, size: Int) throws -> [UInt8] {
        guard size > 0, size <= 256 << 20 else { throw RingRTCError.invalidResponse }
        var out = [UInt8](repeating: 0, count: size)
        let r: SrrResult
        do {
            var span = out.mutableSpan
            r = srr_take_pending(endpoint, &span)
        }
        guard r.status == 0 else { throw RingRTCError.invalidResponse }
        return Array(out.prefix(Int(r.length)))
    }

    /// Blocks up to `timeoutMs` for events (and log messages).
    func waitEvents(timeoutMs: UInt32, buffer: inout [UInt8]) -> [JSONValue] {
        let r: SrrResult
        do {
            var span = buffer.mutableSpan
            r = srr_wait_events(id, timeoutMs, &span)
        }
        let bytes: [UInt8]
        switch r.status {
        case 0: bytes = Array(buffer.prefix(Int(r.length)))
        case 2:
            guard let b = try? Self.takePending(id, size: Int(r.length)) else { return [] }
            bytes = b
        default: return []
        }
        return (try? JSONDecoder().decode([JSONValue].self, from: Data(bytes))) ?? []
    }

    /// False when the frame was refused (bad size, or `data` not exactly one frame).
    @discardableResult
    func sendVideoFrame(width: Int, height: Int, format: VideoPixelFormat, data: [UInt8]) -> Bool {
        guard width > 0, height > 0, width <= 8192, height <= 8192 else { return false }
        return srr_send_video_frame(id, UInt32(width), UInt32(height), format.rawValue, data.span) == 0
    }

    /// The latest remote frame (demux id 0: the 1:1 call) as RGBA into `buffer`.
    func receiveVideoFrame(demuxId: UInt32, maxWidth: Int, maxHeight: Int, into buffer: inout [UInt8]) -> (width: Int, height: Int)? {
        let f: SrrFrame
        do {
            var span = buffer.mutableSpan
            f = srr_receive_video_frame(id, demuxId, UInt32(clamping: maxWidth), UInt32(clamping: maxHeight), &span)
        }
        guard f.status == 0, Int(f.width) * Int(f.height) * 4 <= buffer.count else { return nil }
        return (Int(f.width), Int(f.height))
    }
}

/// `VideoPixelFormatEnum`
public enum VideoPixelFormat: Int32, Sendable {
    case i420 = 0, nv12 = 1, rgba = 2
}

/// The thread that drains an endpoint's events and hands each batch, in order, to the main
/// queue (Node's event loop in upstream).
final class EventPump: Sendable {
    let stopped = Atomic<Bool>(false)

    func start(_ endpoint: NativeEndpoint, deliver: @escaping @Sendable ([JSONValue]) -> Void) {
        let thread = Thread { [self] in
            var buffer = [UInt8](repeating: 0, count: 1 << 20)
            while !self.stopped.load(ordering: .relaxed) {
                let batch = endpoint.waitEvents(timeoutMs: 250, buffer: &buffer)
                if !batch.isEmpty { DispatchQueue.main.async { deliver(batch) } }
            }
        }
        thread.name = "ringrtc.events"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() { stopped.store(true, ordering: .relaxed) }
}
