import Foundation

/// A completed RTP picture can have multiple spatial layers at one timestamp.
struct VideoFrameCounters: Sendable {
    private(set) var codec: Int?
    private(set) var width: Int?, height: Int?
    private(set) var encoded: UInt64 = 0, received: UInt64 = 0, completed: UInt64 = 0, rendered: UInt64 = 0
    private(set) var dropped: UInt64 = 0
    private var awaitingRender: [UInt32] = []
    private(set) var freezes: UInt64 = 0, freezeDuration = 0.0, decodeSeconds = 0.0
    private var lastEncoded: UInt32?, lastInput: UInt32?, lastComplete: UInt32?, lastRender: UInt32?
    private var lastRenderTime: ContinuousClock.Instant?
    private var intervals = [Double]()
    private var recent = [ContinuousClock.Instant]()

    mutating func encode(_ timestamp: UInt32) {
        if lastEncoded != timestamp { encoded += 1; lastEncoded = timestamp }
    }

    mutating func receive(_ timestamp: UInt32) {
        guard timestamp != lastInput, timestamp != lastRender, !awaitingRender.contains(timestamp) else { return }
        lastInput = timestamp
        received += 1
        if let lastRender, Int32(bitPattern: timestamp &- lastRender) < 0 { dropped += 1; return }
        if awaitingRender.count == 128 { awaitingRender.removeFirst(); dropped += 1 }
        awaitingRender.append(timestamp)
    }

    mutating func complete(_ timestamp: UInt32, codec: Int, width: Int, height: Int, decodeSeconds: Double = 0,
                           now: ContinuousClock.Instant = .now) {
        self.codec = codec
        self.width = width
        self.height = height
        self.decodeSeconds += decodeSeconds
        guard timestamp != lastComplete else { return }
        lastComplete = timestamp
        completed += 1
        recent.removeAll { $0.duration(to: now) > .seconds(1) }
        if recent.count == 240 { recent.removeFirst() }
        recent.append(now)
    }

    func fps(at now: ContinuousClock.Instant) -> Double {
        Double(recent.filter { $0.duration(to: now) < .seconds(1) }.count)
    }

    mutating func render(_ timestamp: UInt32, now: ContinuousClock.Instant) {
        guard lastRender != timestamp else { return }
        // Once a later picture is displayed, older complete pictures still awaiting
        // display have been skipped by the decoder or the bounded presentation queue.
        let before = awaitingRender.count
        awaitingRender.removeAll { Int32(bitPattern: timestamp &- $0) > 0 }
        dropped += UInt64(before - awaitingRender.count)
        awaitingRender.removeAll { $0 == timestamp }
        if let previous = lastRenderTime {
            let seconds = previous.duration(to: now) / .seconds(1)
            if !intervals.isEmpty {
                let mean = intervals.reduce(0,+) / Double(intervals.count)
                if seconds >= max(3 * mean, mean + 0.15) { freezes += 1; freezeDuration += seconds }
            }
            if intervals.count == 30 { intervals.removeFirst() }
            intervals.append(seconds)
        }
        rendered += 1
        lastRenderTime = now
        lastRender = timestamp
    }
}

struct RTPObservation: Sendable {
    let ssrc: UInt32
    let outgoing, video: Bool
    var count = RTPStatsCounter()
    var frames: VideoFrameCounters?
    var audio: OpusJitterStatistics?
    var key: UInt64 { (UInt64(ssrc) << 1) | (outgoing ? 1 : 0) }
}

struct StreamDistribution: Encodable, Sendable {
    private(set) var mean = 0.0, min_val = 0.0, max_val = 0.0
    private(set) var sample_count = 0
    private var squaredDeviations = 0.0
    var std_dev: Double { sample_count > 0 ? sqrt(max(0,squaredDeviations / Double(sample_count))) : 0 }
    mutating func add(_ value: Double?) {
        guard let value, value.isFinite else { return }
        min_val = sample_count == 0 ? value : min(value,min_val)
        max_val = sample_count == 0 ? value : max(value,max_val)
        sample_count += 1
        let residual = value - mean
        mean += residual / Double(sample_count)
        squaredDeviations += residual * (value - mean)
    }
    enum CodingKeys: String, CodingKey { case mean, std_dev, min_val, max_val, sample_count }
    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(mean, forKey: .mean)
        try box.encode(std_dev, forKey: .std_dev)
        try box.encode(min_val, forKey: .min_val)
        try box.encode(max_val, forKey: .max_val)
        try box.encode(sample_count, forKey: .sample_count)
    }
    var protobuf: Data {
        var writer = CallingProtoWriter()
        for (field,value) in [(1,mean),(2,std_dev),(3,min_val),(4,max_val)] {
            writer.fixed32(UInt32(field), Float(value).bitPattern)
        }
        writer.integer(5, UInt64(sample_count))
        return writer.data
    }
}

