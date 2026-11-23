import CodecCore
import Foundation

extension DirectCallRole {
    var videoSSRC: UInt32 { self == .caller ? 1003 : 2003 }
}

/// RFC 7741 payloads for RingRTC's V4 VP8 stream. Each picture owns one RTP
/// timestamp. Only the first payload can start partition zero.
struct DirectVideoStream {
    static let vp8: UInt8 = 108
    static let red: UInt8 = 120
    static let maxPictureBytes = 1 << 20
    let sender: SRTPSender
    private let receiver: SRTPReceiver
    private let repairReceiver: SRTPReceiver
    private var reorder = VideoReceiveQueue()
    private var fec = VideoFEC()
    private var parityCount: UInt16 = 0
    var waitingForRepair: Bool { reorder.waiting }
    let feedback: SRTCPSender
    private var lastRefresh: ContinuousClock.Instant?
    private var assembler = VP8Assembly()
    private var vp9 = VP9Assembly()

    struct Encoded: Sendable {
        let bytes: [UInt8]
        let rotation: Int
        let start, end: UInt16
        let id, mask: Int?
        var timestamp: UInt32 = 0
    }

    init(tx: SRTPKeys, rx: SRTPKeys, rtcp: SRTPKeys, role: DirectCallRole, measurements: CallMediaMeasurements? = nil,
         transportNumbers: TransportPacketNumbers? = nil, arrivals: TransportArrivals? = nil) {
        sender = SRTPSender(keys: tx, ssrc: role.videoSSRC, startingAt: .random(in: 0...0x7fff), transportNumbers: transportNumbers)
        receiver = SRTPReceiver(keys: rx, ssrc: role == .caller ? DirectCallRole.callee.videoSSRC : DirectCallRole.caller.videoSSRC,
                                measurements: measurements, clock: 90_000, arrivals: arrivals, collectFEC: true)
        repairReceiver = SRTPReceiver(keys: rx, ssrc: receiver.ssrc+10, arrivals: arrivals)
        feedback = SRTCPSender(keys: rtcp, ssrc: role.videoSSRC)
    }

    func transportFeedback(_ arrivals: TransportArrivals) throws -> Data? {
        guard let packet = arrivals.packet(sender: feedback.ssrc, media: receiver.ssrc) else { return nil }
        return try feedback.seal(packet)
    }

    mutating func open(_ datagram: Data) throws -> Encoded? {
        return try assembler.assemble(receiver.open(datagram))
    }

    mutating func receive(_ datagram: Data, vp8Enabled: Bool, vp9Enabled: Bool, sink: DirectCallVideo,
                          arrival: ContinuousClock.Instant = .now) throws -> Data? {
        guard datagram.count >= 12 else { throw SRTPError.invalidPacket }
        let type = datagram[datagram.startIndex+1] & 0x7f
        let packet: RTPPayload
        if VideoRepair.primaryType(type) != nil { packet = try VideoRepair.unpack(repairReceiver.open(datagram, arrival: arrival)) }
        else { packet = try receiver.open(datagram, arrival: arrival) }
        let primary = packet.type == Self.red ? try Self.primary(packet) : packet
        let received = fec.ingest(primary) + [primary]
        var output = VideoReceiveQueue.Output()
        for part in received {
            let next = reorder.insert(part)
            output.ready += next.ready
            output.missing = next.missing.isEmpty ? output.missing : next.missing
        }
        if !output.missing.isEmpty {
            let available = Set(received.map(\.sequence))
            output.missing.removeAll(where: available.contains)
        }
        return try deliver(output, vp8: vp8Enabled, vp9: vp9Enabled, sink: sink)
    }

    mutating func pollRepair(vp8: Bool, vp9: Bool, sink: DirectCallVideo) throws -> Data? {
        let output = reorder.poll()
        return try deliver(output, vp8: vp8, vp9: vp9, sink: sink)
    }

    private mutating func deliver(_ output: VideoReceiveQueue.Output, vp8: Bool, vp9 enabled: Bool, sink: DirectCallVideo) throws -> Data? {
        for original in output.ready {
            if original.type == VideoFEC.type || original.bytes.isEmpty { parityCount &+= 1; continue }
            let packet = RTPPayload(type:original.type, timestamp:original.timestamp, sequence:original.sequence &- parityCount,
                                    marker:original.marker, rotation:original.rotation, transportNumber:original.transportNumber, bytes:original.bytes)
            if vp8, packet.type == Self.vp8, let picture = try? assembler.assemble(packet) { sink.decode(picture, ssrc: receiver.ssrc) }
            if enabled, packet.type == VP9Assembly.payloadType, let layers = try? self.vp9.assemble(packet) {
                for picture in layers { sink.decode(picture, ssrc: receiver.ssrc) }
            }
        }
        guard let nack = VideoRepair.nack(output.missing, from: sender.ssrc, for: receiver.ssrc) else { return nil }
        return try feedback.seal(nack)
    }

