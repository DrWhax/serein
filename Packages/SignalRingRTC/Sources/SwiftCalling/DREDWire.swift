// Opus 1.6.1 DRED v12 entropy coding. Copyright (c) 2022 Amazon.
// Quantization and Laplace coding notices are included in LICENSE-Opus.txt.
import CodecCore
import Foundation

enum DREDWire {
    typealias History = (state: [Float], latents: [[Float]], offset: Int)
    private static let quantizerSteps = [0, 2, 3, 4, 6, 8, 12, 16]
    private static let maxBytes = 1000
    private static let maxLatents = 26

    /// Offsets use 2.5 ms units relative to the start of this Opus packet.
    /// Each 25-value encoder latent covers four 10 ms feature frames, newest first.
    static func attach(to data: Data, state: [Float], latents: [[Float]], offset: Int,
                       initialQ: Int = 6, step: Int = 5, maxQ: Int = 15) throws -> Data {
        let bytes = try payload(state: state, latents: latents, offset: offset, initialQ: initialQ, step: step, maxQ: maxQ)
        return try OpusPacket(data).addingFirstFrameExtension(id: 126, bytes: bytes)
    }

    static func payload(state: [Float], latents: [[Float]], offset: Int, initialQ: Int, step: Int, maxQ: Int) throws -> [UInt8] {
        guard state.count == 50, (1...maxLatents).contains(latents.count),
              (-8175...16).contains(offset), (0...15).contains(initialQ), (0...7).contains(step),
              (initialQ...15).contains(maxQ), step == 0 || maxQ == 15 || (initialQ < 14 && maxQ > initialQ) else {
            throw OpusPacket.Failure.invalidPacket
        }
        var range = OpusRangeEncoder()
        try range.uniform(UInt32(initialQ), below: 16)
        try range.uniform(UInt32(step), below: 8)
        let delay = 16 - offset
        try range.uniform(delay > 31 ? 1 : 0, below: 2)
        if delay > 31 { try range.uniform(UInt32(delay / 32), below: 256) }
        try range.uniform(UInt32(delay % 32), below: 32)
        if initialQ < 14, step > 0 {
            let count = 14 - initialQ
            if maxQ == 15 { try range.interval(0, count, total: 2*count) }
            else {
                let value = count + maxQ - initialQ - 1
                try range.interval(value, value + 1, total: 2*count)
            }
        }
        try encode(state, level: initialQ, state: true, range: &range)
        for (index, latent) in latents.enumerated() {
            guard latent.count == 25 else { throw OpusPacket.Failure.invalidPacket }
            let level = min(maxQ, initialQ + (quantizerSteps[step]*index + 8)/16)
            try encode(latent, level: level, state: false, range: &range)
        }
        let size = (range.bitsUsed + 7) / 8
        guard size <= maxBytes else { throw OpusPacket.Failure.invalidPacket }
        let entropy = try range.finish(size: size)
        return [68, 12] + entropy
    }

    static func decode(_ packet: OpusPacket) throws -> History? {
        guard let ext = try packet.findExtension({ item in
            guard item.id == 126, item.bytes.count > 2 else { return false }
            var cursor = item.bytes.cursor()
            return try cursor.u8() == 68 && cursor.u8() == 12
        }) else { return nil }
        var cursor = ext.bytes.cursor()
        _ = try cursor.bytes(2)
        let size = cursor.remaining
        guard size <= maxBytes else { throw OpusPacket.Failure.invalidPacket }
        var range = try OpusRangeDecoder(cursor.bytes(size))
        let initialQ = try Int(range.uniform(below: 16)), step = try Int(range.uniform(below: 8))
        let high = try range.uniform(below: 2) == 1 ? Int(range.uniform(below: 256)) * 32 : 0
        let offset = try 16 - Int(range.uniform(below: 32)) - high + ext.frame * packet.samplesPerFrame / 120
        var maxQ = 15
        if initialQ < 14, step > 0 {
            let count = 14 - initialQ
            let value = try range.cumulative(total: 2*count)
            if value >= count {
                maxQ = initialQ + value - count + 1
                try range.consume(lower: value, upper: value + 1, total: 2*count)
            } else { try range.consume(lower: 0, upper: count, total: 2*count) }
        }
        let limit = 8 * size
        let state = try decode(level: initialQ, state: true, range: &range, limit: limit)
        var latents: [[Float]] = []
        while latents.count < maxLatents, limit - range.bitsUsed > 7 {
            let level = min(maxQ, initialQ + (quantizerSteps[step]*latents.count + 8)/16)
            var latent = try decode(level: level, state: false, range: &range, limit: limit)
            latent.append(Float(level)*0.125 - 1)
            latents.append(latent)
        }
        guard !latents.isEmpty else { return nil }
        return (state, latents, offset)
    }

