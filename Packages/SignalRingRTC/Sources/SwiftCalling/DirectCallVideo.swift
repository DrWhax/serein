import CodecCore
import Foundation
import Synchronization
import VideoVP8
import VideoVP9

/// One endpoint's latest camera or screen frame and its decoded remote frame.
/// Bounded queues keep codec work off the audio and signaling actor.
package final class DirectCallVideo: Sendable {
    struct Frame: Sendable {
        let width, height, format: Int
        let bytes: [UInt8]
        let revision: UInt64
        let captured: ContinuousClock.Instant
    }

    private struct Decoded: Sendable {
        let width, height, yStride, uvStride: Int
        let y, u, v: [UInt8]
        init(_ f: VP8Frame) {
            (width,height,yStride,uvStride) = (f.width,f.height,f.yStride,f.uvStride)
            (y,u,v) = (f.y,f.u,f.v)
        }
        init(_ f: VP9Frame) {
            (width,height,yStride,uvStride) = (f.width,f.height,f.yStride,f.uvStride)
            (y,u,v) = (f.y,f.u,f.v)
        }
    }
    private enum Incoming: Sendable { case vp8(DirectVideoStream.Encoded, UInt32), vp9(VP9Assembly.Frame, UInt32) }
    private struct Presentation: Sendable {
        let frame: Decoded
        let ssrc: UInt32
        let rotation: Int
        let timestamp: UInt32
        let deadline: ContinuousClock.Instant
        var size: Int { frame.y.count + frame.u.count + frame.v.count }
    }
    private struct RepairStream {
        let sender: SRTPSender
        var history = VideoSendHistory()
        var stats = RTPStatsCounter()
    }

    /// Why received pictures were not shown: decoder errors by kind, and resets for a gap.
    struct ReceiveDiagnostics: Sendable {
        var gapResets = 0
        var errors: [String: Int] = [:]
        var summary: String {
            let kinds = errors.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
            return "\(gapResets) gap resets, decode errors: " + (kinds.isEmpty ? "none" : kinds)
        }
    }

    private struct State {
        var diagnostics = ReceiveDiagnostics()
        var transport: DirectICETransport?
        var closed = false
        var requested = false
        var sending = false
        var screen = false
        var maxHeight: UInt32?
        var bitrate = 2_000_000
        var repairStreams: [UInt32:RepairStream] = [:]
        var fec = VideoFEC.Generator()
        var fecGroupSize: Int?
        var wantsKeyframe = true
        var revision: UInt64 = 0
        var presentations: [Presentation] = []
        var sentFrames = [UInt32:VideoFrameCounters](), receivedFrames = [UInt32:VideoFrameCounters]()
    }
    let synchronization: RTPMediaSynchronization
    init(synchronization: RTPMediaSynchronization = RTPMediaSynchronization()) { self.synchronization = synchronization }
    private let state = Mutex(State())
    private let outgoing = AsyncStream<Frame>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let incoming = AsyncStream<Incoming>.makeStream(bufferingPolicy: .bufferingNewest(8))

    func frameStats(ssrc: UInt32, outgoing: Bool) -> VideoFrameCounters? {
        state.withLock { outgoing ? $0.sentFrames[ssrc] : $0.receivedFrames[ssrc] }
    }

    func request(_ enabled: Bool) -> UInt64 {
        state.withLock { value in
            if !value.closed, value.requested != enabled {
                value.requested = enabled
                value.fec = VideoFEC.Generator()
                for id in value.repairStreams.keys { value.repairStreams[id]?.history = VideoSendHistory() }
                value.sending = false
                value.revision &+= 1
            }
            return value.revision
        }
    }

    func current(_ enabled: Bool, revision: UInt64) -> Bool {
        state.withLock { !$0.closed && $0.revision == revision && $0.requested == enabled }
    }

    func requestKeyframe() { state.withLock { $0.wantsKeyframe = true } }

    func setMaxHeight(_ height: UInt32) {
        state.withLock {
            if $0.maxHeight != height {
                $0.maxHeight = height
                $0.wantsKeyframe = true
            }
        }
    }

    func setScreenSharing(_ screen: Bool) {
        state.withLock {
            if $0.screen != screen { $0.wantsKeyframe = true }
            $0.screen = screen
        }
    }

    /// RingRTC V4 negotiates RED/ULPFEC. Use parity only when authenticated
    /// receiver feedback shows loss, and keep RTX for packets outside the mask.
    func setLoss(_ fraction: UInt8) {
        let count: Int? = fraction >= 25 ? 4 : (fraction >= 8 ? 8 : nil)
        state.withLock { state in
            if count != state.fecGroupSize { state.fec = VideoFEC.Generator(); state.fecGroupSize = count }
        }
    }

    func setBudget(_ bps: UInt64) {
        state.withLock { $0.bitrate = bps < 32_000 ? 0 : Int(min(bps,4_000_000)) }
    }

    func setSending(_ enabled: Bool, revision: UInt64) {
        state.withLock { value in
            if !value.closed, value.revision == revision { value.sending = enabled && value.requested }
        }
    }

    func replaceTransport(_ transport: DirectICETransport?) {
        state.withLock { state in
            guard !state.closed else { return }
            state.transport = transport
            state.wantsKeyframe = true
        }
    }

    func close() {
        state.withLock { $0.closed = true; $0.presentations.removeAll(); $0.transport = nil }
        outgoing.continuation.finish()
        incoming.continuation.finish()
    }

    func start(sender: SRTPSender?, transport: DirectICETransport, vp9: Bool = false, refresh: @escaping @Sendable () async -> Void) {
        if let sender { startSending(sender: sender, transport: transport, vp9: vp9) }
        startReceiving(refresh: refresh)
    }

    /// Each layer is separately protected and fragmented. Spatial layers of one
    /// camera image share a timestamp, including when the SFU forwards a subset.
    struct SendingLayer {
        let bytes: [UInt8], width: Int, height: Int, key: Bool
        let scalable: ScalableVideoPacketizer.Layer?
        var stream = 0
    }

    /// Allow a refresh one second of path capacity. The quantizer follows the bandwidth
    /// (VideoRateControl); on a picture a whole second could not hold, coarsest at once, then
    /// smaller pictures. A periodic independent picture can retry the original size.
    private struct PictureBudget {
        private let codec: VideoRateControl.Codec
        private(set) var rate: VideoRateControl
        private var screen = false
        private var target = (width: 0, height: 0)
        private(set) var size = (width: 0, height: 0)
        private var retryQuality: ContinuousClock.Instant?
        /// The last picture's budget (bits) and kind, until its bits are known on the wire.
        private var pending: (budget: Int, key: Bool)?

        init(_ codec: VideoRateControl.Codec) {
            self.codec = codec
            rate = VideoRateControl(codec)
        }

        static func byteLimit(bitrate: Int) -> Int {
            // Group encryption adds a 21-byte footer per layer at the SFU-facing
            // assembly boundary. Reserve room for all three spatial layers.
            min(DirectVideoStream.maxPictureBytes - 64, max(24_000, bitrate / 8))
        }

        mutating func prepare(_ dimensions: (width: Int, height: Int), key: Bool, screen: Bool, at now: ContinuousClock.Instant) {
            if screen != self.screen {
                self.screen = screen
                rate = VideoRateControl(codec, screen: screen)
            }
            if target != dimensions || (key && retryQuality.map { now >= $0 } == true) {
                target = dimensions
                size = dimensions
                retryQuality = nil
            }
        }

        func quantizer(key: Bool) -> Int { rate.quantizer(key: key) }

        /// Whether a keyframe of `bytes` should be coded again coarser (VideoRateControl).
        mutating func retryKeyframe(bytes: Int, budget: Int) -> Bool { rate.retryKeyframe(bits: bytes*8, budget: budget) }

        mutating func reduce(bytes: Int, limit: Int, at now: ContinuousClock.Instant) -> Bool {
            retryQuality = now + .seconds(10)
            if rate.quantizer(key: true) < rate.coarsest {
                rate.overshoot()
                return true
            }
            guard max(size.width, size.height) > 16 else { return false }
            let ratio = min(0.8, (Double(limit) / Double(bytes)).squareRoot() * 0.9)
            size = (max(1, Int(Double(size.width) * ratio)), max(1, Int(Double(size.height) * ratio)))
            return true
        }

        mutating func encoded(budget: Int, key: Bool) { pending = (budget, key) }

        /// The last picture's bits as sent (headers and FEC included).
        mutating func sent(bits: Int) {
            guard let pending else { return }
            rate.record(bits: bits, budget: pending.budget, key: pending.key)
            self.pending = nil
        }
    }

    struct VP8Sender {
        var encoder = VP8VideoEncoder()
        private var budget = PictureBudget(.vp8)

        /// `bits`: this stream's share of the bandwidth for this picture.
        mutating func encode(_ frame: Frame, target: (width: Int,height: Int), index: Int,
                             bitrate: Int, bits: Int, key: Bool, screen: Bool) -> SendingLayer? {
            budget.prepare(target, key: key, screen: screen, at: frame.captured)
            let limit = PictureBudget.byteLimit(bitrate: bitrate)
            var independent = key, retries = 0
            while true {
                let size = budget.size
                let pixels = DirectCallVideo.planes(frame, width: size.width, height: size.height)
                guard let picture = encoder.encode(width: size.width, height: size.height, y: pixels.y, u: pixels.u,
                                                   v: pixels.v, quantizer: budget.quantizer(key: independent), keyframe: independent),
                      let header = picture.first else { return nil }
                if header & 1 == 0 && retries < 3 && budget.retryKeyframe(bytes: picture.count, budget: bits) {
                    retries += 1
                    independent = true
                    continue
                }
                if picture.count <= limit {
                    budget.encoded(budget: bits, key: header & 1 == 0)
                    return SendingLayer(bytes: picture, width: size.width, height: size.height, key: header & 1 == 0, scalable: nil, stream: index)
                }
                independent = true
                if !budget.reduce(bytes: picture.count, limit: limit, at: frame.captured) { return nil }
            }
        }

        mutating func sent(bits: Int) { budget.sent(bits: bits) }
    }

    /// One accepted spatial picture advances every VP9 reference slot and the
    /// temporal-layer schedule together. Rejected trials never reach either.
    struct VP9Sender {
        private var encoder: VP9ScalableEncoder?
        private var encoderMode: String?
        private var budget = PictureBudget(.vp9)

        /// `bits`: the bandwidth's share for this picture (all its layers).
        mutating func encode(_ frame: Frame, target: (width: Int, height: Int), bitrate: Int, bits: Int, key: Bool,
                             group: GroupVideoConfiguration?, screen: Bool) -> (frames: [VP9EncodedLayer], mode: String)? {
            budget.prepare(target, key: key, screen: screen, at: frame.captured)
            let limit = PictureBudget.byteLimit(bitrate: bitrate)
            var independent = key, retries = 0
            while true {
                let size = budget.size
                let mode = group?.mode(screenSharing: screen, width: size.width, height: size.height) ?? "L1T1"
                guard var trial = mode == encoderMode ? encoder : VP9ScalableEncoder(mode: mode) else { return nil }
                let pixels = DirectCallVideo.planes(frame, width: size.width, height: size.height)
                guard let pictures = trial.encode(width: size.width, height: size.height, y: pixels.y, u: pixels.u, v: pixels.v,
                                                  quantizer: budget.quantizer(key: independent || key), keyframe: independent) else { return nil }
                let bytes = pictures.reduce(0) { $0 + $1.bytes.count }
                if pictures.first?.refresh == true && retries < 3 && budget.retryKeyframe(bytes: bytes, budget: bits) {
                    retries += 1
                    independent = true
                    continue
                }
                if bytes <= limit {
                    encoder = trial
                    encoderMode = mode
                    budget.encoded(budget: bits, key: pictures.first?.refresh == true)
                    return (pictures, mode)
                }
                independent = true
                if !budget.reduce(bytes: bytes, limit: limit, at: frame.captured) { return nil }
            }
        }

        mutating func sent(bits: Int) { budget.sent(bits: bits) }
    }

    func startSending(sender: SRTPSender, transport: DirectICETransport, vp9: Bool = false,
                      groupVideo: GroupVideoConfiguration? = nil, simulcast: [SRTPSender] = [], protect: (@Sendable (Data) throws -> Data)? = nil) {
        replaceTransport(transport)
        let senders = [sender] + simulcast
        state.withLock { state in
            for media in senders {
                let id = media.ssrc + (protect == nil ? 10 : 1)
                state.repairStreams[media.ssrc] = RepairStream(sender: media.makeRepairSender(ssrc: id))
            }
        }
        Task.detached { [weak self, stream = outgoing.stream] in
            let origin = ContinuousClock.now, timeOffset = UInt32.random(in: .min ... .max)
            var available = origin, lastKeyframe = origin
            var vp8 = [VP8Sender](repeating: VP8Sender(), count: senders.count)
            var scalable = VP9Sender(), previousStreamCount = 0
            var packetizer = ScalableVideoPacketizer(), pictureID: UInt16 = 0
            var previousRevision: UInt64?, previousMode: String?
            // The capture interval (all frames, coded or not), averaged.
            var interval = 1.0 / 30, lastCapture: ContinuousClock.Instant?
            for await frame in stream {
                if let lastCapture {
                    let gap = Double(lastCapture.duration(to: frame.captured) / .microseconds(1)) / 1e6
                    if gap > 0 && gap < 0.5 { interval += (min(0.2, max(1.0/60, gap)) - interval) * 0.1 }
                }
                lastCapture = frame.captured
                // A picture may start while up to half an interval of the last is still being
                // sent: a picture a little over its budget then delays the next, not drops it.
                // The rate control counts that backlog against the next picture's budget.
                guard let self, self.permits(frame.revision), frame.captured >= available - .microseconds(Int(interval * 500_000)) else { continue }
                let (bitrate,height,screen,renew) = self.state.withLock { state in
                    defer { state.wantsKeyframe = false }
                    return (state.bitrate,state.maxHeight,state.screen,state.wantsKeyframe)
                }
                guard bitrate > 0, height != 0 else { continue }
                let backlog = max(0, Double(frame.captured.duration(to: available) / .microseconds(1)) / 1e6)
                let bits = Int(Double(bitrate) * max(interval / 4, interval - backlog))
                let size = Self.size(width: frame.width, height: frame.height, bitrate: bitrate, requestedHeight: height, screen: screen, group: protect != nil)
                let mode = groupVideo?.mode(screenSharing: screen, width: size.width, height: size.height) ?? (vp9 ? "L1T1" : nil)
                let key = renew || mode != previousMode || previousRevision != frame.revision || lastKeyframe.duration(to: frame.captured) >= .seconds(2)
                let layers: [SendingLayer]
                if mode != nil {
                    guard let picture = scalable.encode(frame, target: size, bitrate: bitrate, bits: bits, key: key, group: groupVideo, screen: screen) else {
                        self.requestKeyframe()
                        continue
                    }
                    layers = packetizer.describe(picture.frames, mode: picture.mode, bitrate: bitrate).map { layer in
                        .init(bytes: layer.frame.bytes, width: layer.frame.width, height: layer.frame.height, key: layer.frame.refresh, scalable: layer)
                    }
                } else {
                    let sizes = Self.streamSizes(size, simulcast: !simulcast.isEmpty)
                    let encoded = Self.encodeSimulcast(&vp8, frame, sizes: sizes, bitrate: bitrate, bits: bits, key: key,
                                                       screen: screen, streamsBefore: previousStreamCount)
                    previousStreamCount = encoded.count
                    layers = encoded
                }
                guard !layers.isEmpty, layers.allSatisfy({ $0.bytes.count <= DirectVideoStream.maxPictureBytes }) else { self.requestKeyframe(); continue }
                if layers[0].key { lastKeyframe = frame.captured }
                previousMode = mode
                previousRevision = frame.revision
                pictureID &+= 1
                let timestamp = timeOffset &+ UInt32(truncatingIfNeeded: Int64(origin.duration(to: frame.captured) / .seconds(1) * 90_000))
                do {
                    var sent = [Int](repeating: 0, count: senders.count)
                    for layer in layers {
                        let sender = senders[layer.stream]
                        self.state.withLock { $0.sentFrames[sender.ssrc,default: VideoFrameCounters()].encode(timestamp) }
                        let sealed = try protect.map { Array(try $0(Data(layer.bytes))) } ?? layer.bytes
                        let result = try await self.send(layer, bytes: sealed, sender: sender, revision: frame.revision, pictureID: pictureID,
                                                         timestamp: timestamp, captured: frame.captured, group: protect != nil, available: available)
                        available = result.available
                        sent[layer.stream] += result.bytes * 8
                    }
                    if mode != nil { scalable.sent(bits: sent.reduce(0, +)) }
                    else { for (stream, bits) in sent.enumerated() where bits > 0 { vp8[stream].sent(bits: bits) } }
                } catch { self.requestKeyframe() }
            }
        }
    }

    private func send(_ layer: SendingLayer, bytes: [UInt8], sender: SRTPSender, revision: UInt64, pictureID: UInt16,
                      timestamp: UInt32, captured: ContinuousClock.Instant, group: Bool,
                      available: ContinuousClock.Instant) async throws -> (available: ContinuousClock.Instant, bytes: Int) {
        var cursor = 0, available = available, wire = 0
        while cursor < bytes.count {
            let start = cursor == 0, next = min(bytes.count, cursor + 1060), end = next == bytes.count
            var payload: Data
            let extensions: [(UInt8,[UInt8])], type: UInt8, marker: Bool
            if let scalable = layer.scalable {
                type = VP9Assembly.payloadType
                payload = scalable.payload(start: start, end: end)
                marker = end && scalable.lastSpatial
                extensions = group ? scalable.extensions(start: start, end: end) : []
            } else {
                type = DirectVideoStream.vp8
                payload = Data([start ? 0x90 : 0x80, 0x80, 0x80 | UInt8((pictureID >> 8) & 127), UInt8(truncatingIfNeeded: pictureID)])
                marker = end
                extensions = group ? [(UInt8(6),Self.descriptor(id: pictureID, start: start, end: end, key: layer.key, width: layer.width, height: layer.height))] : []
            }
            payload.append(contentsOf: bytes[cursor..<next])
            let fecSize = group ? nil : state.withLock { $0.fecGroupSize }
            let mediaType = fecSize == nil ? type : DirectVideoStream.red
            let mediaPayload = fecSize == nil ? payload : Data([type]) + payload
            let packet = try sender.seal(mediaPayload, type: mediaType, timestamp: timestamp, marker: marker, extensions: extensions)
            let seq = UInt16(packet[packet.startIndex+2]) << 8 | UInt16(packet[packet.startIndex+3])
            let total = try state.withLock { value in
                guard !value.closed, value.sending, value.revision == revision, value.bitrate > 0, let route = value.transport else { throw CancellationError() }
                try route.send(packet)
                value.repairStreams[sender.ssrc]?.history.record(.init(sequence: seq, type: mediaType, timestamp: timestamp, marker: marker,
                                           extensions: extensions, bytes: mediaPayload, sent: .now))
                sender.didSend(payloadBytes: mediaPayload.count, timestamp: timestamp, captured: captured)
                var wireBytes = packet.count
                if let fecSize, let piece = try Self.protectedPiece(packet, payload: payload, type: type, sequence: seq, timestamp: timestamp, marker: marker),
                   let parity = value.fec.add(piece, count: fecSize) {
                    let red = Data([VideoFEC.type]) + parity
                    let protection = try sender.seal(red, type: DirectVideoStream.red, timestamp: timestamp)
                    try route.send(protection)
                    sender.didSend(payloadBytes: red.count, timestamp: timestamp, captured: captured)
                    wireBytes += protection.count
                }
                return (bytes: wireBytes,budget: value.bitrate)
            }
            available = max(available, .now) + .microseconds(total.bytes * 8_000_000 / total.budget)
            wire += total.bytes
            if !marker { try await Task.sleep(until: available, clock: .continuous) }
            cursor = next
        }
        state.withLock { value in
            value.sentFrames[sender.ssrc,default: VideoFrameCounters()].complete(timestamp, codec: layer.scalable == nil ? 8 : 9, width: layer.width, height: layer.height)
        }
        return (available, wire)
    }

    private static func protectedPiece(_ packet: Data, payload: Data, type: UInt8, sequence: UInt16,
                                       timestamp: UInt32, marker: Bool) throws -> VideoFEC.Piece? {
        var header = ByteCursor(Array(packet))
        let flags = try header.u8()
        try header.skip(11)
        let fields = try RTPFields(&header, flags: flags, retainMutable: true)
        let protected = VideoFECHeader(flags: flags, datagram: packet, headerSize: header.consumed, fields: fields)
        return VideoFEC.Piece(.init(type: type, timestamp: timestamp, sequence: sequence, marker: marker, rotation: 0,
                                    transportNumber: nil, bytes: payload, protectedHeader: protected))
    }

    func repaired(for stream: UInt32) -> RTPStatsCounter {
        state.withLock { $0.repairStreams[stream]?.stats ?? RTPStatsCounter() }
    }

    func repair(_ requested: [UInt16], for stream: UInt32) {
        guard !requested.isEmpty else { return }
        state.withLock { value in
            guard value.sending, !value.closed, let route = value.transport, let sender = value.repairStreams[stream]?.sender else { return }
            for fragment in value.repairStreams[stream]?.history.repairs(requested) ?? [] {
                guard let type = VideoRepair.retransmissionType(fragment.type) else { continue }
                var data = Data([UInt8(fragment.sequence >> 8), UInt8(truncatingIfNeeded: fragment.sequence)])
                data.append(fragment.bytes)
                if let packet = try? sender.seal(data, type: type, timestamp: fragment.timestamp,
                                                 marker: fragment.marker, extensions: fragment.extensions),
                   (try? route.send(packet)) != nil {
                    value.repairStreams[stream]?.stats.record(data.count)
                }
            }
        }
    }

    // AV1 RTP dependency descriptor shared by RingRTC VP8 streams. Two templates
    // describe the single spatial/temporal layer: independently decodable or
    // dependent on the immediately previous picture.
    private static func descriptor(id: UInt16, start: Bool, end: Bool, key: Bool, width: Int, height: Int) -> [UInt8] {
        var bits = MSBBitWriter()
        bits.write(start ? 1 : 0, 1); bits.write(end ? 1 : 0, 1); bits.write(key ? 0 : 1, 6)
        bits.write(Int(id),16)
        if key && start {
            bits.write(16,5) // template dependency structure present
            bits.write(0,6); bits.write(0,5) // template offset zero, one decode target
            bits.write(0,2); bits.write(3,2) // repeated layer, then end
            bits.write(3,2); bits.write(3,2) // both required
            bits.write(0,1) // keyframe has no dependency
            bits.write(1,1); bits.write(0,4); bits.write(0,1) // previous frame
            bits.write(0,1); bits.write(1,1) // zero chains, resolution present
            bits.write(width-1,16); bits.write(height-1,16)
        }
        return bits.finish()
    }

    func startReceiving(open: (@Sendable (Data) throws -> Data)? = nil, refresh: @escaping @Sendable () async -> Void) {
        Task.detached { [weak self, stream = incoming.stream] in
            var limits = DecodeLimits()
            limits.maxDimension = 4096
            limits.maxPixels = 3840 * 2160
            var decoder = VP8VideoDecoder()
            var vp9 = VP9VideoDecoder()
            var lastVP9: UInt16?
            var lastPicture: (id: Int, mask: Int)?
            var previousID: Int?, previousEnd: UInt16?
            for await encoded in stream {
                guard let self, !self.state.withLock({ $0.closed }) else { return }
                let started = ContinuousClock.now
                if case .vp9(let layer, let ssrc) = encoded {
                    // Reset only on a missing picture. FEC and padding take RTP sequence numbers
                    // between pictures (RingRTC negotiates RED/ULPFEC), so a sequence gap alone is
                    // not a loss; an SFU renumbers the sequence when it drops a layer.
                    let sequential = lastVP9.map { $0 &+ 1 == layer.start } ?? true
                    let nextPicture = layer.pictureID.flatMap { id in
                        lastPicture.map { $0.mask == layer.pictureIDMask && (id == $0.id || id == ($0.id + 1) & $0.mask) }
                    } ?? false
                    if !sequential && !nextPicture {
                        vp9 = VP9VideoDecoder()
                        self.state.withLock { $0.diagnostics.gapResets += 1 }
                    }
                    lastVP9 = layer.end
                    lastPicture = layer.pictureID.map { ($0, layer.pictureIDMask) }
                    do {
                        let bytes = try open?(layer.bytes) ?? layer.bytes
                        if let frame = try vp9.decode(Array(bytes)) {
                            self.present(Decoded(frame), rotation: layer.rotation, timestamp: layer.timestamp, ssrc: ssrc, codec: 9, started: started)
                        }
                    } catch {
                        self.noteError(error, codec: 9)
                        vp9 = VP9VideoDecoder()
                        await refresh()
                    }
                    continue
                }
                guard case .vp8(let picture, let ssrc) = encoded else { continue }
                let contiguous: Bool
                if let id = picture.id, let mask = picture.mask, let previousID { contiguous = ((previousID + 1) & mask) == id }
                else { contiguous = previousEnd.map { $0 &+ 1 == picture.start } ?? false }
                if !contiguous {
                    if previousEnd != nil { self.state.withLock { $0.diagnostics.gapResets += 1 } }
                    decoder = VP8VideoDecoder()
                }
                previousID = picture.id
                previousEnd = picture.end
                do {
                    let bytes = try open.map { Array(try $0(Data(picture.bytes))) } ?? picture.bytes
                    if let frame = try decoder.decode(bytes, limits: limits) {
                        self.present(Decoded(frame), rotation: picture.rotation, timestamp: picture.timestamp, ssrc: ssrc, codec: 8, started: started)
                    }
                } catch {
                    self.noteError(error, codec: 8)
                    await refresh()
                }
            }
        }
    }

    private func noteError(_ error: any Error, codec: Int) {
        let kind = "VP\(codec) \(type(of: error)).\(String(String(describing: error).prefix(40)))"
        state.withLock { s in if s.diagnostics.errors.count < 16 || s.diagnostics.errors[kind] != nil { s.diagnostics.errors[kind, default: 0] += 1 } }
    }

    func receiveDiagnostics() -> ReceiveDiagnostics { state.withLock { $0.diagnostics } }

    private func permits(_ revision: UInt64) -> Bool {
        state.withLock { !$0.closed && $0.sending && $0.revision == revision }
    }

    func decode(_ picture: DirectVideoStream.Encoded, ssrc: UInt32) {
        state.withLock { $0.receivedFrames[ssrc,default: VideoFrameCounters()].receive(picture.timestamp) }
        incoming.continuation.yield(.vp8(picture, ssrc))
    }
    func decode(_ layer: VP9Assembly.Frame, ssrc: UInt32) {
        state.withLock { $0.receivedFrames[ssrc,default: VideoFrameCounters()].receive(layer.timestamp) }
        incoming.continuation.yield(.vp9(layer, ssrc))
    }

    private func present(_ frame: Decoded, rotation: Int, timestamp: UInt32, ssrc: UInt32, codec: Int, started: ContinuousClock.Instant) {
        let now = ContinuousClock.now
        let deadline = synchronization.deadline(for: timestamp, ssrc: ssrc, now: now)
        let item = Presentation(frame: frame, ssrc: ssrc, rotation: rotation, timestamp: timestamp, deadline: deadline)
        state.withLock { s in
            guard !s.closed else { return }
            s.receivedFrames[ssrc,default: VideoFrameCounters()].complete(timestamp, codec: codec, width: frame.width, height: frame.height, decodeSeconds: started.duration(to: now) / .seconds(1), now: now)
            // Prefer the highest available spatial layer at one presentation time.
            s.presentations.removeAll { $0.timestamp == timestamp }
            if let ready = s.presentations.lastIndex(where: { $0.deadline <= now }), ready > 0 {
                s.presentations.removeFirst(ready)
            }
            if deadline <= now { s.presentations.removeAll() }
            while !s.presentations.isEmpty && (s.presentations.count >= 8 ||
                    s.presentations.reduce(item.size, { $0 + $1.size }) > 16 * 1024 * 1024) {
                s.presentations.remove(at: s.presentations.count > 1 ? 1 : 0)
            }
            s.presentations.append(item)
        }
    }

    package func submit(width: Int, height: Int, format: Int, data: [UInt8]) -> Bool {
        guard (1...8192).contains(width), (1...8192).contains(height),
              (0...2).contains(format) else { return false }
        let size = format == 2 ? width * height * 4 : width * height + 2 * ((width + 1) / 2) * ((height + 1) / 2)
        guard data.count == size, data.count <= 48 << 20 else { return false }
        return state.withLock { value in
            guard !value.closed, value.sending else { return false }
            outgoing.continuation.yield(.init(width: width, height: height, format: format, bytes: data,
                                              revision: value.revision, captured: .now))
            return true
        }
    }

    /// Normal camera limits preserve Serein’s 960×720 direct and 640×480 group
    /// captures. Group senders can also supply HD for an active speaker. Screen
    /// share captures up to 2880×1800 at 5 fps. Never enlarge a capture.
    static func size(width: Int, height: Int, bitrate: Int, requestedHeight: UInt32?, screen: Bool, group: Bool) -> (width: Int,height: Int) {
        let long = screen ? 2880 : (group ? 1280 : 960)
        let short = screen ? 1800 : 720
        let low = bitrate < 400_000
        let shortLimit = min(low ? (screen ? 540 : 240) : short, Int(requestedHeight ?? UInt32.max))
        let longLimit = low ? (screen ? 960 : 320) : long
        let scale = max(1, Double(max(width,height))/Double(longLimit),
                        Double(min(width,height))/Double(max(1,shortLimit)))
        return (max(1,Int(Double(width)/scale)),max(1,Int(Double(height)/scale)))
    }

    /// One picture's simulcast streams, encoded in parallel (they are independent), each into a
    /// copy of its sender. As when encoded in turn, only the streams before the first failure are
    /// returned and only their senders advance, so a receiver's references match what it got.
    /// Streams from streamsBefore on (new since the last picture) start with a keyframe.
    /// The streams share the picture's bits by pixels^0.75 (about 8%, 24% and 68% for 180p, 360p
    /// and 720p; before, each was budgeted the whole bandwidth).
    static func encodeSimulcast(_ senders: inout [VP8Sender], _ frame: Frame, sizes: [(width: Int, height: Int)],
                                bitrate: Int, bits: Int, key: Bool, screen: Bool = false, streamsBefore: Int) -> [SendingLayer] {
        let trials = senders
        let weights = sizes.map { pow(Double($0.width * $0.height), 0.75) }, sum = weights.reduce(0, +)
        let results = Mutex<[(sender: VP8Sender, picture: SendingLayer?)?]>(.init(repeating: nil, count: sizes.count))
        DispatchQueue.concurrentPerform(iterations: sizes.count) { index in
            var sender = trials[index]
            let picture = sender.encode(frame, target: sizes[index], index: index, bitrate: bitrate,
                                        bits: Int(Double(bits) * weights[index] / sum), key: key || index >= streamsBefore, screen: screen)
            results.withLock { $0[index] = (sender, picture) }
        }
        var encoded = [SendingLayer]()
        for (index, result) in results.withLock({ $0 }).enumerated() {
            guard let result, let picture = result.picture else { break }
            senders[index] = result.sender
            encoded.append(picture)
        }
        return encoded
    }

    /// Independent VP8 streams for RingRTC's three simulcast SSRCs. The base
    /// remains useful to a thumbnail subscriber when a different receiver asks for HD.
    static func streamSizes(_ size: (width: Int,height: Int), simulcast: Bool) -> [(width: Int,height: Int)] {
        guard simulcast else { return [size] }
        let short = min(size.width,size.height)
        let limits = [180,360].filter { $0 < short } + [short]
        return limits.map { (max(1,size.width*$0/short),max(1,size.height*$0/short)) }
    }

    private static func planes(_ f: Frame, width w: Int, height h: Int) -> (width: Int, height: Int, y: [UInt8], u: [UInt8], v: [UInt8]) {
        let cw = (w + 1) / 2, ch = (h + 1) / 2, srcCW = (f.width + 1) / 2
        let base = f.width * f.height, srcUV = srcCW * ((f.height + 1) / 2)
        var y = [UInt8](repeating: 0, count: w*h)
        var u = [UInt8](repeating: 0, count: cw*ch), v = u
        for row in 0..<h {
            let srcRow = row * f.height / h
            for col in 0..<w {
                let srcCol = col * f.width / w
                let src = srcRow * f.width + srcCol
                if f.format == 2 {
                    let r = Int(f.bytes[src*4]), g = Int(f.bytes[src*4+1]), b = Int(f.bytes[src*4+2])
                    y[row*w+col] = UInt8(clamping: 16 + ((66*r + 129*g + 25*b + 128) >> 8))
                    if row.isMultiple(of: 2), col.isMultiple(of: 2) {
                        let uv = row/2*cw + col/2
                        u[uv] = UInt8(clamping: 128 + ((-38*r - 74*g + 112*b + 128) >> 8))
                        v[uv] = UInt8(clamping: 128 + ((112*r - 94*g - 18*b + 128) >> 8))
                    }
                } else {
                    y[row*w+col] = f.bytes[src]
                    if row.isMultiple(of: 2), col.isMultiple(of: 2) {
                        let uv = row/2*cw + col/2, src = srcRow/2*srcCW + srcCol/2
                        u[uv] = f.bytes[base + (f.format == 0 ? src : src*2)]
                        v[uv] = f.bytes[base + (f.format == 0 ? srcUV + src : src*2 + 1)]
                    }
                }
            }
        }
        return (w, h, y, u, v)
    }

    package func receive(maxWidth: Int, maxHeight: Int, into buffer: inout [UInt8]) -> (width: Int, height: Int)? {
        let now = ContinuousClock.now
        guard let item = state.withLock({ value -> Presentation? in
            guard let ready = value.presentations.lastIndex(where: { $0.deadline <= now }) else { return nil }
            let frame = value.presentations[ready]
            value.presentations.removeFirst(ready + 1)
            return frame
        }) else { return nil }
        let f = item.frame, rotation = item.rotation
        let w = rotation.isMultiple(of: 2) ? f.width : f.height
        let h = rotation.isMultiple(of: 2) ? f.height : f.width
        guard min(w,h) <= min(maxWidth,maxHeight), max(w,h) <= max(maxWidth,maxHeight),
              w*h*4 <= buffer.count else { return nil }
        for row in 0..<f.height {
            for col in 0..<f.width {
                let y = max(0, Int(f.y[row*f.yStride + col]) - 16) * 298
                let uv = row/2*f.uvStride + col/2
                let u = Int(f.u[uv]) - 128, v = Int(f.v[uv]) - 128
                let dst: Int
                switch rotation {
                case 1: dst = col*w + (w-1-row)
                case 2: dst = (h-1-row)*w + (w-1-col)
                case 3: dst = (h-1-col)*w + row
                default: dst = row*w + col
                }
                buffer[dst*4] = UInt8(clamping: (y + 409*v + 128) >> 8)
                buffer[dst*4+1] = UInt8(clamping: (y - 100*u - 208*v + 128) >> 8)
                buffer[dst*4+2] = UInt8(clamping: (y + 516*u + 128) >> 8)
                buffer[dst*4+3] = 255
            }
        }
        state.withLock { $0.receivedFrames[item.ssrc]?.render(item.timestamp, now: now) }
        return (w,h)
    }
}
