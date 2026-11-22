import Foundation

/// CELT band shape decoding, RFC 6716 §4.3.4.10–11. Integer split decisions
/// match the Xiph reference so the encoder and decoder spend identical bits.
struct CELTShape {
    private typealias Band = (values: [Double], mask: Int)
    private let frame: CELTFrame
    private var range: OpusRangeDecoder
    private var seed: UInt32
    private var remaining = 0
    private var band = 0

    static func decode(_ frame: CELTFrame, range: inout OpusRangeDecoder, seed: inout UInt32) throws
        -> (bands: [[Double]], masks: [Int]) {
        var decoder = Self(frame: frame, range: range, seed: seed)
        let result = try decoder.decodeBands()
        range = decoder.range
        seed = decoder.seed
        return result
    }

    private mutating func decodeBands() throws -> (bands: [[Double]], masks: [Int]) {
        let m = 1 << frame.lm, channels = frame.channels, edges = CELTTables.edges
        let blocks = frame.transient ? m : 1, origin = m * edges[frame.start]
        var bands = [[Double]](repeating: [Double](repeating: 0, count: frame.samples), count: channels)
        var norm = bands, masks = [Int](repeating: 0, count: 21 * channels)
        var dual = frame.dualStereo, balance = frame.balance
        var updateFolding = true, foldingBand = 0
        for i in frame.start..<frame.end {
            band = i
            let tell = range.eighthBitsUsed
            if i != frame.start { balance -= tell }
            remaining = frame.totalBits * 8 - frame.antiCollapse - tell - 1
            let bits: Int
            if i < frame.codedBands {
                let share = balance / min(3, frame.codedBands-i)
                bits = max(0, min(16383, remaining+1, frame.shapeBits[i]+share))
            } else { bits = 0 }
            let n = frame.width(i), start = m * edges[i], bins = start..<(start+n)
            if (start-n >= origin || i == frame.start+1) && (updateFolding || foldingBand == 0) {
                foldingBand = i
            }
            if i == frame.start+1 {
                // Hybrid's second band is wider than its first. Extend the
                // preceding spectrum before selecting the first folding window.
                let firstWidth = frame.width(frame.start)
                for c in 0..<(dual ? 2 : 1) {
                    for j in firstWidth..<n { norm[c][origin+j] = norm[c][origin+j+firstWidth-n] }
                }
            }
            var lowStart: Int?
            var fills = [Int](repeating: (1<<blocks)-1, count: channels)
            if foldingBand != 0 && (frame.spread != 3 || blocks > 1 || frame.tf[i] < 0) {
                let from = max(origin, m * edges[foldingBand]-n)
                lowStart = from
                fills = [Int](repeating: 0, count: channels)
                for previous in frame.start..<i where edges[previous]*m < from+n && edges[previous+1]*m > from {
                    for c in 0..<channels { fills[c] |= masks[previous*channels+c] }
                }
            }
            if dual && i == frame.intensity {
                dual = false
                for j in origin..<start { norm[0][j] = (norm[0][j]+norm[1][j])*0.5 }
            }
            let scale = sqrt(Double(n))
            if channels == 2 && !dual {
                let low = lowStart.map { Array(norm[0][$0..<($0+n)]) }
                let stereo = try stereo(n, bits: bits, blocks: blocks, low: low, fill: fills[0] | fills[1])
                bands[0].replaceSubrange(bins, with: stereo.left)
                bands[1].replaceSubrange(bins, with: stereo.right)
                norm[0].replaceSubrange(bins, with: stereo.fold.map { $0 * scale })
                masks[i*2] = stereo.mask
                masks[i*2+1] = stereo.mask
            } else {
                for c in 0..<channels {
                    let low = lowStart.map { Array(norm[c][$0..<($0+n)]) }
                    let result = try mono(n, bits: dual ? bits/2 : bits, blocks: blocks, low: low, gain: 1, fill: fills[c])
                    bands[c].replaceSubrange(bins, with: result.values)
                    norm[c].replaceSubrange(bins, with: result.values.map { $0 * scale })
                    masks[i*channels+c] = result.mask
                }
            }
            balance += frame.shapeBits[i] + tell
            updateFolding = bits > n*8
        }
        return (bands, masks)
    }

