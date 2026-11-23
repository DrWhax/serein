import CodecCore
import Foundation

/// RFC 6716 §3, using the 48 kHz RTP clock regardless of the encoder's sample rate.
/// Frame views exclude both framing and padding, including optional Opus extensions.
struct OpusPacket {
    enum Mode { case silk, hybrid, celt }
    enum Failure: Error { case invalidPacket }
    let byteCount: Int
    let configuration: UInt8
    let stereo: Bool
    let samplesPerFrame: Int
    let frames: [ByteSlice]
    let padding: ByteSlice
    var sampleCount: Int { samplesPerFrame * frames.count }
    /// First SILK/VAD header, including the side channel (opus_packet_has_lbrr).
    var containsLBRR: Bool {
        guard mode != .celt, let first = frames.first, !first.isEmpty else { return false }
        var reader = first.cursor()
        guard let word = try? reader.u8() else { return false }
        let blocks = max(1, samplesPerFrame/960)
        return word & (1 << (7-blocks)) != 0 || (stereo && word & (1 << (6-2*blocks)) != 0)
    }
    var mode: Mode {
        if configuration < 12 { return .silk }
        if configuration < 16 { return .hybrid }
        return .celt
    }

    init(_ data: Data) throws {
        guard (1...65_507).contains(data.count) else { throw Failure.invalidPacket }
        byteCount = data.count
        var input = ByteCursor(Array(data))
        let toc = try input.u8()
        configuration = toc >> 3
        stereo = toc & 4 != 0
        switch configuration {
        case 0..<12: samplesPerFrame = [480, 960, 1920, 2880][Int(configuration % 4)]
        case 12..<16: samplesPerFrame = 480 << (configuration % 2)
        default: samplesPerFrame = 120 << (configuration % 4)
        }

        let count: Int, variable: Bool
        var padding = 0
        switch toc & 3 {
        case 0: (count, variable) = (1, false)
        case 1: (count, variable) = (2, false)
        case 2: (count, variable) = (2, true)
        default:
            let layout = try input.u8()
            count = Int(layout & 63)
            variable = layout & 128 != 0
            if layout & 64 != 0 {
                var byte: UInt8
                repeat {
                    byte = try input.u8()
                    padding += byte == 255 ? 254 : Int(byte)
                    guard padding <= input.remaining else { throw Failure.invalidPacket }
                } while byte == 255
            }
        }
        guard count > 0, count * samplesPerFrame <= 5760 else { throw Failure.invalidPacket }
        var framesInput = try input.bytes(input.remaining - padding).cursor()
        self.padding = try input.bytes(padding)
        var lengths: [Int] = []
        if variable {
            var total = 0
            for _ in 1..<count {
                let first = try Int(framesInput.u8())
                let length = first < 252 ? first : first + 4 * (try Int(framesInput.u8()))
                total += length
                lengths.append(length)
            }
            guard total <= framesInput.remaining else { throw Failure.invalidPacket }
            lengths.append(framesInput.remaining - total)
        } else {
            guard framesInput.remaining.isMultiple(of: count) else { throw Failure.invalidPacket }
            lengths = Array(repeating: framesInput.remaining / count, count: count)
        }
        frames = try lengths.map { length in
            guard length <= 1275 else { throw Failure.invalidPacket }
            return try framesInput.bytes(length)
        }
    }
}
