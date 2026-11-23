/// CELT side information and per-band budgets. A frame has at most 21 bands, two channels
/// and 960 transform coefficients per channel. Bit allocation uses integer eighth-bits.
struct CELTFrame {
    let lm: Int, start: Int, end: Int, channels: Int, totalBits: Int
    let silence: Bool
    var transient = false
    var period = 0, tapset = 0
    var gain = 0.0
    var energies: [[Double]]
    var tf = [Int](repeating: 0, count: 21)
    var spread = 2
    var intensity = 0, dualStereo = false
    var codedBands = 0, balance = 0, antiCollapse = 0
    var shapeBits = [Int](repeating: 0, count: 21)
    var fineBits = [Int](repeating: 0, count: 21)
    var finePriority = [Int](repeating: 0, count: 21)
    var samples: Int { 120 << lm }

    init(lm: Int, start: Int, end: Int, energies: [[Double]], totalBits: Int = 0) {
        self.lm = lm
        self.start = start
        self.end = end
        self.energies = energies
        channels = 1
        self.totalBits = totalBits
        silence = false
    }

    init(config: UInt8, stereo: Bool, byteCount: Int, history: [[Double]], range: inout OpusRangeDecoder) throws {
        guard config >= 12, config <= 31, byteCount <= 1275 else { throw OpusPacket.Failure.invalidPacket }
        lm = config < 16 ? 2 + Int(config % 2) : Int(config % 4)
        start = config < 16 ? 17 : 0
        end = config < 16 ? (config < 14 ? 19 : 21) : [13, 17, 19, 21][Int(config - 16) / 4]
        channels = stereo ? 2 : 1
        totalBits = byteCount * 8
        energies = history
        if channels == 1 { energies[0] = zip(energies[0], energies[1]).map(max) }
        silence = try range.bitsUsed >= totalBits || (range.bitsUsed == 1 && range.bit(logProbability: 15) != 0)
        if silence {
            energies = [[Double]](repeating: [Double](repeating: -28, count: 21), count: 2)
            return
        }
        if start == 0, range.bitsUsed + 16 <= totalBits, try range.bit(logProbability: 1) != 0 {
            let octave = Int(try range.uniform(below: 6))
            period = (16 << octave) + Int(try range.rawBits(4 + octave)) - 1
            gain = Double(try range.rawBits(3) + 1) * 0.09375
            if range.bitsUsed + 2 <= totalBits { tapset = Int(try range.symbol(inverseCDF: [2,1,0], precision: 2)) }
        }
        transient = try lm > 0 && range.bitsUsed + 3 <= totalBits && range.bit(logProbability: 3) != 0
        let intra = try range.bitsUsed + 3 <= totalBits && range.bit(logProbability: 3) != 0
        try coarseEnergy(intra, &range)
        try timeFrequency(&range)
        if range.bitsUsed + 4 <= totalBits { spread = Int(try range.symbol(inverseCDF: [25,23,2,0], precision: 5)) }
        let caps = (0..<21).map { band in
            (CELTTables.caps[(2 * lm + channels - 1) * 21 + band] + 64) * channels * width(band) / 4
        }
        var available = totalBits * 8, logp = 6
        var boosts = [Int](repeating: 0, count: 21)
        for band in start..<end {
            let bins = width(band) * channels
            let step = min(bins * 8, max(48, bins))
            var probability = logp
            while range.eighthBitsUsed + probability * 8 < available && boosts[band] < caps[band] {
                guard try range.bit(logProbability: probability) != 0 else { break }
                boosts[band] += step
                available -= step
                probability = 1
            }
            if boosts[band] != 0 { logp = max(2, logp - 1) }
        }
        let trim = range.eighthBitsUsed + 48 <= available ? Int(try range.symbol(inverseCDF: [126,124,119,109,87,41,19,9,4,2,0], precision: 7)) : 5
        let bits = totalBits * 8 - range.eighthBitsUsed - 1
        antiCollapse = transient && lm >= 2 && bits >= (lm + 2) * 8 ? 8 : 0
        try allocate(max(0, bits - antiCollapse), trim: trim, caps: caps, boosts: boosts) { Int(try range.uniform(below: UInt32($0))) }
        for band in start..<end where fineBits[band] > 0 {
            let bins = 1 << fineBits[band]
            for c in 0..<channels { energies[c][band] += (Double(try range.rawBits(fineBits[band])) + 0.5) / Double(bins) - 0.5 }
        }
    }

    func width(_ band: Int) -> Int { (CELTTables.edges[band + 1] - CELTTables.edges[band]) << lm }

    private mutating func coarseEnergy(_ intra: Bool, _ range: inout OpusRangeDecoder) throws {
        let coefficient = intra ? 0 : Double([29440, 26112, 21248, 16384][lm]) / 32768
        let beta = Double(intra ? 4915 : [30147, 22282, 12124, 6554][lm]) / 32768
        var previous = [0.0, 0.0]
        for band in start..<end {
            for channel in 0..<channels {
                let left = totalBits - range.bitsUsed
                let delta: Int
                if left >= 15 {
                    let index = (lm * 2 + (intra ? 1 : 0)) * 42 + band * 2
                    delta = try range.laplace(probability: CELTTables.energyModel[index] << 7, decay: CELTTables.energyModel[index+1] << 6)
                } else if left >= 2 {
                    delta = [0, -1, 1][Int(try range.symbol(inverseCDF: [2,1,0], precision: 2))]
                } else if left == 1 { delta = -Int(try range.bit(logProbability: 1)) }
                else { delta = -1 }
                energies[channel][band] = coefficient * max(-9, energies[channel][band]) + previous[channel] + Double(delta)
                previous[channel] += Double(delta) * (1 - beta)
            }
        }
    }

    private mutating func timeFrequency(_ range: inout OpusRangeDecoder) throws {
        var logp = transient ? 2 : 4
        let reserve = lm > 0 && range.bitsUsed + logp + 1 <= totalBits
        let budget = totalBits - (reserve ? 1 : 0)
        var current = 0, changed = 0
        for band in start..<end {
            if range.bitsUsed + logp <= budget {
                current ^= Int(try range.bit(logProbability: logp))
                changed |= current
            }
            tf[band] = current
            logp = transient ? 4 : 5
        }
        let row = lm * 8 + (transient ? 4 : 0)
        let pick = try reserve && CELTTables.tfSelect[row+changed] != CELTTables.tfSelect[row+changed+2] && range.bit(logProbability: 1) != 0
        for band in start..<end { tf[band] = CELTTables.tfSelect[row + (pick ? 2 : 0) + tf[band]] }
    }

    mutating func finalizeEnergy(_ range: inout OpusRangeDecoder) throws {
        var left = totalBits - range.bitsUsed
        for priority in 0...1 {
            for band in start..<end where left >= channels && fineBits[band] < 8 && finePriority[band] == priority {
                let scale = Double(1 << (fineBits[band] + 1))
                for c in 0..<channels { energies[c][band] += (Double(try range.rawBits(1)) - 0.5) / scale }
                left -= channels
            }
        }
        if channels == 1 { energies[1] = energies[0] }
    }
}
