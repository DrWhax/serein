import CryptoKit
import Foundation
#if !os(Linux)
import Security
import Network
#endif
import Synchronization

/// The socket is chosen once per call leg. A relay leg wraps every datagram, including
/// connectivity checks and RTCP, with the same authenticated TURN allocation.
final class DirectICETransport: Sendable {
    enum Route {
        case host(ICEHostCandidate)
        case sfuStream(ICEHostCandidate, TURNServerEndpoint)
        case relay(TURNPeerTransport)
    }
    struct Credentials {
        let ufrag: String
        let password: String
    }
    enum Failure: Error { case nominationTimeout, noConsent }

    private enum Socket {
        case udp(NWConnection)
        case stream(RTPStreamSocket)
        case relay(TURNPeerTransport)

        func send(_ bytes: Data) throws {
            switch self {
            case .udp(let connection): connection.send(content: bytes, completion: .idempotent)
            case .stream(let stream): try stream.send(bytes)
            case .relay(let turn): try turn.send(bytes)
            }
        }
        func close() {
            switch self {
            case .udp(let connection): connection.cancel()
            case .stream(let stream): stream.close()
            case .relay(let turn): turn.close()
            }
        }
    }

    private struct State {
        var pair: ICEHostPair
        var timer: Task<Void, Never>?
        var closed = false
    }
    private let socket: Socket
    private let state: Mutex<State>
    let relayed: Bool
    private let receiveMedia: @Sendable (Data) -> Void

    private init(route: Route, relayOnly: Bool, local: Credentials, remote: Credentials,
                 role: ICEBinding.Role, hostPort: NWEndpoint.Port?, inbound: NWConnection?, dialHostname: Bool, trustAnchor: SecCertificate?,
                 nomination: ICENomination?,
                 receive: @escaping @Sendable (Data) -> Void) throws {
        var pair: ICEHostPair
        switch route {
        case .host(let candidate):
            relayed = candidate.isRelay
            pair = try ICEHostPair(candidate: candidate, relayOnly: relayOnly, localUfrag: local.ufrag,
                                   localPassword: local.password, remoteUfrag: remote.ufrag,
                                   remotePassword: remote.password, role: role)
            let parameters = NWParameters.udp
            if let hostPort {
                parameters.allowLocalEndpointReuse = true
                let any: NWEndpoint.Host = candidate.address.ip.count == 4 ? .ipv4(.any) : .ipv6(.any)
                parameters.requiredLocalEndpoint = .hostPort(host: any, port: hostPort)
            }
            socket = .udp(inbound ?? NWConnection(to: candidate.endpoint, using: parameters))
        case .sfuStream(let candidate, let server):
            relayed = false
            guard server.transport != .udp, ICEHostCandidate(observed: server.address)?.address == candidate.address else {
                throw Failure.noConsent
            }
            pair = try ICEHostPair(candidate: candidate, relayOnly: relayOnly, localUfrag: local.ufrag,
                                   localPassword: local.password, remoteUfrag: remote.ufrag,
                                   remotePassword: remote.password, role: role)
            socket = .stream(RTPStreamSocket(server: server, dialHostname: dialHostname, trustAnchor: trustAnchor))
        case .relay(let turn):
            relayed = true
            pair = try ICEHostPair(relay: turn, localUfrag: local.ufrag, localPassword: local.password,
                                   remoteUfrag: remote.ufrag, remotePassword: remote.password, role: role)
            socket = .relay(turn)
        }
        pair.reservation = nomination.map(ICENomination.Reservation.init)
        state = Mutex(State(pair: pair))
        receiveMedia = receive
    }

    static func connect(route: Route, relayOnly: Bool, local: Credentials, remote: Credentials,
                        role: ICEBinding.Role, hostPort: NWEndpoint.Port? = nil, trustAnchor: SecCertificate? = nil, nomination: ICENomination? = nil,
                        receive: @escaping @Sendable (Data) -> Void) async throws -> DirectICETransport {
        // Connected UDP normally shares the advertised host port. Some network paths
        // reject the explicit local bind. ICE can discover an ephemeral source port
        // from authenticated checks for the same remote candidate.
        if let hostPort, case .host = route {
            do {
                return try await nominate(route: route, relayOnly: relayOnly, local: local, remote: remote,
                                          role: role, hostPort: hostPort, nomination: nomination, receive: receive)
            } catch { try Task.checkCancellation() }
        }
        do {
            return try await nominate(route: route, relayOnly: relayOnly, local: local, remote: remote,
                                      role: role, hostPort: nil, trustAnchor: trustAnchor, nomination: nomination, receive: receive)
        } catch {
            guard case .sfuStream(_, let server) = route, let identity = server.tlsHostname, identity != server.host else { throw error }
            try Task.checkCancellation()
            return try await nominate(route: route, relayOnly: relayOnly, local: local, remote: remote,
                                      role: role, hostPort: nil, dialHostname: true, trustAnchor: trustAnchor, nomination: nomination, receive: receive)
        }
    }

