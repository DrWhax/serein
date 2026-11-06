import CoreImage
import Metal
import Testing
@testable import SignalUI

@MainActor
@Suite struct VideoRendererTests {
    /// Renders into an offscreen texture and reads it back (CoreImage, colour management off).
    func render(_ f: VideoPlanes, rotation: Int, width: Int, height: Int, fit: VideoRenderer.Fit = .contain) throws -> [UInt8] {
        let r = try #require(VideoRenderer(pixelFormat: .rgba8Unorm))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        let target = try #require(r.device.makeTexture(descriptor: d))
        let cb = try #require(r.draw(f, rotation: rotation, into: target, fit: fit))
        cb.commit()
        cb.waitUntilCompleted()
        let ci = try #require(CIImage(mtlTexture: target, options: [.colorSpace: NSNull()]))
        let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let cg = try #require(ctx.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: nil))
        let data = try #require(cg.dataProvider?.data) as Data
        // CoreImage puts the texture's first row last.
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width * 4 { out[y * width * 4 + x] = data[(height - 1 - y) * cg.bytesPerRow + x] }
        }
        return out
    }

    func uniform(_ w: Int, _ h: Int, y: UInt8, u: UInt8, v: UInt8, full: Bool, matrix: Int) -> VideoPlanes {
        VideoPlanes(width: w, height: h, y: Array(repeating: y, count: w * h), u: Array(repeating: u, count: (w / 2) * (h / 2)),
                    v: Array(repeating: v, count: (w / 2) * (h / 2)), fullRange: full, matrix: matrix, time: 0)
    }

    func expected(_ y: Double, _ u: Double, _ v: Double, full: Bool, bt709: Bool) -> [Double] {
        let cb = (u - 128) / 255, cr = (v - 128) / 255
        let l = full ? y / 255 : (y - 16) / 219, k = full ? 1 : 255.0 / 224
        let rgb = bt709 ? [l + 1.5748 * k * cr, l - 0.1873 * k * cb - 0.4681 * k * cr, l + 1.8556 * k * cb]
                        : [l + 1.402 * k * cr, l - 0.344136 * k * cb - 0.714136 * k * cr, l + 1.772 * k * cb]
        return rgb.map { min(max($0, 0), 1) * 255 }
    }

    @Test func colourConversion() throws {
        for (yy, u, v) in [(16, 128, 128), (235, 128, 128), (81, 90, 240), (145, 54, 34), (41, 240, 110), (128, 128, 128)] as [(UInt8, UInt8, UInt8)] {
            for (full, matrix) in [(false, 1), (false, 6), (true, 1), (true, 5)] {
                let px = try render(uniform(16, 16, y: yy, u: u, v: v, full: full, matrix: matrix), rotation: 0, width: 16, height: 16)
                let e = expected(Double(yy), Double(u), Double(v), full: full, bt709: matrix == 1)
                for c in 0 ..< 3 { #expect(abs(Double(px[8 * 64 + 32 + c]) - e[c]) <= 1.5, "Y \(yy) U \(u) V \(v) full \(full) matrix \(matrix): \(px[8 * 64 + 32 ..< 8 * 64 + 35]) vs \(e)") }
            }
        }
    }

    /// The shader's HDR → SDR path, on the CPU (BT.2020 limited range, HLG or PQ).
    func expectedHDR(_ y: Double, _ u: Double, _ v: Double, pq: Bool) -> [Double] {
        let cb = (u - 128) / 255, cr = (v - 128) / 255, l = (y - 16) / 219, k = 255.0 / 224
        var rgb = [l + 1.4746 * k * cr, l - 0.16455 * k * cb - 0.57135 * k * cr, l + 1.8814 * k * cb].map { min(max($0, 0), 1) }
        var lin: [Double]
        if pq {
            let m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
            lin = rgb.map { let e = pow($0, 1 / m2); return pow(max(e - c1, 0) / (c2 - c3 * e), 1 / m1) * 10000 / 203 }
        } else {
            let a = 0.17883277, b = 0.28466892, c = 0.55991073
            let scene = rgb.map { $0 <= 0.5 ? $0 * $0 * 3 / 12 : (exp(($0 - c) / a) + b) / 12 }
            let ys = 0.2627 * scene[0] + 0.6780 * scene[1] + 0.0593 * scene[2]
            lin = scene.map { $0 * pow(max(ys, 1e-6), 0.2) * 1000 / 203 }
        }
        let lumIn = 0.2627 * lin[0] + 0.6780 * lin[1] + 0.0593 * lin[2]
        let lumOut = lumIn <= 0.8 ? lumIn : 0.8 + 0.2 * (1 - exp(-(lumIn - 0.8) / 0.2))
        lin = lin.map { $0 * (lumIn > 0 ? lumOut / lumIn : 0) }
        let m = [[1.6605, -0.5876, -0.0728], [-0.1246, 1.1329, -0.0083], [-0.0182, -0.1006, 1.1187]]
        rgb = (0..<3).map { i in pow(min(max(m[i][0] * lin[0] + m[i][1] * lin[1] + m[i][2] * lin[2], 0), 1), 1 / 2.4) }
        return rgb.map { $0 * 255 }
    }

    @Test func hdrToSDR() throws {
        for transfer in [18, 16] {
            for (yy, u, v) in [(16, 128, 128), (180, 128, 128), (235, 128, 128), (120, 90, 200), (150, 170, 60)] as [(UInt8, UInt8, UInt8)] {
                var f = uniform(16, 16, y: yy, u: u, v: v, full: false, matrix: 9)
                f.transfer = transfer
                let px = try render(f, rotation: 0, width: 16, height: 16)
                let e = expectedHDR(Double(yy), Double(u), Double(v), pq: transfer == 16)
                for c in 0 ..< 3 { #expect(abs(Double(px[8 * 64 + 32 + c]) - e[c]) <= 2.5, "transfer \(transfer) Y \(yy) U \(u) V \(v): \(px[8 * 64 + 32 ..< 8 * 64 + 35]) vs \(e)") }
            }
        }
        // HLG reference white (75 %) is shown near SDR white, black stays black.
        var white = uniform(16, 16, y: 180, u: 128, v: 128, full: false, matrix: 9)
        white.transfer = 18
        #expect(try render(white, rotation: 0, width: 16, height: 16)[8 * 64 + 32] >= 240)
        #expect(VideoRenderer.colour(matrix: 9, transfer: 18, height: 1080) == .hlg && VideoRenderer.colour(matrix: 1, transfer: 1, height: 1080) == .bt709)
    }

    /// 10-bit planes (two bytes per sample) render as their 8-bit equivalent (code / 4), for SDR
    /// and HDR transfers, and keep the in-between steps 8-bit cannot hold.
    @Test func tenBitPlanes() throws {
        func le(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).flatMap { _ in [UInt8(v & 0xFF), UInt8(v >> 8)] } }
        func deep(_ y: Int, _ u: Int, _ v: Int, transfer: Int) -> VideoPlanes {
            VideoPlanes(width: 16, height: 16, y: le(y, 256), u: le(u, 64), v: le(v, 64), fullRange: false, matrix: 9, time: 0, transfer: transfer, bitDepth: 10)
        }
        for transfer in [1, 18, 16] {
            for (yy, u, v) in [(16, 128, 128), (180, 128, 128), (235, 128, 128), (120, 90, 200)] as [(UInt8, UInt8, UInt8)] {
                var eight = uniform(16, 16, y: yy, u: u, v: v, full: false, matrix: 9)
                eight.transfer = transfer
                let a = try render(eight, rotation: 0, width: 16, height: 16)
                let b = try render(deep(Int(yy) * 4, Int(u) * 4, Int(v) * 4, transfer: transfer), rotation: 0, width: 16, height: 16)
                for c in 0 ..< 3 { #expect(abs(Int(a[8 * 64 + 32 + c]) - Int(b[8 * 64 + 32 + c])) <= 1, "transfer \(transfer) Y \(yy): \(a[8 * 64 + 32 + c]) vs \(b[8 * 64 + 32 + c])") }
            }
        }
        // Halfway between two 8-bit greys (HLG, where steps are coarse): between their renders.
        var lo = uniform(16, 16, y: 150, u: 128, v: 128, full: false, matrix: 9), hi = uniform(16, 16, y: 151, u: 128, v: 128, full: false, matrix: 9)
        lo.transfer = 18
        hi.transfer = 18
        let mid = try render(deep(602, 512, 512, transfer: 18), rotation: 0, width: 16, height: 16)[8 * 64 + 32]
        #expect(try render(lo, rotation: 0, width: 16, height: 16)[8 * 64 + 32] <= mid && mid <= (try render(hi, rotation: 0, width: 16, height: 16)[8 * 64 + 32]))
        // Two bytes per sample are required.
        #expect(!VideoPlanes(width: 16, height: 16, y: le(64, 128), u: le(512, 64), v: le(512, 64), fullRange: false, matrix: 9, time: 0, bitDepth: 10).isValid)
    }

    /// Quadrants of different grey (TL 40, TR 100, BL 160, BR 220) rotated and letterboxed.
    @Test(arguments: [0, 90, 180, 270])
    func rotationAndFit(rotation: Int) throws {
        let w = 32, h = 16
        var y = [UInt8](repeating: 0, count: w * h)
        for j in 0 ..< h { for i in 0 ..< w { y[j * w + i] = [40, 100, 160, 220][(j >= h / 2 ? 2 : 0) + (i >= w / 2 ? 1 : 0)] } }
        let f = VideoPlanes(width: w, height: h, y: y, u: Array(repeating: 128, count: 16 * 8), v: Array(repeating: 128, count: 16 * 8), fullRange: true, matrix: 5, time: 0)
        let size = 64
        let px = try render(f, rotation: rotation, width: size, height: size)
        func grey(_ x: Int, _ y: Int) -> Int { Int(px[(y * size + x) * 4]) }
        // Display quadrant centres: which source quadrant shows there after a clockwise turn.
        let (dw, dh) = rotation % 180 == 0 ? (64, 32) : (32, 64)
        let ox = (size - dw) / 2, oy = (size - dh) / 2
        let tl = grey(ox + dw / 4, oy + dh / 4), tr = grey(ox + 3 * dw / 4, oy + dh / 4), bl = grey(ox + dw / 4, oy + 3 * dh / 4), br = grey(ox + 3 * dw / 4, oy + 3 * dh / 4)
        let expect: [Int]
        switch rotation {
        case 90: expect = [160, 40, 220, 100]
        case 180: expect = [220, 160, 100, 40]
        case 270: expect = [100, 220, 40, 160]
        default: expect = [40, 100, 160, 220]
        }
        #expect([tl, tr, bl, br].enumerated().allSatisfy { abs($1 - expect[$0]) <= 1 }, "rotation \(rotation): \([tl, tr, bl, br]) vs \(expect)")
        // Letterbox bars stay black.
        if rotation % 180 == 0 { #expect(grey(32, 2) == 0 && grey(32, 61) == 0) } else { #expect(grey(2, 32) == 0 && grey(61, 32) == 0) }
    }

    /// Cover: the 2:1 frame fills a square target, its sides cropped.
    @Test func cover() throws {
        let w = 32, h = 16
        var y = [UInt8](repeating: 0, count: w * h)
        for j in 0 ..< h { for i in 0 ..< w { y[j * w + i] = UInt8(40 + i * 5) } }
        let f = VideoPlanes(width: w, height: h, y: y, u: Array(repeating: 128, count: 16 * 8), v: Array(repeating: 128, count: 16 * 8), fullRange: true, matrix: 5, time: 0)
        let px = try render(f, rotation: 0, width: 32, height: 32, fit: .cover)
        // The middle half of the frame (columns 8…23) spans the target, top to bottom.
        func grey(_ x: Int, _ y: Int) -> Int { Int(px[(y * 32 + x) * 4]) }
        #expect(abs(grey(0, 0) - (40 + 8 * 5)) <= 3 && abs(grey(31, 31) - (40 + 23 * 5)) <= 3, "\(grey(0, 0)) \(grey(31, 31))")
        #expect(abs(grey(16, 16) - (40 + 16 * 5)) <= 3)
    }
}
