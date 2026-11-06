// AudioAAC against ffmpeg's decoder (Tools/gen-codec-references.py aac): every decoded frame,
// edit lists ignored. Streams encoded without PNS must match to float rounding; with PNS the
// noise bands come from the same LCG as FFmpeg's, so they are held to the same bound.

import CodecCore
import Foundation
import Testing
@testable import AudioAAC
import ContainerMP4

struct AACReferenceTests {
    /// Decodes a fixture to interleaved float samples.
    static func decode(_ name: String) throws -> (samples: [Float], channels: Int, stats: AACDecoder.Statistics) {
        let bytes = Resources.bytes("AAC/" + name)
        if name.hasSuffix(".aac") {
            let frames = try ADTS.frames(bytes)
            var dec = AACDecoder(config: frames[0].config)
            var out: [Float] = []
            for f in frames {
                #expect(f.rawDataBlocks == 1)
                let pcm = try dec.decode(f.payload)
                for i in 0..<1024 { for c in pcm.indices { out.append(pcm[c][i]) } }
            }
            return (out, frames[0].config.channels, dec.statistics)
        }
        let file = try MP4Demuxer.parse(bytes)
        let track = file.audioTracks[0]
        guard case .aac(_, _, let cfg) = track.sampleEntries[0] else { throw ParseFailure(offset: 0, rule: "test", reason: .invalid("not AAC")) }
        let config = try AACConfig.parse(cfg.audioSpecificConfig)
        var dec = AACDecoder(config: config)
        var out: [Float] = []
        for s in track.samples {
            let pcm = try dec.decode(ByteSlice(Array(bytes[s.offset ..< s.offset + s.size])))
            for i in 0..<1024 { for c in pcm.indices { out.append(pcm[c][i]) } }
        }
        return (out, config.channels, dec.statistics)
    }

    static func reference(_ name: String) -> [Float] {
        let b = Resources.bytes("AAC/" + name + ".f32")
        return stride(from: 0, to: b.count, by: 4).map {
            Float(bitPattern: UInt32(b[$0]) | UInt32(b[$0 + 1]) << 8 | UInt32(b[$0 + 2]) << 16 | UInt32(b[$0 + 3]) << 24)
        }
    }

    static let compared = Resources.files("AAC") { ($0.hasSuffix(".aac") || $0.hasSuffix(".m4a")) && !$0.hasPrefix("he_") }

    @Test(arguments: compared)
    func matchesFFmpeg(name: String) throws {
        let (ours, channels, stats) = try Self.decode(name)
        let ref = Self.reference(name)
        if name.hasSuffix(".aac") {
            #expect(ours.count == ref.count, "\(name): \(ours.count) samples, ffmpeg \(ref.count)")
        } else {
            // ffmpeg trims the last MP4 sample to its stts duration; we return whole frames.
            #expect(ours.count >= ref.count && ours.count - ref.count < 1024 * channels, "\(name): \(ours.count) samples, ffmpeg \(ref.count)")
        }
        print("\(name): \(stats)")
        var worst: Float = 0, worstAt = 0, signal: Double = 0, noise: Double = 0
        for i in 0..<min(ours.count, ref.count) {
            let d = abs(ours[i] - ref[i])
            if d > worst { worst = d; worstAt = i }
            signal += Double(ref[i] * ref[i])
            noise += Double(d * d)
        }
        let snr = noise == 0 ? 999 : 10 * log10(signal / noise)
        print("\(name): max |Δ| \(worst) at \(worstAt), SNR \(fixed(snr, 1)) dB")
        #expect(worst < 1e-4, "\(name): max |Δ| \(worst) at sample \(worstAt)")
    }
}

extension AACReferenceTests {
    /// The fixtures between them cover every coding tool the decoder implements.
    @Test func fixturesCoverTheCodingTools() throws {
        var total = AACDecoder.Statistics()
        for name in Self.compared {
            let s = try Self.decode(name).stats
            total.shortWindowFrames += s.shortWindowFrames; total.transitionFrames += s.transitionFrames
            total.midSideBands += s.midSideBands; total.intensityBands += s.intensityBands; total.noiseBands += s.noiseBands
            total.tnsFilters += s.tnsFilters; total.pulses += s.pulses; total.escapes += s.escapes; total.kbdWindows += s.kbdWindows
        }
        #expect(total.shortWindowFrames > 0 && total.transitionFrames > 0)
        #expect(total.midSideBands > 0 && total.intensityBands > 0 && total.noiseBands > 0)
        #expect(total.tnsFilters > 0 && total.pulses > 0)
        #expect(total.escapes > 0 && total.kbdWindows > 0)
        print("total: \(total)")
    }
}

struct AACStructureTests {
    /// HE-AAC (explicit SBR): the AAC-LC core decodes at half the output rate.
    @Test func heAACDecodesTheCore() throws {
        let bytes = Resources.bytes("AAC/he_stereo_44100_apple_48k.m4a")
        let track = try MP4Demuxer.parse(bytes).audioTracks[0]
        guard case .aac(_, _, let cfg) = track.sampleEntries[0] else { Issue.record("not AAC"); return }
        let config = try AACConfig.parse(cfg.audioSpecificConfig)
        #expect(config.sbrSignalled && config.sampleRate == 22050 && config.channels == 2, "\(config) \(cfg.audioSpecificConfig.copyBytes())")
        var dec = AACDecoder(config: config)
        var peak: Float = 0
        for s in track.samples {
            for ch in try dec.decode(ByteSlice(Array(bytes[s.offset ..< s.offset + s.size]))) { peak = max(peak, ch.map(abs).max() ?? 0) }
        }
        #expect(peak > 0.1 && peak <= 1.5)
    }

