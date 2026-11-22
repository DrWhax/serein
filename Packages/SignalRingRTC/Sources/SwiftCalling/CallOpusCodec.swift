import Foundation

/// Primary speech and optional Opus 1.6.1 deep redundancy share the capture clock.
struct CallOpusEncoder {
    private var primary = OpusSpeechEncoder()
    private var redundancy: Redundancy?
    private var loss: UInt8 = 0

    mutating func setDRED(_ configuration: DREDConfiguration?) {
        redundancy = configuration.map(Redundancy.init)
        primary.setPacketLoss(configuration == nil ? loss : 0)
    }

    mutating func setPacketLoss(_ fraction: UInt8) {
        loss = fraction
        primary.setPacketLoss(redundancy == nil ? fraction : 0)
    }

    mutating func setLowDataMode(_ low: Bool) { primary.setLowDataMode(low) }

    mutating func beginTalkspurt() {
        primary.beginTalkspurt()
        if let configuration = redundancy?.configuration { redundancy = Redundancy(configuration) }
    }

    mutating func transmission(_ samples: [Int16]) throws -> (payload: Data, skipped: UInt32, marker: Bool)? {
        guard samples.count == 960 || samples.count == 2880 else { throw OpusPacket.Failure.invalidPacket }
        let target = samples.count / 12
        let allowance = Self.redundancyBudget(loss: loss, samples: samples.count)
        // Keep the recurrent analysis current even when its bytes are unnecessary.
        // A new receiver report can enable protection on the very next packet.
        if let extensionBytes = redundancy?.prepare(samples, allowance: allowance) {
            var candidate = primary
            let primaryTarget = target - extensionBytes.count - 2
            do {
                guard let frame = try candidate.transmission(samples, targetBytes: primaryTarget) else {
                    primary = candidate
                    return nil
                }
                if frame.payload.count == 1 { primary = candidate; return frame }
                let protected = try OpusPacket(frame.payload).addingFirstFrameExtension(id: 126, bytes: extensionBytes)
                if protected.count <= target {
                    primary = candidate
                    return (protected, frame.skipped, frame.marker)
                }
            } catch {
                // Retry the primary from its original overlap, SILK prediction and DTX history.
            }
        }
        return try primary.transmission(samples)
    }

    /// libopus compute_dred_bitrate's DRED-only allocation at Serein's mono
    /// 32 kb/s capture rate. Longer packet intervals need proportionally fewer repairs.
    static func redundancyBudget(loss: UInt8, samples: Int) -> Int {
        let percent = Int(loss)*100/256
        let fraction = percent > 5 ? min(0.8,0.55 + Double(percent)/100) : 0.12*Double(percent)
        let share = fraction / (fraction + (1-fraction)*Double(samples)/960)
        return Int(share * 20_000 * Double(samples) / (8*48_000))
    }

    private struct Redundancy {
        let configuration: DREDConfiguration
        var analysis: DREDAnalysis
        var network = DREDNetwork(encoding: true)
        var history: [DREDNetwork.Encoded] = []

        init(_ configuration: DREDConfiguration) {
            self.configuration = configuration
            analysis = DREDAnalysis(model: configuration.model)
        }

