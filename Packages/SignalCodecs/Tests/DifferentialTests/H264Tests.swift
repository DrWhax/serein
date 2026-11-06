// VideoH264 against ffmpeg (Tools/gen-codec-references.py h264): every output frame's MD5
// (cropped I420, display order) equals ffmpeg's framemd5.

import CodecCore
import Foundation
import Testing
import ContainerMP4
@testable import VideoH264

struct H264ReferenceTests {
    struct Ref: Decodable { var width: Int; var height: Int; var frames: [String] }
    static let refs: [String: Ref] = try! JSONDecoder().decode([String: Ref].self, from: Data(Resources.bytes("H264/framemd5.json")))

    static func decode(_ name: String, threads: Int = 8) throws -> (frames: [H264Frame], error: String?) {
        let bytes = Resources.bytes("H264/" + name)
        let file = try MP4Demuxer.parse(bytes)
        let track = file.videoTracks[0]
        guard case .avc(_, _, _, let cfg) = track.sampleEntries[0] else { throw ParseFailure(offset: 0, rule: "test", reason: .invalid("not AVC")) }
        var limits = H264Decoder.Limits()
        limits.threads = threads
        var dec = try H264Decoder(sequenceParameterSets: cfg.sequenceParameterSets.map { $0.copyBytes() },
                                  pictureParameterSets: cfg.pictureParameterSets.map { $0.copyBytes() }, limits: limits)
        var frames: [H264Frame] = []
        for (i, s) in track.samples.enumerated() {
            frames += dec.decode(sample: ByteSlice(Array(bytes[s.offset ..< s.offset + s.size])), nalLengthSize: cfg.nalLengthSize, pts: s.compositionTime)
            if dec.errorCount > 0 { return (frames + dec.flush(), "sample \(i): \(String(describing: dec.lastError))") }
        }
        return (frames + dec.flush(), nil)
    }

    static func md5(_ p: YUVPicture) -> String { md5Hex(p.y + p.u + p.v) }

    @Test(arguments: refs.keys.sorted().filter { $0 != "high_1080p.mp4" })
    func matchesFFmpeg(name: String) throws {
        let ref = Self.refs[name]!
        let (frames, error) = try Self.decode(name)
        let hashes = frames.map { Self.md5($0.picture) }
        var matching = 0
        while matching < min(hashes.count, ref.frames.count) && hashes[matching] == ref.frames[matching] { matching += 1 }
        print("\(name): \(frames.count)/\(ref.frames.count) frames, first \(matching) match\(error.map { "; stopped: \($0)" } ?? "")")
        #expect(error == nil, "\(name): \(error ?? "")")
        #expect(frames.first.map { $0.picture.width == ref.width && $0.picture.height == ref.height } ?? false)
        #expect(hashes == ref.frames, "\(name): \(matching) of \(ref.frames.count) frames match")
    }
}

extension H264ReferenceTests {
    /// Development aid: H264_DEBUG_FILE=<mp4> H264_DEBUG_OUT=<yuv> decodes a file and writes
    /// the frames as raw I420.
    @Test func debugDump() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["H264_DEBUG_FILE"], let outPath = env["H264_DEBUG_OUT"] else { return }
        let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        let file = try MP4Demuxer.parse(bytes)
        let track = file.videoTracks[0]
        guard case .avc(_, _, _, let cfg) = track.sampleEntries[0] else { return }
        var dec = try H264Decoder(sequenceParameterSets: cfg.sequenceParameterSets.map { $0.copyBytes() },
                                  pictureParameterSets: cfg.pictureParameterSets.map { $0.copyBytes() })
        var out = Data()
        var frames = 0
        for (i, s) in track.samples.enumerated() {
            for f in dec.decode(sample: ByteSlice(Array(bytes[s.offset ..< s.offset + s.size])), nalLengthSize: cfg.nalLengthSize) {
                out.append(contentsOf: f.picture.y + f.picture.u + f.picture.v); frames += 1
            }
            if dec.errorCount > 0 { print("debug: sample \(i): \(String(describing: dec.lastError))"); break }
        }
        for f in dec.flush() { out.append(contentsOf: f.picture.y + f.picture.u + f.picture.v); frames += 1 }
        try out.write(to: URL(fileURLWithPath: outPath))
        print("debug: wrote \(frames) frames")
    }
}

