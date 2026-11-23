import CryptoKit
import Foundation
import Network
import Security
import Synchronization

/// Relay addresses can enter ICE signaling and TURN messages. They never open a socket.
struct ICERelayCandidate: Sendable, Equatable {
    let address: ICEBinding.Address
    private let numericHost: String
    var sdp: String {
        let related = address.ip.count == 4 ? "0.0.0.0" : "::"
        return "candidate:1 1 udp 16777215 \(numericHost) \(address.port) typ relay raddr \(related) rport 0"
    }

    init?(_ sdp: String) {
        guard sdp.utf8.count <= 4096 else { return nil }
        let fields = sdp.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 8, fields[0].hasPrefix("candidate:"), fields[0].count > 10,
              fields[1] == "1", fields[2].lowercased() == "udp", UInt32(fields[3]) != nil,
              let port = UInt16(fields[5]), port > 0, fields[6] == "typ", fields[7] == "relay" else { return nil }
        let host = String(fields[4])
        if let ip = IPv4Address(host) { self.init(address: .init(ip: Array(ip.rawValue), port: port)) }
        else if !host.contains("%"), let ip = IPv6Address(host) { self.init(address: .init(ip: Array(ip.rawValue), port: port)) }
        else { return nil }
    }

    init?(address: ICEBinding.Address) {
        guard address.port > 0, Self.allowedRelay(address.ip) else { return nil }
        if address.ip.count == 4, let ip = IPv4Address(Data(address.ip)) { numericHost = ip.debugDescription }
        else if address.ip.count == 16, let ip = IPv6Address(Data(address.ip)) { numericHost = ip.debugDescription }
        else { return nil }
        self.address = address
    }

    // Signal WebRTC refuses private peer addresses on a TURN port. Keep permissions
    // off the relay's own loopback, local networks and IPv6 transition mechanisms.
    private static func allowedRelay(_ ip: [UInt8]) -> Bool {
        if ip.count == 16 {
            return ip[0] & 0xe0 == 0x20 && !ip.starts(with: [0x20, 0x02]) && !ip.starts(with: [0x3f, 0xfe])
                && !(ip.starts(with: [0x20, 0x01]) && ip[2] < 2)
        }
        guard ip.count == 4, ip[0] > 0, ip[0] < 224, ip[0] != 10, ip[0] != 127 else { return false }
        return !(ip[0] == 100 && (64...127).contains(ip[1])) && !(ip[0] == 172 && (16...31).contains(ip[1]))
            && !ip.starts(with: [169, 254]) && !ip.starts(with: [192, 168])
            && !ip.starts(with: [192, 0, 0]) && !ip.starts(with: [192, 88, 99])
    }
}

/// Owns the single server connection of a relay-only call leg. Its immutable destination
/// is the configured TURN server. Send and Data indications carry ICE checks, RTP and RTCP alike.
private final class TURNSocket: Sendable {
    typealias Failure = TURNMessage.Failure
    typealias Handler = @Sendable (Data) -> Void
    private struct Waiter {
        let method: TURNMessage.Method
        let key: SymmetricKey?
        let stream: AsyncStream<TURNMessage>.Continuation
    }
    private struct State {
        var closed = false
        var queuedBytes = 0
        var transactions: [[UInt8]: Waiter] = [:]
        var peer: ICERelayCandidate?
        var handler: Handler?
    }
    private let state = Mutex(State())
    private let connection: TURNConnection
    private let framer = Mutex(TURNStreamFramer())
    var networkPath: NWPath? { connection.networkPath }

    init(connection: TURNConnection) {
        self.connection = connection
        connection.start()
        read()
    }

    private func read() {
        connection.read { [weak self] bytes, end in
            guard let self else { return }
            if let bytes, !bytes.isEmpty {
                if connection.isStream {
                    do {
                        let packets = try framer.withLock { try $0.append(bytes) }
                        for packet in packets { deliver(packet) }
                    } catch { close(); return }
                } else { deliver(bytes) }
            }
            if end { close() }
            else if !state.withLock({ $0.closed }) { read() }
        }
    }

