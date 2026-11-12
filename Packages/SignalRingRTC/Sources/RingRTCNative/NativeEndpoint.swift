// The boundary to libsignal_ringrtc (rust/src/lib.rs): commands and events as JSON, frames
// as byte buffers, all passed as Span / MutableSpan (the header's __counted_by/__noescape
// annotations), so nothing here is `unsafe`. Linked by the calling service
// (SignalCalling.xpc) and by tests; never by the app.

import CSignalRingRTC
import Foundation
import SignalRingRTC
import Synchronization

/// One ringrtc call endpoint (`createCallEndpoint`) in this process.
public final class NativeEndpoint: RingRTCEndpoint {
    let id: UInt64
    /// The event buffer (one waiter at a time).
    let events = Mutex<[UInt8]>([])

    public init?(fieldTrials: String) {
        let bytes = Array(fieldTrials.utf8)
        let id = srr_endpoint_create(bytes.span)
        guard id != 0 else { return nil }
        self.id = id
    }

    deinit { srr_endpoint_destroy(id) }

    /// RingRTC on an endpoint in this process.
    public static let factory: RingRTCEndpointFactory = { trials in
        guard let e = NativeEndpoint(fieldTrials: trials) else { throw RingRTCError.noEndpoint }
        return e
    }

    public var generation: UInt64 { 0 }

    /// A command's JSON in, its result's JSON out (static commands work with `endpoint` 0).
    static func run(_ endpoint: UInt64, _ input: [UInt8]) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 64 << 10)
        let r: SrrResult
        do {
            var span = out.mutableSpan
            r = srr_command(endpoint, input.span, &span)
        }
        switch r.status {
        case 0: return Array(out.prefix(Int(r.length)))
        case 1: throw RingRTCError.native(String(decoding: out.prefix(Int(r.length)), as: UTF8.self))
        case 2: return try takePending(endpoint, size: Int(r.length))
        default: throw RingRTCError.invalidResponse
        }
    }

    /// ringrtc's static commands (no endpoint): the call-link key helpers SignalRingRTC
    /// implements itself, which tests compare with these.
    public static func staticCommand(_ name: String, _ fields: [String: JSONValue] = [:]) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(try run(0, try JSONValue.command(name, fields))))
    }

    /// A command as JSON, its result as JSON (the calling service passes them through).
    public func commandJSON(_ input: [UInt8]) throws -> [UInt8] { try Self.run(id, input) }

    public func command(_ name: String, _ fields: [String: JSONValue], generation: UInt64?) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(try commandJSON(try JSONValue.command(name, fields))))
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

    /// Blocks up to `timeoutMs` for events; their JSON array (`[]` when none came).
    public func waitEventsJSON(timeoutMs: UInt32) -> [UInt8] {
        events.withLock { buffer in
            if buffer.isEmpty { buffer = [UInt8](repeating: 0, count: 1 << 20) }
            let r: SrrResult
            do {
                var span = buffer.mutableSpan
                r = srr_wait_events(id, timeoutMs, &span)
            }
            switch r.status {
            case 0: return Array(buffer.prefix(Int(r.length)))
            case 2: return (try? Self.takePending(id, size: Int(r.length))) ?? Array("[]".utf8)
            default: return Array("[]".utf8)
            }
        }
    }

    public func waitEvents(timeoutMs: UInt32) -> EndpointEvents {
        let bytes = waitEventsJSON(timeoutMs: timeoutMs)
        return .events((try? JSONDecoder().decode([JSONValue].self, from: Data(bytes))) ?? [])
    }

    @discardableResult
    public func sendVideoFrame(width: Int, height: Int, format: VideoPixelFormat, data: [UInt8], generation: UInt64?) -> Bool {
        guard format.frameSize(width: width, height: height) == data.count else { return false }
        return srr_send_video_frame(id, UInt32(width), UInt32(height), format.rawValue, data.span) == 0
    }

    public func receiveVideoFrame(demuxId: UInt32, maxWidth: Int, maxHeight: Int, into buffer: inout [UInt8], generation: UInt64?)
        -> (width: Int, height: Int)?
    {
        let f: SrrFrame
        do {
            var span = buffer.mutableSpan
            f = srr_receive_video_frame(id, demuxId, UInt32(clamping: maxWidth), UInt32(clamping: maxHeight), &span)
        }
        guard f.status == 0, Int(f.width) * Int(f.height) * 4 <= buffer.count else { return nil }
        return (Int(f.width), Int(f.height))
    }

    public func close() {}
}