    static func adtsFrames(_ name: String) -> [UInt8] { Resources.bytes("AAC/" + name) }

    @Test func adtsAcceptsID3CRCAndATruncatedTail() throws {
        let plain = Self.adtsFrames("stereo_44100_exact.aac")
        let frames = try ADTS.frames(plain)
        // An ID3v2 tag (size 0x0A, syncsafe) in front.
        let id3: [UInt8] = [0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 10] + Array(repeating: 0, count: 10)
        #expect(try ADTS.frames(id3 + plain).count == frames.count)
        // A frame cut short at the end of the stream is dropped, not an error.
        #expect(try ADTS.frames(Array(plain.dropLast(5))).count == frames.count - 1)
        // Trailing garbage ends the stream.
        #expect(try ADTS.frames(plain + [0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0]).count == frames.count)
        // protection_absent = 0: a 16-bit CRC follows the header and is not part of the payload.
        var crc: [UInt8] = []
        var c = 0
        while c + 7 <= plain.count {
            let len = Int(plain[c + 3] & 3) << 11 | Int(plain[c + 4]) << 3 | Int(plain[c + 5]) >> 5
            var h = Array(plain[c ..< c + 7])
            h[1] &= 0xFE
            let n = len + 2
            h[3] = h[3] & 0xFC | UInt8(n >> 11); h[4] = UInt8((n >> 3) & 0xFF); h[5] = h[5] & 0x1F | UInt8((n & 7) << 5)
            crc += h + [0xAB, 0xCD] + plain[c + 7 ..< c + len]
            c += len
        }
        let withCRC = try ADTS.frames(crc)
        #expect(withCRC.count == frames.count)
        #expect(zip(withCRC, frames).allSatisfy { $0.payload == $1.payload })
        // Not ADTS at all.
        #expect(throws: ParseFailure.self) { try ADTS.frames([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]) }
        // HE-AAC/main profiles are refused in the header.
        var main = plain
        main[2] = main[2] & 0x3F
        #expect(throws: ParseFailure.self) { try ADTS.frames(main) }
    }

    @Test func audioSpecificConfigs() throws {
        // AAC-LC 44.1 kHz stereo, explicit rate, SBR, and refusals.
        #expect(try AACConfig.parse(ByteSlice([0x12, 0x10])) == AACConfig(objectType: 2, samplingIndex: 4, channelConfiguration: 2))
        #expect(try AACConfig.parse(ByteSlice([0x17, 0x80, 0x56, 0x22, 0x08])).sampleRate == 44100)    // index 15 + 44100
        #expect(throws: ParseFailure.self) { try AACConfig.parse(ByteSlice([0x0A, 0x10])) }            // AAC main
        #expect(throws: ParseFailure.self) { try AACConfig.parse(ByteSlice([0x12, 0x14])) }            // 960-sample frames
        #expect(throws: ParseFailure.self) { try AACConfig.parse(ByteSlice([0x12, 0x00])) }            // channel config 0 (PCE)
        #expect(throws: ParseFailure.self) { try AACConfig.parse(ByteSlice([0x12])) }                  // truncated
    }

    @Test func wrongChannelCountIsAnError() throws {
        let frames = try ADTS.frames(Self.adtsFrames("mono_8000_16k.aac"))
        var stereo = AACDecoder(config: AACConfig(objectType: 2, samplingIndex: frames[0].config.samplingIndex, channelConfiguration: 2))
        #expect(throws: ParseFailure.self) { _ = try stereo.decode(frames[0].payload) }
    }

    /// Every truncation and a deterministic set of bit flips either decode or fail with a
    /// ParseFailure; outputs stay finite and frame-sized.
    @Test(arguments: ["stereo_44100_128k.aac", "stereo_44100_32k.aac", "mono_8000_16k.aac", "mono_44100_pulses.aac"])
    func hostileInputs(name: String) throws {
        let frames = try ADTS.frames(Self.adtsFrames(name))
        let config = frames[0].config
        func check(_ dec: inout AACDecoder, _ bytes: [UInt8]) {
            if let pcm = try? dec.decode(ByteSlice(bytes)) {
                #expect(pcm.count == config.channels && pcm.allSatisfy { $0.count == 1024 && $0.allSatisfy(\.isFinite) })
            }
        }
        var dec = AACDecoder(config: config)
        for f in frames.prefix(12) {
            let b = f.payload.copyBytes()
            for n in 0 ..< b.count { check(&dec, Array(b.prefix(n))) }
        }
        var seed: UInt32 = 12345
        for i in 0 ..< 3000 {
            var b = frames[i % frames.count].payload.copyBytes()
            for _ in 0 ..< 1 + i % 4 {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let bit = Int(seed >> 8) % (b.count * 8)
                b[bit / 8] ^= UInt8(0x80) >> UInt8(bit % 8)
            }
            check(&dec, b)
        }
    }
}