    private func deliver(_ bytes: Data) {
        guard let message = try? TURNMessage(bytes) else { return }
        if message.type == 0x0017, let source = try? message.address(.peer), let content = message[.data] {
            let sink = state.withLock { !$0.closed && $0.peer?.address == source ? $0.handler : nil }
            sink?(Data(content))
        } else if let waiter = state.withLock({ $0.transactions[message.id] }),
                  message.type == (waiter.method.rawValue | 0x0100) || message.type == (waiter.method.rawValue | 0x0110) {
            if message.acceptsResponse(key: waiter.key) { waiter.stream.yield(message) }
        }
    }

    func close() {
        let released = state.withLock { state -> (Handler?, [AsyncStream<TURNMessage>.Continuation])? in
            guard !state.closed else { return nil }
            state.closed = true
            let handler = state.handler
            state.handler = nil
            let waiters = state.transactions.values.map(\.stream)
            state.transactions.removeAll()
            return (handler, waiters)
        }
        guard let released else { return }
        // A receive closure may own the transport. Releasing it under the lock would
        // call the allocation's deinitializer while this socket is still locked.
        defer { withExtendedLifetime(released.0) {} }
        for waiter in released.1 { waiter.finish() }
        connection.cancel()
    }

    func receive(from peer: ICERelayCandidate, _ sink: @escaping Handler) {
        let previous = state.withLock { state -> Handler? in
            guard !state.closed else { return nil }
            let previous = state.handler
            state.peer = peer
            state.handler = sink
            return previous
        }
        withExtendedLifetime(previous) {}
    }

    func sendMedia(_ data: Data) throws {
        try state.withLock {
            guard !$0.closed else { throw Failure.closed }
            guard data.count <= 1_048_576 - $0.queuedBytes else { throw Failure.backpressure }
            $0.queuedBytes += data.count
        }
        let size = data.count
        connection.send(data) { [weak self] ok in
            guard let self else { return }
            state.withLock { $0.queuedBytes -= size }
            if !ok { close() }
        }
    }

    func deleteAllocation(_ packet: Data) {
        connection.send(packet) { [self] _ in close() }
    }

    func transaction(_ method: TURNMessage.Method, id: [UInt8], packet: Data, key: SymmetricKey?) async throws -> TURNMessage {
        try Task.checkCancellation()
        let (stream, continuation) = AsyncStream<TURNMessage>.makeStream(bufferingPolicy: .bufferingOldest(1))
        try state.withLock {
            guard !$0.closed else { throw Failure.closed }
            guard $0.transactions.count < 4, $0.transactions[id] == nil else { throw Failure.alreadyConnected }
            $0.transactions[id] = Waiter(method: method, key: key, stream: continuation)
        }
        defer {
            _ = state.withLock { $0.transactions.removeValue(forKey: id) }
            continuation.finish()
        }
        return try await withThrowingTaskGroup(of: TURNMessage.self) { group in
            group.addTask {
                for await message in stream { return message }
                throw Failure.closed
            }
            group.addTask { [self] in
                // RFC 8489. A stream carries each transaction once; UDP retransmits.
                let delays = connection.isStream ? [15_500] : [500, 1000, 2000, 4000, 8000]
                for delay in delays {
                    try Task.checkCancellation()
                    try sendMedia(packet)
                    try await Task.sleep(for: .milliseconds(delay))
                }
                throw Failure.timeout
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw Failure.closed }
            return value
        }
    }
}

final class TURNAllocation: Sendable {
    private typealias Attr = TURNMessage.Attribute
    private struct Auth: Sendable {
        let realm: [UInt8]
        var nonce: [UInt8]
        let key: SymmetricKey
    }
    private struct State {
        var auth: Auth
        var expiry: ContinuousClock.Instant
        var permissionExpiry: ContinuousClock.Instant?
        var connecting = false
        var closed = false
        var upkeep: Task<Void, Never>?

