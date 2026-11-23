import Foundation
import Synchronization
import CodecCore

/// Shared transport-wide packet numbers for all media SSRCs on one ICE association.
final class TransportPacketNumbers: Sendable {
    struct Sent: Sendable {
        let sequence: UInt16
        let bytes: Int
        let time: ContinuousClock.Instant
    }

    private struct State {
        var counter = UInt16.random(in: 0...0x7fff)
        var packets = [Sent?](repeating: nil, count: 2048)
    }
    private let state = Mutex(State())

    func next(bytes: Int, at now: ContinuousClock.Instant = .now) -> [UInt8] {
        state.withLock { state in
            let number = state.counter
            state.counter &+= 1
            state.packets[Int(number) % 2048] = Sent(sequence: number, bytes: bytes, time: now)
            return [UInt8(number >> 8), UInt8(truncatingIfNeeded: number)]
        }
    }

    func take(_ sequence: UInt16) -> Sent? {
        state.withLock { state in
            let index = Int(sequence) % 2048
            guard state.packets[index]?.sequence == sequence else { return nil }
            defer { state.packets[index] = nil }
            return state.packets[index]
        }
    }
}

/// Collect authenticated arrivals from all primary and repair SSRCs. Only the
/// transport-wide number is shared. Each media stream retains its own SRTP replay window.
final class TransportArrivals: Sendable {
    private let state = Mutex(TransportFeedback())
    func record(_ number: UInt16) { state.withLock { $0.observe(number, at: .now) } }
    func packet(sender: UInt32) -> Data? { state.withLock { $0.packet(sender: sender) } }
}

/// Transport-wide feedback used by RingRTC and the Signal SFU (RTPFB FMT=15).
/// Arrival times are in 250us units, independently of each RTP stream's clock.
struct TransportFeedback {
    private let origin = ContinuousClock.now
    private var base: UInt16?
    private var arrivals: [Int:Int64] = [:]
    private var sequence: UInt8 = 0

    mutating func observe(_ packet: UInt16, at now: ContinuousClock.Instant) {
        if base == nil { base = packet }
        guard let first = base else { return }
        var delta = Int(Int16(bitPattern: packet &- first))
        if delta < 0 { return }
        if delta >= 256 { arrivals.removeAll(keepingCapacity:true); base = packet; delta = 0 }
        arrivals[delta] = Int64(origin.duration(to: now) / .microseconds(250))
    }

    mutating func packet(sender: UInt32) -> Data? {
        guard let base, let earliest = arrivals.keys.min(), let first = arrivals[earliest], let last = arrivals.keys.max() else { return nil }
        let reference = first / 256
        var body = [UInt8]()
        func write16(_ value: Int, into bytes: inout [UInt8]) {
            bytes += [UInt8(truncatingIfNeeded:value >> 8),UInt8(truncatingIfNeeded:value)]
        }
        for shift in [24,16,8,0] { body.append(UInt8(truncatingIfNeeded:sender >> shift)) }
        body += [0,0,0,0] // media-source SSRC unused for transport-wide feedback
        write16(Int(base),into:&body); write16(last+1,into:&body)
        for shift in [16,8,0] { body.append(UInt8(truncatingIfNeeded:reference >> shift)) }
        body.append(sequence)
        var previous = reference * 256, deltas: [UInt8] = []
        for block in stride(from:0,through:last,by:7) {
            var chunk = 0xc000
            for i in block..<min(last+1,block+7) {
                guard let time = arrivals[i] else { continue }
                let difference = Int(time - previous)
                previous = time
                if (0...255).contains(difference) {
                    chunk |= 1 << (12-2*(i-block))
                    deltas.append(UInt8(difference))
                } else {
                    chunk |= 2 << (12-2*(i-block))
                    write16(Int(Int16(clamping:difference)),into:&deltas)
                }
            }
            write16(chunk,into:&body)
        }
        body += deltas
        while !body.count.isMultiple(of:4) { body.append(0) }
        var data: [UInt8] = [0x8f,205]
        write16(body.count/4,into:&data)
        data += body
        arrivals.removeAll(keepingCapacity:true)
        self.base = base &+ UInt16(last+1)
        sequence &+= 1
        return Data(data)
    }
}
