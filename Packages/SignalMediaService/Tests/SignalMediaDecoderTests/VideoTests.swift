// The service's video requests against ffmpeg (Tools/gen-codec-references.py videoservice):
// metadata, the poster frame (first frame as displayed), playback sessions (every frame
// bit-exact, in display order, with its time) and seeking.

import CodecCore
import CryptoKit
import Foundation
import ImagePNG
import MediaXPCInterface
import Testing
@testable import SignalMediaDecoder

struct VideoServiceTests {
    struct Ref: Decodable { var frames: [String]; var times: [Double]; var displayWidth: Int; var displayHeight: Int }
    static let dir = Bundle.module.resourceURL!.appendingPathComponent("Resources/Video")
    static let refs: [String: Ref] = try! JSONDecoder().decode([String: Ref].self, from: Data(contentsOf: dir.appendingPathComponent("references.json")))
    static func bytes(_ name: String) -> Data { try! Data(contentsOf: dir.appendingPathComponent(name)) }
    static func md5(_ f: VideoFrame) -> String { Insecure.MD5.hash(data: f.y + f.u + f.v).map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined() }

    @Test(arguments: refs.keys.sorted())
    func infoAndPoster(name: String) async throws {
        let ref = Self.refs[name]!
        let d = MediaDecoder()
        let info = try await d.videoInfo(Self.bytes(name)).validated()
        #expect(info.width == ref.displayWidth && info.height == ref.displayHeight, "\(info)")
        #expect(abs(info.duration - (ref.times.last! + (ref.times.count > 1 ? ref.times[1] - ref.times[0] : 0))) < 0.05)
        let poster = try await d.posterFrame(Self.bytes(name)).validated()
        #expect(poster.width == ref.displayWidth && poster.height == ref.displayHeight)
        // Against ffmpeg's RGB of the displayed first frame: a different chroma upsampling, so
        // compared on average.
        let decoded = try PNGDecoder.decode(Array(poster.png)).stillImage
        let rgb = [UInt8](try Data(contentsOf: Self.dir.appendingPathComponent(name + ".frame0.rgb")))
        #expect(decoded.width == poster.width && rgb.count == poster.width * poster.height * 3)
        var sum = 0
        for i in 0 ..< poster.width * poster.height { for c in 0 ..< 3 { sum += abs(Int(decoded.rgba[i * 4 + c]) - Int(rgb[i * 3 + c])) } }
        let mean = Double(sum) / Double(poster.width * poster.height * 3)
        #expect(mean < 3, "\(name): mean |Δ| \(mean)")
    }

    @Test(arguments: refs.keys.sorted())
    func sessionFramesMatchFFmpeg(name: String) async throws {
        let ref = Self.refs[name]!
        let d = MediaDecoder()
        let (id, _) = try await d.openVideo(Self.bytes(name))
        var frames: [VideoFrame] = []
        while true {
            let batch = try await d.videoFrames(id, count: 5)
            if batch.isEmpty { break }
            frames += try batch.map { try $0.validated() }
        }
        #expect(frames.map(Self.md5) == ref.frames)
        #expect(zip(frames.map(\.time), ref.times).allSatisfy { abs($0 - $1) < 1e-6 })
        // Seek to the middle: decoding restarts at a sync sample at or before it and the frames
        // from the target on match.
        let target = ref.times[ref.times.count / 2]
        try await d.seekVideo(id, to: target)
        var after: [VideoFrame] = []
        while after.filter({ $0.time >= target - 1e-6 }).count < 3 {
            let b = try await d.videoFrames(id, count: 8)
            if b.isEmpty { break }
            after += b
        }
        #expect(after.first.map { $0.time <= target + 1e-6 } ?? false)
        let fromTarget = after.filter { $0.time >= target - 1e-6 }
        let k = ref.times.count / 2
        #expect(fromTarget.prefix(3).map(Self.md5) == Array(ref.frames[k ..< k + 3]))
        await d.closeVideo(id)
        await #expect(throws: MediaProcessingError.self) { try await d.videoFrames(id, count: 1) }
    }

    @Test func notVideo() async throws {
        let d = MediaDecoder()
        await #expect(throws: MediaProcessingError.self) { try await d.videoInfo(Data("not a video".utf8)) }
        // Audio-only MP4: no video track.
        let m4a = try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Resources/Audio/stereo_48000_96k.m4a"))
        await #expect(throws: MediaProcessingError.self) { try await d.posterFrame(m4a) }
    }
}
