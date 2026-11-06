import Testing
import CodecCore
@testable import AudioMP3

@Suite struct MP3AnalysisTests {
    static func noise(_ n: Int, seed: UInt32 = 1) -> [Float] {
        var s = seed
        return (0 ..< n).map { _ in
            s = s &* 1_664_525 &+ 1_013_904_223
            return Float(Int32(bitPattern: s)) / Float(Int32.max) * 0.5
        }
    }

    /// Analysis → decoder synthesis, unquantised, for a block-type sequence; returns the output.
    static func roundTrip(_ pcm: [Float], types: [Int]) -> [Float] {
        var a = MP3Analysis()
        var dec = MP3Decoder(lsf: false)
        var out: [Float] = []
        for (g, t) in types.enumerated() {
            let sub = a.subbands(pcm[g * 576 ..< (g + 1) * 576])
            var gr = MP3Decoder.Granule()
            gr.blockType = t
            gr.hybrid = a.mdct(sub, blockType: t)
            dec.antialias(&gr)
            var slots = [Float](repeating: 0, count: 576)
            dec.imdct(gr, channel: 0, into: &slots, granule: 0)
            var pcmOut = [Float](repeating: 0, count: 576)
            for slot in 0 ..< 18 { dec.synthesize(slots, slot: slot, channel: 0, into: &pcmOut) }
            out += pcmOut
        }
        return out
    }

    @Test func perfectReconstruction() {
        let n = 576 * 12
        let pcm = Self.noise(n)
        for types in [[Int](repeating: 0, count: 12), [0, 0, 1, 2, 2, 3, 0, 1, 2, 3, 0, 0]] {
            let out = Self.roundTrip(pcm, types: types)
            // Find the delay and gain.
            var best = (delay: 0, err: Float.infinity, gain: Float(0))
            for d in 0 ..< 1200 {
                var num: Float = 0, den: Float = 0
                for i in 1500 ..< 5000 { num += out[i + d] * pcm[i]; den += pcm[i] * pcm[i] }
                let gain = num / den
                var err: Float = 0
                for i in 1500 ..< 5000 { let e = out[i + d] - gain * pcm[i]; err += e * e }
                if err < best.err { best = (d, err, gain) }
            }
            var maxErr: Float = 0
            for i in 1500 ..< 5000 { maxErr = max(maxErr, abs(out[i + best.delay] - pcm[i])) }
            print("types \(types): delay \(best.delay) gain \(best.gain) max error \(maxErr)")
            #expect(best.delay == MP3Encoder.analysisDelay && abs(best.gain - 1) < 1e-4 && maxErr < 1e-4)
        }
    }
}
