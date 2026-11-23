/* Copyright (c) 2001-2011 Timothy B. Terriberry
   Copyright (c) 2008-2009 Xiph.Org Foundation */
/*
   Redistribution and use in source and binary forms, with or without
   modification, are permitted provided that the following conditions
   are met:

   - Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.

   - Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
   ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
   A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER
   OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
   EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
   PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
   PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
   LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
   NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
   SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

// RFC 6716 §4.1. CELT raw bits are packed from the opposite end of the range-coded frame.
struct OpusRangeEncoder {
    private var low: UInt32 = 0
    private var width: UInt32 = 1 << 31
    private var bytes: [UInt8] = []
    private var pending: UInt8?
    private var pendingOnes = 0
    private var normalizedBits = 33
    private var rawCount = 0
    private var raw: [UInt8] = []

    var bitsUsed: Int { normalizedBits + rawCount - (32 - width.leadingZeroBitCount) }
    var eighthBitsUsed: Int {
        let log = 32 - width.leadingZeroBitCount
        let scaled = Int(width >> (log - 16)), bin = (scaled >> 12) - 8
        let bounds = [35733, 38967, 42495, 46340, 50535, 55109, 60097, 65535]
        return bitsUsed * 8 - bin - (scaled > bounds[bin] ? 1 : 0)
    }

    mutating func rawBits(_ value: UInt32, _ count: Int) throws {
        guard (0...25).contains(count), value < 1 << count, rawCount + count <= 1275*8 else { throw OpusPacket.Failure.invalidPacket }
        for i in 0..<count {
            if rawCount.isMultiple(of: 8) { raw.append(0) }
            raw[rawCount/8] |= UInt8((value >> i) & 1) << (rawCount % 8)
            rawCount += 1
        }
    }

    mutating func bit(_ value: Bool, logProbability: Int) throws {
        guard (1...23).contains(logProbability) else { throw OpusPacket.Failure.invalidPacket }
        let upper = width >> logProbability
        width -= upper
        if value { low += width; width = upper }
        try normalize()
    }

    mutating func interval(_ lower: Int, _ upper: Int, total: Int) throws {
        guard (2...65536).contains(total), lower >= 0, lower < upper, upper <= total else { throw OpusPacket.Failure.invalidPacket }
        let scale = width / UInt32(total)
        if lower > 0 {
            low += width - scale * UInt32(total - lower)
            width = scale * UInt32(upper - lower)
        } else { width -= scale * UInt32(total - upper) }
        try normalize()
    }

    mutating func uniform(_ value: UInt32, below total: UInt32) throws {
        guard total > 1, value < total else { throw OpusPacket.Failure.invalidPacket }
        let maximum = total - 1, count = max(0, 32 - maximum.leadingZeroBitCount - 8)
        let coarse = Int(value >> count)
        try interval(coarse, coarse+1, total: Int(maximum >> count)+1)
        try rawBits(value & ((1 << count)-1), count)
    }

    mutating func laplace(_ requested: Int, probability: Int, decay: Int) throws -> Int {
        if requested == 0 { try interval(0, probability, total: 32768); return 0 }
        var width = ((32768 - 32 - probability) * (16384 - decay) / 32768) + 1
        var lower = probability, magnitude = 1
        while magnitude < abs(requested) && lower + 2 * width < 32767 {
            lower += 2 * width
            width = ((width - 1) * 2 * decay / 32768) + 1
            magnitude += 1
        }
        let positive = requested > 0 && lower + width < 32768
        if positive { lower += width }
        try interval(lower, min(32768, lower+width), total: 32768)
        return positive ? magnitude : -magnitude
    }

    /// An emitted digit has eight data bits and may carry into its predecessor.
    /// A run of 0xff digits can only be committed when the next carry is known.
    private mutating func emit(_ digit: UInt32) throws {
        guard bytes.count + pendingOnes <= 1275 else { throw OpusPacket.Failure.invalidPacket }
        if digit == 255 {
            pendingOnes += 1
            return
        }
        let carry = UInt8(digit >> 8)
        if let pending { bytes.append(pending &+ carry) }
        bytes.append(contentsOf: repeatElement(255 &+ carry, count: pendingOnes))
        pendingOnes = 0
        pending = UInt8(truncatingIfNeeded: digit)
    }

    mutating func symbol(_ value: Int, _ cdf: [UInt8], offset: Int = 0, precision: Int = 8) throws {
        guard (1...8).contains(precision), offset >= 0, value >= 0, offset <= cdf.count, value < cdf.count - offset else {
            throw OpusPacket.Failure.invalidPacket
        }
        guard Int(cdf[offset + value]) < 1 << precision, value == 0 || Int(cdf[offset + value - 1]) <= 1 << precision else { throw OpusPacket.Failure.invalidPacket }
        let scale = width >> precision
        let lower = scale * UInt32(cdf[offset + value])
        let upper = value == 0 ? width : scale * UInt32(cdf[offset + value - 1])
        guard lower < upper else { throw OpusPacket.Failure.invalidPacket }
        low += width - upper
        width = upper - lower
        try normalize()
    }

    private mutating func normalize() throws {
        while width <= 1 << 23 {
            normalizedBits += 8
            try emit(low >> 23)
            low = (low << 8) & 0x7fff_ffff
            width <<= 8
        }
    }

    /// Choose a binary prefix whose entire interval lies inside the final range.
    mutating func finish(size: Int? = nil) throws -> [UInt8] {
        var bits = width.leadingZeroBitCount
        var mask = UInt32(0x7fff_ffff) >> bits
        var prefix = (low + mask) & ~mask
        if (prefix | mask) >= low + width {
            bits += 1
            mask >>= 1
            prefix = (low + mask) & ~mask
        }
        while bits > 0 {
            try emit(prefix >> 23)
            prefix = (prefix << 8) & 0x7fff_ffff
            bits -= 8
        }
        if pending != nil || pendingOnes != 0 { try emit(0) }
        guard let size else {
            guard bytes.count <= 1275, raw.isEmpty else { throw OpusPacket.Failure.invalidPacket }
            return bytes
        }
        guard (1...1275).contains(size), bytes.count + rawCount / 8 <= size else { throw OpusPacket.Failure.invalidPacket }
        if bytes.count + raw.count > size, rawCount % 8 > -bits { throw OpusPacket.Failure.invalidPacket }
        bytes.append(contentsOf: repeatElement(0, count: size - bytes.count))
        for (i, digit) in raw.enumerated() { bytes[size-1-i] |= digit }
        return bytes
    }
}
