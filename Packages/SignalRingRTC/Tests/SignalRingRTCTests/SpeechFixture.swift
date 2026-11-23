import Foundation
import Synchronization
import Testing
@testable import SwiftCalling

/// The reference peer reads and writes raw PCM at its audio device. The Swift peer uses
/// the same sample format at the input of its encoder and the output of its decoder.
final class SpeechFixture: Sendable {
    private struct Playout {
        var samples: [Int16] = []
        var nextTimestamp: UInt32?
        var failure: String?
    }
    private let received = Mutex(Playout())
    private let directory: URL
    private let seconds = min(600, max(7, Int(ProcessInfo.processInfo.environment["SEREIN_SPEECH_SECONDS"] ?? "") ?? 7))
    private let nativeInput: [Int16]
    private let swiftInput: [Int16]

    init(directory: URL) throws {
        self.directory = directory
        nativeInput = try Self.pcm(at: directory.appending(path: "native-input.pcm"))
        swiftInput = try Self.pcm(at: directory.appending(path: "swift-input.pcm"))
    }

    private static func pcm(at url: URL, maxBytes: Int = 2_880_000) throws -> [Int16] {
        let data = try Data(contentsOf: url)
        try #require((960...maxBytes).contains(data.count) && data.count.isMultiple(of: 2))
        return stride(from: 0, to: data.count, by: 2).map {
            Int16(bitPattern: UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8)
        }
    }

    func block(_ index: Int) -> [Int16] {
        let start = 2880 * index
        return (0..<2880).map { swiftInput[(start + $0) % swiftInput.count] }
    }

    func append(timestamp: UInt32, samples: [Int16]) {
        received.withLock { state in
            let gap = state.nextTimestamp.map { Int(Int32(bitPattern: timestamp &- $0)) } ?? 0
            guard (0...48_000).contains(gap), state.samples.count + gap + samples.count <= 48_000 * (seconds + 15) else {
                state.failure = "Unexpected speech timestamp or duration"
                return
            }
            state.samples.append(contentsOf: repeatElement(0, count: gap))
            state.samples.append(contentsOf: samples)
            state.nextTimestamp = timestamp &+ UInt32(samples.count)
        }
    }

    func fail(_ error: any Error) { received.withLock { $0.failure = String(describing: error) } }

    struct PlayoutEnd {
        let swift: Int
        let native: Int
    }

    func activeSpeechEnd() throws -> PlayoutEnd {
        let url = directory.appending(path: "native-output.pcm")
        let bytes = try #require(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        return PlayoutEnd(swift: received.withLock { $0.samples.count }, native: bytes / 2)
    }

    func verify(route: String, through end: PlayoutEnd? = nil) throws {
        let swiftOutput = received.withLock { $0 }
        try #require(swiftOutput.failure == nil, "Swift audio receive error: \(String(describing: swiftOutput.failure))")
        let nativeOutput = try Self.pcm(at: directory.appending(path: "native-output.pcm"), maxBytes: 96_000 * (seconds + 15))
        let nativePhrase = SpeechSpectrum(nativeInput)
        let swiftPhrase = SpeechSpectrum(swiftInput)
        if ProcessInfo.processInfo.environment["SEREIN_KEEP_SPEECH"] == "1" {
            var data = Data(capacity: 2 * swiftOutput.samples.count)
            for sample in swiftOutput.samples {
                let value = UInt16(bitPattern: sample)
                data.append(UInt8(truncatingIfNeeded: value))
                data.append(UInt8(value >> 8))
            }
            try data.write(to: directory.appending(path: "swift-output.pcm"))
        }
        for (side, samples, limit, expected, other) in [("Swift", swiftOutput.samples, end?.swift, nativePhrase, swiftPhrase),
                                                        ("RingRTC", nativeOutput, end?.native, swiftPhrase, nativePhrase)] {
            let output = samples.prefix(limit ?? samples.count)
            if seconds > 15 {
                try #require(output.count >= (seconds - 3) * 48_000, "Playout stopped early at \(side)")
                let beginning = SpeechSpectrum(Array(output.prefix(7 * 48_000)))
                #expect(beginning.bestMatch(for: expected) > 0.76)
            }
            let decoded = SpeechSpectrum(Array(output.suffix(7 * 48_000)))
            let score = decoded.bestMatch(for: expected)
            let wrong = decoded.bestMatch(for: other)
            print("speech PCM \(route) at \(side): \(output.count) samples, expected phrase \(score), other phrase \(wrong)")
            #expect(score > 0.76, "Decoded PCM must reproduce the spoken phrase across speech bands")
            #expect(score > wrong + 0.20, "Each receiver must identify the other peer's phrase")
        }
    }
}

/// Normalized correlation of time-varying energy in eight speech bands. Find a whole
/// utterance in the longer playout, allowing unknown call setup and packetization delay.
/// A constant signal (including silence) scores zero. The wrong utterance is a negative
/// control passed through exactly the same alignment search.
private struct SpeechSpectrum {
    private let envelopes: [[Double]]
    private static let bands = [240.0, 350, 520, 740, 1030, 1480, 2050, 2850]
    private static let window = (0..<160).map { 0.5 - 0.5 * cos(2 * .pi * Double($0) / 159) }

    init(_ pcm: [Int16]) {
        var signal: [Double] = []
        for i in stride(from: 0, to: pcm.count - pcm.count % 6, by: 6) {
            var sum = 0
            for j in 0..<6 { sum += Int(pcm[i+j]) }
            signal.append(Double(sum) / (6 * 32768))
        }
        let coefficients = Self.bands.map { center in
            [0.91, 1, 1.09].map { 2 * cos(2 * .pi * center * $0 / 8000) }
        }
        var bands = [[Double]](repeating: [], count: coefficients.count)
        for start in stride(from: 0, to: max(0, signal.count - 159), by: 80) {
            let windowed = Self.window.enumerated().map { $0.element * signal[start + $0.offset] }
            for (band, probes) in coefficients.enumerated() {
                var energy = 0.0
                for c in probes {
                    var u = 0.0, v = 0.0
                    for sample in windowed {
                        let value = sample + c * u - v
                        v = u
                        u = value
                    }
                    energy += max(0, u*u + v*v - c*u*v)
                }
                bands[band].append(log1p(energy * 1000))
            }
        }
        envelopes = bands
    }

    func bestMatch(for phrase: Self) -> Double {
        let length = phrase.envelopes[0].count, available = envelopes[0].count
        guard length >= 50, available >= length else { return 0 }
        var scores = [Double](repeating: 0, count: available - length + 1)
        for (signal, reference) in zip(envelopes, phrase.envelopes) {
            let mean = reference.reduce(0, +) / Double(length)
            let target = reference.map { $0 - mean }
            let energy = target.reduce(0) { $0 + $1 * $1 }
            guard energy > 0.0001 else { continue }
            for lag in scores.indices {
                var sum = 0.0, square = 0.0, dot = 0.0
                for i in 0..<length {
                    let x = signal[lag+i]
                    sum += x
                    square += x*x
                    dot += x*target[i]
                }
                let variance = square - sum*sum/Double(length)
                if variance > 0.0001 { scores[lag] += dot / sqrt(variance * energy) }
            }
        }
        return (scores.max() ?? 0) / Double(envelopes.count)
    }
}
