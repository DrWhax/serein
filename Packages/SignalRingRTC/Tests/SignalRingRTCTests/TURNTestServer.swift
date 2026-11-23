// A loopback TURN server for the relay tests (RFC 8656 with RFC 5389 long-term credentials),
// so they run in every `swift test` without coturn. It mirrors Tools/with-calling-turn.py's
// coturn: realm serein.test, user serein / serein-test-relay, fingerprints, peers only on
// 127.0.0.1, and relay addresses reported as TEST-NET 192.0.2.1 (ICERelayCandidate refuses
// loopback), translated in both directions. UDP and TCP; TLS still needs the coturn runner.
// Its message codec is written independently of the client's TURNMessage on purpose, and
// native RingRTC's own TURN client (TURNInteropTests) exercises it too.

import CryptoKit
import Foundation
import Network
import Synchronization

final class TURNTestServer: Sendable {
    static let realm = "serein.test", username = "serein", password = "serein-test-relay"
    static let external: [UInt8] = [192, 0, 2, 1]

    /// The process-wide server, started on first use.
    static let shared: TURNTestServer = {
        let lease = ProcessInfo.processInfo.environment["SEREIN_TEST_TURN_SHORT_LEASE"] == "1"
        return try! TURNTestServer(lifetime: lease ? 8 : 600, nonceLifetime: lease ? .seconds(2) : .seconds(3600))
    }()

    /// UDP and TCP listeners on loopback; relay sockets are per allocation, also loopback.
    var port: UInt16 { udp.port?.rawValue ?? 0 }
    var tcpPort: UInt16 { tcp.port?.rawValue ?? 0 }
    private let lifetime: UInt32
    private let nonceLifetime: Duration
    private let queue = DispatchQueue(label: "serein.test.turn")
    private let udp: NWListener, tcp: NWListener
    private let state = Mutex(State())
    private static let key = SymmetricKey(data: Data(Insecure.MD5.hash(data: Data("\(username):\(realm):\(password)".utf8))))

    private struct State {
        var nonces: [String: ContinuousClock.Instant] = [:]
        var allocations: [String: Allocation] = [:]   // by client 5-tuple description
    }

    private final class Allocation: Sendable {
        let client: Client
        let relay: NWListener
        var relayPort: UInt16 { relay.port?.rawValue ?? 0 }
        let state: Mutex<Inner>
        struct Inner {
            var expiry: ContinuousClock.Instant
            /// The one permitted peer IP (this machine, as 192.0.2.1), refreshed for 300 s.
            var allowedUntil: ContinuousClock.Instant?
            var peers: [UInt16: NWConnection] = [:]
            var closed = false
        }
        init(client: Client, relay: NWListener, expiry: ContinuousClock.Instant) {
            self.client = client
            self.relay = relay
            state = Mutex(Inner(expiry: expiry))
        }
        var permitted: Bool { state.withLock { !$0.closed && $0.expiry > .now && ($0.allowedUntil.map { $0 > .now } ?? false) } }
        func close() {
            let peers = state.withLock { s -> [NWConnection] in
                s.closed = true
                defer { s.peers.removeAll() }
                return Array(s.peers.values)
            }
            relay.cancel()
            for peer in peers { peer.cancel() }
        }
    }

    /// A client's control connection: one UDP flow or one TCP stream.
    private struct Client: Sendable {
        let connection: NWConnection
        let stream: Bool
        var id: String { "\(stream ? "tcp" : "udp") \(connection.endpoint)" }
        func send(_ message: [UInt8]) { connection.send(content: Data(message), completion: .idempotent) }
    }

    init(lifetime: UInt32, nonceLifetime: Duration) throws {
        self.lifetime = lifetime
        self.nonceLifetime = nonceLifetime
        let udpParameters = NWParameters.udp
        udpParameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        udp = try NWListener(using: udpParameters)
        let tcpParameters = NWParameters.tcp
        tcpParameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        tcp = try NWListener(using: tcpParameters)
        udp.newConnectionHandler = { [weak self] connection in self?.accept(connection, stream: false) }
        tcp.newConnectionHandler = { [weak self] connection in self?.accept(connection, stream: true) }
        for listener in [udp, tcp] {
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
            listener.start(queue: queue)
            guard ready.wait(timeout: .now() + 5) == .success, listener.port != nil else { throw CocoaError(.featureUnsupported) }
        }
    }

    // MARK: control connections