        var activePermission: Bool {
            guard !closed, let permissionExpiry else { return false }
            let now = ContinuousClock.now
            return permissionExpiry > now && expiry > now
        }
    }
    fileprivate var networkPath: NWPath? { socket.networkPath }
    let localCandidate: ICERelayCandidate
    private let socket: TURNSocket
    private let username: [UInt8]
    private let state: Mutex<State>

    private init(socket: TURNSocket, username: [UInt8], auth: Auth, candidate: ICERelayCandidate, lifetime: UInt32) {
        self.socket = socket
        self.username = username
        self.localCandidate = candidate
        state = Mutex(State(auth: auth, expiry: .now.advanced(by: .seconds(lifetime))))
    }

    deinit { socket.close() }

    static func open(server: TURNServerEndpoint, username: String, password: String,
                     trustAnchor: SecCertificate? = nil) async throws -> TURNAllocation {
        do {
            return try await allocate(through: TURNConnection(server: server, dialHostname: false, trustAnchor: trustAnchor),
                                      username: username, password: password)
        } catch let error as TURNMessage.Failure {
            guard let name = server.tlsHostname, name != server.host else { throw error }
            switch error {
            case .closed, .timeout:
                try Task.checkCancellation()
                return try await allocate(through: TURNConnection(server: server, dialHostname: true, trustAnchor: trustAnchor),
                                          username: username, password: password)
            default: throw error
            }
        }
    }

    private static func allocate(through connection: TURNConnection, username: String, password: String) async throws -> TURNAllocation {
        // Signal issues opaque ASCII credentials. Reject other profiles before deriving a key.
        guard (1...509).contains(username.utf8.count), (1...1024).contains(password.utf8.count),
              username.utf8.allSatisfy({ (0x21...0x7e).contains($0) }), password.utf8.allSatisfy({ (0x20...0x7e).contains($0) })
        else { connection.cancel(); throw TURNMessage.Failure.invalidCredentials }
        let socket = TURNSocket(connection: connection)
        do {
            let id = TURNMessage.newID()
            let transport: [(Attr, [UInt8])] = [(.transport, [17, 0, 0, 0])]
            let request = try TURNMessage.packet(TURNMessage.Method.allocate.rawValue, id: id, attributes: transport)
            let challenge = try await socket.transaction(.allocate, id: id, packet: request, key: nil)
            guard challenge.type == 0x0113, challenge.errorCode == 401, let realm = challenge[.realm],
                  !realm.isEmpty, realm.count <= 763, let nonce = challenge.legacyNonce else {
                throw TURNMessage.Failure.server(challenge.errorCode ?? 0)
            }
            let name = Array(username.utf8)
            let credentials = name + [58] + realm + [58] + password.utf8
            let key = SymmetricKey(data: Insecure.MD5.hash(data: credentials))
            var auth = Auth(realm: realm, nonce: nonce, key: key)
            let result = try await exchange(.allocate, socket: socket, username: name, auth: &auth) { _ in transport }
            guard let candidate = try ICERelayCandidate(address: result.address(.relayed)) else { throw TURNMessage.Failure.malformed }
            let lifetime = try result.lifetime()
            guard lifetime > 0 else { throw TURNMessage.Failure.closed }
            return TURNAllocation(socket: socket, username: name, auth: auth, candidate: candidate, lifetime: lifetime)
        } catch { socket.close(); throw error }
    }

    private static func exchange(_ method: TURNMessage.Method, socket: TURNSocket, username: [UInt8], auth: inout Auth,
                                 fields: ([UInt8]) throws -> [(Attr, [UInt8])]) async throws -> TURNMessage {
        for attempt in 0...1 {
            let id = TURNMessage.newID()
            let attributes = try fields(id) + [(.username, username), (.realm, auth.realm), (.nonce, auth.nonce)]
            let request = try TURNMessage.packet(method.rawValue, id: id, attributes: attributes, key: auth.key)
            let result = try await socket.transaction(method, id: id, packet: request, key: auth.key)
            if result.type == (method.rawValue | 0x0100) { return result }
            guard attempt == 0, result.errorCode == 438, result[.realm] == auth.realm, let nonce = result.legacyNonce else {
                throw TURNMessage.Failure.server(result.errorCode ?? 0)
            }
            auth.nonce = nonce
        }
        throw TURNMessage.Failure.invalidCredentials
    }

