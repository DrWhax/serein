// AV1 video (inter frames) against dav1d, frame by frame: AV1_VIDEO=<ivf>:<framemd5> decodes an
// IVF file and compares every output frame's MD5 with ffmpeg's framemd5 of libdav1d.

import CodecCore
import Foundation
import Testing
@testable import VideoAV1

/// The frames of an IVF file (32-byte header, then a 12-byte header per frame).
func ivfFrames(_ data: [UInt8]) -> [[UInt8]] {
    guard data.count >= 32, data[0] == 0x44, data[1] == 0x4B, data[2] == 0x49, data[3] == 0x46 else { return [] }
    let headerLen = Int(data[6]) | Int(data[7]) << 8
    var pos = headerLen
    var out: [[UInt8]] = []
    while pos + 12 <= data.count {
        let size = Int(data[pos]) | Int(data[pos + 1]) << 8 | Int(data[pos + 2]) << 16 | Int(data[pos + 3]) << 24
        pos += 12
        guard pos + size <= data.count else { break }
        out.append(Array(data[pos..<(pos + size)]))
        pos += size
    }
    return out
}

/// ffmpeg framemd5: the hash column of each frame line.
func frameMD5s(_ text: String) -> [String] {
    text.split(separator: "\n").filter { !$0.hasPrefix("#") }.compactMap { $0.split(separator: ",").last?.trimmingCharacters(in: .whitespaces) }
}

@Suite struct AV1VideoFileCompare {
    @Test func compareFile() throws {
        guard let spec = ProcessInfo.processInfo.environment["AV1_VIDEO"] else { return }
        let parts = spec.split(separator: ":").map(String.init)
        let frames = ivfFrames([UInt8](try Data(contentsOf: URL(fileURLWithPath: parts[0]))))
        let want = frameMD5s(String(decoding: try Data(contentsOf: URL(fileURLWithPath: parts[1])), as: UTF8.self))
        let d = try AV1VideoDecoder()
        var got: [AV1Frame] = []
        let start = ContinuousClock.now
        for (i, s) in frames.enumerated() { got += d.decode(sample: ByteSlice(s), pts: Int64(i)) }
        got += d.flush()
        let elapsed = ContinuousClock.now - start
        var firstBad: Int?
        for (i, (fr, w)) in zip(got, want).enumerated() where md5Hex(rawBytes(fr)) != w { firstBad = i; break }
        print("tools:", AV1InterTool.allCases.filter { d.interStats[$0.rawValue] > 0 }.map { "\($0)" }.joined(separator: " "))
        print("av1: \(got.count) of \(want.count) frames in \(elapsed), errors \(d.errorCount), \(got.first.map { "\($0.width)x\($0.height)" } ?? ""), first mismatch: \(firstBad.map(String.init) ?? "none")")
    }
}

/// The clips of Tools/gen-av1-video-fixtures.sh, bit-exact against dav1d frame by frame, and
/// together using every inter tool the encoders produce.
@Suite struct AV1VideoTests {
    static let names = ["p1", "p1mvs", "alt", "full", "rot", "mandel", "zoom", "superres", "aq", "obmc", "cyclic"]
    static let directory = AV1Fixture.directory.appendingPathComponent("video")

    static func decode(_ name: String) throws -> (frames: [AV1Frame], want: [String], decoder: AV1VideoDecoder) {
        let samples = ivfFrames([UInt8](try Data(contentsOf: directory.appendingPathComponent("\(name).ivf"))))
        let want = frameMD5s(String(decoding: try Data(contentsOf: directory.appendingPathComponent("\(name).md5")), as: UTF8.self))
        let d = try AV1VideoDecoder()
        var frames: [AV1Frame] = []
        for (i, s) in samples.enumerated() { frames += d.decode(sample: ByteSlice(s), pts: Int64(i)) }
        frames += d.flush()
        return (frames, want, d)
    }

    @Test(arguments: names) func bitExact(_ name: String) throws {
        let (frames, want, d) = try Self.decode(name)
        #expect(d.errorCount == 0)
        #expect(frames.count == want.count, "\(name): \(frames.count) frames, dav1d \(want.count)")
        for (i, (f, w)) in zip(frames, want).enumerated() {
            #expect(md5Hex(rawBytes(f)) == w, "\(name) frame \(i)")
        }
        #expect(frames.map(\.pts) == frames.map(\.pts).sorted(), "\(name): frames out of order")
    }

    /// Dual filters and predicted segment ids: no encoder here produces them (the code follows
    /// the specification; the cyclic clip reads seg_id_predicted, always 0).
    static let notProduced: Set<AV1InterTool> = [.dualFilter, .segmentPredicted]

    @Test func everyToolIsUsed() throws {
        var total = [Int](repeating: 0, count: AV1InterTool.allCases.count)
        for name in Self.names {
            let d = try Self.decode(name).decoder
            for (k, v) in d.interStats.enumerated() { total[k] += v }
        }
        for t in AV1InterTool.allCases where !Self.notProduced.contains(t) { #expect(total[t.rawValue] > 0, "no clip uses \(t)") }
    }

    /// A clip cut short, or with a damaged frame, decodes what it can without crashing.
    @Test func damagedClipsDoNotCrash() throws {
        let samples = ivfFrames([UInt8](try Data(contentsOf: Self.directory.appendingPathComponent("rot.ivf"))))
        let d = try AV1VideoDecoder()
        for (i, s) in samples.enumerated() {
            var b = s
            if i % 3 == 1 { b = Array(b.prefix(b.count / 2)) }
            if i % 5 == 2, b.count > 10 { b[b.count / 2] ^= 0x5A }
            _ = d.decode(sample: ByteSlice(b), pts: Int64(i))
        }
        _ = d.flush()
        #expect(d.errorCount > 0)
    }
}
