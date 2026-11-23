import Foundation

/// RFC 6716 mono, 20 ms CELT analysis and quantization. Hybrid speech shares
/// the SILK range coder and codes bands 17...20. Transform-only audio codes
/// all 21 bands. Bit allocation and split decisions are shared with synthesis.
struct CELTEncoder {
    private var overlap = [Double](repeating: 0, count: 120)
    private var lastSample = 0.0

    mutating func analyze(_ pcm: ArraySlice<Int16>) -> [Double] {
        var weighted = overlap
        weighted.reserveCapacity(1080)
        for sample in pcm {
            let value = Double(sample)
            weighted.append(value - lastSample * 0.8500061)
            lastSample = value
        }
        overlap = Array(weighted.suffix(120))
        return CELTSynthesis.analyze(weighted)
    }

    /// Compensate for analysis pre-emphasis before comparing the low and high
    /// bands. A normal-band speech formant should not masquerade as music.
    private static let powerWeights: [Double] = (0..<800).map { i -> Double in
        let angle = (Double(i) + 0.5) * Double.pi / 960.0
        return 1.0 / (1.7225 - 1.7 * cos(angle))
    }

    static func highBandFraction(_ spectra: [[Double]]) -> Double {
        var high = 0.0, low = 1e-12
        for spectrum in spectra {
            for i in 0..<800 {
                let power = spectrum[i] * spectrum[i] * powerWeights[i]
                if i >= 320 { high += power } else { low += power }
            }
        }
        return high / (high + low)
    }

    static func encode(_ spectrum: [Double], start: Int, bytes: Int, range: inout OpusRangeEncoder) throws -> [UInt8] {
        let zero = [[Double]](repeating: [Double](repeating: 0, count: 21), count: 2)
        var frame = CELTFrame(lm: 3, start: start, end: 21, energies: zero, totalBits: bytes * 8)
        let bands = start..<frame.end, bits = frame.totalBits
        if range.bitsUsed == 1 { try range.bit(false, logProbability: 15) }
        if start == 0 && range.bitsUsed + 16 <= bits { try range.bit(false, logProbability: 1) } // pitch filter
        if range.bitsUsed + 3 <= bits { try range.bit(false, logProbability: 3) } // long MDCT
        guard range.bitsUsed + 3 <= bits else { throw OpusPacket.Failure.invalidPacket }
        try range.bit(true, logProbability: 3) // independently coded band energies
        var target = [Double](repeating: -28, count: 21), powers = [Double](repeating: 0, count: 21)
        var previous = 0.0
        for band in bands {
            let bins = (CELTTables.edges[band] << 3)..<(CELTTables.edges[band+1] << 3)
            powers[band] = spectrum[bins].reduce(0) { $0 + $1*$1 }
            target[band] = max(-28, 0.5*log2(max(1e-18, powers[band])) - Double(CELTTables.meansQ4[band])/16)
            let wanted = Int((target[band]-previous).rounded()), left = bits-range.bitsUsed
            let delta: Int
            if left >= 15 {
                let i = 7 * 42 + band*2
                delta = try range.laplace(wanted, probability: CELTTables.energyModel[i]<<7, decay: CELTTables.energyModel[i+1]<<6)
            } else if left >= 2 {
                delta = min(1,max(-1,wanted))
                try range.symbol(delta == 0 ? 0 : delta < 0 ? 1 : 2, [2,1,0], precision: 2)
            } else if left == 1 {
                delta = wanted < 0 ? -1 : 0
                try range.bit(delta != 0, logProbability: 1)
            } else { delta = -1 }
            frame.energies[0][band] = previous + Double(delta)
            previous += Double(delta) * (1.0 - 4915.0/32768)
        }
        let tfBudget = bits - (range.bitsUsed + 5 <= bits ? 1 : 0)
        for band in bands {
            let logp = band == start ? 4 : 5
            if range.bitsUsed + logp <= tfBudget { try range.bit(false, logProbability: logp) }
        }
        // Long blocks with unchanged TF resolution use the same zero at either
        // selector, so there is no selector bit. Use unmixed pulses for tones.
        if range.bitsUsed + 4 <= bits { try range.symbol(0, [25,23,2,0], precision: 5) }
        let caps = (0..<21).map { (CELTTables.caps[6*21+$0]+64) * frame.width($0) / 4 }
        var boosts = [Int](repeating: 0, count: 21)
        let energy = powers.reduce(1e-12,+)
        var available = bits*8, logp = 6
        for band in bands {
            let step = min(frame.width(band)*8, max(48,frame.width(band)))
            let wanted = powers[band] > energy*0.12 ? 2 : 0
            var probability = logp
            while range.eighthBitsUsed + probability*8 < available && boosts[band] < caps[band] {
                let more = boosts[band] < step*wanted && available - range.eighthBitsUsed > step + 80*8
                try range.bit(more, logProbability: probability)
                if !more { break }
                boosts[band] += step
                available -= step
                probability = 1
            }
            if boosts[band] != 0 { logp = max(2,logp-1) }
        }
        if range.eighthBitsUsed + 48 <= available { try range.symbol(5, [126,124,119,109,87,41,19,9,4,2,0], precision: 7) }
        try frame.allocate(max(0,bits*8-range.eighthBitsUsed-1), trim: 5, caps: caps, boosts: boosts) { choices in
            // Mono only signals the voluntary band-skip decision.
            guard choices == 2 else { throw OpusPacket.Failure.invalidPacket }
            try range.bit(true, logProbability: 1)
            return 1
        }
        for band in bands where frame.fineBits[band] > 0 {
            let fine = frame.fineBits[band], count = 1 << fine
            let digit = min(count-1,max(0,Int(floor((target[band]-frame.energies[0][band]+0.5)*Double(count)))))
            try range.rawBits(UInt32(digit), fine)
            frame.energies[0][band] += (Double(digit)+0.5)/Double(count)-0.5
        }
        var balance = frame.balance
        for band in bands {
            let tell = range.eighthBitsUsed
            if band != start { balance -= tell }
            var left = bits*8-tell-1
            if band < frame.codedBands {
                let budget = max(0,min(16383,left+1,frame.shapeBits[band]+balance/min(3,frame.codedBands-band)))
                let begin = CELTTables.edges[band] << 3
                try shape(spectrum[begin..<begin+frame.width(band)], band: band, lm: 3, bits: budget, left: &left, range: &range)
            }
            balance += frame.shapeBits[band] + tell
        }
        var remaining = bits-range.bitsUsed
        for priority in 0...1 {
            for band in bands where remaining > 0 && frame.fineBits[band] < 8 && frame.finePriority[band] == priority {
                try range.rawBits(target[band] > frame.energies[0][band] ? 1 : 0, 1)
                remaining -= 1
            }
        }
        return try range.finish(size: bytes)
    }

