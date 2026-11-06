// H2+: decoded pictures of the generated clips, bit-exact against ffmpeg's framemd5.

import CodecCore
import ContainerMP4
import CryptoKit
import Foundation
import Testing
@testable import VideoHEVC

extension HEVCFixture {
    /// Every frame (output order) decoded by VideoHEVC.
    func decodeAll() throws -> (frames: [HEVCFrame], errors: Int) {
        let d = try HEVCDecoder(vps: config.videoParameterSets.map { $0.copyBytes() }, sps: config.sequenceParameterSets.map { $0.copyBytes() },
                                pps: config.pictureParameterSets.map { $0.copyBytes() }, nalLengthSize: config.nalLengthSize)
        var frames: [HEVCFrame] = []
        for (i, s) in samples().enumerated() { frames += d.decode(sample: ByteSlice(s), pts: Int64(i)) }
        frames += d.flush()
        return (frames, d.errorCount)
    }

    /// The MD5s ffmpeg's framemd5 lists (one per output frame).
    func expectedMD5s() throws -> [String] {
        String(decoding: try golden("framemd5"), as: UTF8.self).split(separator: "\n").filter { !$0.hasPrefix("#") }.compactMap {
            $0.split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces) }
        }
    }
}

/// framemd5's hash: Y, U, V planes packed (8-bit samples as bytes, deeper as 16-bit LE).
func md5(_ f: HEVCFrame) -> String {
    var bytes: [UInt8] = []
    for plane in [f.y, f.u, f.v] {
        for s in plane {
            if f.bitDepth == 8 { bytes.append(UInt8(s)) } else { bytes.append(UInt8(s & 0xFF)); bytes.append(UInt8(s >> 8)) }
        }
    }
    return Insecure.MD5.hash(data: bytes).map { String($0, radix: 16).leftPadded(2) }.joined()
}

extension String {
    func leftPadded(_ n: Int, _ pad: Character = "0") -> String { count >= n ? self : String(repeating: pad, count: n - count) + self }
}

@Suite struct HEVCDecodeTests {
    @Test(arguments: ["intra8_nolf", "intra10_nolf", "intra8big_nolf", "lossless_nolf", "scaling_intra_nolf", "intra8", "intra10",
                       "ipb8", "ipb10", "scaling8", "tiles8", "vt10"]) func intraBitExact(_ name: String) throws {
        let f = try HEVCFixture(name)
        let (frames, errors) = try f.decodeAll()
        let expected = try f.expectedMD5s()
        #expect(errors == 0)
        #expect(!expected.isEmpty)
        #expect(frames.count == expected.count, "decoded \(frames.count), expected \(expected.count)")
        print("HEVC \(name): \(frames.count) frames, first \(frames.first.map(md5) ?? "-") want \(expected.first ?? "-")")
        for (i, (frame, want)) in zip(frames, expected).enumerated() {
            #expect(md5(frame) == want, "frame \(i)")
        }
    }
}

/// Debugging aid: HEVC_DEBUG=<fixture>:<raw ffmpeg yuv> reports the first differing sample.
@Suite struct HEVCDebugCompare {
    @Test func firstMismatch() throws {
        guard let spec = ProcessInfo.processInfo.environment["HEVC_DEBUG"] else { return }
        let parts = spec.split(separator: ":").map(String.init)
        let f = try HEVCFixture(parts[0])
        let (frames, errors) = try f.decodeAll()
        let ref = [UInt8](try Data(contentsOf: URL(fileURLWithPath: parts[1])))
        print("debug: \(frames.count) frames, \(errors) errors")
        var off = 0
        for (fi, fr) in frames.enumerated() {
            let bps = fr.bitDepth > 8 ? 2 : 1
            for (pi, (plane, w)) in [(fr.y, fr.width), (fr.u, fr.chromaWidth), (fr.v, fr.chromaWidth)].enumerated() {
                for (i, s) in plane.enumerated() {
                    let r = bps == 1 ? Int(ref[off]) : Int(ref[off]) | Int(ref[off + 1]) << 8
                    off += bps
                    if Int(s) != r {
                        print("debug: frame \(fi) plane \(pi) first mismatch at (\(i % w), \(i / w)): got \(s) want \(r)")
                        return
                    }
                }
            }
        }
        print("debug: all equal")
    }
}

