import Foundation

/// Stateful CELT layer used by Opus's transform-only and hybrid configurations.
struct CELTDecoder {
    private static let zero = [[Double]](repeating: [Double](repeating: 0, count: 21), count: 2)
    private static let floor = [[Double]](repeating: [Double](repeating: -28, count: 21), count: 2)
    private var energy = zero
    private var background = zero
    private var lossDuration = 0
    private var startBand = 17, endBand = 21
    private var previous = floor
    private var older = floor
    private var seed: UInt32 = 0
    private var synthesis = CELTSynthesis()

    mutating func decode(config: UInt8, stereo: Bool, bytes: Int, range: inout OpusRangeDecoder) throws -> [Int16] {
        var history = energy
        if lossDuration > 0 {
            let lm = config < 16 ? 2 + Int(config % 2) : Int(config % 4)
            let missing = Double(1 + min(10, lossDuration >> lm))
            let margin = lm == 0 ? 1.5 : lm == 1 ? 0.5 : 0
            for c in 0..<2 {
                for b in 0..<21 {
                    let e = history[c][b], a = previous[c][b], z = older[c][b]
                    history[c][b] = (e < max(a,z) ? max(-20, e - missing * max(a-e, (z-e)*0.5)) : min(e,a,z)) - margin
                }
            }
        }
        var frame = try CELTFrame(config: config, stereo: stereo, byteCount: bytes, history: history, range: &range)
        startBand = frame.start
        endBand = frame.end
        var bands: [[Double]]
        if frame.silence {
            bands = [[Double]](repeating: [Double](repeating: 0, count: frame.samples), count: frame.channels)
        } else {
            var foldingSeed = seed
            var shape = try CELTShape.decode(frame, range: &range, seed: &foldingSeed)
            let restore = try frame.antiCollapse > 0 && range.rawBits(1) != 0
            try frame.finalizeEnergy(&range)
            if restore { restoreTransientBlocks(frame, bands: &shape.bands, masks: shape.masks, seed: foldingSeed) }
            bands = shape.bands
        }
        guard range.bitsUsed <= bytes * 8 else { throw OpusPacket.Failure.invalidPacket }
        let pcm = synthesis.render(frame, shapes: bands)
        energy = frame.energies
        if !frame.transient { older = previous; previous = energy }
        for c in 0..<2 {
            for b in 0..<21 {
                let rise = 0.001 * Double(min(160, lossDuration + (1 << frame.lm)))
                background[c][b] = min(background[c][b] + rise, energy[c][b])
                if b < frame.start || b >= frame.end {
                    energy[c][b] = 0
                    previous[c][b] = -28
                    older[c][b] = -28
                } else if frame.transient {
                    previous[c][b] = min(previous[c][b], energy[c][b])
                }
            }
        }
        seed = range.range
        lossDuration = 0
        return pcm
    }

    /// Noise-based CELT PLC uses the energy envelope of the previous spectrum. In a
    /// hybrid frame it reconstructs only frequencies above the SILK band.
    mutating func conceal(samples: Int) -> [Int16] {
        var pcm: [Int16] = []
        while pcm.count < samples {
            let remaining = samples - pcm.count
            guard let lm = (0...3).last(where: { (120 << $0) <= remaining }) else { break }
            let n = 120 << lm
            var bands = [Double](repeating: 0, count: n)
            for b in startBand..<endBand {
                energy[0][b] = max(background[0][b], energy[0][b] - (lossDuration == 0 ? 1.5 : 0.5))
                let bins = (CELTTables.edges[b] << lm)..<(CELTTables.edges[b+1] << lm)
                var power = 1e-15
                for i in bins {
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    bands[i] = Double(Int32(bitPattern: seed) >> 20)
                    power += bands[i] * bands[i]
                }
                let scale = 1 / power.squareRoot()
                for i in bins { bands[i] *= scale }
            }
            let frame = CELTFrame(lm: lm, start: startBand, end: endBand, energies: energy)
            pcm += synthesis.render(frame, shapes: [bands])
            lossDuration = min(10_000, lossDuration + (1 << lm))
        }
        return pcm
    }

    private func restoreTransientBlocks(_ frame: CELTFrame, bands: inout [[Double]], masks: [Int], seed: UInt32) {
        let blocks = 1 << frame.lm
        var seed = seed
        for b in frame.start..<frame.end {
            let n = frame.width(b), at = CELTTables.edges[b] << frame.lm
            let threshold = 0.5 * exp2(-0.125 * Double((1 + frame.shapeBits[b]) / n))
            for c in 0..<frame.channels {
                let mask = masks[b * frame.channels + c]
                if mask == (1 << blocks) - 1 { continue }
                let prev = frame.channels == 1 ? max(previous[0][b], previous[1][b]) : previous[c][b]
                let prev2 = frame.channels == 1 ? max(older[0][b], older[1][b]) : older[c][b]
                let difference = max(0, frame.energies[c][b] - min(prev, prev2))
                let radius = min(threshold, (frame.lm == 3 ? 2 * 2.0.squareRoot() : 2) * exp2(-difference)) / Double(n).squareRoot()
                for block in 0..<blocks where mask & (1 << block) == 0 {
                    for i in stride(from: at+block, to: at+n, by: blocks) {
                        seed = seed &* 1_664_525 &+ 1_013_904_223
                        bands[c][i] = seed & 0x8000 != 0 ? radius : -radius
                    }
                }
                let power = bands[c][at..<at+n].reduce(1e-15) { $0 + $1*$1 }
                let gain = 1 / power.squareRoot()
                for i in at..<at+n { bands[c][i] *= gain }
            }
        }
    }
}