    private static func shape(_ bins: ArraySlice<Double>, band: Int, lm: Int, bits: Int,
                              left: inout Int, range: inout OpusRangeEncoder) throws {
        let n = bins.count, cache = CELTTables.pulseIndex[(lm+1)*21+band]
        guard cache >= 0 else { throw OpusPacket.Failure.invalidPacket }
        let table = CELTTables.pulseBits
        if lm >= 0 && bits > table[cache+table[cache]]+12 && n > 2 {
            let half = n/2, mid = bins.prefix(half), side = bins.suffix(half)
            let steps = CELTShape.angleSteps(bits: bits, n: half, band: band, lm: lm-1)
            let before = range.eighthBitsUsed
            var angle = 0
            if steps > 1 {
                let x = sqrt(mid.reduce(0) { $0+$1*$1 }), y = sqrt(side.reduce(0) { $0+$1*$1 })
                let digit = min(steps,max(0,Int((2*atan2(y,x)/Double.pi * Double(steps)).rounded())))
                let lower = (0..<digit).reduce(0) { $0 + min($1+1,steps+1-$1) }
                try range.interval(lower, lower+min(digit+1,steps+1-digit), total: (steps/2+1)*(steps/2+1))
                angle = digit*16384/steps
            }
            let used = range.eighthBitsUsed-before
            left -= used
            let budget = bits-used
            let midBits = max(0,min(budget,(budget-CELTShape.angle(angle,n:half).delta)/2))
            let sideBits = budget-midBits, previous = left
            if midBits >= sideBits {
                try shape(mid,band:band,lm:lm-1,bits:midBits,left:&left,range:&range)
                let excess = angle == 0 ? 0 : max(0,midBits-(previous-left)-24)
                try shape(side,band:band,lm:lm-1,bits:sideBits+excess,left:&left,range:&range)
            } else {
                try shape(side,band:band,lm:lm-1,bits:sideBits,left:&left,range:&range)
                let excess = angle == 16384 ? 0 : max(0,sideBits-(previous-left)-24)
                try shape(mid,band:band,lm:lm-1,bits:midBits+excess,left:&left,range:&range)
            }
        } else {
            let pulses = CELTShape.pulses(bits: bits, cache: cache, remaining: &left)
            if pulses > 0 {
                let vector = quantize(bins, pulses: pulses)
                try range.uniform(CELTPVQ.index(vector,pulses:pulses), below: CELTPVQ.size(dimensions:n,pulses:pulses))
            }
        }
    }

    /// Project onto the integer L1 sphere, then place remaining pulses where
    /// they give the largest normalized correlation with the original band.
    private static func quantize(_ bins: ArraySlice<Double>, pulses: Int) -> [Int] {
        let magnitudes = bins.map(abs), sum = magnitudes.reduce(1e-30,+)
        var vector = magnitudes.map { Int($0 * Double(pulses - 1) / sum) }
        var dot = zip(vector,magnitudes).reduce(0.0) { $0 + Double($1.0)*$1.1 }
        var norm = vector.reduce(0) { $0 + $1*$1 }
        for _ in vector.reduce(0,+)..<pulses {
            var selected = 0, best = -1.0
            for i in vector.indices {
                let numerator = dot+magnitudes[i], power = norm+2*vector[i]+1
                let score = numerator*numerator/Double(power)
                if score > best { best = score; selected = i }
            }
            dot += magnitudes[selected]
            norm += 2*vector[selected]+1
            vector[selected] += 1
        }
        return zip(vector,bins).map { $1 < 0 ? -$0 : $0 }
    }
}