        mutating func prepare(_ samples: [Int16], allowance: Int) -> [UInt8]? {
            let features = analysis.features(samples)
            for i in stride(from: 0, to: features.count - 1, by: 2) {
                let encoded = network.encode(features[i] + features[i+1], model: configuration.model)
                history.insert(encoded, at: 0)
            }
            if history.count > 54 { history.removeLast(history.count - 54) }
            // Select the state at the first 20 ms of this packet. Each alternate
            // latent then describes 40 ms backwards from that instant.
            let first = samples.count / 960 - 1
            guard allowance >= 16, history.count > first + 3 else { return nil }
            let end = min(history.count - 1, first + 2 * min(26, (configuration.duration + 5) / 4))
            var latents = stride(from: first, to: end, by: 2).map { history[$0].latent }
            // 4 ms Opus lookahead, 11 samples of analysis delay at 16 kHz and
            // a 20 ms analysis frame produce a ten-tick (25 ms) DRED offset.
            func encode(_ latents: [[Float]], initialQ: Int) -> [UInt8]? {
                guard let payload = try? DREDWire.payload(state: history[first].state, latents: latents, offset: 10,
                                                         initialQ: initialQ, step: 5, maxQ: 15),
                      payload.count + 2 <= allowance else { return nil }
                return payload
            }
            while latents.count > 2 {
                if let payload = encode(latents, initialQ: 6) { return payload }
                latents.removeLast()
            }
            // Under a hard packet cap, a high-entropy initial state can exceed the
            // estimated cost even at the minimum two chunks. Coarsen it before
            // giving the entire capture budget back to the primary.
            if latents.count == 2 {
                for q in [6, 8, 10, 12] {
                    if let payload = encode(latents, initialQ: q) { return payload }
                }
            }
            return nil
        }
    }
}

struct CallOpusRecovery {
    let configuration: DREDConfiguration
    private var previousPCM: [Int16] = []
    private var predictor: DeepPLC

    init(_ configuration: DREDConfiguration) {
        self.configuration = configuration
        predictor = DeepPLC(model: configuration.model)
    }

    mutating func observe(_ pcm: [Int16]) {
        predictor.update(pcm)
        remember(pcm)
    }

    private mutating func remember(_ pcm: [Int16]) {
        if pcm.count >= 960 { previousPCM = Array(pcm.suffix(960)) }
        else { previousPCM = Array((previousPCM + pcm).suffix(960)) }
    }

    mutating func conceal(samples: Int) -> [Int16] {
        var speech = [Int16]()
        while speech.count < samples {
            speech += predictor.conceal(samples: min(5760, samples - speech.count))
        }
        remember(speech)
        return speech
    }

    // The advertised history can cover only part of a burst. Decode its recurrent
    // network once, then render and account for one local playout block at a time.
    struct Repair {
        let features: [[Float]]
        let offset: Int
        var synthesis: DREDSynthesis?
    }

    func prepare(_ packet: OpusPacket, distance: Int) -> Repair? {
        guard let wire = try? DREDWire.decode(packet) else { return nil }
        let earliest = Self.index(distance, offset: wire.offset)
        let latest = Self.index(min(distance, 480), offset: wire.offset)
        guard earliest >= 0, latest < wire.latents.count * 4 else { return nil }
        return Repair(features: DREDNetwork.decode(state: wire.state, latents: wire.latents, model: configuration.model),
                      offset: wire.offset)
    }

    private static func index(_ distance: Int, offset: Int) -> Int {
        Int(floor(Double(distance + offset * 120) / 480)) - 2
    }

    mutating func recover(_ repair: inout Repair, distance: Int, samples: Int) -> (pcm: [Int16], recovered: Int, silent: UInt64) {
        var pcm = [Int16](), recovered = 0, silent: UInt64 = 0
        while pcm.count < samples {
            let earlier = distance - pcm.count, count = min(480, samples - pcm.count)
            let i = Self.index(earlier, offset: repair.offset)
            if earlier <= configuration.duration * 480, repair.features.indices.contains(i) {
                var synthesis: DREDSynthesis
                if let continuing = repair.synthesis { synthesis = continuing }
                else {
                    synthesis = DREDSynthesis(model: configuration.model)
                    let history = (1...5).reversed().map { repair.features[min(repair.features.count-1, i + $0)] }
                    synthesis.prime(pcm: previousPCM, features: history)
                }
                let block = Array(synthesis.synthesize(repair.features[i]).prefix(count))
                repair.synthesis = synthesis
                observe(block)
                pcm += block
                recovered += block.count
            } else {
                let block = conceal(samples: count)
                silent += OpusJitterBuffer.silence(block)
                pcm += block
            }
        }
        return (pcm, recovered, silent)
    }
}
