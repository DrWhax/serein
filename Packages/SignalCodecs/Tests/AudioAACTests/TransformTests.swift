import Testing
import CodecCore
@testable import AudioAAC

@Suite struct AACTransformTests {
    func pseudoRandom(_ n: Int, seed: UInt32) -> [Float] {
        var s = seed
        return (0..<n).map { _ in
            s = s &* 1_664_525 &+ 1_013_904_223
            return Float(Int32(bitPattern: s)) / Float(Int32.max)
        }
    }

    @Test(arguments: [8, 16, 128, 1024])
    func dct4MatchesDirectFormula(m: Int) {
        let x = pseudoRandom(m, seed: UInt32(m))
        let fast = DCT4(size: m).transform(x)
        var worst: Double = 0
        for n in 0..<m {
            var acc = 0.0
            for k in 0..<m { acc += Double(x[k]) * LibM.cos(Double.pi / Double(m) * (Double(n) + 0.5) * (Double(k) + 0.5)) }
            worst = max(worst, abs(acc - Double(fast[n])))
        }
        #expect(worst < 1e-3 * Double(m).squareRoot(), "max error \(worst)")
    }

    @Test(arguments: [128, 1024])
    func imdctMatchesDirectFormula(m: Int) {
        let x = pseudoRandom(m, seed: 7)
        let fast = IMDCT(coefficients: m).transform(x)
        let n2 = 2 * m
        let n0 = (Double(n2) / 2 + 1) / 2
        var worst: Double = 0
        for n in 0..<n2 {
            var acc = 0.0
            for k in 0..<m { acc += Double(x[k]) * LibM.cos(2 * Double.pi / Double(n2) * (Double(n) + n0) * (Double(k) + 0.5)) }
            acc *= 2 / Double(n2)
            worst = max(worst, abs(acc - Double(fast[n])))
        }
        #expect(worst < 1e-5, "max error \(worst)")
    }

    @Test func windowsArePowerComplementary() {
        for w in [AACWindows.sineLong, AACWindows.kbdLong, AACWindows.sineShort, AACWindows.kbdShort] {
            let h = w.count / 2
            for n in 0..<h { #expect(abs(w[n] * w[n] + w[n + h] * w[n + h] - 1) < 1e-5) }
        }
    }
}
