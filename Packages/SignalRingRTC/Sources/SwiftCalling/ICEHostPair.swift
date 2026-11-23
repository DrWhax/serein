import CryptoKit
import Foundation
import Network
import Synchronization

/// RFC 8445 regular nomination. A controlling agent may check multiple pairs
/// concurrently, but only one can carry USE-CANDIDATE for this ICE generation.
final class ICENomination: Sendable {
    private let selected = Mutex<UUID?>(nil)

    final class Reservation: Sendable {
        private let id = UUID()
        private let election: ICENomination
        init(_ election: ICENomination) { self.election = election }
        func claim() -> Bool {
            election.selected.withLock {
                if $0 == nil { $0 = id }
                return $0 == id
            }
        }
        func release() { election.selected.withLock { if $0 == id { $0 = nil } } }
        deinit { release() }
    }
}

/// A numeric remote address for a local UDP socket.
/// Never resolve a name from remote signaling.
struct ICEHostCandidate: Sendable {
    let isRelay: Bool
    let endpoint: NWEndpoint
    let address: ICEBinding.Address

    init?(observed endpoint: NWEndpoint) {
        guard case .hostPort(let host, let port) = endpoint, port.rawValue > 0 else { return nil }
        switch host {
        case .ipv4(let ip): address = .init(ip: Array(ip.rawValue), port: port.rawValue)
        case .ipv6(let ip): address = .init(ip: Array(ip.rawValue), port: port.rawValue)
        default: return nil
        }
        isRelay = false
        self.endpoint = endpoint
    }

    init?(_ sdp: String) { self.init(sdp, relay: false) }

    init?(_ sdp: String, relay: Bool) {
        guard sdp.utf8.count <= 4096 else { return nil }
        let parts = sdp.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 8, parts[0].hasPrefix("candidate:"), parts[0].count > 10,
              parts[1] == "1", parts[2].lowercased() == "udp", UInt32(parts[3]) != nil,
              parts[6] == "typ", (relay ? parts[7] == "relay" : parts[7] == "host" || parts[7] == "srflx"),
              let number = UInt16(parts[5]), number != 0,
              let port = NWEndpoint.Port(rawValue: number) else { return nil }
        let host: NWEndpoint.Host
        if let ip = IPv4Address(String(parts[4])) {
            host = .ipv4(ip)
            address = .init(ip: Array(ip.rawValue), port: number)
        } else if let ip = IPv6Address(String(parts[4])) {
            host = .ipv6(ip)
            address = .init(ip: Array(ip.rawValue), port: number)
        } else { return nil }
        isRelay = relay
        endpoint = .hostPort(host: host, port: port)
    }
}

/// Connectivity, regular nomination and consent for one UDP pair with fixed roles.
/// Relay-only callers supply the permission-bound TURN transport for this ICE pair.
struct ICEHostPair: Sendable {
    enum Failure: Error { case relayRequired, credentials, expired }
    typealias Instant = ContinuousClock.Instant

    private let localKey: SymmetricKey
    private let remoteKey: SymmetricKey
    private let incomingName: String
    private let outgoingName: String
    private let peerAddress: ICEBinding.Address
    private let role: ICEBinding.Role
    private var pending: [UInt8]?
    private var pendingPacket: Data?
    private var pendingSent: Instant?
    private(set) var lastRoundTrip: (at: Instant, milliseconds: Double)?
    private var consentRequests: [[UInt8]: Instant] = [:]
    var reservation: ICENomination.Reservation?
    private var pendingNomination = false
    private var remoteNominated = false
    private var nominated = false
    private var lastSuccess: Instant?
    private var nextCheck: Instant?
    private var started: Instant?
    private var expired = false

    init(candidate: ICEHostCandidate, relayOnly: Bool, localUfrag: String, localPassword: String,
         remoteUfrag: String, remotePassword: String, role: ICEBinding.Role) throws {
        guard !relayOnly else { throw Failure.relayRequired }
        try self.init(peerAddress: candidate.address, localUfrag: localUfrag, localPassword: localPassword,
                      remoteUfrag: remoteUfrag, remotePassword: remotePassword, role: role)
    }

    init(relay: TURNPeerTransport, localUfrag: String, localPassword: String,
         remoteUfrag: String, remotePassword: String, role: ICEBinding.Role) throws {
        try self.init(peerAddress: relay.peer.address, localUfrag: localUfrag, localPassword: localPassword,
                      remoteUfrag: remoteUfrag, remotePassword: remotePassword, role: role)
    }

