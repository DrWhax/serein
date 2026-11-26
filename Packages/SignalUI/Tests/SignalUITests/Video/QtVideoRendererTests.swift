#if os(Linux)
import Testing
@testable import SignalUI

struct QtVideoRendererTests {
    @Test func limitedRangeRotationAndMirroring() throws {
        let row: [UInt8] = [16, 235, 126]
        var frame = VideoPlanes(width: 3, height: 2, y: row + row, u: [128, 128], v: [128, 128], fullRange: false, matrix: 1, time: 0)
        let normal = try #require(VideoRenderer.image(frame))
        #expect(normal.pixels[0] == 0 && normal.pixels[4] == 255 && abs(Int(normal.pixels[8]) - 128) <= 1)
        let rotated = try #require(VideoRenderer.image(frame, rotation: 90))
        #expect(rotated.width == 2 && rotated.height == 3 && rotated.pixels[8] == 255)
        let mirrored = try #require(VideoRenderer.image(frame, mirrored: true))
        #expect(mirrored.pixels[0] == normal.pixels[8] && mirrored.pixels[8] == 0)
        frame.width = Int.max
        #expect(VideoRenderer.image(frame) == nil)
    }

    @Test func highDepthAndHDR() throws {
        let frame = VideoPlanes(width: 2, height: 2, y: [16, 235, 126, 126], u: [128], v: [128], fullRange: false, matrix: 1, time: 0)
        let reference = try #require(VideoRenderer.image(frame))
        for depth in 9...12 {
            func promote(_ plane: [UInt8]) -> [UInt8] {
                plane.flatMap { sample in
                    let word = UInt16(sample) << (depth - 8)
                    return [UInt8(truncatingIfNeeded: word), UInt8(word >> 8)]
                }
            }
            var deep = frame
            deep.bitDepth = depth
            deep.y = promote(frame.y)
            deep.u = promote(frame.u)
            deep.v = promote(frame.v)
            #expect(VideoRenderer.image(deep)?.pixels == reference.pixels)
            for transfer in [16, 18] {
                deep.matrix = 9
                deep.transfer = transfer
                let mapped = try #require(VideoRenderer.image(deep))
                #expect(mapped.pixels[0] == 0 && mapped.pixels[4] > mapped.pixels[8])
            }
        }
    }
}
#endif