    static func primary(_ red: RTPPayload) throws -> RTPPayload {
        var cursor = ByteCursor(Array(red.bytes))
        var redundantBytes = 0
        var type = try cursor.u8()
        while type & 0x80 != 0 {
            try cursor.skip(1)
            redundantBytes += Int(try cursor.u16be() & 0x03ff)
            type = try cursor.u8()
        }
        try cursor.skip(redundantBytes)
        return RTPPayload(type: type, timestamp: red.timestamp, sequence: red.sequence, marker: red.marker,
                          rotation: red.rotation, transportNumber: red.transportNumber, bytes: Data(cursor.rest().copyBytes()), protectedHeader: red.protectedHeader)
    }

    /// RFC 4585 Picture Loss Indication. Bound feedback when a reference is unavailable.
    mutating func refresh() throws -> Data? {
        let now = ContinuousClock.now
        if let lastRefresh, lastRefresh.duration(to: now) < .milliseconds(300) { return nil }
        lastRefresh = now
        var packet = Data([0x81, 206, 0, 2])
        for ssrc in [sender.ssrc, receiver.ssrc] {
            for shift in [24, 16, 8, 0] { packet.append(UInt8(truncatingIfNeeded: ssrc >> shift)) }
        }
        return try feedback.seal(packet)
    }
}

struct VP8Assembly {
    private var assembly: Picture?
    private var lastTimestamp: UInt32?

    private struct Picture {
        let timestamp: UInt32
        var start: UInt16?
        var end: UInt16?
        var bytes = 0
        var parts: [UInt16: Data] = [:]
        var rotation = 0
        var id, mask: Int?
    }

    mutating func assemble(_ rtp: RTPPayload) throws -> DirectVideoStream.Encoded? {
        let rtp = rtp.type == DirectVideoStream.red ? try DirectVideoStream.primary(rtp) : rtp
        guard rtp.type == DirectVideoStream.vp8 else { return nil }
        var cursor = ByteCursor(Array(rtp.bytes))
        let descriptor = try cursor.u8()
        var id, mask: Int?
        if descriptor & 0x80 != 0 {
            let extensions = try cursor.u8()
            if extensions & 0x80 != 0 {
                let first = try cursor.u8()
                if first & 0x80 == 0 { id = Int(first); mask = 127 }
                else { id = Int(first & 127) * 256 + Int(try cursor.u8()); mask = 32767 }
            }
            if extensions & 0x40 != 0 { try cursor.skip(1) }
            if extensions & 0x30 != 0 { try cursor.skip(1) }
        }
        guard !cursor.isAtEnd else { return nil }
        if let lastTimestamp, Int32(bitPattern: rtp.timestamp &- lastTimestamp) <= 0 { return nil }
        if let current = assembly?.timestamp, current != rtp.timestamp,
           Int32(bitPattern: rtp.timestamp &- current) < 0 { return nil }
        if assembly?.timestamp != rtp.timestamp { assembly = Picture(timestamp: rtp.timestamp) }
        guard let count = assembly?.bytes, let parts = assembly?.parts.count,
              count + cursor.remaining <= DirectVideoStream.maxPictureBytes, parts < 2048 else {
            assembly = nil
            lastTimestamp = rtp.timestamp
            return nil
        }
        assembly?.bytes += cursor.remaining
        assembly?.parts[rtp.sequence] = Data(cursor.rest().copyBytes())
        if descriptor & 0x1f == 0x10 {
            assembly?.start = rtp.sequence
            assembly?.id = id
            assembly?.mask = mask
        }
        if rtp.marker {
            assembly?.end = rtp.sequence
            assembly?.rotation = rtp.rotation
        }
        guard let start = assembly?.start, let end = assembly?.end, let parts = assembly?.parts,
              Int(end &- start) + 1 == parts.count else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(assembly?.bytes ?? 0)
        for index in 0..<parts.count {
            guard let part = parts[start &+ UInt16(index)] else { return nil }
            bytes.append(contentsOf: part)
        }
        defer { lastTimestamp = rtp.timestamp; assembly = nil }
        return .init(bytes: bytes, rotation: assembly?.rotation ?? 0, start: start, end: end, id: assembly?.id, mask: assembly?.mask, timestamp: rtp.timestamp)
    }

}
