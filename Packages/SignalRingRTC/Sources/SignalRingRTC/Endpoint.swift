// What RingRTC drives: one ringrtc call endpoint, through its commands and events (JSON, as
// rust/src/commands.rs and events.rs define them) and its video frames. The endpoint is either
// in this process (RingRTCNative: tests, and the calling service itself) or in the calling
// service, SignalCalling.xpc (CallXPC: the app). The app never loads ringrtc: WebRTC, its
// network stack and the call audio run in that sandboxed process.
//
// A remote endpoint can be lost (its process crashed, or stopped answering). Its `generation`
// then moves on: everything made on an earlier generation (calls, group call clients) is gone,
// and a command or frame for it is refused rather than reaching whatever the new endpoint has
// under the same number. The event wait reports the loss once, so RingRTC ends those calls.

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

    public static func bytes(_ d: Data) -> JSONValue { .string(d.base64EncodedString()) }
    public static func bytes(_ d: Data?) -> JSONValue { d.map { .string($0.base64EncodedString()) } ?? .null }
    public static func id(_ v: UInt64) -> JSONValue { .string(String(v)) }

    /// A command as ringrtc reads it: the fields plus `cmd`.
    public static func command(_ name: String, _ fields: [String: JSONValue]) throws -> [UInt8] {
        var obj = fields
        obj["cmd"] = .string(name)
        return [UInt8](try JSONEncoder().encode(JSONValue.object(obj)))
    }
}

public enum RingRTCError: Error, Equatable, Sendable {
    case native(String)
    case noEndpoint
    case invalidResponse
    /// The endpoint is gone (the calling service ended), or the call belongs to one that is.
    case lost
}

/// `VideoPixelFormatEnum`
public enum VideoPixelFormat: Int32, Sendable {
    case i420 = 0, nv12 = 1, rgba = 2

    /// The bytes of one packed frame (rust/src/commands.rs `frame_size`); nil for empty or
    /// oversized dimensions.
    public func frameSize(width: Int, height: Int) -> Int? {
        guard (1...8192).contains(width), (1...8192).contains(height) else { return nil }
        switch self {
        case .i420, .nv12: return width * height + 2 * ((width + 1) / 2) * ((height + 1) / 2)
        case .rgba: return width * height * 4
        }
    }
}

/// What a wait for events found.
public enum EndpointEvents: Sendable, Equatable {
    case events([JSONValue])
    /// The endpoint was lost: everything made on generations up to `generation` is gone.
    case lost(generation: UInt64)
}

/// One ringrtc call endpoint (`createCallEndpoint`).
public protocol RingRTCEndpoint: AnyObject, Sendable {
    /// Moves on each time the endpoint is lost (always 0 in process).
    var generation: UInt64 { get }
    /// A command's result. With `generation`, refused (`RingRTCError.lost`) unless the endpoint
    /// is still that generation; without, a lost endpoint is replaced first.
    func command(_ name: String, _ fields: [String: JSONValue], generation: UInt64?) throws -> JSONValue
    /// Blocks up to `timeoutMs` for events (and log messages).
    func waitEvents(timeoutMs: UInt32) -> EndpointEvents
    /// False when the frame was refused (bad size, `data` not exactly one frame, another
    /// generation) or dropped.
    @discardableResult
    func sendVideoFrame(width: Int, height: Int, format: VideoPixelFormat, data: [UInt8], generation: UInt64?) -> Bool
    /// The newest remote frame of `demuxId` (0: the 1:1 call) since the last one handed out, as
    /// RGBA into `buffer`; it fits `maxWidth`×`maxHeight` in either orientation.
    func receiveVideoFrame(demuxId: UInt32, maxWidth: Int, maxHeight: Int, into buffer: inout [UInt8], generation: UInt64?) -> (width: Int, height: Int)?
    /// RingRTC is done with it (replaced by `setConfig`, or released).
    func close()
}

extension RingRTCEndpoint {
    public func command(_ name: String, _ fields: [String: JSONValue] = [:]) throws -> JSONValue {
        try command(name, fields, generation: nil)
    }
}

/// Makes an endpoint with ringrtc's field-trial string (`Name/Value/…/`).
public typealias RingRTCEndpointFactory = @Sendable (_ fieldTrials: String) throws -> any RingRTCEndpoint

/// The thread that drains an endpoint's events and hands each batch, in order, to the main
/// queue (Node's event loop in upstream); a loss is handed over the same way.
final class EventPump: Sendable {
    let stopped = Atomic<Bool>(false)

    func start(_ endpoint: any RingRTCEndpoint, deliver: @escaping @Sendable (EndpointEvents) -> Void) {
        let thread = Thread { [self] in
            while !self.stopped.load(ordering: .relaxed) {
                let found = endpoint.waitEvents(timeoutMs: 250)
                if case .events(let batch) = found, batch.isEmpty { continue }
                DispatchQueue.main.async { deliver(found) }
            }
        }
        thread.name = "ringrtc.events"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() { stopped.store(true, ordering: .relaxed) }
}
