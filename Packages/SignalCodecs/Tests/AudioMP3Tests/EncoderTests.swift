import Foundation
import Testing
import CodecCore
@testable import AudioMP3

@Suite struct MP3EncoderTests {
    /// A voice-like test signal: a gliding harmonic tone with syllable envelope, plosive clicks
    /// and a little noise.
    static func voice(rate: Int, seconds: Double) -> [Float] {
        var seed: UInt32 = 9
        return (0 ..< Int(Double(rate) * seconds)).map { n in
            let t = Double(n) / Double(rate)
            let f0 = 140 + 40 * LibM.sin(2 * Double.pi * 1.3 * t)
            var v = 0.0
            for h in 1 ... 12 { v += LibM.sin(2 * Double.pi * f0 * Double(h) * t) / Double(h) }
            let env = 0.5 + 0.5 * LibM.sin(2 * Double.pi * 3 * t)
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Double(Int32(bitPattern: seed)) / Double(Int32.max)
            let click = (n % (rate * 7 / 10)) < 40 ? noise * 0.6 : 0
            return Float(0.25 * v * env + 0.01 * noise + click)
        }
    }

    static func encode(_ pcm: [Float], rate: Int, chunk: Int = 1024) throws -> (bytes: [UInt8], encoder: MP3Encoder) {
        var enc = try MP3Encoder(inputSampleRate: rate)
        var out: [UInt8] = []
        var i = 0
        while i < pcm.count {
            out += enc.encode(Array(pcm[i ..< min(pcm.count, i + chunk)]))
            i += chunk
        }
        out += enc.flush()
        let tag = enc.tagFrame()
        for (k, b) in tag.enumerated() { out[k] = b }
        return (out, enc)
    }

    @Test(arguments: [48000, 44100, 32000, 24000, 16000, 8000])
    func roundTrip(rate: Int) throws {
        let pcm = Self.voice(rate: rate, seconds: 3)
        let (bytes, enc) = try Self.encode(pcm, rate: rate)
        let stream = try MP3Stream.parse(bytes)
        #expect(stream.sampleRate == enc.sampleRate && stream.channels == 1)
        #expect(stream.info?.encoderDelay == MP3Encoder.encoderDelay)
        #expect(stream.info?.frameCount == stream.frames.count)
        #expect(abs(stream.durationSeconds - 3) < 0.001, "duration \(stream.durationSeconds)")
        let kbps = Double(bytes.count * 8) / 3 / 1000
        // Decode, trim delay, compare with the input at the output rate.
        var dec = MP3Decoder(for: stream)
        var out: [Float] = []
        for f in stream.frames { out += try dec.decode(f)[0] }
        let skip = MP3Encoder.encoderDelay + MP3Decoder.decoderDelay
        let reference: [Float]
        if enc.sampleRate == rate {
            reference = pcm
        } else {
            var r = MP3Resampler(inRate: rate, outRate: enc.sampleRate, cutoffHz: Double(enc.sampleRate) / 2 * 0.95)
            reference = r.process(pcm) + r.flush(totalInput: pcm.count)
        }
        let n = min(reference.count, out.count - skip)
        var sig = 0.0, err = 0.0
        for i in 0 ..< n { sig += Double(reference[i] * reference[i]); let d = Double(out[i + skip] - reference[i]); err += d * d }
        let snr = 10 * LibM.log10(sig / max(err, 1e-20))
        if let dir = ProcessInfo.processInfo.environment["MP3_ENCODER_DUMP"] {
            try? Data(bytes).write(to: URL(fileURLWithPath: "\(dir)/ours_\(rate).mp3"))
        }
        print("in \(rate) → out \(enc.sampleRate): \(bytes.count) bytes, \(stream.frames.count) frames, \(String(Int(kbps))) kbps, SNR \(Int(snr)) dB")
        #expect(kbps <= 90)
        // Upstream's settings (VBR 7) on voice: about LAME's bitrate (≈ 55 kbps at 32 kHz).
        if enc.sampleRate == 32000 { #expect(kbps > 40 && kbps < 70 && snr > 15, "\(kbps) kbps, \(snr) dB") }
        #expect(snr > 10)
    }
}

extension MP3EncoderTests {
    @Test func fineQuantisationIsNearTransparent() throws {
        let rate = 32000
        let pcm = Self.voice(rate: rate, seconds: 1)
        var previous = (kbps: Int.max, snr: 999)
        for offset in [-40.0, -10.0, 0.0, 6.0] {
            var enc = try MP3Encoder(inputSampleRate: rate, maxBitrateKbps: 320)
            enc.psycho = MP3Psychoacoustics(sampleRate: rate, sampleRateIndex: 2, quality: 7, lowpassHz: 14900, offsetOverride: offset)
            var bytes = enc.encode(pcm) + enc.flush()
            let tag = enc.tagFrame()
            for (k, b) in tag.enumerated() { bytes[k] = b }
            let stream = try MP3Stream.parse(bytes)
            var dec = MP3Decoder(for: stream)
            var out: [Float] = []
            for f in stream.frames { out += try dec.decode(f)[0] }
            let skip = 1057
            var sig = 0.0, err = 0.0
            for i in 0 ..< pcm.count { sig += Double(pcm[i] * pcm[i]); let d = Double(out[i + skip] - pcm[i]); err += d * d }
            let kbps = bytes.count * 8 / 1000, snr = Int(10 * LibM.log10(sig / err))
            print("offset \(offset): \(kbps) kbps, SNR \(snr) dB")
            // More allowed noise: fewer bits and less SNR; fine steps approach the filterbank's limit.
            #expect(kbps <= previous.kbps && snr <= previous.snr + 1)
            if offset == -40 { #expect(snr >= 28) }
            previous = (kbps, snr)
        }
    }
}