struct StreamSnapshot: Encodable, Sendable {
    let ssrc: UInt32
    var bitrate, packet_loss, jitter, rtt, jitter_buffer_delay, framerate: Double?
    var width, height: Int?
    var protobuf: Data {
        var writer = CallingProtoWriter()
        writer.integer(1, UInt64(ssrc))
        for (i, value) in [bitrate,packet_loss,jitter,rtt,jitter_buffer_delay,framerate].enumerated() {
            if let value { writer.fixed32(UInt32(2+i), Float(value).bitPattern) }
        }
        if let width, let height { writer.integer(8,UInt64(width)); writer.integer(9,UInt64(height)) }
        return writer.data
    }
}

struct StreamAggregate: Encodable, Sendable {
    let ssrc: UInt32
    var bitrate: StreamDistribution?, packet_loss_pct: StreamDistribution?, jitter: StreamDistribution?
    var freeze_count: StreamDistribution?, video_codec: Int?, codec_implementation: String?
    var audio_relative_arrival_delay: StreamDistribution?, audio_concealment_pct: StreamDistribution?, audio_redundant_packets: UInt64?, audio_jitter_buffer_flushes: UInt64?
    mutating func add(_ field: WritableKeyPath<Self,StreamDistribution?>, _ value: Double?) {
        guard let value else { return }
        var sample = self[keyPath: field] ?? StreamDistribution()
        sample.add(value)
        self[keyPath: field] = sample
    }
    var protobuf: Data {
        var writer = CallingProtoWriter()
        for (field, value) in [(1,bitrate),(2,packet_loss_pct),(3,jitter),(4,freeze_count),(8,audio_concealment_pct),(11,audio_relative_arrival_delay)] {
            if let value { writer.bytes(UInt32(field), value.protobuf) }
        }
        writer.integer(6,UInt64(ssrc))
        if let video_codec { writer.integer(5, UInt64(video_codec)) }
        if let codec_implementation { writer.bytes(7, codec_implementation.utf8) }
        if let audio_redundant_packets { writer.integer(9, audio_redundant_packets) }
        if let audio_jitter_buffer_flushes { writer.integer(10, audio_jitter_buffer_flushes) }
        return writer.data
    }
}

struct StreamSummaries: Encodable, Sendable {
    var audio_send_stream_summaries = [StreamAggregate](), audio_recv_stream_summaries = [StreamAggregate]()
    var video_send_stream_summaries = [StreamAggregate](), video_recv_stream_summaries = [StreamAggregate]()
    var protobuf: Data {
        var writer = CallingProtoWriter()
        for (i, series) in [audio_send_stream_summaries,audio_recv_stream_summaries,video_send_stream_summaries,video_recv_stream_summaries].enumerated() {
            for item in series { writer.bytes(UInt32(5+i),item.protobuf) }
        }
        return writer.data
    }
}

struct StreamStatsSet: Encodable, Sendable {
    let timestamp: UInt64
    var audio_recv_stats = [StreamSnapshot](), audio_send_stats = [StreamSnapshot]()
    var video_recv_stats = [StreamSnapshot](), video_send_stats = [StreamSnapshot]()
    var events = [UInt64](), rtt_stun = [Double]()
    var relayed: Bool?
    var protobuf: Data {
        var writer = CallingProtoWriter()
        writer.integer(1,timestamp)
        for (i, series) in [audio_recv_stats,audio_send_stats,video_recv_stats,video_send_stats].enumerated() {
            for item in series { writer.bytes(UInt32(2+i),item.protobuf) }
        }
        for event in events { writer.integer(6,event) }
        for rtt in rtt_stun { writer.fixed32(7,Float(rtt).bitPattern) }
        if let relayed { writer.integer(8,relayed ? 1 : 0) }
        return writer.data
    }
}

