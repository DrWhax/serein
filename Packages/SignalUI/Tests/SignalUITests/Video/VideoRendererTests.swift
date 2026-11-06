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