/// Debugging aid: HEVC_MD5=<mp4>:<framemd5>:<frames> decodes a file and compares frame MD5s.
@Suite struct HEVCFileCompare {
    @Test func compareFile() throws {
        guard let spec = ProcessInfo.processInfo.environment["HEVC_MD5"] else { return }
        let parts = spec.split(separator: ":").map(String.init)
        let f = try HEVCFixture(parts[0])
        let want = String(decoding: try Data(contentsOf: URL(fileURLWithPath: parts[1])), as: UTF8.self).split(separator: "\n")
            .filter { !$0.hasPrefix("#") }.compactMap { $0.split(separator: ",").last?.trimmingCharacters(in: .whitespaces) }
        let limit = Int(parts[2]) ?? 30
        let d = try HEVCDecoder(vps: f.config.videoParameterSets.map { $0.copyBytes() }, sps: f.config.sequenceParameterSets.map { $0.copyBytes() },
                                pps: f.config.pictureParameterSets.map { $0.copyBytes() }, nalLengthSize: f.config.nalLengthSize)
        var frames: [HEVCFrame] = []
        let start = ContinuousClock.now
        for (i, s) in f.samples().enumerated() {
            frames += d.decode(sample: ByteSlice(s), pts: Int64(i))
            if frames.count >= limit { break }
        }
        if frames.count < limit { frames += d.flush() }
        let elapsed = ContinuousClock.now - start
        var firstBad: Int?
        for (i, (fr, w)) in zip(frames.prefix(limit), want).enumerated() where md5(fr) != w { firstBad = i; break }
        print("file: \(min(frames.count, limit)) frames in \(elapsed), errors \(d.errorCount), \(frames.first.map { "\($0.width)x\($0.height) \($0.bitDepth)-bit" } ?? ""), first mismatch: \(firstBad.map(String.init) ?? "none")")
    }
}

/// Debugging aid: HEVC_MATCH=<mp4>:<raw yuv of one frame> → mismatching luma samples vs each early frame.
@Suite struct HEVCFrameMatch {
    @Test func match() throws {
        guard let spec = ProcessInfo.processInfo.environment["HEVC_MATCH"] else { return }
        let parts = spec.split(separator: ":").map(String.init)
        let f = try HEVCFixture(parts[0])
        let ref = [UInt8](try Data(contentsOf: URL(fileURLWithPath: parts[1])))
        let d = try HEVCDecoder(vps: f.config.videoParameterSets.map { $0.copyBytes() }, sps: f.config.sequenceParameterSets.map { $0.copyBytes() },
                                pps: f.config.pictureParameterSets.map { $0.copyBytes() }, nalLengthSize: f.config.nalLengthSize)
        var frames: [HEVCFrame] = []
        for (i, s) in f.samples().enumerated() { frames += d.decode(sample: ByteSlice(s), pts: Int64(i)); if frames.count >= 8 { break } }
        for (k, fr) in frames.enumerated() {
            var bad = 0, firstBad: (Int, Int)?
            for (i, s) in fr.y.enumerated() {
                let r = Int(ref[2 * i]) | Int(ref[2 * i + 1]) << 8
                if Int(s) != r { bad += 1; if firstBad == nil { firstBad = (i % fr.width, i / fr.width) } }
            }
            print("match: frame \(k) poc \(fr.poc): \(bad) of \(fr.y.count) luma samples differ, first \(firstBad.map { "\($0)" } ?? "-")")
            if k == 0 {
                // Per 32x32 block of the first rows: mismatching samples (to see where it starts).
                var line = ""
                for by in 0..<3 {
                    for bx in 0..<12 {
                        var n = 0
                        for y in (by * 32)..<(by * 32 + 32) { for x in (bx * 32)..<(bx * 32 + 32) {
                            let i = x + y * fr.width
                            if Int(fr.y[i]) != (Int(ref[2 * i]) | Int(ref[2 * i + 1]) << 8) { n += 1 }
                        } }
                        line += String(n).leftPadded(5, " ")
                    }
                    line += "\n"
                }
                print("match: block mismatches (first 3 CTB rows x 12):\n\(line)")
                print("match: samples (0..8, 0): got \(fr.y[0..<8].map { $0 }) want \((0..<8).map { Int(ref[2 * $0]) | Int(ref[2 * $0 + 1]) << 8 })")
            }
        }
    }
}
