import Foundation
import Synchronization
import Testing
@testable import SwiftCalling

/// Observe native RTP at the authenticated media boundary. For each native FEC
/// mask, withhold one observed original and compare all restored video bytes.
final class NativeVideoFECProbe: Sendable {
    private struct State {
        var recent = [UInt16:RTPPayload]()
        var latest: UInt16 = 0
        var originals = 0, parity = 0
        var matched = false
        var rate = GroupSendRate()
        var acknowledged = false
    }
    private let state = Mutex(State())
    let numbers = TransportPacketNumbers()
    private let arrivals = TransportArrivals()
    private let receiver: SRTPReceiver
    private let control: SRTCPSender
    private let remoteSSRC: UInt32
    private let role: DirectCallRole
    init(role: DirectCallRole, incoming: SRTPKeys, outgoingControl: SRTPKeys) {
        self.role = role
        remoteSSRC = role == .caller ? DirectCallRole.callee.videoSSRC : DirectCallRole.caller.videoSSRC
        receiver = SRTPReceiver(keys: incoming, ssrc: remoteSSRC, arrivals: arrivals, collectFEC: true)
        control = SRTCPSender(keys: outgoingControl, ssrc: role.videoSSRC)
    }

    func observe(_ datagram: Data) {
        guard let packet = try? receiver.open(datagram) else { return }
        let primary = packet.type == DirectVideoStream.red ? try? DirectVideoStream.primary(packet) : packet
        guard let primary else { return }
        state.withLock { state in
            state.latest = packet.sequence
            if primary.type != VideoFEC.type {
                state.originals += 1
                if state.recent.count > 256 { state.recent = state.recent.filter { packet.sequence &- $0.key < 180 } }
                state.recent[packet.sequence] = primary
                return
            }
            state.parity += 1
            guard !state.matched, let equation = try? VideoFEC.Equation(primary.bytes, at: .now),
                  let dropped = equation.sequences.first,
                  let expected = state.recent[dropped],
                  equation.sequences.allSatisfy({ state.recent[$0] != nil }) else { return }
            var decoder = VideoFEC()
            for id in equation.sequences where id != dropped {
                if let part = state.recent[id] { _ = decoder.ingest(part) }
            }
            if let repaired = decoder.ingest(primary).first {
                state.matched = repaired.sequence == dropped && repaired.type == expected.type && repaired.timestamp == expected.timestamp
                    && repaired.rotation == expected.rotation && repaired.marker == expected.marker && repaired.bytes == expected.bytes
            }
        }
    }

    func observeControl(_ plain: Data) {
        state.withLock { if (try? $0.rate.receive(plain,sent:numbers)) == true { $0.acknowledged = true } }
    }
    var acknowledged: Bool { state.withLock { $0.acknowledged } }

    func feedback(to transport: DirectICETransport) throws {
        if let feedback = arrivals.packet(sender: role.videoSSRC) { try transport.send(control.seal(feedback)) }
        let (latest,count) = state.withLock { ($0.latest,$0.originals) }
        guard count > 0 else { return }
        // A controlled 25% receiver loss report and long RTT cause the unmodified
        // WebRTC controller to protect subsequent camera frames with ULPFEC.
        var report = Data([0x81,201,0,7])
        func word(_ value: UInt32) {
            for shift in [24,16,8,0] { report.append(UInt8(truncatingIfNeeded:value >> shift)) }
        }
        word(role.videoSSRC); word(remoteSSRC)
        word(64 << 24 | UInt32(count/4)); word(UInt32(latest)); word(1200)
        let current = Date().timeIntervalSince1970 + 2_208_988_800.0 - 0.3
        word(UInt32(truncatingIfNeeded:UInt64(current*65536))); word(0)
        try transport.send(control.seal(report))
    }
    var matched: Bool { state.withLock { $0.matched } }
    var observed: String { state.withLock { "observed \($0.originals) native media and \($0.parity) native parity packets" } }
}