    private struct Distribution {
        let scale, zero, decay, deadZone: [UInt8]
        let count: Int
        init(state: Bool) {
            scale = state ? DREDQuantization.stateScale : DREDQuantization.latentScale
            zero = state ? DREDQuantization.stateZero : DREDQuantization.latentZero
            decay = state ? DREDQuantization.stateDecay : DREDQuantization.latentDecay
            deadZone = state ? DREDQuantization.stateDeadZone : DREDQuantization.latentDeadZone
            count = state ? 50 : 25
        }
    }

    // Inverse CDFs use 15 bits of precision. The last magnitude symbol escapes
    // into another group of seven, using the same geometric distribution.
    private static func magnitudes(_ decay: Int) -> [Int] {
        var cdf = [max(7, decay)]
        for i in 1..<7 { cdf.append(max(7 - i, (cdf[i - 1]*decay) >> 15)) }
        return cdf + [0]
    }

    private static func encodeSymbol(_ symbol: Int, cdf: [Int], range: inout OpusRangeEncoder) throws {
        let lower = symbol == 0 ? 0 : 32768 - cdf[symbol-1]
        try range.interval(lower, 32768 - cdf[symbol], total: 32768)
    }

    private static func decodeSymbol(_ cdf: [Int], range: inout OpusRangeDecoder) throws -> Int {
        let value = try range.cumulative(total: 32768)
        guard let index = cdf.firstIndex(where: { value < 32768 - $0 }) else { throw OpusPacket.Failure.invalidPacket }
        let lower = index == 0 ? 0 : 32768 - cdf[index - 1]
        try range.consume(lower: lower, upper: 32768 - cdf[index], total: 32768)
        return index
    }

    private static func encode(_ values: [Float], level: Int, state: Bool, range: inout OpusRangeEncoder) throws {
        let table = Distribution(state: state)
        for (index, value) in values.enumerated() {
            guard value.isFinite, abs(value) < 65_536 else { throw OpusPacket.Failure.invalidPacket }
            let i = level * table.count + index
            guard table.decay[i] != 0, table.zero[i] != 255 else { continue }
            let scaled = value * Float(table.scale[i]) / 256, delta = Float(table.deadZone[i]) / 256
            let adjusted = scaled - delta * DREDModel.tanhApprox(scaled / (delta + 0.1))
            let q = Int(floor(0.5 + adjusted))
            let nonzero = 32768 - Int(table.zero[i]) * 128
            try encodeSymbol(q == 0 ? 0 : q > 0 ? 1 : 2, cdf: [nonzero, nonzero / 2, 0], range: &range)
            if q != 0 {
                let cdf = magnitudes(Int(table.decay[i]) * 128)
                var remaining = abs(q) - 1
                repeat {
                    guard range.bitsUsed <= maxBytes * 8 else { throw OpusPacket.Failure.invalidPacket }
                    try encodeSymbol(min(7, remaining), cdf: cdf, range: &range)
                    remaining -= 7
                } while remaining >= 0
            }
        }
    }

    private static func decode(level: Int, state: Bool, range: inout OpusRangeDecoder, limit: Int) throws -> [Float] {
        let table = Distribution(state: state)
        var values = Array(repeating: Float.zero, count: table.count)
        for index in values.indices {
            let i = level * table.count + index
            guard table.decay[i] != 0, table.zero[i] != 255 else { continue }
            let nonzero = 32768 - Int(table.zero[i]) * 128
            let sign = try decodeSymbol([nonzero, nonzero / 2, 0], range: &range)
            if sign != 0 {
                let cdf = magnitudes(Int(table.decay[i]) * 128)
                var magnitude = 1, part: Int
                repeat {
                    guard range.bitsUsed <= limit else { throw OpusPacket.Failure.invalidPacket }
                    part = try decodeSymbol(cdf, range: &range)
                    magnitude += part
                } while part == 7
                values[index] = Float(sign == 2 ? -magnitude : magnitude) * 256 / Float(max(1, table.scale[i]))
            }
        }
        guard range.bitsUsed <= limit else { throw OpusPacket.Failure.invalidPacket }
        return values
    }
}
