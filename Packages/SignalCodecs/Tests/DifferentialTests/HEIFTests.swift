// HEIC and AVIF against ImageIO (Apple's decoders as an oracle on trusted fixtures). ImageIO
// reports irot / imir as an orientation instead of applying them, so geometry is checked
// against libavif in ImageHEIFTests; here only files without transforms are compared. Its
// 4:2:0 chroma upsampling differs from libavif's (which ours matches) on the test pattern's
// sharp colour edges (worst cases over 100 there), so colour is only checked for gross errors
// by its mean (a wrong matrix, swapped planes or misplaced tiles give means far over 10;
// exactness is ImageHEIFTests' job), and alpha, which needs no conversion, exactly.

import CodecCore
import Foundation
import ImageHEIF
import Testing

@Suite struct HEIFImageIOTests {
    @Test(arguments: ["heicgrid.heic", "heicalpha.heic", "avif8.avif", "avif10.avif", "avifgridalpha.avif"])
    func matchesImageIO(name: String) throws {
        let bytes = Resources.bytes("HEIF/" + name)
        let ours = try HEIFDecoder.decode(bytes, codecs: [.hevc, .av1]).image
        let ref = try #require(ImageIOOracle.frame(bytes, index: 0), "ImageIO decodes \(name)")
        try #require(ref.width == ours.width && ref.height == ours.height, "\(name): \(ours.width)x\(ours.height) vs \(ref.width)x\(ref.height)")
        let mine = premultiplied(ours)
        var worst = 0, sum = 0, alphaWorst = 0
        for i in 0..<mine.count {
            let e = abs(Int(mine[i]) - Int(ref.rgba[i]))
            if i % 4 == 3 { alphaWorst = max(alphaWorst, e); continue }
            worst = max(worst, e)
            sum += e
        }
        let mean = Double(sum) / Double(mine.count / 4 * 3)
        print("HEIF vs ImageIO \(name): colour worst \(worst), mean \(fixed(mean, 3)); alpha worst \(alphaWorst)")
        #expect(mean < 6, "\(name): colour mean \(fixed(mean, 3)), worst \(worst)")
        #expect(alphaWorst == 0, "\(name): alpha worst \(alphaWorst)")
    }
}