    private func accept(_ connection: NWConnection, stream: Bool) {
        connection.start(queue: queue)
        let client = Client(connection: connection, stream: stream)
        if stream { readStream(client, pending: []) } else { readDatagram(client) }
    }

    private func readDatagram(_ client: Client) {
        client.connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            if let data { self.handle(Array(data), from: client) }
            self.readDatagram(client)
        }
    }

    private func readStream(_ client: Client, pending: [UInt8]) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = pending + (data.map(Array.init) ?? [])
            while buffer.count >= 20 {
                let length = 20 + (Int(buffer[2]) << 8 | Int(buffer[3]))
                guard buffer.count >= length else { break }
                self.handle(Array(buffer[0..<length]), from: client)
                buffer.removeFirst(length)
            }
            if done || error != nil {
                self.release(client)
                return
            }
            self.readStream(client, pending: buffer)
        }
    }

    private func release(_ client: Client) {
        let allocation = state.withLock { $0.allocations.removeValue(forKey: client.id) }
        allocation?.close()
        client.connection.cancel()
    }

    // MARK: TURN methods

    private func handle(_ bytes: [UInt8], from client: Client) {
        guard let message = Message(bytes) else { return }
        switch message.type {
        case 0x0001:   // Binding: the client's address as this server sees it
            client.send(Message.response(0x0101, id: message.id, attributes: [(0x0020, xorAddress(observed(client), id: message.id))], key: nil))
        case 0x0003: allocate(message, client)
        case 0x0004: refresh(message, client)
        case 0x0008: permission(message, client)
        case 0x0016: send(message, client)
        default: break
        }
    }

    /// RFC 5389 §10.2: an unauthenticated request gets 401 with a realm and nonce; a stale
    /// nonce 438. Both answers are unsigned; every other answer is signed.
    private func authenticate(_ message: Message, _ client: Client) -> Bool {
        let now = ContinuousClock.now
        guard let mac = message.integrity, let user = message.string(0x0006), let realm = message.string(0x0014),
              let nonce = message.string(0x0015) else {
            client.send(Message.response(0x0110 | message.type, id: message.id, attributes: challenge(401), key: nil))
            return false
        }
        guard user == Self.username, realm == Self.realm,
              HMAC<Insecure.SHA1>.isValidAuthenticationCode(mac, authenticating: message.signed, using: Self.key) else {
            client.send(Message.response(0x0110 | message.type, id: message.id, attributes: challenge(401), key: nil))
            return false
        }
        let issued = state.withLock { $0.nonces[nonce] }
        guard let issued, issued.duration(to: now) < nonceLifetime else {
            client.send(Message.response(0x0110 | message.type, id: message.id, attributes: challenge(438), key: nil))
            return false
        }
        return true
    }

    private func challenge(_ code: Int) -> [(UInt16, [UInt8])] {
        let nonce = (0..<16).map { _ in String(UInt8.random(in: 0...15), radix: 16) }.joined()
        state.withLock { $0.nonces[nonce] = .now }
        return [(0x0009, errorCode(code)), (0x0014, Array(Self.realm.utf8)), (0x0015, Array(nonce.utf8))]
    }

    private func errorCode(_ code: Int) -> [UInt8] { [0, 0, UInt8(code / 100), UInt8(code % 100)] }

    private func fail(_ message: Message, _ client: Client, _ code: Int) {
        client.send(Message.response(0x0110 | message.type, id: message.id, attributes: [(0x0009, errorCode(code))], key: Self.key))
    }

    private func allocate(_ message: Message, _ client: Client) {
        guard authenticate(message, client) else { return }
        guard message.attribute(0x0019) == [17, 0, 0, 0] else { return fail(message, client, 442) }
        let existing = state.withLock { s in (s.allocations[client.id], s.allocations.count) }
        if existing.0 != nil { return fail(message, client, 437) }
        guard existing.1 < 16 else { return fail(message, client, 486) }
        // As VoiceHostPort: a wildcard listener with reuse, so the connected peer sockets below
        // can share its port (binding 127.0.0.1 on both sides is refused: address in use).
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        guard let relay = try? NWListener(using: parameters) else { return fail(message, client, 508) }
        let allocation = Allocation(client: client, relay: relay, expiry: .now + .seconds(Int(lifetime)))
        relay.newConnectionHandler = { [weak self, weak allocation] peer in
            guard let self, let allocation, case .hostPort(_, let port) = peer.endpoint else { peer.cancel(); return }
            let fresh = allocation.state.withLock { s in
                guard s.peers[port.rawValue] == nil else { return false }
                s.peers[port.rawValue] = peer
                return true
            }
            guard fresh else { peer.cancel(); return }
            peer.start(queue: self.queue)
            self.relay(peer, port: port.rawValue, allocation)
        }
        let ready = DispatchSemaphore(value: 0)
        relay.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        relay.start(queue: DispatchQueue(label: "serein.test.turn.relay"))
        guard ready.wait(timeout: .now() + 2) == .success, allocation.relayPort != 0 else {
            relay.cancel()
            return fail(message, client, 508)
        }
        let relayPort = allocation.relayPort
        state.withLock { $0.allocations[client.id] = allocation }
        client.send(Message.response(0x0103, id: message.id, attributes: [
            (0x0016, xorAddress((Self.external, relayPort), id: message.id)),
            (0x0020, xorAddress(observed(client), id: message.id)),
            (0x000d, bigEndian(lifetime)),
        ], key: Self.key))
    }

    private func refresh(_ message: Message, _ client: Client) {
        guard authenticate(message, client) else { return }
        guard let allocation = live(client) else { return fail(message, client, 437) }
        let requested = message.attribute(0x000d).map { $0.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } } ?? lifetime
        if requested == 0 {
            state.withLock { _ = $0.allocations.removeValue(forKey: client.id) }
            allocation.close()
        } else {
            allocation.state.withLock { $0.expiry = .now + .seconds(Int(min(requested, lifetime))) }
        }
        client.send(Message.response(0x0104, id: message.id, attributes: [(0x000d, bigEndian(requested == 0 ? 0 : min(requested, lifetime)))], key: Self.key))
    }

    /// Only the external TEST-NET address (this machine) is a permitted peer, as coturn's
    /// --denied-peer-ip/--allowed-peer-ip with --external-ip; anything else is 403.
    private func permission(_ message: Message, _ client: Client) {
        guard authenticate(message, client) else { return }
        guard let allocation = live(client) else { return fail(message, client, 437) }
        let peers = message.attributes(0x0012).compactMap { peerAddress($0, id: message.id) }
        guard !peers.isEmpty, peers.allSatisfy({ $0.ip == Self.external }) else { return fail(message, client, 403) }
        allocation.state.withLock { $0.allowedUntil = .now + .seconds(300) }
        client.send(Message.response(0x0108, id: message.id, attributes: [], key: Self.key))
    }

    private func send(_ message: Message, _ client: Client) {
        guard let allocation = live(client), let raw = message.attribute(0x0012), let peer = peerAddress(raw, id: message.id),
              peer.ip == Self.external, let data = message.attribute(0x0013) else { return }
        guard allocation.permitted, let target = NWEndpoint.Port(rawValue: peer.port),
              let local = NWEndpoint.Port(rawValue: allocation.relayPort) else { return }
        // The peer's datagrams then come back on this connected socket, not the relay listener.
        let (connection, fresh): (NWConnection?, Bool) = allocation.state.withLock { s in
            guard !s.closed else { return (nil, false) }
            if let existing = s.peers[peer.port] { return (existing, false) }
            let parameters = NWParameters.udp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.any), port: local)
            let made = NWConnection(to: .hostPort(host: .ipv4(.loopback), port: target), using: parameters)
            s.peers[peer.port] = made
            return (made, true)
        }
        guard let connection else { return }
        if fresh {
            connection.start(queue: queue)
            relay(connection, port: peer.port, allocation)
        }
        connection.send(content: Data(data), completion: .idempotent)
    }

    /// Datagrams from a permitted peer reach the client as Data indications from 192.0.2.1.
    private func relay(_ peer: NWConnection, port: UInt16, _ allocation: Allocation) {
        peer.receiveMessage { [weak self, weak allocation] data, _, _, error in
            guard let self, let allocation, error == nil else { return }
            if allocation.permitted, let data {
                let id = (0..<12).map { _ in UInt8.random(in: .min ... .max) }
                allocation.client.send(Message.response(0x0017, id: id, attributes: [
                    (0x0012, self.xorAddress((Self.external, port), id: id)), (0x0013, Array(data)),
                ], key: nil))
            }
            self.relay(peer, port: port, allocation)
        }
    }

    private func live(_ client: Client) -> Allocation? {
        guard let allocation = state.withLock({ $0.allocations[client.id] }) else { return nil }
        if allocation.state.withLock({ $0.expiry <= .now }) {
            state.withLock { _ = $0.allocations.removeValue(forKey: client.id) }
            allocation.close()
            return nil
        }
        return allocation
    }

    // MARK: addresses

    private func observed(_ client: Client) -> ([UInt8], UInt16) {
        if case .hostPort(.ipv4(let ip), let port) = client.connection.endpoint { return (Array(ip.rawValue), port.rawValue) }
        return ([127, 0, 0, 1], 0)
    }

    private func xorAddress(_ address: ([UInt8], UInt16), id: [UInt8]) -> [UInt8] {
        let port = address.1 ^ 0x2112
        let mask = Message.cookie
        return [0, 1, UInt8(port >> 8), UInt8(port & 0xff)] + zip(address.0, mask).map { $0 ^ $1 }
    }

    private func peerAddress(_ value: [UInt8], id: [UInt8]) -> (ip: [UInt8], port: UInt16)? {
        guard value.count == 8, value[1] == 1 else { return nil }
        let port = (UInt16(value[2]) << 8 | UInt16(value[3])) ^ 0x2112
        return (zip(value[4..<8], Message.cookie).map { $0 ^ $1 }, port)
    }

    private func bigEndian(_ value: UInt32) -> [UInt8] { [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) } }
}

