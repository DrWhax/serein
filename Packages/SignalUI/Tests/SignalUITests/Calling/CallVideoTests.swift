import CoreImage
import Metal
import Testing
@testable import SignalUI

@MainActor
@Suite struct CallVideoTests {
    /// Planes with stride padding are packed tight; any inconsistent size is refused.
    @Test func packNV12Planes() throws {
        let w = 4, h = 2, ys = 8, uvs = 6
        var y = [UInt8](repeating: 0xEE, count: ys * h), uv = [UInt8](repeating: 0xEE, count: uvs * (h / 2))
        for r in 0..<h { for c in 0..<w { y[r * ys + c] = UInt8(r * 10 + c) } }
        for c in 0..<w { uv[c] = UInt8(100 + c) }
        let f = try #require(CaptureFrames.pack(width: w, height: h, planes: [(h, w, ys, y), (h / 2, w / 2, uvs, uv)]))
        #expect(f.nv12 == [0, 1, 2, 3, 10, 11, 12, 13, 100, 101, 102, 103])
        #expect(f.planes.u == [100, 102] && f.planes.v == [101, 103] && f.planes.y == [0, 1, 2, 3, 10, 11, 12, 13])

        #expect(CaptureFrames.pack(width: 3, height: 2, planes: [(2, 3, 8, y), (1, 1, 6, uv)]) == nil)              // odd width
        #expect(CaptureFrames.pack(width: w, height: h, planes: [(h, w, 2, y), (1, 2, uvs, uv)]) == nil)            // stride < width
        #expect(CaptureFrames.pack(width: w, height: h, planes: [(h, w, ys, Array(y.prefix(9))), (1, 2, uvs, uv)]) == nil) // short plane
        #expect(CaptureFrames.pack(width: w, height: h, planes: [(h, w, ys, y)]) == nil)                           // one plane
        #expect(CaptureFrames.pack(width: w, height: h, planes: [(h, w, ys, y), (2, 2, uvs, uv)]) == nil)           // chroma rows
        #expect(CapturedFrame(width: 4, height: 2, nv12: [UInt8](repeating: 0, count: 11)) == nil)
    }

    @Test func captureFormatChoice() {
        let formats = [(width: 1920, height: 1080, maxRate: 30.0), (width: 1280, height: 720, maxRate: 30.0), (width: 960, height: 540, maxRate: 30.0),
                       (width: 640, height: 480, maxRate: 60.0), (width: 960, height: 720, maxRate: 15.0)]
        // 960×720 fits but only reaches 15 fps; the largest fitting area still wins (as getUserMedia's ideal size).
        #expect(CameraCapture.bestFormat(formats, maxWidth: 960, maxHeight: 720, framerate: 30) == 4)
        #expect(CameraCapture.bestFormat(formats, maxWidth: 640, maxHeight: 480, framerate: 30) == 3)
        // Nothing fits: the smallest format, scaled down on output.
        #expect(CameraCapture.bestFormat([(width: 1920, height: 1080, maxRate: 30), (width: 1280, height: 720, maxRate: 30)],
                                         maxWidth: 640, maxHeight: 480, framerate: 30) == 1)
        #expect(CameraCapture.outputSize(width: 1280, height: 720, maxWidth: 640, maxHeight: 480) == (640, 360))
        #expect(CameraCapture.outputSize(width: 720, height: 1280, maxWidth: 960, maxHeight: 720) == (540, 960))
        #expect(CameraCapture.outputSize(width: 640, height: 480, maxWidth: 960, maxHeight: 720) == (640, 480))
    }

    /// Remote RGBA frames draw as-is, contained, and mirrored when asked.
    @Test func rgbaFramesRender() throws {
        let r = try #require(VideoRenderer(pixelFormat: .rgba8Unorm))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 2, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        func render(_ mirrored: Bool) throws -> [UInt8] {
            let target = try #require(r.device.makeTexture(descriptor: d))
            // Left half red, right half blue.
            let px: [UInt8] = [255, 0, 0, 255, 255, 0, 0, 255, 0, 0, 255, 255, 0, 0, 255, 255,
                               255, 0, 0, 255, 255, 0, 0, 255, 0, 0, 255, 255, 0, 0, 255, 255]
            let cb = try #require(r.draw(RGBAFrame(width: 4, height: 2, pixels: px), into: target, mirrored: mirrored))
            cb.commit()
            cb.waitUntilCompleted()
            let ci = try #require(CIImage(mtlTexture: target, options: [.colorSpace: NSNull()]))
            let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
            let cg = try #require(ctx.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: nil))
            let data = try #require(cg.dataProvider?.data) as Data
            return Array(data.prefix(16))
        }
        let plain = try render(false), mirrored = try render(true)
        #expect(plain[0] > 200 && plain[2] < 50 && plain[12] < 50 && plain[14] > 200)
        #expect(mirrored[0] < 50 && mirrored[2] > 200 && mirrored[12] > 200 && mirrored[14] < 50)
        #expect(r.draw(RGBAFrame(width: 4, height: 2, pixels: [0, 0, 0]), into: try #require(r.device.makeTexture(descriptor: d))) == nil)
    }
}
