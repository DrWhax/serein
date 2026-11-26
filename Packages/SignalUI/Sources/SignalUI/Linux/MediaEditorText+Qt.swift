#if os(Linux)
@_spi(Qt) import SwiftUI

extension MediaEditorText {
    static func font(_ size: CGFloat, name: String = AxoFonts.interName(weight: 700)) -> Font {
        AxoFonts.register()
        return .custom(name, fixedSize: size)
    }

    static func editorFont(_ size: CGFloat) -> Font { font(size) }

    static func width(_ text: String, font: Font) -> CGFloat {
        QtTextLayout.lines(in: AttributedString(text), font: font).first?.advance ?? 0
    }

    static func draw(_ text: String, fontSize: CGFloat, fontName: String = AxoFonts.interName(weight: 700), fill: RGBA,
                     stroke: RGBA?, background: RGBA?, in context: GraphicsContext) {
        let face = font(fontSize, name: fontName)
        let glyphBox = fontSize * sizeMult
        var top = -size(text, fontSize: fontSize).height / 2
        for line in text.components(separatedBy: "\n") {
            let width = width(line, font: face)
            if let background, width > 0 {
                context.fill(Path(CGRect(x: -width / 2, y: top, width: width, height: glyphBox)), with: .color(background.swiftUIColor))
            }
            if !line.isEmpty {
                var label = context.resolve(Text(verbatim: line).font(face).foregroundColor(fill.swiftUIColor))
                if let stroke { label.strokeGlyphs(color: stroke.swiftUIColor, lineWidth: 2) }
                let baseline = label.firstBaseline(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity))
                context.draw(label, at: CGPoint(x: 0, y: top + glyphBox - fontSize * sizeFraction - baseline), anchor: .top)
            }
            top += glyphBox * lineHeight
        }
    }
}
#endif
