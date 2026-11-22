import Foundation

/// RFC 6716 §4.3.4.10. CWRS enumeration and spreading follow the Xiph Opus
/// implementation (LICENSE-Opus.txt). Codebook indices occupy at most 32 bits.
enum CELTPVQ {
    // A band can have 176 dimensions and the pulse cache permits at most 128 pulses.
    // Saturation above the index space preserves every count used by a valid codebook.
    private static let counts: [[UInt64]] = {
        let limit = UInt64(UInt32.max) + 1
        var rows = [[UInt64]](repeating: [UInt64](repeating: 0, count: 130), count: 177)
        rows[0][0] = 1
        for n in 1..<rows.count {
            for k in 1..<130 {
                rows[n][k] = min(limit, rows[n-1][k] + rows[n][k-1] + rows[n-1][k-1])
            }
        }
        return rows
    }()

    static func size(dimensions n: Int, pulses k: Int) throws -> UInt32 {
        guard (1..<counts.count).contains(n), (1...128).contains(k),
              let size = UInt32(exactly: counts[n][k] + counts[n][k+1]) else {
            throw OpusPacket.Failure.invalidPacket
        }
        return size
    }

    static func vector(dimensions n: Int, pulses k: Int, index: UInt32) throws -> [Int] {
        guard try index < size(dimensions: n, pulses: k) else { throw OpusPacket.Failure.invalidPacket }
        var remaining = k, code = UInt64(index)
        var result = [Int](repeating: 0, count: n)
        for i in 0..<n {
            let row = counts[n-i]
            let negative = code >= row[remaining+1]
            if negative { code -= row[remaining+1] }
            let before = remaining
            while row[remaining] > code { remaining -= 1 }
            code -= row[remaining]
            result[i] = negative ? remaining - before : before - remaining
        }
        return result
    }

    /// Reverse the CWRS enumeration used by vector(dimensions:pulses:index:).
    static func index(_ vector: [Int], pulses: Int) throws -> UInt32 {
        let total = try size(dimensions: vector.count, pulses: pulses)
        var remaining = pulses, code: UInt64 = 0
        for i in vector.indices {
            let row = counts[vector.count-i]
            if vector[i] < 0 { code += row[remaining+1] }
            remaining -= abs(vector[i])
            guard remaining >= 0 else { throw OpusPacket.Failure.invalidPacket }
            code += row[remaining]
        }
        guard remaining == 0, code < total else { throw OpusPacket.Failure.invalidPacket }
        return UInt32(code)
    }

    static func decode(_ n: Int, pulses k: Int, blocks: Int, gain: Double, spread: Int,
                       range: inout OpusRangeDecoder) throws -> (values: [Double], mask: Int) {
        let total = try size(dimensions: n, pulses: k)
        let pulses = try vector(dimensions: n, pulses: k, index: range.uniform(below: total))
        let energy = pulses.reduce(0) { $0 + $1 * $1 }
        let scale = gain / sqrt(Double(energy))
        var values = pulses.map { Double($0) * scale }
        let blockSize = n / blocks
        var mask = 0
        for i in pulses.indices where pulses[i] != 0 { mask |= 1 << (i / blockSize) }
        if spread > 0 && 2*k < n {
            let factor = [15, 10, 5][spread-1]
            let rotationGain = Double(n) / Double(n + factor*k)
            let theta = Double.pi / 4 * rotationGain * rotationGain
            let cosine = cos(theta), sine = sin(theta)
            var secondStride = 0
            if n >= 8 * blocks {
                secondStride = 1
                while (secondStride*secondStride + secondStride)*blocks + (blocks >> 2) < n { secondStride += 1 }
            }
            for block in 0..<blocks {
                if secondStride > 0 {
                    rotate(&values, offset: block*blockSize, count: blockSize, step: secondStride, c: sine, s: cosine)
                }
                rotate(&values, offset: block*blockSize, count: blockSize, step: 1, c: cosine, s: sine)
            }
        }
        return (values, mask)
    }

    private static func rotate(_ values: inout [Double], offset: Int, count: Int, step: Int, c: Double, s: Double) {
        func pair(_ i: Int) {
            let a = values[offset+i], b = values[offset+i+step]
            values[offset+i] = c*a - s*b
            values[offset+i+step] = c*b + s*a
        }
        for i in 0..<(count-step) { pair(i) }
        for i in stride(from: count-2*step-1, through: 0, by: -1) { pair(i) }
    }
}
