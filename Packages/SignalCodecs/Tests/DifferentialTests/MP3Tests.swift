// AudioMP3 against ffmpeg's decoder (Tools/gen-codec-references.py mp3): every frame after
// the Xing/LAME tag frame, no delay trimming.

import CodecCore
import Foundation
import Testing
@testable import AudioMP3

struct MP3ReferenceTests {
    /// `monoGain`: what a mono frame is scaled by in a stereo layout (ffmpeg's −3 dB upmix).
    static func decode(_ bytes: [UInt8], channels: Int? = nil, monoGain: Float = 1) throws -> (samples: [Float], stream: MP3Stream, stats: MP3Decoder.Statistics) {
        let stream = try MP3Stream.parse(bytes)
        var dec = MP3Decoder(for: stream)
        var out: [Float] = []
        let layout = channels ?? stream.channels
        for f in stream.frames {
            let gain: Float = f.header.channels == 1 && layout == 2 ? monoGain : 1
            let pcm = try dec.decode(f, channels: layout)
            for i in 0 ..< pcm[0].count { for c in pcm.indices { out.append(pcm[c][i] * gain) } }
        }
        return (out, stream, dec.statistics)
    }

    static func reference(_ path: String) -> [Float] {
        let b = Resources.bytes(path + ".f32")
        return stride(from: 0, to: b.count, by: 4).map {
            Float(bitPattern: UInt32(b[$0]) | UInt32(b[$0 + 1]) << 8 | UInt32(b[$0 + 2]) << 16 | UInt32(b[$0 + 3]) << 24)
        }
    }

    static let fixtures = Resources.files("MP3") { $0.hasSuffix(".mp3") }

    @Test(arguments: fixtures)
    func matchesFFmpeg(name: String) throws {
        try Self.compare("MP3/" + name)
    }

    @discardableResult
    static func compare(_ path: String, tolerance: Float = 1e-4, channels: Int? = nil, monoGain: Float = 1) throws -> MP3Decoder.Statistics {
        let name = path
        let (ours, stream, stats) = try Self.decode(Resources.bytes(path), channels: channels, monoGain: monoGain)
        let ref = Self.reference(path)
        #expect(ours.count == ref.count, "\(name): \(ours.count) samples, ffmpeg \(ref.count)")
        var worst: Float = 0, worstAt = 0, signal: Double = 0, noise: Double = 0
        for i in 0 ..< min(ours.count, ref.count) {
            let d = abs(ours[i] - ref[i])
            if d > worst { worst = d; worstAt = i }
            signal += Double(ref[i] * ref[i])
            noise += Double(d * d)
        }
        let snr = noise == 0 ? 999 : 10 * log10(signal / noise)
        print("\(name): \(stream.frames.count) frames, max |Δ| \(worst) at \(worstAt), SNR \(fixed(snr, 1)) dB, \(stats)")
        #expect(worst < tolerance, "\(name): max |Δ| \(worst) at sample \(worstAt)")
        return stats
    }

    static let conformance = Resources.files("MP3Conformance") { $0.hasSuffix(".bit") && $0 != "he_free.bit" }

    @Test(arguments: conformance)
    func conformanceMatchesFFmpeg(name: String) throws {
        if name == "he_mode.bit" {
            try Self.compare("MP3Conformance/" + name, channels: 2, monoGain: 0.70710678)
        } else {
            try Self.compare("MP3Conformance/" + name)
        }
    }
}

extension MP3ReferenceTests {
    /// The fixtures between them use every coding tool.
    @Test func fixturesCoverTheCodingTools() throws {
        var t = MP3Decoder.Statistics()
        let paths = Self.fixtures.map { "MP3/" + $0 } + Self.conformance.map { "MP3Conformance/" + $0 }
        for p in paths {
            let s = try Self.decode(Resources.bytes(p), channels: 2).stats
            t.shortBlocks += s.shortBlocks; t.mixedBlocks += s.mixedBlocks; t.startStopBlocks += s.startStopBlocks
            t.midSideGranules += s.midSideGranules; t.intensityGranules += s.intensityGranules
            t.scfsiGranules += s.scfsiGranules; t.count1TableB += s.count1TableB; t.crcFrames += s.crcFrames
            t.tablesUsed |= s.tablesUsed
        }
        #expect(t.shortBlocks > 0 && t.mixedBlocks > 0 && t.startStopBlocks > 0)
        #expect(t.midSideGranules > 0 && t.intensityGranules > 0 && t.scfsiGranules > 0 && t.count1TableB > 0 && t.crcFrames > 0)
        // Every table_select except 4 and 14 (not used by the standard).
        #expect(t.tablesUsed | (1 << 4) | (1 << 14) == UInt32.max, "tables used: \(String(t.tablesUsed, radix: 2))")
    }
}