    private mutating func mono(_ n: Int, bits: Int, blocks: Int, low: [Double]?, gain: Double, fill: Int) throws -> Band {
        if n == 1 {
            var value = 1.0
            if remaining >= 8 {
                if try range.rawBits(1) != 0 { value = -1 }
                remaining -= 8
            }
            return ([value], 1)
        }
        var blocks = blocks, width = n/blocks, low = low, fill = fill
        let long = blocks == 1, recombine = max(0, frame.tf[band])
        let compact = [0,1,1,1,2,3,3,3,2,3,3,3,2,3,3,3]
        for k in 0..<recombine {
            if low != nil { Self.haar(&low!, count: n>>k, stride: 1<<k) }
            fill = compact[fill&15] | (compact[(fill>>4)&15] << 2)
        }
        blocks >>= recombine
        width <<= recombine
        var divisions = 0
        while width.isMultiple(of: 2) && divisions < -frame.tf[band] {
            if low != nil { Self.haar(&low!, count: width, stride: blocks) }
            fill |= fill << blocks
            blocks <<= 1
            width >>= 1
            divisions += 1
        }
        if blocks > 1, let values = low {
            low = Self.reorder(values, blockCount: blocks<<recombine, hadamard: long, interleave: false)
        }
        var result = try partition(n, bits: bits, blocks: blocks, low: low, lm: frame.lm, gain: gain, fill: fill)
        if blocks > 1 {
            result.values = Self.reorder(result.values, blockCount: blocks<<recombine, hadamard: long, interleave: true)
        }
        for _ in 0..<divisions {
            blocks >>= 1
            width <<= 1
            result.mask |= result.mask >> blocks
            Self.haar(&result.values, count: width, stride: blocks)
        }
        let expand = [0,3,12,15,48,51,60,63,192,195,204,207,240,243,252,255]
        for k in 0..<recombine {
            result.mask = expand[result.mask & 15]
            Self.haar(&result.values, count: n>>k, stride: 1<<k)
        }
        result.mask &= (1 << (blocks << recombine)) - 1
        return result
    }

    private static func haar(_ values: inout [Double], count: Int, stride: Int) {
        let scale = 0.7071067811865475
        for lane in 0..<stride {
            for pair in 0..<(count/2) {
                let i = pair*2*stride+lane, j = i+stride
                let a = values[i], b = values[j]
                values[i] = (a+b)*scale
                values[j] = (a-b)*scale
            }
        }
    }

    private static let order = [1,0, 3,0,2,1, 7,0,4,3,6,1,5,2, 15,0,8,7,12,3,11,4,14,1,9,6,13,2,10,5]

    private static func reorder(_ values: [Double], blockCount: Int, hadamard: Bool, interleave: Bool) -> [Double] {
        var result = values
        let width = values.count/blockCount
        for block in 0..<blockCount {
            let permutation = hadamard ? order[blockCount-2+block] : block
            for j in 0..<width {
                let a = j*blockCount+block, b = permutation*width+j
                if interleave { result[a] = values[b] } else { result[b] = values[a] }
            }
        }
        return result
    }

    private mutating func partition(_ n: Int, bits: Int, blocks: Int, low: [Double]?, lm: Int, gain: Double, fill: Int) throws -> Band {
        let cache = CELTTables.pulseIndex[(lm+1)*21+band], table = CELTTables.pulseBits
        guard cache >= 0 else { throw OpusPacket.Failure.invalidPacket }
        let maxQ = table[cache]
        if lm >= 0 && bits > table[cache+maxQ]+12 && n > 2 {
            let half = n/2, subBlocks = (blocks+1)/2
            var fill = blocks == 1 ? (fill&1) | (fill<<1) : fill, bits = bits
            let angle = try theta(half, bits: &bits, blocks: subBlocks, originalBlocks: blocks, lm: lm-1, stereo: false, fill: &fill)
            var delta = angle.delta
            if blocks > 1 && angle.interior {
                if angle.value > 8192 { delta -= delta >> (5-lm) }
                else { delta = min(0, delta + ((half*8) >> (6-lm))) }
            }
            var midBits = max(0,min(bits,(bits-delta)/2)), sideBits = bits-midBits
            let before = remaining, midLow = low.map { Array($0.prefix(half)) }, sideLow = low.map { Array($0.suffix(half)) }
            let mid: Band, side: Band
            if midBits >= sideBits {
                mid = try partition(half, bits: midBits, blocks: subBlocks, low: midLow, lm: lm-1, gain: gain*angle.mid, fill: fill)
                if angle.value != 0 { sideBits += max(0, midBits-(before-remaining)-24) }
                side = try partition(half, bits: sideBits, blocks: subBlocks, low: sideLow, lm: lm-1, gain: gain*angle.side, fill: fill>>subBlocks)
            } else {
                side = try partition(half, bits: sideBits, blocks: subBlocks, low: sideLow, lm: lm-1, gain: gain*angle.side, fill: fill>>subBlocks)
                if angle.value != 16384 { midBits += max(0, sideBits-(before-remaining)-24) }
                mid = try partition(half, bits: midBits, blocks: subBlocks, low: midLow, lm: lm-1, gain: gain*angle.mid, fill: fill)
            }
            return (mid.values+side.values, mid.mask | (side.mask<<(blocks>>1)))
        }

        let k = Self.pulses(bits: bits, cache: cache, remaining: &remaining)
        if k > 0 {
            return try CELTPVQ.decode(n, pulses: k, blocks: blocks, gain: gain, spread: frame.spread, range: &range)
        }
        let mask = (1 << blocks)-1, live = fill & mask
        var values = [Double](repeating: 0, count: n)
        guard live != 0 else { return (values, 0) }
        for j in 0..<n {
            seed = seed &* 1664525 &+ 1013904223
            if let low { values[j] = low[j] + (seed & 0x8000 != 0 ? 1.0/256 : -1.0/256) }
            else { values[j] = Double(Int32(bitPattern: seed) >> 20) }
        }
        let scale = gain / sqrt(values.reduce(1e-15) { $0 + $1 * $1 })
        return (values.map { $0 * scale }, low == nil ? mask : live)
    }