    private init(peerAddress: ICEBinding.Address, localUfrag: String, localPassword: String,
                 remoteUfrag: String, remotePassword: String, role: ICEBinding.Role) throws {
        guard Self.valid(localUfrag, min: 4), Self.valid(remoteUfrag, min: 4),
              Self.valid(localPassword, min: 22), Self.valid(remotePassword, min: 22) else { throw Failure.credentials }
        self.peerAddress = peerAddress
        self.role = role
        localKey = SymmetricKey(data: Data(localPassword.utf8))
        remoteKey = SymmetricKey(data: Data(remotePassword.utf8))
        incomingName = localUfrag + ":" + remoteUfrag
        outgoingName = remoteUfrag + ":" + localUfrag
    }

    /// RFC 8445 §5.3: an ice-pwd carries at least 128 bits of randomness. 24 ice-chars from the
    /// system generator carry 144, as WebRTC's do.
    static func randomPassword() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
        return String(decoding: (0..<24).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] }, as: UTF8.self)
    }

    static func valid(_ field: String, min: Int) -> Bool {
        (min...256).contains(field.utf8.count) && field.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 43 || $0 == 47
        }
    }

    var hasBindingResponse: Bool { lastSuccess != nil }

    func canSendMedia(at now: Instant) -> Bool {
        guard !expired, nominated, let lastSuccess else { return false }
        return now < lastSuccess.advanced(by: .seconds(30))
    }

    private mutating func checkDeadline(_ now: Instant) throws {
        if let since = lastSuccess ?? started, now >= since.advanced(by: .seconds(30)) { expired = true }
        if expired {
            consentRequests.removeAll()
            pending = nil
            pendingPacket = nil
            throw Failure.expired
        }
    }

    /// Poll during initial connectivity checks. After nomination each consent request has a
    /// new unpredictable transaction ID and is sent once, at randomized 4–6 second intervals.
    mutating func check(at now: Instant) throws -> Data? {
        try checkDeadline(now)
        if started == nil { started = now }
        if let nextCheck, now < nextCheck { return nil }
        if !nominated, let pendingPacket {
            pendingSent = nil // A retransmission makes the corresponding RTT ambiguous.
            nextCheck = now.advanced(by: .milliseconds(500))
            return pendingPacket
        }
        let transaction = (0..<12).map { _ in UInt8.random(in: .min ... .max) }
        let nominate: Bool
        if case .controlling = role { nominate = lastSuccess != nil && !nominated } else { nominate = false }
        if nominate, reservation?.claim() == false {
            nextCheck = now.advanced(by: .milliseconds(100))
            return nil
        }
        let packet = try ICEBinding.request(transaction: transaction, username: outgoingName, role: role,
                                            priority: (110 << 24) | (65_535 << 8) | 255, nominate: nominate, password: remoteKey)
        let interval: Duration = nominated ? .milliseconds(Int.random(in: 4000...6000)) : .milliseconds(500)
        if nominated {
            consentRequests = consentRequests.filter { $0.value > now }
            consentRequests[transaction] = now.advanced(by: .seconds(30))
        } else {
            pending = transaction
            pendingSent = now
            pendingPacket = Data(packet)
        }
        pendingNomination = nominate
        nextCheck = now.advanced(by: interval)
        return Data(packet)
    }

    private mutating func nominate(at now: Instant) {
        if !nominated {
            nominated = true
            nextCheck = now.advanced(by: .milliseconds(Int.random(in: 4000...6000)))
        }
    }

    mutating func receive(_ data: Data, at now: Instant) throws -> Data? {
        try checkDeadline(now)
        guard started != nil, let first = data.first, data.count <= 65_507 else { return nil }
        if first == 1 {
            let reply = try ICEBinding(packet: Array(data), password: remoteKey)
            let expires = consentRequests.removeValue(forKey: reply.transaction)
            let liveConsent = expires.map { now < $0 } ?? false
            guard reply.isResponse, reply.transaction == pending || liveConsent else { return nil }
            if let code = reply.errorCode {
                if code == 403 {
                    expired = true
                    try checkDeadline(now)
                }
                return nil
            }
            if !liveConsent {
                pending = nil
                pendingPacket = nil
            }
            if let sent = liveConsent ? expires?.advanced(by: .seconds(-30)) : pendingSent {
                lastRoundTrip = (now, sent.duration(to: now) / .milliseconds(1))
            }
            lastSuccess = now
            if pendingNomination || remoteNominated { nominate(at: now) }
            if !nominated, case .controlling = role { nextCheck = now }
        } else if first == 0 {
            let request = try ICEBinding(packet: Array(data), password: localKey)
            guard !request.isResponse, request.username == incomingName else { return nil }
            switch (role, request.role) {
            case (.controlled, .controlling):
                if request.nominated {
                    remoteNominated = true
                    if lastSuccess != nil { nominate(at: now) }
                }
            case (.controlling, .controlled):
                guard !request.nominated else { return nil }
            case (_, nil):
                // RFC 7675 consent requests may omit the ICE attributes.
                guard nominated, !request.nominated else { return nil }
            default: return nil
            }
            return try Data(request.response(mapped: peerAddress, password: localKey))
        }
        return nil
    }
}
