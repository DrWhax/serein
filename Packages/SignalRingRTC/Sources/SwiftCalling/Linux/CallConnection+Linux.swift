#if os(Linux)
import CLinuxCallNetwork
import Foundation
import Synchronization

// These are the parameters the ICE engine configures before opening a UDP socket.
final class NWParameters {
    static var udp: NWParameters { NWParameters() }
    var allowLocalEndpointReuse = false
    var requiredLocalEndpoint: NWEndpoint?
}

final class NWConnection: Sendable {
    enum SendCompletion: Sendable {
        case idempotent, contentProcessed(@Sendable (POSIXError?) -> Void)
        func finish(_ success: Bool) {
            if case .contentProcessed(let callback) = self { callback(success ? nil : POSIXError(.EIO)) }
        }
    }
    struct Dial: Sendable {
        let mode: CallNetMode
        let family: Int32
        let reuse: Bool
        let localPort: UInt16
        let identity: String
        let root: Data
    }
    private struct State {
        var started = false
        var ready = false
        var cancelled = false
        var first: Data?
        var pendingWrites = 0
    }
    let endpoint: NWEndpoint
    private let id: UInt64
    private let dial: Dial?
    private let state: Mutex<State>
    private let connect = DispatchGroup()
    private let input = DispatchQueue(label: "org.serein.call.read", qos: .userInitiated)
    private let output = DispatchQueue(label: "org.serein.call.write", qos: .userInitiated)

    init(to endpoint: NWEndpoint, using settings: NWParameters) {
        let local: UInt16, family: Int32
        switch settings.requiredLocalEndpoint {
        case .hostPort(let host, let port):
            local = port.rawValue
            if case .ipv6 = host { family = 6 } else { family = 4 }
        case nil: local = 0; family = 0
        }
        self.endpoint = endpoint
        dial = Dial(mode: CallDatagram, family: family, reuse: settings.allowLocalEndpointReuse, localPort: local, identity: "", root: Data())
        id = call_net_new()
        state = Mutex(State())
        connect.enter()
    }
    init(to endpoint: NWEndpoint, tlsIdentity: String?, root: Data?) {
        self.endpoint = endpoint
        dial = Dial(mode: tlsIdentity == nil ? CallStream : CallTLS, family: 0, reuse: false, localPort: 0,
                    identity: tlsIdentity ?? "", root: root ?? Data())
        id = call_net_new()
        state = Mutex(State())
        connect.enter()
    }
    fileprivate init(id: UInt64, endpoint: NWEndpoint, first: Data) {
        self.id = id
        self.endpoint = endpoint
        dial = nil
        state = Mutex(State(first: first))
        connect.enter()
    }

    func start(queue: DispatchQueue) {
        guard state.withLock({ s in
            if s.started || s.cancelled { return false }
            s.started = true
            return true
        }) else { return }
        queue.async { [self] in
            var ready = true
            if let dial, case .hostPort(let host, let port) = endpoint {
                ready = call_net_connect(id, Array(host.text.utf8).span, port.rawValue, dial.family, dial.localPort, dial.reuse ? 1 : 0,
                                         dial.mode, Array(dial.identity.utf8).span, Array(dial.root).span) != 0
            }
            state.withLock { $0.ready = ready && !$0.cancelled }
            connect.leave()
        }
    }
    func cancel() {
        let neverStarted = state.withLock { s in
            guard !s.cancelled else { return false }
            s.cancelled = true
            s.ready = false
            s.first = nil
            return !s.started
        }
        call_net_cancel(id)
        if neverStarted { connect.leave() }
    }
    deinit { cancel(); call_net_release(id) }

    // The local address selected for this socket identifies the interface that actually carried the call.
    var currentPath: NWPath? {
        guard state.withLock({ $0.ready }), let endpoint = Self.local(id) else { return nil }
        return NWPath(local: endpoint)
    }
    fileprivate static func local(_ id: UInt64) -> NWEndpoint? {
        var bytes = [UInt8](repeating: 0, count: 16)
        var buffer = bytes.mutableSpan
        let result = call_net_local(id, &buffer)
        return NWEndpoint(bytes: Data(bytes.prefix(Int(result.ip_size))), port: result.port)
    }

