#if os(Linux)
import CLinuxServiceSocket
import Foundation
import LinuxServiceTransport
import Synchronization

/// The supervisor gives each process only its edges in the service graph.
/// Each route is an inherited Unix socket pair. A new session and then each
/// individual request get independent descriptors passed via SCM_RIGHTS.
private enum Route: Int32 {
    case decoder = 160, parser, fetcher, gifs, voice, calling, messages, fetcherToParser

    init(service: String) throws {
        switch service {
        case "org.signalsafe.SignalMediaDecoder": self = .decoder
        case "org.signalsafe.SignalLinkPreviewParser": self = .parser
        case "org.signalsafe.SignalLinkPreviewFetcher": self = .fetcher
        case "org.signalsafe.SignalGifSearch": self = .gifs
        case "org.signalsafe.SignalVoiceNoteEncoder": self = .voice
        case "org.signalsafe.SignalCalling": self = .calling
        case "org.signalsafe.SignalMessageParser": self = .messages
        default: throw XPCServiceError.lost("unknown Linux service")
        }
    }

    var server: XPCPeer {
        switch self {
        case .decoder: .decoder
        case .parser, .fetcherToParser: .parser
        case .fetcher: .fetcher
        case .gifs: .gifs
        case .voice: .voice
        case .calling: .calling
        case .messages: .messageParser
        }
    }
}

public enum XPCPeer: String, Sendable, CaseIterable {
    case app, decoder, parser, fetcher, gifs, voice, calling, messageParser = "messages"
    public static func requirement(_ peer: XPCPeer) -> XPCPeerRequirement? { peer }
    public static func required(_ peer: XPCPeer, by service: String) -> XPCPeerRequirement { peer }
}
public typealias XPCPeerRequirement = XPCPeer

public struct XPCEndpoint: Sendable {
    fileprivate let high: UInt64
    fileprivate let low: UInt64
}

public enum XPCTarget: Sendable {
    case service(String)
    case endpoint(XPCEndpoint)

    func open(peer: XPCPeer?) throws -> Socket {
        let route: Route
        let token: XPCEndpoint
        switch self {
        case .service(let name):
            route = try Route(service: name)
            token = .init(high: 0, low: 0)
        case .endpoint(let endpoint):
            route = .fetcherToParser
            token = endpoint
        }
        guard peer == nil || peer == route.server else { throw XPCServiceError.lost("wrong service role") }
        let control = try Socket(serein_duplicate_route(route.rawValue))
        return try Socket(serein_open_channel(control.fd, 0, token.high, token.low))
    }
}

final class Socket: Sendable {
    let handle: FileHandle
    var fd: Int32 { handle.fileDescriptor }

    init(_ fd: Int32) throws {
        guard fd >= 0 else { throw XPCServiceError.lost("service channel unavailable") }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    func interrupt() { serein_interrupt_channel(fd) }
}

public struct XPCMessage: Sendable {
    public var payload: Data?
    public var endpoint: XPCEndpoint?
    public var error: String?

    public init(payload: Data? = nil, endpoint: XPCEndpoint? = nil, error: String? = nil) {
        self.payload = payload
        self.endpoint = endpoint
        self.error = error
    }

    public func result() throws -> Data {
        guard let payload else { throw MediaProcessingError.undecodable(error ?? "no reply") }
        return payload
    }

    public func requirePayload() throws -> Data {
        guard let payload else { throw MediaProcessingError.invalidResult }
        return payload
    }

    // Metadata is bounded independently of the payload. Endpoint tokens never
    // grant access to a route that the supervisor did not give to the process.
    func write(to socket: Socket) throws {
        var header = Data([1, (payload == nil ? 0 : 1) | (endpoint == nil ? 0 : 2) | (error == nil ? 0 : 4)])
        if let endpoint {
            for word in [endpoint.high, endpoint.low] {
                for shift in stride(from: 0, to: 64, by: 8) { header.append(UInt8(truncatingIfNeeded: word >> shift)) }
            }
        }
        if let error {
            for scalar in error.unicodeScalars {
                let bytes = String(scalar).utf8
                guard header.count + bytes.count <= 2 + (endpoint == nil ? 0 : 16) + 512 else { break }
                header.append(contentsOf: bytes)
            }
        }
        try LinuxServiceTransport.write(header, to: socket.handle)
        if let payload { try LinuxServiceTransport.write(payload, to: socket.handle) }
    }

