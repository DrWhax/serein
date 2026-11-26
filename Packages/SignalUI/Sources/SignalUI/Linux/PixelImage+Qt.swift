#if os(Linux)
@_spi(Qt) import SwiftUI

extension PixelImage {
    @ViewBuilder var qtRaster: some View {
        if let raster = Image(rgba8: image.pixels, width: image.width, height: image.height, scale: image.scale) {
            raster.resizable()
        }
    }
}
#endif