/// RFC 5389 messages, parsed and written here without the client's code.
private struct Message {
    static let cookie: [UInt8] = [0x21, 0x12, 0xa4, 0x42]
    let type: UInt16
    let id: [UInt8]
    private(set) var list: [(UInt16, [UInt8])] = []
    private(set) var integrity: [UInt8]?
    private(set) var signed: [UInt8] = []

    init?(_ bytes: [UInt8]) {
        guard bytes.count >= 20, bytes[0] & 0xc0 == 0, Array(bytes[4..<8]) == Self.cookie else { return nil }
        let length = Int(bytes[2]) << 8 | Int(bytes[3])
        guard bytes.count == 20 + length, length % 4 == 0 else { return nil }
        type = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        id = Array(bytes[8..<20])
        var offset = 20
        while offset + 4 <= bytes.count {
            let kind = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
            let size = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            guard offset + 4 + size <= bytes.count else { return nil }
            let value = Array(bytes[(offset + 4)..<(offset + 4 + size)])
            if kind == 0x0008 {
                // The HMAC covers the header, with its length counting through this attribute.
                var prefix = Array(bytes[0..<offset])
                let through = offset + 24 - 20
                prefix[2] = UInt8(through >> 8)
                prefix[3] = UInt8(through & 0xff)
                signed = prefix
                integrity = value
            } else if integrity == nil, kind != 0x8028 {
                list.append((kind, value))
            }
            offset += 4 + (size + 3) / 4 * 4
        }
    }