    /// Either role can learn a peer-reflexive address. Verify the
    /// initial check before sending any bytes to its source or adopting its socket.
    static func accept(_ connection: NWConnection, candidate: ICEHostCandidate,
                       local: Credentials, remote: Credentials, role: ICEBinding.Role, nomination: ICENomination? = nil,
                       receive: @escaping @Sendable (Data) -> Void) async throws -> DirectICETransport {
        let first = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(1))
        connection.start(queue: DispatchQueue(label: "serein.call.inbound-udp"))
        connection.receiveMessage { data, _, _, error in
            if error == nil, let data, (20...2048).contains(data.count) { first.continuation.yield(data) }
            first.continuation.finish()
        }
        let timeout = Task {
            try await Task.sleep(for: .seconds(1))
            first.continuation.finish()
        }
        defer { timeout.cancel(); first.continuation.finish() }
        for await bytes in first.stream {
            try Task.checkCancellation()
            let check = try ICEBinding(packet: Array(bytes), password: SymmetricKey(data: Data(local.password.utf8)))
            guard !check.isResponse, check.username == local.ufrag + ":" + remote.ufrag else { throw Failure.noConsent }
            switch (role, check.role) {
            case (.controlling, .controlled) where !check.nominated, (.controlled, .controlling): break
            default: throw Failure.noConsent
            }
            return try await nominate(route: .host(candidate), relayOnly: false, local: local, remote: remote,
                                      role: role, hostPort: nil, inbound: connection, first: bytes, nomination: nomination, receive: receive)
        }
        throw Failure.noConsent
    }

    private static func nominate(route: Route, relayOnly: Bool, local: Credentials, remote: Credentials,
                                 role: ICEBinding.Role, hostPort: NWEndpoint.Port?, inbound: NWConnection? = nil, first: Data? = nil, dialHostname: Bool = false, trustAnchor: SecCertificate? = nil, nomination: ICENomination? = nil,
                                 receive: @escaping @Sendable (Data) -> Void) async throws -> DirectICETransport {
        let transport = try DirectICETransport(route: route, relayOnly: relayOnly, local: local, remote: remote,
                                               role: role, hostPort: hostPort, inbound: inbound, dialHostname: dialHostname, trustAnchor: trustAnchor, nomination: nomination, receive: receive)
        do {
            transport.listen(startSocket: inbound == nil)
            if let first { try transport.check(); transport.receive(first) }
            let started = ContinuousClock.now
            let deadline = started.advanced(by: .seconds(8))
            while !transport.hasConsent {
                try transport.check()
                guard ContinuousClock.now < deadline else { throw Failure.nominationTimeout }
                if hostPort != nil, ContinuousClock.now >= started.advanced(by: .seconds(2)),
                   !transport.state.withLock({ $0.pair.hasBindingResponse }) { throw Failure.nominationTimeout }
                try await Task.sleep(for: .milliseconds(40))
            }
            transport.state.withLock { state in
                state.timer = Task { [weak transport] in
                    do {
                        while !Task.isCancelled {
                            try await Task.sleep(for: .milliseconds(500))
                            guard let transport else { return }
                            try transport.check()
                        }
                    } catch { transport?.close() }
                }
            }
            return transport
        } catch {
            transport.close()
            throw error
        }
    }

    private func listen(startSocket: Bool) {
        switch socket {
        case .udp(let connection):
            if startSocket { connection.start(queue: DispatchQueue(label: "serein.call.direct-udp")) }
            read(connection)
        case .stream(let stream):
            stream.start(receive: { [weak self] in self?.receive($0) }, ended: { [weak self] in self?.close() })
        case .relay(let turn):
            turn.receive { [weak self] in self?.receive($0) }
        }
    }
    private func read(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            guard error == nil else { close(); return }
            if let data { receive(data) }
            if !state.withLock({ $0.closed }) { read(connection) }
        }
    }
    private func receive(_ data: Data) {
        guard let first = data.first else { return }
        if first < 2 {
            guard let response = try? state.withLock({ state -> Data? in
                guard !state.closed else { return nil }
                return try state.pair.receive(data, at: .now)
            }) else { return }
            do { try socket.send(response) } catch { close() }
        } else if hasConsent { receiveMedia(data) }
    }
    private var networkPath: NWPath? {
        switch socket {
        case .udp(let connection): return connection.currentPath
        case .relay(let relay): return relay.networkPath
        case .stream(let stream): return stream.networkPath
        }
    }

    var adapter: Int? { networkPath.map { CallNetworkPath($0).adapter } }

    var localHostEndpoint: (address: String, port: Int)? {
        guard !relayed, case let .hostPort(host, port) = networkPath?.localEndpoint else { return nil }
        switch host {
        case .ipv4(let address): return (address.debugDescription, Int(port.rawValue))
        case .ipv6(let address): return (address.debugDescription, Int(port.rawValue))
        default: return nil
        }
    }

    var consented: Bool { hasConsent }
    var lastRoundTrip: (at: ContinuousClock.Instant, milliseconds: Double)? { state.withLock { $0.pair.lastRoundTrip } }
    private var hasConsent: Bool { state.withLock { !$0.closed && $0.pair.canSendMedia(at: .now) } }
    private func check() throws {
        let packet = try state.withLock { state in
            guard !state.closed else { throw Failure.noConsent }
            return try state.pair.check(at: .now)
        }
        if let packet { try socket.send(packet) }
    }
    func send(_ media: Data) throws {
        try state.withLock {
            guard !$0.closed, $0.pair.canSendMedia(at: .now) else { throw Failure.noConsent }
            try socket.send(media)
        }
    }
    func close() {
        let wasOpen = state.withLock { state in
            guard !state.closed else { return false }
            state.closed = true
            state.pair.reservation?.release()
            state.timer?.cancel()
            state.timer = nil
            return true
        }
        if wasOpen { socket.close() }
    }
    deinit { socket.close() }
}