    static func pulses(bits: Int, cache: Int, remaining: inout Int) -> Int {
        let table = CELTTables.pulseBits, maxQ = table[cache]
        var lower = 0, upper = maxQ
        for _ in 0..<6 {
            let middle = (lower+upper+1)/2
            if table[cache+middle] >= bits-1 { upper = middle } else { lower = middle }
        }
        func cost(_ q: Int) -> Int { q == 0 ? 0 : table[cache+q]+1 }
        var q = bits-cost(lower) <= cost(upper)-bits ? lower : upper
        while q > 0 && cost(q) > remaining { q -= 1 }
        remaining -= cost(q)
        return q < 8 ? q : (8+(q&7)) << ((q>>3)-1)
    }

    struct Angle {
        let value: Int, delta: Int, mid: Double, side: Double
        var interior: Bool { value > 0 && value < 16384 }
    }

    private static let exp2 = [16384,17866,19483,21247,23170,25267,27554,30048]

    private mutating func theta(_ n: Int, bits: inout Int, blocks: Int, originalBlocks: Int, lm: Int, stereo: Bool, fill: inout Int) throws -> Angle {
        let qn = stereo && band >= frame.intensity ? 1 : Self.angleSteps(bits: bits, n: n, band: band, lm: lm, twoPhase: stereo && n == 2)
        let before = range.eighthBitsUsed
        var value = 0
        if qn != 1 {
            if stereo && n > 2 || !stereo && originalBlocks == 1 {
                let half = qn/2
                let total = stereo ? (half+1)*3+half : (half+1)*(half+1)
                let digit = try range.cumulative(total: total)
                var lower = 0
                for x in 0...qn {
                    let width = stereo ? (x <= half ? 3 : 1) : min(x+1,qn+1-x)
                    if digit < lower+width {
                        try range.consume(lower: lower, upper: lower+width, total: total)
                        value = x
                        break
                    }
                    lower += width
                }
            } else { value = Int(try range.uniform(below: UInt32(qn+1))) }
            value = value*16384/qn
        } else if stereo && bits > 16 && remaining > 16 {
            // RFC 8251 disables intensity phase inversion for mono output.
            // Consume the sign from stereo packets to keep the range synchronized.
            _ = try range.bit(logProbability: 2)
        }
        let spent = range.eighthBitsUsed-before
        bits -= spent
        remaining -= spent
        if value == 0 { fill &= (1<<blocks)-1 }
        if value == 16384 { fill &= ((1<<blocks)-1) << blocks }
        return Self.angle(value, n: n)
    }

    static func angleSteps(bits: Int, n: Int, band: Int, lm: Int, twoPhase: Bool = false) -> Int {
        let cap = CELTTables.logWidths[band]+lm*8
        let offset = (cap>>1) - (twoPhase ? 16 : 4), size = 2*n-1-(twoPhase ? 1 : 0)
        let qb = min(64, bits-cap-32, (bits+size*offset)/size)
        return qb < 4 ? 1 : (((exp2[qb&7] >> (14-(qb>>3)))+1)>>1)<<1
    }

