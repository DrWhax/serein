import Foundation
import Testing
@testable import SwiftCalling

@Suite struct VideoRateControlTests {
    /// A picture's bits at quantizer q for content whose bits fall `slope`-fold each time the
    /// quantizer step doubles (about 42 VP9 indices); clips measured 1.3x (flat) to 5x (noise).
    private func bits(_ q: Int, complexity: Double, slope: Double) -> Int {
        Int(complexity * pow(slope, -Double(q) / 42))
    }

    /// Steady content settles at 70-100% of its budget whatever its slope, and a halved budget
    /// raises the quantizer within a few pictures.
    @Test(arguments: [1.6, 2.4, 5.0])
    func settlesAtTheBudgetAndFollowsItDown(slope: Double) {
        var rate = VideoRateControl(.vp9)
        let complexity = 33_000 * pow(slope, 100.0 / 42)  // the budget at q100: halved, still reachable
        var budget = 33_000, sizes: [Int] = []
        for picture in 0..<120 {
            if picture == 80 { budget /= 2 }
            let size = bits(rate.quantizer(key: false), complexity: complexity, slope: slope)
            rate.record(bits: size, budget: budget, key: false)
            sizes.append(size)
        }
        let settled = sizes[50..<80].reduce(0, +) / 30, after = sizes[90..<120].reduce(0, +) / 30
        #expect(settled <= 33_000 && settled >= 33_000 * 7 / 10, "settled at \(settled) bits")
        #expect(after <= 16_500 && after >= 16_500 * 6 / 10, "after halving \(after) bits")
        // Within three pictures of the halving, no picture is over twice the new budget.
        #expect(sizes[83..<120].allSatisfy { $0 <= 2 * 16_500 })
    }

    /// Plenty of bandwidth: the finest quantizer, no finer.
    @Test func idleBandwidthGoesFinest() {
        var rate = VideoRateControl(.vp8)
        for _ in 0..<60 { rate.record(bits: 1_000, budget: 100_000, key: false) }
        #expect(rate.quantizer(key: false) == rate.finest)
    }

    /// The first keyframe starts at the finest quantizer and a keyframe is coded again only when
    /// it would hold more than eight pictures' budget; later keyframes are never finer than
    /// the pictures around them.
    @Test func oversizedKeyframesAreCodedAgainCoarser() {
        var rate = VideoRateControl(.vp9)
        #expect(rate.quantizer(key: true) == rate.finest)
        let small = rate.retryKeyframe(bits: 7 * 10_000, budget: 10_000)
        let large = rate.retryKeyframe(bits: 40 * 10_000, budget: 10_000)
        #expect(!small && large)
        #expect(rate.quantizer(key: true) > rate.finest)
        var inter = VideoRateControl(.vp9)
        for _ in 0..<10 { inter.record(bits: 80_000, budget: 10_000, key: false) }
        #expect(inter.quantizer(key: true) >= inter.quantizer(key: false))
        var coarsest = VideoRateControl(.vp8)
        coarsest.overshoot()
        let again = coarsest.retryKeyframe(bits: 100 * 10_000, budget: 10_000)
        #expect(!again)
    }

    /// Screen content stops coarsening sooner (the pacer drops frames rather than blur text).
    @Test func screenContentKeepsAFinerCeiling() {
        #expect(VideoRateControl(.vp9, screen: true).coarsest < VideoRateControl(.vp9).coarsest)
        #expect(VideoRateControl(.vp8, screen: true).coarsest < VideoRateControl(.vp8).coarsest)
        var screen = VideoRateControl(.vp9, screen: true)
        for _ in 0..<40 { screen.record(bits: 1_000_000, budget: 10_000, key: false) }
        #expect(screen.quantizer(key: false) == screen.coarsest)
    }
}
