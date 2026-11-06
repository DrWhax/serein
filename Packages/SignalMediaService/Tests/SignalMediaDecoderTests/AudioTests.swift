// The service's audio requests: upstream's waveform builder, presentation timelines
// (gapless trims) and waveforms against ffmpeg's default decode, chunked decoding from any
// point, voice-note recording.

import Foundation
import MediaXPCInterface
import Testing
@testable import SignalMediaDecoder

struct WaveformBuilderTests {
    // ts/test-node/util/waveformBuilder_test.std.ts
    @Test func upstreamVectors() {
        #expect(WaveformBuilder().collect() == [])
        var b = WaveformBuilder()
        for i in 0 ..< 10 { b.push(Float(i) / 10) }
        #expect(b.collect() == [0, 170, 196, 211, 221, 229, 236, 242, 247, 251])
        b = WaveformBuilder()
        for i in 0 ..< 199 { b.push(Float(i % 10) / 10) }
        #expect(b.collect() == Array(repeating: [157, 205, 226, 239, 249], count: 20).flatMap { $0 }.dropLast(1) + [247])
        b = WaveformBuilder()
        for i in 0 ..< 999 { b.push(Float(i % 10) / 10) }
        #expect(b.collect() == Array(Array(repeating: [226, 234, 230, 231, 235], count: 13).flatMap { $0 }.prefix(62)) + [232])
    }
}

struct AudioServiceTests {
    struct Ref: Decodable { var frames: Int; var channels: Int; var sampleRate: Int; var waveform: [Int] }
    static let dir = Bundle.module.resourceURL!.appendingPathComponent("Resources/Audio")
    static let refs: [String: Ref] = try! JSONDecoder().decode([String: Ref].self, from: Data(contentsOf: dir.appendingPathComponent("references.json")))
    static func bytes(_ name: String) -> Data { try! Data(contentsOf: dir.appendingPathComponent(name)) }

    @Test(arguments: refs.keys.sorted())
    func summaryMatchesFFmpeg(name: String) async throws {
        let ref = Self.refs[name]!
        let s = try await MediaDecoder().audioSummary(Self.bytes(name)).validated()
        #expect(s.sampleRate == ref.sampleRate && s.channels == ref.channels)
        #expect(Int((s.duration * Double(s.sampleRate)).rounded()) == ref.frames, "\(name): \(s.duration * Double(s.sampleRate)) frames, ffmpeg \(ref.frames)")
        #expect(s.waveform.count == ref.waveform.count)
        #expect(zip(s.waveform, ref.waveform).allSatisfy { abs($0 - $1) <= 1 }, "\(name): \(s.waveform) vs \(ref.waveform)")
    }

    /// Any chunk equals the same stretch of a full decode (the warm-up makes it exact). Streams
    /// with perceptual noise substitution differ in their noise bands: the noise generator runs
    /// through the whole stream (as FFmpeg's), so a later start draws different noise.
    static let usesPNS: Set<String> = ["mono_22050_48k.m4a"]

    @Test(arguments: refs.keys.sorted())
    func chunksAgreeWithTheWholeDecode(name: String) async throws {
        let d = MediaDecoder(), bytes = Self.bytes(name)
        let whole = try await d.decodeAudio(bytes, startFrame: 0, maxFrames: .max).validated(requestedStart: 0, maxFrames: .max)
        #expect(whole.frameCount == whole.totalFrames)
        let all = whole.floats, ch = whole.channels
        for start in [0, 1, 1151, 1152, 4000, whole.totalFrames / 2, whole.totalFrames - 300] {
            let c = try await d.decodeAudio(bytes, startFrame: start, maxFrames: 5000).validated(requestedStart: start, maxFrames: 5000)
            let f = c.floats
            #expect(c.frameCount == min(5000, whole.totalFrames - start))
            var worst: Float = 0
            for i in f.indices { worst = max(worst, abs(f[i] - all[start * ch + i])) }
            if Self.usesPNS.contains(name) {
                #expect(f.allSatisfy { $0.isFinite && abs($0) <= 1.5 })
            } else {
                #expect(worst < 1e-6, "\(name) @\(start): \(worst)")
            }
        }
        // Past the end: an empty chunk.
        let tail = try await d.decodeAudio(bytes, startFrame: whole.totalFrames + 10, maxFrames: 100)
        #expect(tail.frameCount == 0 && tail.startFrame == whole.totalFrames)
    }

    @Test func notAudio() async {
        await #expect(throws: MediaProcessingError.self) { try await MediaDecoder().audioSummary(Data("hello world, not audio".utf8)) }
        await #expect(throws: MediaProcessingError.self) { try await MediaDecoder().audioSummary(Data([0xFF, 0xFB, 0x90, 0x00] + Array(repeating: 0, count: 50))) }
    }

    @Test func voiceNoteSession() async throws {
        let d = MediaDecoder()
        let rate = 48000
        let id = try await d.startVoiceNote(sampleRate: rate)
        var n = 0
        for _ in 0 ..< 200 {   // 128-sample render quanta, ≈ 0.53 s
            let chunk = (0 ..< 128).map { i -> Float in Float(0.3 * sin(2 * Double.pi * 220 * Double(n + i) / Double(rate))) }
            n += 128
            try await d.appendVoiceNote(id, samples: chunk)
        }
        let note = try await d.finishVoiceNote(id).validated()
        #expect(abs(note.duration - Double(n) / Double(rate)) < 1e-9)
        #expect(!note.waveform.isEmpty && note.waveform.count <= 100)
        // The recording plays back with the same duration (the tag's delay and padding trim it).
        let s = try await d.audioSummary(note.data).validated()
        #expect(s.sampleRate == 32000 && s.channels == 1)
        #expect(abs(s.duration - note.duration) < 1.0 / 32000 + 1e-9, "\(s.duration) vs \(note.duration)")
        await #expect(throws: MediaProcessingError.self) { try await d.appendVoiceNote(id, samples: [0]) }
        let other = try await d.startVoiceNote(sampleRate: 44100)
        await d.cancelVoiceNote(other)
        await #expect(throws: MediaProcessingError.self) { try await d.finishVoiceNote(other) }
    }
}