    private func renew(_ peer: ICERelayCandidate, allocation: Bool) async throws {
        var auth = try state.withLock {
            guard !$0.closed, $0.expiry > .now else { throw TURNMessage.Failure.closed }
            return $0.auth
        }
        if allocation {
            let response = try await Self.exchange(.refresh, socket: socket, username: username, auth: &auth) { _ in [] }
            let lifetime = try response.lifetime()
            guard lifetime > 0 else { throw TURNMessage.Failure.closed }
            state.withLock { $0.expiry = .now.advanced(by: .seconds(lifetime)); $0.auth = auth }
        }
        _ = try await Self.exchange(.permission, socket: socket, username: username, auth: &auth) { id in
            [(.peer, try TURNMessage.xorAddress(peer.address, id: id))]
        }
        state.withLock { $0.permissionExpiry = .now.advanced(by: .seconds(300)); $0.auth = auth }
    }

    func connect(to peer: ICERelayCandidate) async throws -> TURNPeerTransport {
        try state.withLock {
            guard !$0.closed else { throw TURNMessage.Failure.closed }
            guard !$0.connecting else { throw TURNMessage.Failure.alreadyConnected }
            $0.connecting = true
        }
        do {
            try await renew(peer, allocation: false)
            let upkeep = Task { [weak self] in
                while let deadline = self?.state.withLock({ min($0.expiry, $0.permissionExpiry ?? .now) }) {
                    let remaining = ContinuousClock.now.duration(to: deadline)
                    do {
                        guard remaining > .zero else { throw TURNMessage.Failure.closed }
                        try await Task.sleep(for: remaining / 2)
                        try await self?.renew(peer, allocation: true)
                    } catch { self?.close(); return }
                }
            }
            try state.withLock {
                guard !$0.closed else { upkeep.cancel(); throw TURNMessage.Failure.closed }
                $0.upkeep = upkeep
            }
            return TURNPeerTransport(allocation: self, peer: peer)
        } catch { close(); throw error }
    }

    fileprivate func receive(from peer: ICERelayCandidate, _ sink: @escaping @Sendable (Data) -> Void) {
        socket.receive(from: peer) { [weak self] packet in
            if self?.state.withLock({ $0.activePermission }) == true { sink(packet) }
        }
    }

    fileprivate func send(_ data: Data, to peer: ICERelayCandidate) throws {
        guard data.count <= 65_447 else { throw TURNMessage.Failure.malformed }
        let id = TURNMessage.newID()
        let packet = try TURNMessage.packet(0x0016, id: id, attributes: [(.peer, try TURNMessage.xorAddress(peer.address, id: id)), (.data, Array(data))])
        try state.withLock {
            guard $0.activePermission else { throw TURNMessage.Failure.closed }
            try socket.sendMedia(packet)
        }
    }

    func close() {
        let auth = state.withLock { state -> Auth? in
            guard !state.closed else { return nil }
            state.closed = true
            state.upkeep?.cancel()
            state.upkeep = nil
            return state.auth
        }
        guard let auth else { return }
        // Best-effort deletion. An unreachable server eventually expires the allocation.
        let attributes: [(Attr, [UInt8])] = [(.lifetime, [0, 0, 0, 0]), (.username, username), (.realm, auth.realm), (.nonce, auth.nonce)]
        if let packet = try? TURNMessage.packet(TURNMessage.Method.refresh.rawValue, id: TURNMessage.newID(), attributes: attributes, key: auth.key) {
            socket.deleteAllocation(packet)
        } else { socket.close() }
    }
}

struct TURNPeerTransport: Sendable {
    var networkPath: NWPath? { allocation.networkPath }
    fileprivate let allocation: TURNAllocation
    let peer: ICERelayCandidate
    func receive(_ sink: @escaping @Sendable (Data) -> Void) { allocation.receive(from: peer, sink) }
    func send(_ datagram: Data) throws { try allocation.send(datagram, to: peer) }
    func close() { allocation.close() }
}