extension H264ReferenceTests {
    /// The phone-like 1080p30 High stream: bit-exact, and the decoding speed (meaningful in
    /// release builds).
    @Test(arguments: [8]) func phone1080p(threads: Int) throws {
        let name = "high_1080p.mp4"
        let ref = Self.refs[name]!
        let start = ContinuousClock.now
        let (frames, error) = try Self.decode(name, threads: threads)
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let hashes = frames.map { Self.md5($0.picture) }
        print("threads \(threads): 1080p: \(frames.count) frames in \(fixed(seconds, 2)) s = \(fixed(Double(frames.count) / seconds, 1)) fps, \(zip(hashes, ref.frames).filter { $0 == $1 }.count) match")
        #expect(error == nil)
        #expect(hashes == ref.frames)
    }
}

struct H264HostileInputTests {
    /// Every sample of a stream with deterministic bit flips (NAL length prefixes kept), and
    /// truncations of each sample: decoding throws or yields frames, never traps.
    @Test(arguments: ["main_cabac_b_spatial.mp4", "baseline_p_cavlc_ref3.mp4", "high_8x8_cqm.mp4", "high_cavlc_8x8.mp4"])
    func corruptedStreams(name: String) throws {
        let bytes = Resources.bytes("H264/" + name)
        let file = try MP4Demuxer.parse(bytes)
        let track = file.videoTracks[0]
        guard case .avc(_, _, _, let cfg) = track.sampleEntries[0] else { return }
        let sps = cfg.sequenceParameterSets.map { $0.copyBytes() }, pps = cfg.pictureParameterSets.map { $0.copyBytes() }
        var seed: UInt32 = 4242
        // H264_STRESS=<rounds> runs many more mutation rounds (development).
        let rounds = Int(ProcessInfo.processInfo.environment["H264_STRESS"] ?? "") ?? 6
        for round in 0 ..< rounds {
            var dec = try H264Decoder(sequenceParameterSets: sps, pictureParameterSets: pps)
            var frames = 0
            for (i, s) in track.samples.enumerated() {
                var b = Array(bytes[s.offset ..< s.offset + s.size])
                if round % 2 == 0 {
                    // Flip 1–8 bits past the 4-byte length prefix and the NAL header.
                    for _ in 0 ..< 1 + (i + round) % 8 where b.count > 6 {
                        seed = seed &* 1_664_525 &+ 1_013_904_223
                        let bit = 40 + Int(seed >> 8) % ((b.count - 5) * 8)
                        b[bit / 8] ^= UInt8(0x80) >> UInt8(bit % 8)
                    }
                } else {
                    // Truncate (fixing the length prefix).
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    let keep = 6 + Int(seed >> 8) % max(1, b.count - 6)
                    b = Array(b.prefix(keep))
                    let n = keep - 4
                    b[0] = UInt8(n >> 24 & 0xFF); b[1] = UInt8(n >> 16 & 0xFF); b[2] = UInt8(n >> 8 & 0xFF); b[3] = UInt8(n & 0xFF)
                }
                let out = dec.decode(sample: ByteSlice(b), nalLengthSize: cfg.nalLengthSize)
                frames += out.count
                #expect(out.allSatisfy { $0.picture.y.count == $0.picture.width * $0.picture.height })
            }
            frames += dec.flush().count
            // Every picture comes out, concealed where damaged (a damaged header may merge or
            // split pictures, so allow some slack).
            #expect(frames >= track.samples.count / 2, "\(name) round \(round): \(frames) of \(track.samples.count) frames")
        }
        // Parameter sets themselves damaged.
        for k in 0 ..< 64 {
            var s0 = sps[0]
            s0[1 + k % (s0.count - 1)] ^= UInt8(1 << (k % 8))
            _ = try? H264Decoder(sequenceParameterSets: [s0], pictureParameterSets: pps)
        }
    }
}