    func send(content: Data, completion: SendCompletion) {
        guard content.count <= 65536, state.withLock({ s in
            guard !s.cancelled, s.pendingWrites < 128 else { return false }
            s.pendingWrites += 1
            return true
        }) else { completion.finish(false); return }
        // Keeping one serial send queue preserves RTP and stream byte ordering across setup.
        output.async { [self] in
            connect.wait()
            let ok = state.withLock { $0.ready } && call_net_write(id, Array(content).span) != 0
            state.withLock { $0.pendingWrites -= 1 }
            completion.finish(ok)
        }
    }

    func read(max: Int, completion: @escaping @Sendable (Data?, Bool, POSIXError?) -> Void) {
        input.async { [self] in
            connect.wait()
            guard state.withLock({ $0.ready }) else { completion(nil, false, POSIXError(.ENOTCONN)); return }
            if let first = state.withLock({ s in let first = s.first; s.first = nil; return first }) {
                completion(first, false, nil)
                return
            }
            var bytes = [UInt8](repeating: 0, count: max)
            var buffer = bytes.mutableSpan
            let n = Int(call_net_read(id, &buffer))
            if n < 0 { completion(nil, false, POSIXError(.EIO)); return }
            let stream = dial.map { $0.mode != CallDatagram } ?? false
            completion(Data(bytes.prefix(n)), stream && n == 0, nil)
        }
    }
    func receiveMessage(_ completion: @escaping @Sendable (Data?, Void?, Bool, POSIXError?) -> Void) {
        read(max: 65536) { data, eof, error in completion(data, nil, eof, error) }
    }
}

final class NWListener: Sendable {
    enum State { case setup, ready, failed, cancelled }
    private struct Callbacks {
        var state: State = .setup
        var stateHandler: (@Sendable (State) -> Void)?
        var connectionHandler: (@Sendable (NWConnection) -> Void)?
    }
    private let id: UInt64
    private let callbacks = Mutex(Callbacks())
    let port: NWEndpoint.Port?
    var state: State { callbacks.withLock { $0.state } }
    var stateUpdateHandler: (@Sendable (State) -> Void)? {
        get { callbacks.withLock { $0.stateHandler } }
        set { callbacks.withLock { $0.stateHandler = newValue } }
    }
    var newConnectionHandler: (@Sendable (NWConnection) -> Void)? {
        get { callbacks.withLock { $0.connectionHandler } }
        set { callbacks.withLock { $0.connectionHandler = newValue } }
    }
    init(using settings: NWParameters) throws {
        let handle = call_net_new()
        guard call_net_listen(handle, settings.allowLocalEndpointReuse ? 1 : 0) != 0, case .hostPort(_, let port) = NWConnection.local(handle) else {
            call_net_release(handle)
            throw POSIXError(.EADDRNOTAVAIL)
        }
        id = handle
        self.port = port
    }
    func start(queue: DispatchQueue) {
        queue.async { [self] in
            guard callbacks.withLock({ s in
                guard s.state == .setup else { return false }
                s.state = .ready
                return true
            }) else { return }
            stateUpdateHandler?(.ready)
            var bytes = [UInt8](repeating: 0, count: 65536)
            var ip = [UInt8](repeating: 0, count: 16)
            while state == .ready {
                var payload = bytes.mutableSpan, address = ip.mutableSpan
                let peer = call_net_accept(id, &payload, &address)
                guard peer.id != 0 else {
                    let failed = callbacks.withLock { s in
                        guard s.state == .ready else { return false }
                        s.state = .failed
                        return true
                    }
                    if failed { stateUpdateHandler?(.failed) }
                    break
                }
                guard state == .ready, let handle = newConnectionHandler,
                      let endpoint = NWEndpoint(bytes: Data(ip.prefix(Int(peer.ip_size))), port: peer.port) else {
                    call_net_release(peer.id)
                    continue
                }
                handle(NWConnection(id: peer.id, endpoint: endpoint, first: Data(bytes.prefix(Int(peer.count)))))
            }
        }
    }
    func cancel() {
        let changed = callbacks.withLock { s in
            guard s.state != .cancelled else { return false }
            s.state = .cancelled
            return true
        }
        call_net_cancel(id)
        if changed { stateUpdateHandler?(.cancelled) }
    }
    deinit { call_net_release(id) }
}
#endif
