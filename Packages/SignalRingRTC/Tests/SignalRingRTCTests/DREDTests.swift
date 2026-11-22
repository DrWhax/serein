import Foundation
import Testing
@testable import SwiftCalling

struct DREDTests {
    @Test func rejectsInvalidWeights() {
        #expect(throws: (any Error).self) { try DREDModel(weights: Data(repeating: 0, count: 64)) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEREIN_DRED_WEIGHTS"] != nil))
    func partialWireHistoryRepairsOnlyCoveredSamples() throws {
        let path = try #require(ProcessInfo.processInfo.environment["SEREIN_DRED_WEIGHTS"])
        let model = try DREDModel(weights: Data(contentsOf: URL(fileURLWithPath: path)))
        let configuration = try #require(DREDConfiguration(model: model, duration: 50))
        let pcm = (0..<960).map { Int16(8000 * sin(2 * Double.pi * Double($0) / 80)) }
        var primary = OpusSpeechEncoder()
        let packet = try primary.encode(pcm)
        let state = [Float](repeating: 0, count: 50), latent = [Float](repeating: 0, count: 25)
        for (offset, expected) in [(10, 1440), (-2, 1920)] {
            let bytes = try DREDWire.attach(to: packet, state: state, latents: [latent], offset: offset)
            var recovery = CallOpusRecovery(configuration)
            recovery.observe(pcm)
            let decoded = try OpusPacket(bytes)
            var plan = try #require(recovery.prepare(decoded, distance: 5760))
            var repaired = 0
            for distance in stride(from: 5760, to: 0, by: -960) {
                let block = recovery.recover(&plan, distance: distance, samples: 960)
                #expect(block.pcm.count == 960)
                repaired += block.recovered
            }
            #expect(repaired == expected)
        }
    }

    // Quantized Opus 1.6.1, scalar reference with the published Signal weight blob.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEREIN_DRED_WEIGHTS"] != nil))
    func quantizedNetworkMatchesOpus() throws {
        let path = try #require(ProcessInfo.processInfo.environment["SEREIN_DRED_WEIGHTS"])
        let model = try DREDModel(weights: Data(contentsOf: URL(fileURLWithPath: path)))
        var encoder = DREDNetwork(encoding: true), last: DREDNetwork.Encoded?
        for j in 0..<4 {
            let input: [Float] = (0..<40).map { i in Float(((i+j*5)*13)%45 - 18)/20 }
            last = encoder.encode(input, model: model)
        }
        let actual = try #require(last)
        let frames = DREDNetwork.decode(state: actual.state, latents: [actual.latent + [-0.25]], model: model)
        let expected: [[Float]] = [
            [3.089843, -0.013820, 1.838812, 2.910513, -1.038051, -12.095520, -1.749053, -0.217806, -1.654239, 3.147493],
            [-0.708002, -0.416160, 24.410496, 2.345343, 3.715388, -3.826708, 0.155414, 1.865216, -2.672141, 10.913927],
            [-0.109021, 0.145079, 0.759030, 0.939584, 0.005772, 0.010252, 0.511977, -0.111688, 0.069036, 0.440143]
        ]
        #expect(frames.count == 4)
        for (row, reference) in zip([actual.state, actual.latent, try #require(frames.first)], expected) {
            let error = zip(row, reference).map { abs($0 - $1) }.max()
            #expect(try #require(error) < 0.00002)
        }
    }
}
