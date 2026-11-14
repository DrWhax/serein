// Frames scaled to the player's size in the service (VideoScaling.swift): the area-averaging
// resampler is exact on whole and fractional ratios, keeps 10-bit samples, never enlarges, and
// sessions hand out frames at the size their fit shows them at.

import Foundation
import MediaXPCInterface
import Testing
@testable import SignalMediaDecoder

@Suite struct VideoScalingTests {
    @Test(arguments: [(7, 7), (8, 4), (9, 2), (3594, 1199), (2152, 720), (5, 1)])
    func tapsCoverTheInputOnce(n: Int, m: Int) {
        let t = PlaneScaler.Taps(from: n, to: m)
        let one = UInt32(1 << PlaneScaler.bits)
        var coverage = [UInt64](repeating: 0, count: n)
        for i in 0..<m {
            let ws = t.weights[i * t.count ..< (i + 1) * t.count]
            #expect(ws.reduce(0, +) == one)
            #expect(t.first[i] >= 0 && t.first[i] + t.count <= n)
            for (k, w) in ws.enumerated() { coverage[t.first[i] + k] += UInt64(w) }
        }
        // Every input sample counts m/n of a whole output in total (to rounding).
        let expected = Double(one) * Double(m) / Double(n)
        #expect(coverage.allSatisfy { abs(Double($0) - expected) <= Double(m) })
    }

    @Test func wholeRatiosAreBlockMeans() {
        // 4x2 -> 2x1: each output the mean of a 2x2 block.
        let plane: [UInt8] = [10, 20, 100, 200,
                              30, 40, 0, 4]
        #expect(PlaneScaler.scale(plane, width: 4, height: 2, to: 2, 1, bitDepth: 8) == [25, 76])
    }

    @Test func fractionalRatiosWeighByOverlap() {
        // 3 -> 2: output 0 covers input 0 and half of input 1, output 1 the other half and input 2.
        let out = PlaneScaler.scale([0, 90, 180], width: 3, height: 1, to: 2, 1, bitDepth: 8)
        #expect(out == [30, 150])
    }

    @Test func flatPlanesStayFlat() {
        let flat = [UInt8](repeating: 235, count: 37 * 23)
        #expect(PlaneScaler.scale(flat, width: 37, height: 23, to: 11, 7, bitDepth: 8).allSatisfy { $0 == 235 })
        // 10-bit, two bytes a sample (little-endian): the largest code survives.
        var deep: [UInt8] = []
        for _ in 0..<(37 * 23) { deep += [0xFF, 0x03] }
        let out = PlaneScaler.scale(deep, width: 37, height: 23, to: 11, 7, bitDepth: 10)
        #expect(out.count == 11 * 7 * 2)
        #expect(stride(from: 0, to: out.count, by: 2).allSatisfy { Int(out[$0]) | Int(out[$0 + 1]) << 8 == 1023 })
    }

    @Test func deepSamplesKeepTheirPrecision() {
        // 2 -> 1 of 10-bit 513 and 514: 513.5 rounds to 514, which 8 bits could not tell apart.
        let out = PlaneScaler.scale([0x01, 0x02, 0x02, 0x02], width: 2, height: 1, to: 1, 1, bitDepth: 10)
        #expect(Int(out[0]) | Int(out[1]) << 8 == 514)
    }

    @Test func sizesForAFit() {
        let fit = VideoFit(width: 600, height: 400)
        // Contained: the limiting side decides; even sizes; never larger than decoded.
        #expect(fit.frameSize(width: 3594, height: 2152, rotation: 0) == (600, 360))
        #expect(fit.frameSize(width: 320, height: 240, rotation: 0) == (320, 240))
        // A 90° track is shown on its side: the fit is turned to the decoded orientation.
        #expect(fit.frameSize(width: 3594, height: 2152, rotation: 90) == (400, 240))
        // Covering: the other side decides.
        #expect(VideoFit(width: 600, height: 400, cover: true).frameSize(width: 3594, height: 2152, rotation: 0) == (668, 400))
        #expect(VideoFit(width: 16, height: 16).frameSize(width: 4000, height: 10, rotation: 0) == (16, 2))
        // Shown at more than half its size: sent as decoded (the GPU's filtering is enough).
        #expect(VideoFit(width: 2880, height: 1800).frameSize(width: 3594, height: 2152, rotation: 0) == (3594, 2152))
        #expect(VideoFit(width: 1797, height: 1076).frameSize(width: 3594, height: 2152, rotation: 0).width < 3594)
    }

    @Test func fitsAreChecked() {
        #expect(throws: MediaProcessingError.self) { try VideoFit(width: 0, height: 100).validated() }
        #expect(throws: MediaProcessingError.self) { try VideoFit(width: 100, height: 1 << 20).validated() }
        #expect(throws: MediaProcessingError.self) {
            try VideoFrame(time: 0, width: 4, height: 2, y: Data(count: 8), u: Data(count: 2), v: Data(count: 2), fullRange: false, matrix: 1,
                           decodedWidth: 2, decodedHeight: 2).validated()
        }
    }

    /// The same session with and without a fit: the frames come smaller, scaled from the very
    /// frames it would have sent, and they say what size they were decoded at.
    @Test(.serialized, arguments: [("high_bframes_aac_faststart.mp4", false), ("main_rotated_90.mp4", true)])
    func sessionsScaleToTheirFit(name: String, sideways: Bool) async throws {
        let bytes = VideoServiceTests.bytes(name)
        let d = MediaDecoder()
        let (full, _) = try await d.openVideo(bytes)
        let (fitted, info) = try await d.openVideo(bytes)
        // Shown on its side (90° or 270°): the fit applies turned.
        #expect((info.rotation % 180 != 0) == sideways)
        let rotation = info.rotation
        // The view: a bubble a third of the video's display size, in display orientation.
        let fit = VideoFit(width: info.width / 3, height: info.height / 3)
        let a = try await d.videoFrames(full, count: 4)
        let b = try await d.videoFrames(fitted, count: 4, fit: fit)
        #expect(a.count == 4 && b.count == 4)
        for (f, s) in zip(a, b) {
            let (w, h) = fit.frameSize(width: f.width, height: f.height, rotation: rotation)
            #expect(s.width == w && s.height == h && s.width < f.width)
            #expect(s.decodedWidth == f.width && s.decodedHeight == f.height)
            #expect(s.time == f.time && s.matrix == f.matrix && s.fullRange == f.fullRange)
            _ = try s.validated()
            // Scaled from the same picture: the planes' means agree.
            func mean(_ p: Data) -> Double { Double(p.reduce(0) { $0 + Int($1) }) / Double(p.count) }
            #expect(abs(mean(s.y) - mean(f.y)) < 1 && abs(mean(s.u) - mean(f.u)) < 1 && abs(mean(s.v) - mean(f.v)) < 1)
        }
        // A fit larger than the video changes nothing.
        let big = try await d.videoFrames(full, count: 2, fit: VideoFit(width: 4000, height: 4000))
        #expect(big.count == 2 && big.allSatisfy { $0.width == a[0].width && $0.height == a[0].height && $0.decodedWidth == $0.width })
        // The flat wire format carries the decoded size.
        #expect(try MediaXPCWire.decodeFrames(MediaXPCWire.encodeFrames(b), maxFrames: 8) == b)
        await d.closeVideo(full)
        await d.closeVideo(fitted)
    }
}
