import Foundation
import Network
import SignalRingRTC
import SwiftCalling
import Synchronization

/// A UDP impairment fixture. It drops an encrypted primary fragment per direction
/// and observes the negotiated RTX SSRC, payload type and original RTP timestamp.
final class VideoLossProxy: Sendable {
    private struct Direction {
        var audio = 0, audioDrops = 0
        var receiverReports = 0
        var originals = 0
        var lostAt: UInt32?
        var expectedSSRC: UInt32?
        var expectedType: UInt8?
        var recovered = false
        var transportFeedback = false
    }
    private struct State {
        var target: NWEndpoint?
        var connections: [NWConnection] = []
        var directions = [Direction(), Direction()]
    }
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "org.serein.test.video-loss-proxy")
    private let listener: NWListener
    private let rtxOffset: UInt32

    private let dropAudio: Bool
    private let uplinkAudioLossPeriod: Int

    init(rtxOffset: UInt32 = 10, dropAudio: Bool = false, uplinkAudioLossPeriod: Int = 48) throws {
        self.uplinkAudioLossPeriod = max(4, uplinkAudioLossPeriod)
        self.dropAudio = dropAudio
        self.rtxOffset = rtxOffset
        let params = NWParameters.udp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] peer in self?.connect(peer) }
        listener.start(queue: queue)
    }

    var audioLoss: [Int] { state.withLock { $0.directions.map(\.audioDrops) } }
    var swiftReceptionReports: Int { state.withLock { $0.directions[0].receiverReports } }
    var swiftAudioPackets: Int { state.withLock { $0.directions[0].audio } }
    var port: UInt16? { listener.port?.rawValue }
    var evidence: [String] {
        state.withLock { $0.directions.map { "primary=\($0.originals) dropped=\(String(describing: $0.lostAt)) RTX=\($0.recovered) TCC=\($0.transportFeedback)" } }
    }
    var reportedTransportFeedback: Bool { state.withLock { $0.directions[0].transportFeedback } }
    var repairedBothDirections: Bool { state.withLock { $0.directions.allSatisfy(\.recovered) } }

    func setTarget(_ host: IPv4Address, port: NWEndpoint.Port) -> Bool {
        state.withLock {
            guard $0.target == nil else { return false }
            $0.target = .hostPort(host: .ipv4(host), port: port)
            return true
        }
    }

    func substitute(_ candidate: IceCandidateMessage) -> IceCandidateMessage? {
        guard let update = try? IceCandidateUpdate(envelope: candidate.opaque), let sdp = update.addedSDP,
              let local = port else { return nil }
        let fields = sdp.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 8, fields[2].lowercased() == "udp", fields[7] == "host",
              let host = IPv4Address(String(fields[4])), let number = UInt16(fields[5]),
              let destination = NWEndpoint.Port(rawValue: number), setTarget(host, port: destination) else { return nil }
        let replacement = IceCandidateUpdate(addedSDP: "candidate:proxy 1 udp \(fields[3]) 127.0.0.1 \(local) typ host")
        return .init(callId: candidate.callId, opaque: replacement.envelope())
    }

    func substituteJoin(_ json: Data) throws -> Data {
        guard var response = try JSONSerialization.jsonObject(with: json) as? [String:Any],
              let addresses = response["udpAddresses"] as? [String],
              let address = addresses.first, let sep = address.lastIndex(of: ":"),
              let host = IPv4Address(String(address[..<sep])),
              let number = UInt16(address[address.index(after: sep)...]),
              let upstream = NWEndpoint.Port(rawValue: number), let local = port else { return json }
        _ = setTarget(host, port: upstream)
        response["udpAddresses"] = ["127.0.0.1:\(local)"]
        response["tcpAddresses"] = []
        response["tlsAddresses"] = []
        response["ips"] = ["127.0.0.1"]
        response["port"] = Int(local)
        return try JSONSerialization.data(withJSONObject: response)
    }

    private func connect(_ peer: NWConnection) {
        guard let target = state.withLock({ $0.target }) else { peer.cancel(); return }
        let upstream = NWConnection(to: target, using: .udp)
        state.withLock { $0.connections += [peer,upstream] }
        peer.start(queue: queue)
        upstream.start(queue: queue)
        relay(from: peer, to: upstream, direction: 0)
        relay(from: upstream, to: peer, direction: 1)
    }

    private func relay(from: NWConnection, to: NWConnection, direction: Int) {
        from.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            if let data, !self.shouldDrop(data, direction: direction) { to.send(content: data, completion: .idempotent) }
            self.relay(from: from, to: to, direction: direction)
        }
    }

    private func shouldDrop(_ data: Data, direction: Int) -> Bool {
        guard data.count >= 28, data.first.map({ $0 >> 6 }) == 2 else { return false }
        let bytes = [UInt8](data.prefix(12))
        if (192...223).contains(bytes[1]) {
            if bytes[1] == 201 && bytes[0] & 31 != 0 { state.withLock { $0.directions[direction].receiverReports += 1 } }
            if bytes[1] == 205 && bytes[0] & 31 == 15 { state.withLock { $0.directions[direction].transportFeedback = true } }
            return false
        }
        let type = bytes[1] & 0x7f
        let timestamp = bytes[4..<8].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let ssrc = bytes[8..<12].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return state.withLock {
            var d = $0.directions[direction]
            defer { $0.directions[direction] = d }
            if dropAudio && type == 102 {
                d.audio += 1
                let period = direction == 0 ? uplinkAudioLossPeriod : 48
                let start = min(20, period / 2)
                if (start...start+1).contains(d.audio % period) {
                    d.audioDrops += 1
                    return true
                }
            }
            if [108,109,120].contains(type) {
                d.originals += 1
                if d.lostAt == nil, d.originals >= 3, data.count > 110 {
                    d.lostAt = timestamp
                    d.expectedSSRC = ssrc &+ rtxOffset
                    d.expectedType = type == 120 ? 121 : type + 10
                    return true
                }
            } else if type == d.expectedType, ssrc == d.expectedSSRC, timestamp == d.lostAt {
                d.recovered = true
            }
            return false
        }
    }

    func close() {
        listener.cancel()
        state.withLock { $0.connections.forEach { $0.cancel() }; $0.connections.removeAll() }
    }
}