struct CallStreamStatistics {
    private struct Track {
        var previous = RTPObservation(ssrc: 0, outgoing: false, video: false)
        var lost: Int32 = 0
        var aggregate: StreamAggregate
    }
    private var tracks = [UInt64: Track]()
    private var sampled = ContinuousClock.now
    private(set) var sets = [StreamStatsSet]()
    mutating func add(_ inputs: [RTPObservation], rtt: Double?, relayed: Bool?, now: ContinuousClock.Instant,
                      metrics: (RTPObservation) -> (lost: Int32?, fraction: Double?, jitter: Double?, rtt: Double?)) {
        let seconds = sampled.duration(to: now) / .seconds(1)
        guard seconds > 0 else { return }
        sampled = now
        var set = StreamStatsSet(timestamp: CallTimeline.now, relayed: relayed)
        if let rtt { set.rtt_stun.append(rtt) }
        for source in inputs.sorted(by: { $0.key < $1.key }) where source.count.packets > 0 {
            guard tracks.count < 500 || tracks[source.key] != nil else { continue }
            var track = tracks[source.key] ?? Track(aggregate: StreamAggregate(ssrc: source.ssrc))
            let previous = track.previous, network = metrics(source)
            func change(_ current: UInt64, _ prior: UInt64) -> UInt64 { current >= prior ? current-prior : current }
            var item = StreamSnapshot(ssrc: source.ssrc)
            let packets = change(source.count.packets,previous.count.packets)
            item.bitrate = Double(change(source.count.bytes,previous.count.bytes)) * 8 / seconds
            item.jitter = network.jitter
            item.rtt = network.rtt
            if let fraction = network.fraction { item.packet_loss = fraction*100 }
            else if let lost = network.lost {
                let delta = Int64(lost)-Int64(track.lost)
                let expected = Double(packets) + Double(delta)
                if expected > 0 { item.packet_loss = max(0,Double(delta) * 100 / expected) }
                track.lost = lost
            }
            track.aggregate.add(\.bitrate,item.bitrate)
            track.aggregate.add(\.packet_loss_pct,item.packet_loss)
            track.aggregate.add(\.jitter,item.jitter)
            if let frames = source.frames, let codec = frames.codec {
                item.framerate = Double(change(frames.completed,previous.frames?.completed ?? 0)) / seconds
                item.width = frames.width
                item.height = frames.height
                track.aggregate.video_codec = codec
                track.aggregate.codec_implementation = "Swift VP\(codec)"
                if !source.outgoing {
                    track.aggregate.add(\.freeze_count,Double(change(frames.freezes,previous.frames?.freezes ?? 0)))
                }
            }
            if let audio = source.audio {
                let prev = previous.audio ?? OpusJitterStatistics()
                let samples = change(audio.emittedSamples,prev.emittedSamples)
                if samples > 0 {
                    item.jitter_buffer_delay = 1000 * max(0,audio.cumulativeDelaySeconds-prev.cumulativeDelaySeconds)/Double(samples)
                    let concealed = change(audio.concealedSamples,prev.concealedSamples)
                    let silent = change(audio.silentConcealedSamples,prev.silentConcealedSamples)
                    track.aggregate.add(\.audio_concealment_pct,Double(concealed-min(concealed,silent))*100/Double(samples))
                }
                if packets > 0 {
                    track.aggregate.add(\.audio_relative_arrival_delay,1000 * max(0,audio.relativeArrivalDelaySeconds-prev.relativeArrivalDelaySeconds) / Double(packets))
                }
                track.aggregate.audio_redundant_packets = (track.aggregate.audio_redundant_packets ?? 0) + change(audio.fecReceivedPackets,prev.fecReceivedPackets)
                track.aggregate.audio_jitter_buffer_flushes = (track.aggregate.audio_jitter_buffer_flushes ?? 0) + change(audio.flushes,prev.flushes)
            }
            switch (source.video,source.outgoing) {
            case (true,true): set.video_send_stats.append(item)
            case (true,false): set.video_recv_stats.append(item)
            case (false,true): set.audio_send_stats.append(item)
            case (false,false): set.audio_recv_stats.append(item)
            }
            track.previous = source
            tracks[source.key] = track
        }
        if !inputs.isEmpty || rtt != nil {
            if sets.count == 30 { sets.removeFirst() }
            sets.append(set)
        }
    }

    mutating func beginSession() {
        sampled = .now
        for key in tracks.keys {
            guard var track = tracks[key] else { continue }
            track.previous = RTPObservation(ssrc: track.previous.ssrc, outgoing: track.previous.outgoing, video: track.previous.video)
            track.lost = 0
            tracks[key] = track
        }
    }

    var summaries: StreamSummaries {
        var result = StreamSummaries()
        for track in tracks.sorted(by: { $0.key < $1.key }).map(\.value) {
            switch (track.previous.video,track.previous.outgoing) {
            case (true,true): result.video_send_stream_summaries.append(track.aggregate)
            case (true,false): result.video_recv_stream_summaries.append(track.aggregate)
            case (false,true): result.audio_send_stream_summaries.append(track.aggregate)
            case (false,false): result.audio_recv_stream_summaries.append(track.aggregate)
            }
        }
        return result
    }
}