    static func angle(_ value: Int, n: Int) -> Angle {
        let mid: Int, side: Int, delta: Int
        if value == 0 {
            mid = 32767; side = 0; delta = -16384
        } else if value == 16384 {
            mid = 0; side = 32767; delta = 16384
        } else {
            mid = Self.cosine(value)
            side = Self.cosine(16384-value)
            let lc = Int.bitWidth-mid.leadingZeroBitCount, ls = Int.bitWidth-side.leadingZeroBitCount
            func logTerm(_ coefficient: Int, _ log: Int) -> Int {
                let x = coefficient << (15-log)
                return Self.product(x, Self.product(x,-2597)+7932)
            }
            let logTan = (ls-lc)*2048 + logTerm(side,ls) - logTerm(mid,lc)
            delta = Self.product((n-1)<<7,logTan)
        }
        return Angle(value: value, delta: delta, mid: Double(mid)/32768, side: Double(side)/32768)
    }

    private static func product(_ a: Int, _ b: Int) -> Int { (16384 + a*b) >> 15 }

    private static func cosine(_ angle: Int) -> Int {
        let x = (4096+angle*angle) >> 13
        return 32768-x + product(x,-7651 + product(x,8277 + product(-626,x)))
    }

    private mutating func stereo(_ n: Int, bits: Int, blocks: Int, low: [Double]?, fill: Int) throws
        -> (left: [Double], right: [Double], fold: [Double], mask: Int) {
        let originalFill = fill
        if n == 1 {
            let left = try mono(n, bits: bits, blocks: blocks, low: low, gain: 1, fill: fill)
            let right = try mono(n, bits: bits, blocks: blocks, low: low, gain: 1, fill: fill)
            return (left.values, right.values, left.values, 1)
        }
        var bits = bits, fill = fill
        let angle = try theta(n, bits: &bits, blocks: blocks, originalBlocks: blocks, lm: frame.lm, stereo: true, fill: &fill)
        let fold: [Double], mask: Int
        var left = [Double](repeating: 0, count: n), right = left
        if n == 2 {
            let signBits = angle.interior ? 8 : 0
            remaining -= signBits
            let sign = try signBits > 0 && range.rawBits(1) != 0 ? -1.0 : 1.0
            let main = try mono(n, bits: bits-signBits, blocks: blocks, low: low, gain: 1, fill: originalFill)
            let other = [-sign*main.values[1], sign*main.values[0]]
            let mid = angle.value > 8192 ? other : main.values, side = angle.value > 8192 ? main.values : other
            for i in 0..<n {
                left[i] = angle.mid*mid[i] - angle.side*side[i]
                right[i] = angle.mid*mid[i] + angle.side*side[i]
            }
            fold = main.values
            mask = main.mask
        } else {
            var midBits = max(0,min(bits,(bits-angle.delta)/2)), sideBits = bits-midBits
            let before = remaining
            let mid: Band, side: Band
            if midBits >= sideBits {
                mid = try mono(n, bits: midBits, blocks: blocks, low: low, gain: 1, fill: fill)
                if angle.value != 0 { sideBits += max(0, midBits-(before-remaining)-24) }
                side = try mono(n, bits: sideBits, blocks: blocks, low: nil, gain: angle.side, fill: fill>>blocks)
            } else {
                side = try mono(n, bits: sideBits, blocks: blocks, low: nil, gain: angle.side, fill: fill>>blocks)
                if angle.value != 16384 { midBits += max(0, sideBits-(before-remaining)-24) }
                mid = try mono(n, bits: midBits, blocks: blocks, low: low, gain: 1, fill: fill)
            }
            fold = mid.values
            mask = mid.mask | side.mask
            let sideEnergy = side.values.reduce(0.0) { $0+$1*$1 }
            let cross = zip(mid.values,side.values).reduce(0.0) { $0+$1.0*$1.1 } * angle.mid
            let total = angle.mid*angle.mid+sideEnergy, el = total-2*cross, er = total+2*cross
            if min(el,er) < 6e-4 {
                left = mid.values
                right = mid.values
            } else {
                let lg = 1/sqrt(el), rg = 1/sqrt(er)
                for i in 0..<n {
                    left[i] = lg * (angle.mid*mid.values[i]-side.values[i])
                    right[i] = rg * (angle.mid*mid.values[i]+side.values[i])
                }
            }
        }
        return (left, right, fold, mask)
    }
}