    static func read(from socket: Socket, maxPayload: Int) throws -> Self {
        guard let header = try LinuxServiceTransport.read(socket.handle, maxBytes: 530) else {
            throw XPCServiceError.lost("service closed the request")
        }
        guard header.count >= 2,
              header[0] == 1, header[1] < 8 else { throw MediaProcessingError.invalidResult }
        let flags = header[1]
        let start = flags & 2 == 0 ? 2 : 18
        guard header.count >= start else { throw MediaProcessingError.invalidResult }
        var message = Self()
        if flags & 2 != 0 {
            func word(_ first: Int) -> UInt64 {
                (0..<8).reduce(0) { $0 | UInt64(header[first + $1]) << (8 * $1) }
            }
            message.endpoint = .init(high: word(2), low: word(10))
        }
        if flags & 4 != 0 {
            guard header.count - start <= 512,
                  let detail = String(data: header.dropFirst(start), encoding: .utf8) else { throw MediaProcessingError.invalidResult }
            message.error = detail
        } else if header.count != start { throw MediaProcessingError.invalidResult }
        if flags & 1 != 0 {
            guard let payload = try LinuxServiceTransport.read(socket.handle, maxBytes: maxPayload) else { throw MediaProcessingError.invalidResult }
            message.payload = payload
        }
        return message
    }
}

public protocol XPCMessageHandler: Sendable {
    var maxRequestBytes: Int { get }
    func reply(to request: XPCMessage) async throws -> XPCMessage
    func sessionEnded()
}
extension XPCMessageHandler { public func sessionEnded() {} }

final class ActiveRequests: Sendable {
    private struct State {
        var ended = false
        var sockets: [Int32: Socket] = [:]
    }
    private let state = Mutex(State())

    func insert(_ socket: Socket) -> Bool {
        state.withLock {
            guard !$0.ended, $0.sockets.count < 64 else { return false }
            $0.sockets[socket.fd] = socket
            return true
        }
    }
    func remove(_ socket: Socket) { _ = state.withLock { $0.sockets.removeValue(forKey: socket.fd) } }
    func end() {
        let active = state.withLock { state in
            state.ended = true
            defer { state.sockets.removeAll() }
            return state.sockets
        }
        for socket in active.values { socket.interrupt() }
    }
}

public enum XPCServer {
    public static func serve(_ name: String, requirement: XPCPeerRequirement, _ handler: some XPCMessageHandler) -> Never {
        serve(name, requirement: requirement, sessions: { handler })
    }

    public static func serve<H: XPCMessageHandler>(_ name: String, requirement: XPCPeerRequirement,
                                                   sessions make: @escaping @Sendable () throws -> H) -> Never {
        guard let route = try? Route(service: name), requirement == .app else { exit(78) }
        listen(route, token: .init(high: 0, low: 0), sessions: make)
        exit(78)
    }

    fileprivate static func listen<H: XPCMessageHandler>(_ route: Route, token: XPCEndpoint,
                                                         sessions make: @escaping @Sendable () throws -> H) {
        guard let listener = try? Socket(serein_duplicate_route(route.rawValue)) else { return }
        let capacity = DispatchSemaphore(value: 32)
        while let session = try? Socket(serein_accept_channel(listener.fd, 0, token.high, token.low)) {
            guard capacity.wait(timeout: .now()) == .success else { continue }
            DispatchQueue.global().async {
                defer { capacity.signal() }
                guard let handler = try? make() else { return }
                let active = ActiveRequests()
                defer { active.end(); handler.sessionEnded() }
                while let request = try? Socket(serein_accept_channel(session.fd, 1, 0, 0)) {
                    guard active.insert(request) else { continue }
                    DispatchQueue.global().async {
                        do {
                            let message = try XPCMessage.read(from: request, maxPayload: handler.maxRequestBytes)
                            Task {
                                let reply: XPCMessage
                                do { reply = try await handler.reply(to: message) }
                                catch { reply = .init(error: String(describing: error)) }
                                DispatchQueue.global().async {
                                    defer { active.remove(request) }
                                    try? reply.write(to: request)
                                }
                            }
                        } catch {
                            active.remove(request)
                        }
                    }
                }
            }
        }
    }
}

public final class EndpointService: XPCMessageHandler {
    private let endpoint: XPCEndpoint

    public init(requirement: XPCPeerRequirement?, _ handler: some XPCMessageHandler) {
        guard requirement == .fetcher else { exit(78) }
        let endpoint = XPCEndpoint(high: .random(in: .min ... .max), low: .random(in: .min ... .max))
        self.endpoint = endpoint
        DispatchQueue.global().async {
            XPCServer.listen(.fetcherToParser, token: endpoint, sessions: { handler })
        }
    }
    public var maxRequestBytes: Int { 0 }
    public func reply(to request: XPCMessage) async throws -> XPCMessage {
        guard request.payload == nil else { throw MediaProcessingError.unsupportedFormat }
        return .init(endpoint: endpoint)
    }
}
#endif
