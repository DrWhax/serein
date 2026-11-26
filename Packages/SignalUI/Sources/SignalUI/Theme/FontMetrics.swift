#if os(Linux)
@_spi(Qt) import SwiftUI
#else
import CoreText
import SwiftUI
#endif

extension CSSTextStyle {
    var fontMetrics: (ascent: CGFloat, descent: CGFloat, xHeight: CGFloat) {
        #if os(Linux)
        AxoFonts.register()
        return QtFontDatabase.metrics(family: fontName, size: size)
        #else
        let font = ctFont
        return (CTFontGetAscent(font), CTFontGetDescent(font), CTFontGetXHeight(font))
        #endif
    }
}
