import Foundation
import Testing
@testable import SwiftCalling

struct DREDFrontendTests {
    /// Opus 1.6.1 scalar LPCNet/FARGAN with the SHA-512-checked Signal model.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEREIN_DRED_WEIGHTS"] != nil))
    func matchesNativeAnalysisAndWaveform() throws {
        let path = try #require(ProcessInfo.processInfo.environment["SEREIN_DRED_WEIGHTS"])
        let model = try DREDModel(weights: Data(contentsOf: URL(fileURLWithPath: path)))
        var analyzer = DREDAnalysis(model: model), synth = DREDSynthesis(model: model)
        for frame in 0..<16 {
            let signal = (0..<160).map { Float((($0+160*frame)*193%8001)-4000) }
            let actual = analyzer.analyze(signal)
            let features = (0..<20).map { Float(((($0+3*frame)*13)%45)-18)/20 }
            let waveform = synth.synthesize16k(features)
            if frame.isMultiple(of: 3) {
                let expected = Self.features[frame/3]
                for i in expected.indices { #expect(abs(actual[i]-expected[i]) < 0.0001) }
                let pcm = Self.waveforms[frame/3]
                for i in pcm.indices { #expect(abs(Int(waveform[i*7])-pcm[i]) <= 7) }
            }
        }
        let mic = (0..<960).map { Int16(($0*193%8001)-4000) }
        var whole = DREDAnalysis(model: model), fragmented = DREDAnalysis(model: model)
        let expected = whole.features(mic)
        let first = fragmented.features(Array(mic.prefix(213)))
        let second = fragmented.features(Array(mic.dropFirst(213)))
        #expect(expected.count == 2 && expected == first+second)
        var a = DREDSynthesis(model: model), b = DREDSynthesis(model: model)
        a.prime(pcm: mic, features: expected)
        let continued = a.synthesize(expected[1])
        let cold = b.synthesize(expected[1])
        #expect(continued.count == 480 && continued != cold)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEREIN_DRED_WEIGHTS"] != nil))
    func standalonePLCMatchesOpusAcrossTwoLossBursts() throws {
        let path = try #require(ProcessInfo.processInfo.environment["SEREIN_DRED_WEIGHTS"])
        let model = try DREDModel(weights: Data(contentsOf: URL(fileURLWithPath: path)))
        var plc = DeepPLC(model: model), output = [Int16]()
        for frame in 0..<47 {
            if (18..<25).contains(frame) || frame >= 40 { output += plc.conceal16k() }
            else { plc.update16k((0..<160).map { Float((($0+160*frame)*193%8001)-4000) }) }
        }
        try #require(output.count == 2240)
        for (i, sample) in Self.plcReference.enumerated() { #expect(abs(Int(output[37*i])-sample) <= 5) }
    }

    private static let plcReference = [-2176, -781, -2452, -3353, 1877, 2453, 2282, 1199, -63, -513, -2258, -2170, 460, 1418, 1357, 1643, -312, -436, -1471, -1693, 1039, 1281, 1017, -301, -490, -1337, -810, 623, 631, 960, 323, -3411, 2887, 2498, 2289, 768, 209, -1878, -2469, -1311, -2035, 2441, 1902, 1365, -172, -791, -1538, -1347, -1653, 2062, 1674, 1117, 337, -113, -1376, -1120, 442, 498, 401, 279, -151]

    private static let features: [[Float]] = [
        [12.2883358, -1.1963426, 0.2559499, -0.0984209, -0.1706665, -0.3154351, -0.3571011, -0.2467084, -0.1626739, -0.2905156, -0.2889234, -0.0433397, -0.0594197, -0.0646544, -0.0106357, 0.1804794, 0.4304996, 0.3799967, 0.0619828, -0.3615565],
        [13.1477318, -2.1034577, -0.5430458, -0.790992, -0.8119199, -0.9112142, -0.9069293, -0.730629, -0.6023822, -0.6868412, -0.6344098, -0.312886, -0.2696702, -0.2266322, -0.1082271, 0.1984327, 0.548793, 0.4957834, 1.1258688, 0.4723762],
        [13.1367035, -2.1153007, -0.5576764, -0.8033418, -0.8248582, -0.9213436, -0.9188662, -0.7410759, -0.6139002, -0.695575, -0.6436053, -0.3208661, -0.2780909, -0.2317748, -0.1116673, 0.1963512, 0.5457593, 0.4934486, 1.1250746, 0.4441086],
        [13.1346378, -2.1257827, -0.5610819, -0.8110371, -0.8290431, -0.9304702, -0.9221148, -0.7464154, -0.6144487, -0.7000396, -0.6442737, -0.3223504, -0.2759252, -0.2337468, -0.1136377, 0.1941127, 0.5478861, 0.4960424, 1.1252849, 0.4444015],
        [13.1482086, -2.1142027, -0.5491952, -0.8070132, -0.8190959, -0.9237139, -0.9114659, -0.7420329, -0.6066403, -0.6949701, -0.6365111, -0.3202012, -0.2720726, -0.2305716, -0.1078347, 0.1935784, 0.5419034, 0.4886908, 1.1282365, 0.4718783],
        [13.1689014, -2.0859742, -0.5314808, -0.795514, -0.8021201, -0.903548, -0.8934516, -0.7310908, -0.5969403, -0.683007, -0.6253859, -0.3171106, -0.2710722, -0.2231299, -0.0948186, 0.1962739, 0.5276926, 0.4712977, 1.1273854, 0.4714846],
    ]
    private static let waveforms: [[Int]] = [
        [12, 4, 3, -5, -16, -9, -43, 6, 4, -12, 6, 32, 54, 82, 4, 31, 25, 12, -27, -34, 3, 55, -32],
        [22, 30, -7, 19, 41, 113, 54, 33, 31, 77, 92, 92, -1, 18, 67, 114, 15, 51, -61, -34, -3, -95, -109],
        [64, -14, 52, -12, -115, -55, -52, 66, -129, -147, -75, 44, 5, 2, -160, -114, 103, -33, 41, -194, -120, 101, 62],
        [9, 35, -69, 40, -54, -29, 67, -2, -68, -50, -113, 52, -132, -207, -40, -114, -54, 105, -14, 7, -12, -92, -53],
        [-148, -92, -127, -212, -128, -107, -47, 38, -111, -89, 24, -201, 100, 2, 66, 276, -14, 138, 51, 49, 175, 64, 169],
        [-28, 3, -67, 18, -64, -32, 68, 21, 27, -79, 42, 36, 156, -38, 41, 4, 0, 24, -2, -63, -6, 58, 31],
    ]
}
