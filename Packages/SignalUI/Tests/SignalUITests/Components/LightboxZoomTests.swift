// LightboxZoomableImage's geometry: where the fitted image sits, the pointer pan, the keys.

import Foundation
import Testing
@testable import SignalUI

@Suite struct LightboxZoomTests {
    static func image(_ w: Int, _ h: Int) -> RGBAImage { RGBAImage(width: w, height: h, pixels: Data(count: w * h * 4)) }

    @Test func fittedInsideTheSideMargins() {
        // 200×100 in a 580×400 area: a 500px-wide box, so 500×250, centred.
        let r = LightboxZoomableImage.fittedRect(Self.image(200, 100), in: CGSize(width: 580, height: 400))
        #expect(r == CGRect(x: 40, y: 75, width: 500, height: 250))
    }

    @Test func panFollowsThePointerWhereTheImageOverflows() {
        let area = CGSize(width: 580, height: 400)
        let fitted = CGRect(x: 40, y: 75, width: 500, height: 250)
        #expect(LightboxZoomableImage.pan(zoom: 1, fitted: fitted, area: area, pointer: .zero) == .zero)
        // 2×: 1000×500, overflowing by 210 and 50 on each side.
        #expect(LightboxZoomableImage.pan(zoom: 2, fitted: fitted, area: area, pointer: .zero) == CGSize(width: 210, height: 50))
        #expect(LightboxZoomableImage.pan(zoom: 2, fitted: fitted, area: area, pointer: CGPoint(x: 580, y: 400)) == CGSize(width: -210, height: -50))
        #expect(LightboxZoomableImage.pan(zoom: 2, fitted: fitted, area: area, pointer: CGPoint(x: 290, y: 200)) == .zero)
        // 1.2×: 600×300 overflows only across.
        #expect(LightboxZoomableImage.pan(zoom: 1.2, fitted: fitted, area: area, pointer: .zero).height == 0)
    }

    @Test func keys() {
        #expect(LightboxZoomableImage.keyZoom(1, "=") == 2)
        #expect(LightboxZoomableImage.keyZoom(8, "+") == 8)
        #expect(LightboxZoomableImage.keyZoom(1, "-") == 1)
        #expect(LightboxZoomableImage.keyZoom(4, "0") == 1)
    }
}