    func attribute(_ kind: UInt16) -> [UInt8]? { list.first { $0.0 == kind }?.1 }
    func attributes(_ kind: UInt16) -> [[UInt8]] { list.filter { $0.0 == kind }.map(\.1) }
    func string(_ kind: UInt16) -> String? { attribute(kind).flatMap { String(bytes: $0, encoding: .utf8) } }

    /// Attributes, then MESSAGE-INTEGRITY when keyed, then FINGERPRINT (coturn --fingerprint).
    static func response(_ type: UInt16, id: [UInt8], attributes: [(UInt16, [UInt8])], key: SymmetricKey?) -> [UInt8] {
        var body: [UInt8] = []
        for (kind, value) in attributes {
            body += [UInt8(kind >> 8), UInt8(kind & 0xff), UInt8(value.count >> 8), UInt8(value.count & 0xff)] + value
            body += [UInt8](repeating: 0, count: (4 - value.count % 4) % 4)
        }
        func header(_ length: Int) -> [UInt8] { [UInt8(type >> 8), UInt8(type & 0xff), UInt8(length >> 8), UInt8(length & 0xff)] + cookie + id }
        if let key {
            let mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: header(body.count + 24) + body, using: key))
            body += [0, 0x08, 0, 20] + mac
        }
        let crc = CRC32.of(header(body.count + 8) + body) ^ 0x5354_554e
        body += [0x80, 0x28, 0, 4] + [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: crc >> $0) }
        return header(body.count) + body
    }
}

private enum CRC32 {
    static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 != 0 ? 0xedb8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }
    static func of(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
        return crc ^ 0xffff_ffff
    }
}
