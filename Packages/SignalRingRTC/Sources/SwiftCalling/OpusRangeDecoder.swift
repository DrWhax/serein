import CodecCore

/// Entropy decoder shared by the SILK and CELT layers of an Opus frame (RFC 6716 §4.1).
/// Arithmetic decoding reads forward, with zero lookahead after the frame. CELT raw bits
/// read backward from its end. The two readers can overlap by design.
struct OpusRangeDecoder {
    private var bytes: [UInt8]
    private var forward = 0
    private var rawPosition = 0
    private var carry: UInt32
    private(set) var range: UInt32 = 128
    private var value: UInt32
    private var countedBits = 9
    var bitsUsed: Int { countedBits - (32 - range.leadingZeroBitCount) }

    /// Conservative fractional bit position, in eighths (RFC 6716 §4.1.6.2).
    var eighthBitsUsed: Int {
        let log = 32 - range.leadingZeroBitCount
        let normalized = Int(range >> (log - 16))
        let bin = (normalized >> 12) - 8
        let thresholds = [35733, 38967, 42495, 46340, 50535, 55109, 60097, 65535]
        return (countedBits - log) * 8 - bin - (normalized > thresholds[bin] ? 1 : 0)
    }

    mutating func removeRedundancy(_ count: Int) throws {
        guard (0...bytes.count).contains(count), rawPosition == 0,
              bitsUsed <= (bytes.count - count) * 8 else { throw OpusPacket.Failure.invalidPacket }
        bytes.removeLast(count)
    }

    func cumulative(total: Int) throws -> Int {
        guard (2...65536).contains(total) else { throw OpusPacket.Failure.invalidPacket }
        let scale = range / UInt32(total)
        return total - 1 - min(Int(value / scale), total - 1)
    }

    mutating func consume(lower: Int, upper: Int, total: Int) throws {
        guard 0 <= lower, lower < upper, upper <= total, (2...65536).contains(total) else { throw OpusPacket.Failure.invalidPacket }
        let scale = range / UInt32(total)
        let offset = scale * UInt32(total - upper)
        guard value >= offset else { throw OpusPacket.Failure.invalidPacket }
        value -= offset
        range = lower == 0 ? range - offset : scale * UInt32(upper - lower)
        guard value < range else { throw OpusPacket.Failure.invalidPacket }
        normalize()
    }

    mutating func laplace(probability: Int, decay: Int) throws -> Int {
        guard (1..<32736).contains(probability), (0..<16384).contains(decay) else { throw OpusPacket.Failure.invalidPacket }
        let symbol = try cumulative(total: 32768)
        var lower = 0, width = probability, magnitude = 0
        if symbol >= width {
            magnitude = 1
            lower = width
            width = ((32768 - 32 - probability) * (16384 - decay) / 32768) + 1
            while width > 1 && symbol >= lower + 2 * width {
                lower += 2 * width
                width = ((width - 1) * 2 * decay / 32768) + 1
                magnitude += 1
            }
            if width == 1 {
                let extra = (symbol - lower) / 2
                magnitude += extra
                lower += 2 * extra
            }
            if symbol < lower + width { magnitude = -magnitude } else { lower += width }
        }
        try consume(lower: lower, upper: min(lower + width, 32768), total: 32768)
        return magnitude
    }

    init(_ frame: ByteSlice) throws {
        guard frame.count <= 1275 else { throw OpusPacket.Failure.invalidPacket }
        bytes = frame.copyBytes()
        carry = UInt32(bytes.first ?? 0)
        forward = min(1, bytes.count)
        value = 127 - (carry >> 1)
        normalize()
    }

    private mutating func normalize() {
        while range <= 1 << 23 {
            let next: UInt32
            if forward < bytes.count {
                next = UInt32(bytes[forward])
                forward += 1
            } else { next = 0 }
            let symbol = ((carry & 1) << 7) | (next >> 1)
            range <<= 8
            value = ((value << 8) | (255 - symbol)) & 0x7fff_ffff
            carry = next
            countedBits += 8
        }
    }

    mutating func bit(logProbability: Int) throws -> UInt32 {
        guard (1...23).contains(logProbability) else { throw OpusPacket.Failure.invalidPacket }
        let split = range >> logProbability
        let one = value < split
        if one {
            range = split
        } else {
            value -= split
            range -= split
        }
        normalize()
        return one ? 1 : 0
    }

    mutating func symbol(inverseCDF: some RandomAccessCollection<UInt8>, precision: Int = 8) throws -> UInt32 {
        guard (1...8).contains(precision), inverseCDF.count <= 256, inverseCDF.last == 0 else {
            throw OpusPacket.Failure.invalidPacket
        }
        let scale = range >> precision
        var upper = range
        for (index, boundary) in inverseCDF.enumerated() {
            guard UInt32(boundary) < 1 << precision else { throw OpusPacket.Failure.invalidPacket }
            let lower = scale * UInt32(boundary)
            guard lower <= upper else { throw OpusPacket.Failure.invalidPacket }
            if value >= lower {
                value -= lower
                range = upper - lower
                normalize()
                return UInt32(index)
            }
            upper = lower
        }
        throw OpusPacket.Failure.invalidPacket
    }

    mutating func rawBits(_ count: Int) throws -> UInt32 {
        guard (0...25).contains(count), rawPosition + count <= bytes.count * 8 else { throw OpusPacket.Failure.invalidPacket }
        var bits: UInt32 = 0
        for shift in 0..<count {
            let byte = bytes[bytes.count - 1 - rawPosition / 8]
            bits |= UInt32((byte >> (rawPosition % 8)) & 1) << shift
            rawPosition += 1
        }
        countedBits += count
        return bits
    }

    mutating func uniform(below total: UInt32) throws -> UInt32 {
        guard total >= 2 else { throw OpusPacket.Failure.invalidPacket }
        let maximum = total - 1
        let rawCount = max(0, 32 - maximum.leadingZeroBitCount - 8)
        let coarseTotal = (maximum >> rawCount) + 1
        let scale = range / coarseTotal
        let digit = coarseTotal - 1 - min(value / scale, coarseTotal - 1)
        let offset = scale * (coarseTotal - 1 - digit)
        value -= offset
        range = digit == 0 ? range - offset : scale
        normalize()
        let decoded = (digit << rawCount) | (try rawBits(rawCount))
        guard decoded < total else { throw OpusPacket.Failure.invalidPacket }
        return decoded
    }
}