struct MP3StreamTests {
    static let sample = Resources.bytes("MP3/stereo_44100_cbr128.mp3")

    @Test func encoderInfoAndDuration() throws {
        let s = try MP3Stream.parse(Self.sample)
        #expect(s.info?.encoderDelay == 576 && s.info?.isCBR == true)
        #expect(s.info?.frameCount == s.frames.count)
        // 2 s of audio: 78 frames × 1152 − 576 − padding = 88200 samples.
        #expect(abs(s.durationSeconds - 2.0) < 0.001, "\(s.durationSeconds)")
    }

    @Test func tagsAndJunkAroundFrames() throws {
        let plain = try MP3Stream.parse(Self.sample)
        let id3v2: [UInt8] = [0x49, 0x44, 0x33, 3, 0, 0, 0, 0, 0, 20] + Array(repeating: 0xFF, count: 20)  // 0xFF inside the tag
        let id3v1: [UInt8] = Array("TAG".utf8) + Array(repeating: 0x20, count: 125)
        let ape: [UInt8] = Array("APETAGEX".utf8) + [0xD0, 0x07, 0, 0, 32, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x00] + Array(repeating: 0, count: 8)
        let tagged = try MP3Stream.parse(id3v2 + Self.sample + ape + id3v1)
        #expect(tagged.frames.count == plain.frames.count && tagged.info == plain.info)
        // Junk (including false syncs) between frames is skipped; the frames around it decode.
        let f = plain.frames
        let cut = f[10].offset
        let junk: [UInt8] = [0xFF, 0xFB, 0x00, 0x12, 0xFF, 0xE0, 0x33, 0x00, 0x01]
        let spliced = Array(Self.sample[..<cut]) + junk + Array(Self.sample[cut...])
        #expect(try MP3Stream.parse(spliced).frames.count == plain.frames.count)
        // Not MP3 / Layer II / free format.
        #expect(throws: ParseFailure.self) { try MP3Stream.parse(Array("RIFF....WAVEfmt ".utf8) + Array(repeating: 0, count: 100)) }
        var layer2 = Array(Self.sample)
        for frame in f { layer2[frame.offset + 1] = layer2[frame.offset + 1] & 0xF9 | 0x04 }
        let firstTag = try MP3Stream.parse(Self.sample).frames[0].offset - 417  // the Info frame
        layer2[max(0, firstTag) + 1] = layer2[max(0, firstTag) + 1] & 0xF9 | 0x04
        #expect(throws: ParseFailure.self) { try MP3Stream.parse(layer2) }
        #expect(throws: ParseFailure.self) { try MP3Stream.parse(Resources.bytes("MP3Conformance/he_free.bit")) }
    }

    /// Every truncation of the first frames and a deterministic set of bit flips decode to
    /// finite, frame-sized output or fail with a ParseFailure.
    @Test(arguments: ["MP3/stereo_44100_vbr_q7.mp3", "MP3/mono_8000_cbr8.mp3", "MP3Conformance/he_mode.bit", "MP3Conformance/si_block.bit"])
    func hostileInputs(path: String) throws {
        let bytes = Resources.bytes(path)
        let stream = try MP3Stream.parse(bytes)
        func check(_ dec: inout MP3Decoder, _ frame: MP3Frame) {
            if let pcm = try? dec.decode(frame) {
                #expect(pcm.count == frame.header.channels && pcm.allSatisfy { $0.count == frame.header.samplesPerFrame && $0.allSatisfy(\.isFinite) })
            }
        }
        var dec = MP3Decoder(for: stream)
        for f in stream.frames.prefix(8) {
            let b = f.bytes.copyBytes()
            for n in 4 ..< b.count {
                guard let h = MP3Header.parse(b[0], b[1], b[2], b[3]) else { continue }
                check(&dec, MP3Frame(header: h, bytes: ByteSlice(Array(b.prefix(n))), offset: 0))
            }
        }
        var seed: UInt32 = 777
        for i in 0 ..< 3000 {
            let f = stream.frames[i % stream.frames.count]
            var b = f.bytes.copyBytes()
            for _ in 0 ..< 1 + i % 4 {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let bit = 32 + Int(seed >> 8) % ((b.count - 4) * 8)   // keep the header
                b[bit / 8] ^= UInt8(0x80) >> UInt8(bit % 8)
            }
            check(&dec, MP3Frame(header: f.header, bytes: ByteSlice(b), offset: 0))
        }
        // And whole-stream parsing of a damaged file never traps.
        var damaged = bytes
        for i in stride(from: 100, to: damaged.count, by: 97) { damaged[i] ^= 0x5A }
        if let s = try? MP3Stream.parse(damaged) {
            var d = MP3Decoder(for: s)
            for f in s.frames where f.header.lsf == d.lsf { _ = try? d.decode(f) }
        }
    }
}
