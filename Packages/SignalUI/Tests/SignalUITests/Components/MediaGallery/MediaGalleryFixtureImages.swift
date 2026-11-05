// Decodes the captures' blurhash previews (data:image/bmp;base64 URLs) and fixture paths.

import Foundation
import ImageBMP
@testable import SignalUI

func fixtureDataURLImage(_ src: String) -> RGBAImage? {
    if src.hasPrefix("/fixtures/") { return src.hasSuffix(".png") ? fixturePNG(String(src.dropFirst(10))) : fixtureByURL(src) }
    guard let comma = src.firstIndex(of: ","), let data = Data(base64Encoded: String(src[src.index(after: comma)...])),
          let buffer = try? BMPDecoder.decode([UInt8](data)) else { return nil }
    return RGBAImage(buffer)
}
