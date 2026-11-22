import Testing
@testable import SwiftCalling

struct CallEchoControlTests {
    private func speechNoise(seed: UInt32) -> [Int16] {
        var state = seed, low = 0
        return (0..<12_000).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            low = (low * 3 + Int(Int16(truncatingIfNeeded: state >> 16))) / 4
            return Int16(low)
        }
    }

    @Test func removesDelayedPlayoutWhileRetainingNearEndSpeech() {
        let echo = CallEchoControl(enabled: true)
        let far = speechNoise(seed: 2)
        let near = speechNoise(seed: 7).prefix(960).map { $0 / 8 }
        echo.render(far, at: 0)
        let reflected = (0..<960).map { far[4801 + $0] / 2 + far[4350 + $0] / 4 }
        let captured = zip(near, reflected).map(+)
        let cleaned = echo.process(captured, at: 8000)
        let error = zip(cleaned, near).reduce(0.0) { $0 + Double(Int($1.0) - Int($1.1)) * Double(Int($1.0) - Int($1.1)) }
        let echoEnergy = reflected.reduce(0.0) { $0 + Double($1) * Double($1) }
        #expect(error < echoEnergy * 0.03)
        echo.setEnabled(false)
        #expect(echo.process(captured, at: 8000) == captured)
    }

    @Test func unrelatedSpeechAndStalePlayoutPassThrough() {
        let echo = CallEchoControl(enabled: true)
        echo.render(speechNoise(seed: 1), at: 0)
        let near = Array(speechNoise(seed: 16).prefix(960))
        #expect(echo.process(near, at: 7000) == near)
        #expect(echo.process(near, at: 96_000) == near)
    }
}
