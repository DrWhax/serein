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

    // One at a time: the service allows `VideoLimits.maxSessions` open videos and the other
    // video suites run alongside.
    @Test(.serialized, arguments: refs.keys.sorted())
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

/// HEVC Main10 HLG (an Android / iPhone HDR recording in miniature).
@Suite struct HEVCVideoTests {
    static let clip = Bundle.module.resourceURL!.appendingPathComponent("Resources/Video/hlg10.mp4")

    @Test func hevcSessionsDecodeTagged() async throws {
        let d = MediaDecoder()
        let bytes = try Data(contentsOf: Self.clip)
        let info = try await d.videoInfo(bytes)
        #expect(info.width == 128 && info.height == 72)
        let (session, _) = try await d.openVideo(bytes)
        var frames: [VideoFrame] = []
        while true {
            let next = try await d.videoFrames(session, count: 4)
            if next.isEmpty { break }
            frames += try next.map { try $0.validated() }
        }
        #expect(frames.count == 6)
        #expect(frames.allSatisfy { $0.matrix == 9 && $0.transfer == 18 && $0.width == 128 })
        // Playback keeps the 10 bits: two bytes per sample, the luma of a real picture above 8-bit range.
        #expect(frames.allSatisfy { $0.bitDepth == 10 && $0.y.count == 128 * 72 * 2 })
        let first = frames[0].y
        #expect(stride(from: 0, to: first.count, by: 2).contains { Int(first[$0]) | Int(first[$0 + 1]) << 8 > 255 })
        // The flat wire format round-trips them.
        #expect(try MediaXPCWire.decodeFrames(MediaXPCWire.encodeFrames(frames), maxFrames: 8) == frames)
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $0.time < $1.time })
        try await d.seekVideo(session, to: 0)
        #expect(try await d.videoFrames(session, count: 1).count == 1)
        await d.closeVideo(session)
        let poster = try await d.posterFrame(bytes)
        #expect(poster.width == 128 && poster.height == 72 && poster.png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
    }
}

/// Throughput of the service's video sessions (HEVC_SESSION=<mp4>): frames per second.
@Suite struct VideoSessionSpeed {
    @Test func throughput() async throws {
        guard let path = ProcessInfo.processInfo.environment["HEVC_SESSION"] else { return }
        let d = MediaDecoder()
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let (s, _) = try await d.openVideo(bytes)
        let start = ContinuousClock.now
        var n = 0
        while n < 120 {
            let f = try await d.videoFrames(s, count: 8)
            if f.isEmpty { break }
            let wire = MediaXPCWire.encodeFrames(f)
            _ = try MediaXPCWire.decodeFrames(wire, maxFrames: VideoLimits.maxFramesPerRequest).map { try $0.validated() }
            n += f.count
        }
        let t = ContinuousClock.now - start
        await d.closeVideo(s)
        print("session: \(n) frames in \(t) (\(Double(n) / (Double(t.components.seconds) + Double(t.components.attoseconds) / 1e18)) fps) incl. XPC encoding")
    }
}
